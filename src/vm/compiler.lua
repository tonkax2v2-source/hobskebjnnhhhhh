-- compiler.lua
-- Compiles a parsed Lua AST into a list of VM protos (bytecode functions).
--
-- Design notes for correctness:
--   * Every local lives in a box {v=...}. A fresh box is allocated by NEWLOCAL
--     each time a declaration is executed, so a closure created inside a loop
--     captures that iteration's box (per-iteration capture, like real Lua).
--   * `for` loops are desugared (see desugar.lua) into while + locals before we
--     get here, so the compiler only handles while/repeat/if/do/local/etc.
--   * Closures/upvalues/metatables/coroutines are provided by the host Lua: the
--     VM only encodes program structure, it does not re-implement the runtime.
--
-- A proto = {
--   numparams, is_vararg, numslots,
--   code    = { {op, a}, ... },
--   consts  = { <lua values> },
--   protos  = { <nested protos> },
--   upvals  = { {kind="local"|"upval", index=n}, ... },
-- }

local opcodes = require("src.vm.opcodes")
local OP = opcodes.OP

local Compiler = {}
Compiler.__index = Compiler

local function is_multi(e)
  local k = e.kind
  return k == "CallExpr" or k == "MethodCallExpr" or k == "VarargExpr"
end

-- Recognises the per-function encryption macro: LPH_ENCFUNC(function ... end)
-- or ENCFUNC(function ... end). Matched by name regardless of whether a local
-- no-op fallback (`local LPH_ENCFUNC = LPH_ENCFUNC or function(f) return f end`)
-- shadows it, since the name is a reserved compile-time marker.
local function is_encfunc_call(node)
  if node.kind ~= "CallExpr" then return false end
  local f = node.func
  if f.kind ~= "NameExpr" then return false end
  if f.name ~= "LPH_ENCFUNC" and f.name ~= "ENCFUNC" then return false end
  return #node.args == 1 and node.args[1].kind == "FunctionExpr"
end

local BINOP = {
  ["+"] = OP.ADD, ["-"] = OP.SUB, ["*"] = OP.MUL, ["/"] = OP.DIV,
  ["%"] = OP.MOD, ["^"] = OP.POW, ["//"] = OP.IDIV, [".."] = OP.CONCAT,
  ["&"] = OP.BAND, ["|"] = OP.BOR, ["~"] = OP.BXOR, ["<<"] = OP.SHL, [">>"] = OP.SHR,
  ["=="] = OP.EQ, ["~="] = OP.NE, ["<"] = OP.LT, ["<="] = OP.LE,
  [">"] = OP.GT, [">="] = OP.GE,
}
local UNOP = { ["-"] = OP.NEG, ["not"] = OP.NOT, ["#"] = OP.LEN, ["~"] = OP.BNOT }

local function new_proto(parent)
  return {
    parent = parent, numparams = 0, is_vararg = false, numslots = 0,
    code = {}, consts = {}, constmap = {}, protos = {}, upvals = {},
    upvalcache = {}, labels = {}, pending_gotos = {}, loops = {},
  }
end

function Compiler.new()
  return setmetatable({ proto = nil, enc = false }, Compiler)
end

----------------------------------------------------------------------
-- Low-level emission helpers
----------------------------------------------------------------------

