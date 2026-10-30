-- parser.lua
-- Recursive-descent parser for Lua 5.1-5.4.
-- Builds an AST (plain tables with a `kind` field) and resolves every
-- NameExpr to a declaration when one exists in the lexical scope chain,
-- so later passes can rename locals without touching globals.

local Tokenizer = require("src.tokenizer")

local Parser = {}
Parser.__index = Parser

----------------------------------------------------------------------
-- Scope helpers
----------------------------------------------------------------------

local function new_scope(parent, is_function)
  return {
    parent = parent,
    is_function = is_function or false,
    vars = {},        -- name -> decl
    order = {},       -- declaration order
  }
end

local function scope_declare(scope, name, kind)
  local decl = { name = name, kind = kind or "local", scope = scope, uses = {} }
  scope.vars[name] = decl
  scope.order[#scope.order + 1] = decl
  return decl
end

local function scope_resolve(scope, name)
  local s = scope
  while s do
    local d = s.vars[name]
    if d then return d end
    s = s.parent
  end
  return nil
end

----------------------------------------------------------------------
-- Parser core
----------------------------------------------------------------------

function Parser.new(tokens, chunkname)
  return setmetatable({
    toks = tokens,
    i = 1,
    chunkname = chunkname or "?",
    scope = nil,
  }, Parser)
end

function Parser:cur() return self.toks[self.i] end
function Parser:peek(o) return self.toks[self.i + (o or 0)] end
function Parser:advance()
  local t = self.toks[self.i]
  self.i = self.i + 1
  return t
end

function Parser:error(msg, tok)
  tok = tok or self:cur()
  error(string.format("%s:%d: %s (near '%s')", self.chunkname, tok.line, msg, tostring(tok.value)), 0)
end

function Parser:check(ttype, tvalue)
  local t = self:cur()
  if t.type ~= ttype then return false end
  if tvalue ~= nil and t.value ~= tvalue then return false end
  return true
end

function Parser:accept(ttype, tvalue)
  if self:check(ttype, tvalue) then return self:advance() end
  return nil
end

function Parser:expect(ttype, tvalue)
  if not self:check(ttype, tvalue) then
    self:error("expected " .. (tvalue or ttype))
  end
  return self:advance()
end

function Parser:is_op(v) return self:check("op", v) end
function Parser:is_kw(v) return self:check("keyword", v) end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------

function Parser:parse()
  self.scope = new_scope(nil, true)
  local body = self:block()
  if not self:check("eof") then
    self:error("'<eof>' expected")
  end
  return { kind = "Chunk", body = body, scope = self.scope }
end

local BLOCK_END = {
  ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true,
}

function Parser:block_terminated()
  local t = self:cur()
  if t.type == "eof" then return true end
  if t.type == "keyword" and BLOCK_END[t.value] then return true end
  return false
end

-- Parses a block in the CURRENT scope (caller manages scope push/pop).
function Parser:block()
  local stats = {}
  while not self:block_terminated() do
    if self:is_kw("return") then
      stats[#stats + 1] = self:return_stat()
      break
    end
    local s = self:statement()
    if s then stats[#stats + 1] = s end
  end
  return { kind = "Block", stats = stats }
end

-- Runs fn inside a freshly pushed scope, returns (result, scope).
function Parser:scoped(is_function, fn)
  local parent = self.scope
  local s = new_scope(parent, is_function)
  self.scope = s
  local r = fn(s)
  self.scope = parent
  return r, s
end

----------------------------------------------------------------------
-- Statements
----------------------------------------------------------------------

function Parser:statement()
  local t = self:cur()

  if t.type == "op" and t.value == ";" then
    self:advance()
    return nil
  end
  if t.type == "op" and t.value == "::" then
    return self:label_stat()
  end

  if t.type == "keyword" then
    local v = t.value
    if v == "break" then self:advance(); return { kind = "BreakStat", line = t.line } end
    if v == "goto" then
      self:advance()
      local name = self:expect("name").value
      return { kind = "GotoStat", label = name, line = t.line }
    end
    if v == "do" then
      self:advance()
      local body, s = self:scoped(false, function() return self:block() end)
      self:expect("keyword", "end")
      return { kind = "DoStat", body = body, scope = s }
    end
    if v == "while" then return self:while_stat() end
    if v == "repeat" then return self:repeat_stat() end
    if v == "if" then return self:if_stat() end
    if v == "for" then return self:for_stat() end
    if v == "function" then return self:function_stat() end
    if v == "local" then return self:local_stat() end
  end

  -- expression statement: call or assignment
  return self:expr_stat()
end

function Parser:label_stat()
  local line = self:cur().line
  self:expect("op", "::")
  local name = self:expect("name").value
  self:expect("op", "::")
  return { kind = "LabelStat", name = name, line = line }
end

function Parser:return_stat()
  local line = self:cur().line
  self:expect("keyword", "return")
  local exprs = {}
  if not self:block_terminated() and not self:is_op(";") then
    exprs = self:expr_list()
  end
  self:accept("op", ";")
  return { kind = "ReturnStat", exprs = exprs, line = line }
end

function Parser:while_stat()
  local line = self:cur().line
  self:expect("keyword", "while")
  local cond = self:expr()
  self:expect("keyword", "do")
  local body, s = self:scoped(false, function() return self:block() end)
  self:expect("keyword", "end")
  return { kind = "WhileStat", cond = cond, body = body, scope = s, line = line }
end

function Parser:repeat_stat()
  local line = self:cur().line
  self:expect("keyword", "repeat")
  -- In Lua, the until-condition can see locals declared in the body,
  -- so the condition is parsed inside the same scope.
  local body, cond
  local _, s = self:scoped(false, function()
    body = self:block()
    self:expect("keyword", "until")
    cond = self:expr()
  end)
  return { kind = "RepeatStat", body = body, cond = cond, scope = s, line = line }
end

function Parser:if_stat()
  local line = self:cur().line
  self:expect("keyword", "if")
  local clauses = {}
  local cond = self:expr()
  self:expect("keyword", "then")
  local body, s = self:scoped(false, function() return self:block() end)
  clauses[#clauses + 1] = { cond = cond, body = body, scope = s }
  while self:is_kw("elseif") do
    self:advance()
    local c = self:expr()
    self:expect("keyword", "then")
    local b, sc = self:scoped(false, function() return self:block() end)
    clauses[#clauses + 1] = { cond = c, body = b, scope = sc }
  end
  local else_body, else_scope
  if self:is_kw("else") then
    self:advance()
    else_body, else_scope = self:scoped(false, function() return self:block() end)
  end
  self:expect("keyword", "end")
  return { kind = "IfStat", clauses = clauses, else_body = else_body,
           else_scope = else_scope, line = line }
end

function Parser:for_stat()
  local line = self:cur().line
  self:expect("keyword", "for")
  local first = self:expect("name").value
  if self:is_op("=") then
    -- numeric for
    self:advance()
    local start = self:expr()
    self:expect("op", ",")
    local limit = self:expr()
    local step
    if self:accept("op", ",") then step = self:expr() end
    self:expect("keyword", "do")
    local var_decl, body, s
    _, s = self:scoped(false, function(sc)
      var_decl = scope_declare(sc, first, "loopvar")
      body = self:block()
    end)
    self:expect("keyword", "end")
    return { kind = "NumericForStat", var = var_decl, start = start,
             limit = limit, step = step, body = body, scope = s, line = line }
  else
    -- generic for
    local names = { first }
    while self:accept("op", ",") do
      names[#names + 1] = self:expect("name").value
    end
    self:expect("keyword", "in")
    local exprs = self:expr_list()
    self:expect("keyword", "do")
    local decls, body, s = {}, nil, nil
    _, s = self:scoped(false, function(sc)
      for _, nm in ipairs(names) do
        decls[#decls + 1] = scope_declare(sc, nm, "loopvar")
      end
      body = self:block()
    end)
    self:expect("keyword", "end")
    return { kind = "GenericForStat", names = decls, exprs = exprs,
             body = body, scope = s, line = line }
  end
end

function Parser:function_stat()
  local line = self:cur().line
  self:expect("keyword", "function")
  -- funcname: Name {'.' Name} [':' Name]
  local base_name = self:expect("name").value
  local base_decl = scope_resolve(self.scope, base_name)
  local target = { kind = "NameExpr", name = base_name, ref = base_decl, line = line }
  if base_decl then base_decl.uses[#base_decl.uses + 1] = target end
  local is_method = false
  while self:is_op(".") do
    self:advance()
    local key = self:expect("name").value
    target = { kind = "IndexExpr", obj = target,
               index = { kind = "StringExpr", value = key, as_name = true } }
  end
  if self:accept("op", ":") then
    local key = self:expect("name").value
    target = { kind = "IndexExpr", obj = target,
               index = { kind = "StringExpr", value = key, as_name = true } }
    is_method = true
  end
  local func = self:function_body(is_method, line)
  return { kind = "FunctionStat", target = target, func = func,
           is_method = is_method, line = line }
end

function Parser:local_stat()
  local line = self:cur().line
  self:expect("keyword", "local")
  if self:is_kw("function") then
    self:advance()
    local name = self:expect("name").value
    -- The function name is in scope within its own body (for recursion).
    local decl = scope_declare(self.scope, name, "local")
    local func = self:function_body(false, line)
    return { kind = "LocalFunctionStat", name = decl, func = func, line = line }
  end
  -- local names [attribs] = exprs
  local names = {}
  repeat
    local nm = self:expect("name").value
    local attrib
    if self:accept("op", "<") then
      attrib = self:expect("name").value
      self:expect("op", ">")
    end
    names[#names + 1] = { name = nm, attrib = attrib }
  until not self:accept("op", ",")
  local exprs = {}
  if self:accept("op", "=") then
    exprs = self:expr_list()
  end
  -- Declarations become visible AFTER the initializer expressions.
  local decls = {}
  for _, n in ipairs(names) do
    local d = scope_declare(self.scope, n.name, "local")
    d.attrib = n.attrib
    decls[#decls + 1] = d
  end
  return { kind = "LocalStat", names = decls, exprs = exprs, line = line }
end

function Parser:expr_stat()
  local line = self:cur().line
  local e = self:suffixed_expr()
  if self:is_op("=") or self:is_op(",") then
    local targets = { e }
    while self:accept("op", ",") do
      targets[#targets + 1] = self:suffixed_expr()
    end
    self:expect("op", "=")
    local exprs = self:expr_list()
    for _, tgt in ipairs(targets) do
      if tgt.kind ~= "NameExpr" and tgt.kind ~= "IndexExpr" then
        self:error("cannot assign to this expression")
      end
    end
    return { kind = "AssignStat", targets = targets, exprs = exprs, line = line }
  end
  if e.kind ~= "CallExpr" and e.kind ~= "MethodCallExpr" then
    self:error("syntax error: unexpected expression statement")
  end
  return { kind = "CallStat", call = e, line = line }
end

----------------------------------------------------------------------
-- Expressions
----------------------------------------------------------------------

function Parser:expr_list()
  local list = { self:expr() }
  while self:accept("op", ",") do
    list[#list + 1] = self:expr()
  end
  return list
end

-- Binary operator binding powers: {left, right}. Right < left => right assoc.
local BINPRI = {
  ["or"]  = {1, 1},   ["and"] = {2, 2},
  ["<"] = {3, 3}, [">"] = {3, 3}, ["<="] = {3, 3},
  [">="] = {3, 3}, ["~="] = {3, 3}, ["=="] = {3, 3},
  ["|"] = {4, 4}, ["~"] = {5, 5}, ["&"] = {6, 6},
  ["<<"] = {7, 7}, [">>"] = {7, 7},
  [".."] = {9, 8},                      -- right associative
  ["+"] = {10, 10}, ["-"] = {10, 10},
  ["*"] = {11, 11}, ["/"] = {11, 11}, ["//"] = {11, 11}, ["%"] = {11, 11},
  ["^"] = {14, 13},                     -- right associative, binds tighter than unary
}
local UNARY_PRI = 12

local function binop_name(tok)
  if tok.type == "keyword" and (tok.value == "and" or tok.value == "or") then
    return tok.value
  end
  if tok.type == "op" and BINPRI[tok.value] then return tok.value end
  return nil
end

function Parser:expr(limit)
  limit = limit or 0
  local left
  local t = self:cur()
  -- unary operators
  if (t.type == "op" and (t.value == "-" or t.value == "#" or t.value == "~"))
     or (t.type == "keyword" and t.value == "not") then
    self:advance()
    local operand = self:expr(UNARY_PRI)
    left = { kind = "UnopExpr", op = t.value, operand = operand, line = t.line }
  else
    left = self:simple_expr()
  end

  while true do
    local op = binop_name(self:cur())
    if not op then break end
    local pri = BINPRI[op]
    if pri[1] <= limit then break end
    local line = self:cur().line
    self:advance()
    local right = self:expr(pri[2])
    left = { kind = "BinopExpr", op = op, lhs = left, rhs = right, line = line }
  end
  return left
end

function Parser:simple_expr()
  local t = self:cur()
  if t.type == "number" then
    self:advance()
    return { kind = "NumberExpr", text = t.value, line = t.line }
  elseif t.type == "string" then
    self:advance()
    return { kind = "StringExpr", value = t.value, line = t.line }
  elseif t.type == "keyword" then
    if t.value == "nil" then self:advance(); return { kind = "NilExpr", line = t.line } end
    if t.value == "true" then self:advance(); return { kind = "TrueExpr", line = t.line } end
    if t.value == "false" then self:advance(); return { kind = "FalseExpr", line = t.line } end
    if t.value == "function" then
      self:advance()
      return self:function_body(false, t.line)
    end
  elseif t.type == "op" then
    if t.value == "..." then self:advance(); return { kind = "VarargExpr", line = t.line } end
    if t.value == "{" then return self:table_expr() end
  end
  return self:suffixed_expr()
end

function Parser:primary_expr()
  local t = self:cur()
  if t.type == "op" and t.value == "(" then
    self:advance()
    local e = self:expr()
    self:expect("op", ")")
    return { kind = "ParenExpr", expr = e, line = t.line }
  elseif t.type == "name" then
    self:advance()
    local decl = scope_resolve(self.scope, t.value)
    local node = { kind = "NameExpr", name = t.value, ref = decl, line = t.line }
    if decl then decl.uses[#decl.uses + 1] = node end
    return node
  end
  self:error("unexpected symbol")
end

function Parser:suffixed_expr()
  local e = self:primary_expr()
  while true do
    local t = self:cur()
    if t.type == "op" and t.value == "." then
      self:advance()
      local key = self:expect("name").value
      e = { kind = "IndexExpr", obj = e,
            index = { kind = "StringExpr", value = key, as_name = true }, line = t.line }
    elseif t.type == "op" and t.value == "[" then
      self:advance()
      local idx = self:expr()
      self:expect("op", "]")
      e = { kind = "IndexExpr", obj = e, index = idx, line = t.line }
    elseif t.type == "op" and t.value == ":" then
      self:advance()
      local method = self:expect("name").value
      local args = self:call_args()
      e = { kind = "MethodCallExpr", obj = e, method = method, args = args, line = t.line }
    elseif (t.type == "op" and (t.value == "(" or t.value == "{"))
           or t.type == "string" then
      local args = self:call_args()
      e = { kind = "CallExpr", func = e, args = args, line = t.line }
    else
      break
    end
  end
  return e
end

function Parser:call_args()
  local t = self:cur()
  if t.type == "string" then
    self:advance()
    return { { kind = "StringExpr", value = t.value, line = t.line } }
  end
  if t.type == "op" and t.value == "{" then
    return { self:table_expr() }
  end
  self:expect("op", "(")
  local args = {}
  if not self:is_op(")") then
    args = self:expr_list()
  end
  self:expect("op", ")")
  return args
end

function Parser:table_expr()
  local line = self:cur().line
  self:expect("op", "{")
  local fields = {}
  while not self:is_op("}") do
    if self:is_op("[") then
      self:advance()
      local key = self:expr()
      self:expect("op", "]")
      self:expect("op", "=")
      local val = self:expr()
      fields[#fields + 1] = { kind = "exprkey", key = key, value = val }
    elseif self:check("name") and self:peek(1) and self:peek(1).type == "op"
           and self:peek(1).value == "=" then
      local key = self:advance().value
      self:expect("op", "=")
      local val = self:expr()
      fields[#fields + 1] = { kind = "rec", key = key, value = val }
    else
      fields[#fields + 1] = { kind = "list", value = self:expr() }
    end
    if not (self:accept("op", ",") or self:accept("op", ";")) then
      break
    end
  end
  self:expect("op", "}")
  return { kind = "TableExpr", fields = fields, line = line }
end

function Parser:function_body(is_method, line)
  self:expect("op", "(")
  local params, is_vararg, body, scope
  _, scope = self:scoped(true, function(sc)
    params = {}
    if is_method then
      params[#params + 1] = scope_declare(sc, "self", "param")
    end
    if not self:is_op(")") then
      repeat
        if self:is_op("...") then
          self:advance()
          is_vararg = true
          break
        end
        local nm = self:expect("name").value
        params[#params + 1] = scope_declare(sc, nm, "param")
      until not self:accept("op", ",")
    end
    self:expect("op", ")")
    body = self:block()
    self:expect("keyword", "end")
  end)
  return { kind = "FunctionExpr", params = params, is_vararg = is_vararg or false,
           body = body, scope = scope, is_method = is_method, line = line }
end

----------------------------------------------------------------------

local M = {}

function M.parse(src, chunkname)
  local toks = Tokenizer.new(src, chunkname):tokenize()
  return Parser.new(toks, chunkname):parse()
end

M.Parser = Parser
M.new_scope = new_scope
M.scope_declare = scope_declare
M.scope_resolve = scope_resolve

return M