function Compiler:emit(op, a)
  local code = self.proto.code
  code[#code + 1] = { op, a or 0 }
  return #code
end

function Compiler:here() return #self.proto.code end

function Compiler:patch(idx, target)
  self.proto.code[idx][2] = target
end

function Compiler:newslot()
  local p = self.proto
  p.numslots = p.numslots + 1
  return p.numslots
end

function Compiler:declare(decl)
  local s = self:newslot()
  decl.vm_proto = self.proto
  decl.vm_slot = s
  return s
end

function Compiler:const(v)
  local key = type(v) .. "\0" .. tostring(v)
  local map = self.proto.constmap
  if map[key] then return map[key] end
  local idx = #self.proto.consts + 1
  self.proto.consts[idx] = v
  map[key] = idx
  return idx
end

function Compiler:resolve_upval(proto, decl)
  if proto.upvalcache[decl] then return proto.upvalcache[decl] end
  local desc
  if decl.vm_proto == proto.parent then
    desc = { kind = "local", index = decl.vm_slot }
  else
    local j = self:resolve_upval(proto.parent, decl)
    desc = { kind = "upval", index = j }
  end
  local idx = #proto.upvals + 1
  proto.upvals[idx] = desc
  proto.upvalcache[decl] = idx
  return idx
end

function Compiler:emit_get_name(node)
  local d = node.ref
  if not d then self:emit(OP.GETGLOBAL, self:const(node.name)); return end
  if d.vm_proto == self.proto then
    self:emit(OP.GETLOCAL, d.vm_slot)
  else
    self:emit(OP.GETUPVAL, self:resolve_upval(self.proto, d))
  end
end

function Compiler:emit_set_name(node)
  local d = node.ref
  if not d then self:emit(OP.SETGLOBAL, self:const(node.name)); return end
  if d.vm_proto == self.proto then
    self:emit(OP.SETLOCAL, d.vm_slot)
  else
    self:emit(OP.SETUPVAL, self:resolve_upval(self.proto, d))
  end
end

----------------------------------------------------------------------
-- Expressions
----------------------------------------------------------------------

local function numval(node)
  local v = tonumber(node.text)
  if v == nil then error("vm: bad number literal '" .. tostring(node.text) .. "'") end
  return v
end

function Compiler:expr(node, want)
  want = want or 1
  local k = node.kind
  if k == "NilExpr" then self:emit(OP.PUSHNIL)
  elseif k == "TrueExpr" then self:emit(OP.PUSHTRUE)
  elseif k == "FalseExpr" then self:emit(OP.PUSHFALSE)
  elseif k == "NumberExpr" then self:emit(OP.PUSHK, self:const(numval(node)))
  elseif k == "StringExpr" then self:emit(OP.PUSHK, self:const(node.value))
  elseif k == "VarargExpr" then self:emit(OP.PUSHVARARG, want == -1 and -1 or 1)
  elseif k == "NameExpr" then self:emit_get_name(node)
  elseif k == "ParenExpr" then self:expr(node.expr, 1)
  elseif k == "IndexExpr" then
    self:expr(node.obj, 1); self:expr(node.index, 1); self:emit(OP.GETTABLE)
  elseif k == "CallExpr" then
    if is_encfunc_call(node) then
      self:compile_closure(node.args[1], true)       -- encrypted function, 1 value
    else
      self:compile_call(node, want == -1 and -1 or 1)
    end
  elseif k == "MethodCallExpr" then self:compile_methodcall(node, want == -1 and -1 or 1)
  elseif k == "FunctionExpr" then self:compile_closure(node)
  elseif k == "TableExpr" then self:compile_table(node)
  elseif k == "BinopExpr" then self:compile_binop(node)
  elseif k == "UnopExpr" then
    self:expr(node.operand, 1); self:emit(UNOP[node.op])
  else
    error("vm: cannot compile expression of kind " .. tostring(k))
  end
end

-- Pushes exactly `n` values from an expression list (Lua list adjustment).
function Compiler:exprlist_adjusted(exprs, n)
  self:emit(OP.OPENFRAME)
  local m = #exprs
  for i = 1, m do
    local last = (i == m)
    self:expr(exprs[i], (last and is_multi(exprs[i])) and -1 or 1)
  end
  self:emit(OP.ADJUST, n)
end

function Compiler:compile_call(node, nret)
  self:emit(OP.OPENFRAME)
  self:expr(node.func, 1)
  local args = node.args
  local m = #args
  for i = 1, m do
    self:expr(args[i], (i == m and is_multi(args[i])) and -1 or 1)
  end
  self:emit(OP.CALL, nret)
end

function Compiler:compile_methodcall(node, nret)
  self:emit(OP.OPENFRAME)
  self:expr(node.obj, 1)
  self:emit(OP.SELF, self:const(node.method))
  local args = node.args
  local m = #args
  for i = 1, m do
    self:expr(args[i], (i == m and is_multi(args[i])) and -1 or 1)
  end
  self:emit(OP.CALL, nret)
end

function Compiler:compile_closure(node, encrypted)
  local proto = self:compile_function(node, self.proto, encrypted)
  local idx = #self.proto.protos + 1
  self.proto.protos[idx] = proto
  self:emit(OP.CLOSURE, idx)
end

function Compiler:compile_table(node)
  self:emit(OP.NEWTABLE)
  local tslot = self:newslot()
  self:emit(OP.NEWLOCAL, tslot)
  local arrayi = 0
  local fields = node.fields
  for i, f in ipairs(fields) do
    if f.kind == "rec" then
      self:emit(OP.GETLOCAL, tslot)
      self:expr(f.value, 1)
      self:emit(OP.SETINDEXK, self:const(f.key))
    elseif f.kind == "exprkey" then
      self:emit(OP.GETLOCAL, tslot)
      self:expr(f.key, 1)
      self:expr(f.value, 1)
      self:emit(OP.SETTABLE)
    else -- list
      if i == #fields and is_multi(f.value) then
        self:emit(OP.GETLOCAL, tslot)
        self:emit(OP.OPENFRAME)
        self:expr(f.value, -1)
        self:emit(OP.SETLIST, arrayi)
      else
        arrayi = arrayi + 1
        self:emit(OP.GETLOCAL, tslot)
        self:expr(f.value, 1)
        self:emit(OP.SETINDEXI, arrayi)
      end
    end
  end
  self:emit(OP.GETLOCAL, tslot)
end

function Compiler:compile_binop(node)
  local op = node.op
  if op == "and" then
    self:expr(node.lhs, 1)
    local j = self:emit(OP.JMPIFFALSEK, 0)
    self:expr(node.rhs, 1)
    self:patch(j, self:here() + 1)
  elseif op == "or" then
    self:expr(node.lhs, 1)
    local j = self:emit(OP.JMPIFTRUEK, 0)
    self:expr(node.rhs, 1)
    self:patch(j, self:here() + 1)
  else
    self:expr(node.lhs, 1)
    self:expr(node.rhs, 1)
    self:emit(BINOP[op])
  end
end

----------------------------------------------------------------------
-- Statements
----------------------------------------------------------------------

function Compiler:compile_block(block)
  for _, s in ipairs(block.stats) do
    self:compile_stat(s)
  end
end

function Compiler:compile_stat(s)
  local k = s.kind
  if k == "LocalStat" then
    for _, d in ipairs(s.names) do
      if d.attrib == "close" then error("vm: <close> is not supported") end
    end
    self:exprlist_adjusted(s.exprs, #s.names)
    local slots = {}
    for _, d in ipairs(s.names) do slots[#slots + 1] = self:declare(d) end
    for i = #slots, 1, -1 do self:emit(OP.NEWLOCAL, slots[i]) end

  elseif k == "LocalFunctionStat" then
    local slot = self:declare(s.name)
    self:emit(OP.DECLLOCAL, slot)
    self:compile_closure(s.func)
    self:emit(OP.SETLOCAL, slot)

  elseif k == "FunctionStat" then
    self:assign_single(s.target, s.func)

  elseif k == "AssignStat" then
    if #s.targets == 1 then
      self:assign_single(s.targets[1], nil, s.exprs)
    else
      self:assign_multi(s.targets, s.exprs)
    end

  elseif k == "CallStat" then
    if is_encfunc_call(s.call) then
      self:compile_closure(s.call.args[1], true)     -- builds the closure...
      self:emit(OP.POP, 1)                            -- ...and discards it (statement)
    elseif s.call.kind == "MethodCallExpr" then
      self:compile_methodcall(s.call, 0)
    else
      self:compile_call(s.call, 0)
    end

  elseif k == "DoStat" then
    self:compile_block(s.body)

  elseif k == "WhileStat" then
    local top = self:here() + 1
    self.proto.loops[#self.proto.loops + 1] = { breaks = {} }
    self:expr(s.cond, 1)
    local jf = self:emit(OP.JMPIFFALSE, 0)
    self:compile_block(s.body)
    self:emit(OP.JMP, top)
    self:patch(jf, self:here() + 1)
    self:close_loop()

  elseif k == "RepeatStat" then
    local top = self:here() + 1
    self.proto.loops[#self.proto.loops + 1] = { breaks = {} }
    self:compile_block(s.body)
    self:expr(s.cond, 1)
    self:emit(OP.JMPIFFALSE, top)
    self:close_loop()

  elseif k == "IfStat" then
    local endjumps = {}
    for _, c in ipairs(s.clauses) do
      self:expr(c.cond, 1)
      local jf = self:emit(OP.JMPIFFALSE, 0)
      self:compile_block(c.body)
      endjumps[#endjumps + 1] = self:emit(OP.JMP, 0)
      self:patch(jf, self:here() + 1)
    end
    if s.else_body then self:compile_block(s.else_body) end
    for _, j in ipairs(endjumps) do self:patch(j, self:here() + 1) end

  elseif k == "ReturnStat" then
    if #s.exprs == 0 then
      self:emit(OP.RETURN0)
    else
      self:emit(OP.OPENFRAME)
      local m = #s.exprs
      for i = 1, m do
        self:expr(s.exprs[i], (i == m and is_multi(s.exprs[i])) and -1 or 1)
      end
      self:emit(OP.RETURN)
    end

  elseif k == "BreakStat" then
    local loops = self.proto.loops
    if #loops == 0 then error("vm: break outside loop") end
    local j = self:emit(OP.JMP, 0)
    local lc = loops[#loops]
    lc.breaks[#lc.breaks + 1] = j

  elseif k == "GotoStat" then
    local j = self:emit(OP.JMP, 0)
    self.proto.pending_gotos[#self.proto.pending_gotos + 1] = { name = s.label, idx = j }

  elseif k == "LabelStat" then
    if self.proto.labels[s.name] then
      error("vm: duplicate label '" .. s.name .. "' in function (not supported)")
    end
    self.proto.labels[s.name] = self:here() + 1

  else
    error("vm: cannot compile statement of kind " .. tostring(k))
  end
end

function Compiler:close_loop()
  local loops = self.proto.loops
  local lc = loops[#loops]
  loops[#loops] = nil
  for _, j in ipairs(lc.breaks) do self:patch(j, self:here() + 1) end
end

-- target = rhs_single, where rhs comes from either `func_node` (FunctionStat)
-- or an expression list `exprs` (AssignStat with one target).
function Compiler:assign_single(target, func_node, exprs)
  if target.kind == "NameExpr" then
    if func_node then self:expr(func_node, 1) else self:exprlist_adjusted(exprs, 1) end
    self:emit_set_name(target)
  elseif target.kind == "IndexExpr" then
    self:expr(target.obj, 1)
    self:expr(target.index, 1)
    if func_node then self:expr(func_node, 1) else self:exprlist_adjusted(exprs, 1) end
    self:emit(OP.SETTABLE)
  else
    error("vm: invalid assignment target " .. tostring(target.kind))
  end
end

function Compiler:assign_multi(targets, exprs)
  local n = #targets
  self:exprlist_adjusted(exprs, n)
  local temps = {}
  for i = 1, n do temps[i] = self:newslot() end
  for i = n, 1, -1 do self:emit(OP.NEWLOCAL, temps[i]) end
  for i = 1, n do
    local t = targets[i]
    if t.kind == "NameExpr" then
      self:emit(OP.GETLOCAL, temps[i])
      self:emit_set_name(t)
    elseif t.kind == "IndexExpr" then
      self:expr(t.obj, 1)
      self:expr(t.index, 1)
      self:emit(OP.GETLOCAL, temps[i])
      self:emit(OP.SETTABLE)
    else
      error("vm: invalid assignment target " .. tostring(t.kind))
    end
  end
end

----------------------------------------------------------------------
-- Functions / top level
----------------------------------------------------------------------

function Compiler:finalize_proto(proto)
  for _, g in ipairs(proto.pending_gotos) do
    local addr = proto.labels[g.name]
    if not addr then error("vm: goto to undefined label '" .. g.name .. "'") end
    proto.code[g.idx][2] = addr
  end
end

function Compiler:compile_function(node, parent, encrypted)
  local proto = new_proto(parent)
  -- An encrypted function encrypts its descendants too (like LPH_ENCFUNC).
  proto.encrypted = encrypted or self.enc or false
  local saved = self.proto
  local saved_enc = self.enc
  self.proto = proto
  self.enc = proto.encrypted
  proto.is_vararg = node.is_vararg and true or false
  for _, p in ipairs(node.params) do self:declare(p) end
  proto.numparams = #node.params
  self:compile_block(node.body)
  self:emit(OP.RETURN0)
  self:finalize_proto(proto)
  self.proto = saved
  self.enc = saved_enc
  return proto
end

-- Compiles a whole chunk (its Chunk.body) as a vararg main function.
function Compiler:compile_chunk(chunk)
  local main = {
    kind = "FunctionExpr",
    params = {},
    is_vararg = true,
    body = chunk.body,
  }
  return self:compile_function(main, nil)
end

local M = {}
function M.compile(chunk)
  return Compiler.new():compile_chunk(chunk)
end
M.Compiler = Compiler
return M
