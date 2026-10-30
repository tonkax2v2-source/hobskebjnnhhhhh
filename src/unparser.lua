-- unparser.lua
-- Turns an AST back into valid Lua source.
-- * Precedence-aware: inserts parentheses only where needed.
-- * Never wraps a call / vararg in parentheses implicitly (would truncate
--   multiple return values), so semantics are preserved.
-- * Terminates every statement with ';' to sidestep the ambiguous
--   "prefix(exp)" call syntax entirely.

local Unparser = {}
Unparser.__index = Unparser

local EXPR_PREC = {
  ["or"] = 1, ["and"] = 2,
  ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
  ["|"] = 4, ["~"] = 5, ["&"] = 6,
  ["<<"] = 7, [">>"] = 7,
  [".."] = 9,
  ["+"] = 10, ["-"] = 10,
  ["*"] = 11, ["/"] = 11, ["//"] = 11, ["%"] = 11,
  ["^"] = 14,
}
local UNARY_PREC = 12
local RIGHT_ASSOC = { [".."] = true, ["^"] = true }

-- Lua keywords that must not be used as a bare table key `k=`.
local function is_ident(s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

function Unparser.new(opts)
  return setmetatable({ out = {}, opts = opts or {}, last = "" }, Unparser)
end

local function is_word(c)
  return c ~= "" and c:match("[%w_]") ~= nil
end

-- Decides whether a separating space is required between the previously
-- emitted character `a` and the next character `b` so the lexer re-tokenises
-- the output identically (avoids `1..2`, `aorb`, `--` comments, etc.).
local function needs_sep(a, b)
  if a == "" or b == "" then return false end
  if is_word(a) and is_word(b) then return true end          -- ab -> a b
  if a:match("%d") and b == "." then return true end          -- 1. -> 1 .
  if a == "." and b:match("%d") then return true end          -- .5 edge
  if a == "-" and b == "-" then return true end               -- -- comment
  if a == "/" and b == "/" then return true end               -- // merge
  if a == "~" and b == "=" then return true end               -- ~= merge
  if a == "<" and (b == "<" or b == "=") then return true end
  if a == ">" and (b == ">" or b == "=") then return true end
  if a == "=" and b == "=" then return true end
  if a == ":" and b == ":" then return true end
  if a == "[" and b == "[" then return true end               -- long string
  return false
end

function Unparser:emit(s)
  if s == "" then return end
  local first = s:sub(1, 1)
  if needs_sep(self.last, first) then
    self.out[#self.out + 1] = " "
  end
  self.out[#self.out + 1] = s
  self.last = s:sub(-1)
end

function Unparser:name_of(decl)
  return decl.newname or decl.name
end

-- Returns the output precedence of an expression node (higher binds tighter).
local function prec_of(node)
  if node.kind == "BinopExpr" then return EXPR_PREC[node.op] end
  if node.kind == "UnopExpr" then return UNARY_PREC end
  return 100 -- atoms / calls / indexes
end

----------------------------------------------------------------------
-- Expressions
----------------------------------------------------------------------

function Unparser:expr(node)
  local k = node.kind
  if k == "NilExpr" then self:emit("nil")
  elseif k == "TrueExpr" then self:emit("true")
  elseif k == "FalseExpr" then self:emit("false")
  elseif k == "VarargExpr" then self:emit("...")
  elseif k == "NumberExpr" then self:emit(node.text)
  elseif k == "StringExpr" then self:emit(self:quote(node.value))
  elseif k == "NameExpr" then
    if node.ref then self:emit(self:name_of(node.ref)) else self:emit(node.name) end
  elseif k == "ParenExpr" then
    self:emit("("); self:expr(node.expr); self:emit(")")
  elseif k == "IndexExpr" then
    self:index_expr(node)
  elseif k == "CallExpr" then
    self:call_target(node.func)
    self:args(node.args)
  elseif k == "MethodCallExpr" then
    self:call_target(node.obj)
    self:emit(":"); self:emit(node.method)
    self:args(node.args)
  elseif k == "FunctionExpr" then
    self:func_expr(node)
  elseif k == "TableExpr" then
    self:table_expr(node)
  elseif k == "BinopExpr" then
    self:binop(node)
  elseif k == "UnopExpr" then
    self:unop(node)
  else
    error("unparser: unknown expr kind " .. tostring(k))
  end
end

-- The callee / index base must itself be a prefixexp; wrap in parens otherwise.
function Unparser:call_target(node)
  local k = node.kind
  if k == "NameExpr" or k == "IndexExpr" or k == "CallExpr"
     or k == "MethodCallExpr" or k == "ParenExpr" then
    self:expr(node)
  else
    self:emit("("); self:expr(node); self:emit(")")
  end
end

function Unparser:index_expr(node)
  self:call_target(node.obj)
  if node.index.kind == "StringExpr" and node.index.as_name
     and is_ident(node.index.value) then
    self:emit("."); self:emit(node.index.value)
  else
    self:emit("["); self:expr(node.index); self:emit("]")
  end
end

function Unparser:args(args)
  self:emit("(")
  for i, a in ipairs(args) do
    if i > 1 then self:emit(",") end
    self:expr(a)
  end
  self:emit(")")
end

function Unparser:binop(node)
  local p = EXPR_PREC[node.op]
  local right_assoc = RIGHT_ASSOC[node.op]
  -- left operand
  local lp = prec_of(node.lhs)
  local need_l = right_assoc and (lp <= p) or (lp < p)
  if need_l then self:emit("("); self:expr(node.lhs); self:emit(")")
  else self:expr(node.lhs) end
  -- operator (word operators need surrounding spaces)
  if node.op == "and" or node.op == "or" then
    self:emit(" " .. node.op .. " ")
  else
    self:emit(node.op)
  end
  -- right operand
  local rp = prec_of(node.rhs)
  local need_r = right_assoc and (rp < p) or (rp <= p)
  if need_r then self:emit("("); self:expr(node.rhs); self:emit(")")
  else self:expr(node.rhs) end
end

function Unparser:unop(node)
  if node.op == "not" then self:emit("not ") else self:emit(node.op) end
  local op = node.operand
  local need = prec_of(op) < UNARY_PREC
  -- Avoid "- -x" / "--x" (comment) and "~ ~x" collisions.
  if not need and op.kind == "UnopExpr" then need = true end
  if not need and node.op == "-" and op.kind == "NumberExpr"
     and tostring(op.text):sub(1,1) == "-" then need = true end
  if need then self:emit("("); self:expr(op); self:emit(")")
  else self:expr(op) end
end

function Unparser:func_expr(node)
  self:emit("function(")
  local first = true
  for _, p in ipairs(node.params) do
    if not first then self:emit(",") end
    first = false
    self:emit(self:name_of(p))
  end
  if node.is_vararg then
    if not first then self:emit(",") end
    self:emit("...")
  end
  self:emit(")")
  self:block(node.body)
  self:emit("end")
end

function Unparser:table_expr(node)
  self:emit("{")
  for i, f in ipairs(node.fields) do
    if i > 1 then self:emit(",") end
    if f.kind == "list" then
      self:expr(f.value)
    elseif f.kind == "rec" then
      if is_ident(f.key) then
        self:emit(f.key)
      else
        self:emit("["); self:emit(self:quote(f.key)); self:emit("]")
      end
      self:emit("="); self:expr(f.value)
    elseif f.kind == "exprkey" then
      self:emit("["); self:expr(f.key); self:emit("]")
      self:emit("="); self:expr(f.value)
    end
  end
  self:emit("}")
end

-- Produces a safe double-quoted Lua string literal from a raw byte string.
function Unparser:quote(s)
  local buf = { '"' }
  for i = 1, #s do
    local b = s:byte(i)
    local c = s:sub(i, i)
    if c == '"' then buf[#buf+1] = '\\"'
    elseif c == "\\" then buf[#buf+1] = "\\\\"
    elseif b == 10 then buf[#buf+1] = "\\n"
    elseif b == 13 then buf[#buf+1] = "\\r"
    elseif b == 9 then buf[#buf+1] = "\\t"
    -- Non-printable and high bytes: always a 3-digit decimal escape so a
    -- following literal digit cannot merge into the escape (e.g. \27 + "7").
    elseif b < 32 or b >= 127 then buf[#buf+1] = string.format("\\%03d", b)
    else buf[#buf+1] = c end
  end
  buf[#buf+1] = '"'
  return table.concat(buf)
end

----------------------------------------------------------------------
-- Statements
----------------------------------------------------------------------

function Unparser:block(block)
  for _, s in ipairs(block.stats) do
    self:statement(s)
    self:emit(";")
  end
end

function Unparser:statement(s)
  local k = s.kind
  if k == "LocalStat" then
    self:emit("local ")
    for i, d in ipairs(s.names) do
      if i > 1 then self:emit(",") end
      self:emit(self:name_of(d))
      if d.attrib and self.opts.keep_attribs then
        self:emit("<" .. d.attrib .. ">")
      end
    end
    if #s.exprs > 0 then
      self:emit("=")
      self:expr_list(s.exprs)
    end
  elseif k == "LocalFunctionStat" then
    self:emit("local function " .. self:name_of(s.name))
    self:func_tail(s.func)
  elseif k == "FunctionStat" then
    -- `function a.b:c() ... end` desugars to `a.b.c = function(self) ... end`.
    -- Emitting the assignment form avoids tracking the ':' vs '.' separator
    -- and is semantically identical.
    self:expr(s.target)
    self:emit("=")
    self:expr(s.func)
  elseif k == "AssignStat" then
    for i, t in ipairs(s.targets) do
      if i > 1 then self:emit(",") end
      self:expr(t)
    end
    self:emit("=")
    self:expr_list(s.exprs)
  elseif k == "CallStat" then
    self:expr(s.call)
  elseif k == "DoStat" then
    self:emit("do "); self:block(s.body); self:emit("end")
  elseif k == "WhileStat" then
    self:emit("while "); self:expr(s.cond); self:emit(" do ")
    self:block(s.body); self:emit("end")
  elseif k == "RepeatStat" then
    self:emit("repeat "); self:block(s.body)
    self:emit("until "); self:expr(s.cond)
  elseif k == "IfStat" then
    for i, c in ipairs(s.clauses) do
      self:emit(i == 1 and "if " or "elseif ")
      self:expr(c.cond); self:emit(" then ")
      self:block(c.body)
    end
    if s.else_body then
      self:emit("else "); self:block(s.else_body)
    end
    self:emit("end")
  elseif k == "NumericForStat" then
    self:emit("for " .. self:name_of(s.var) .. "=")
    self:expr(s.start); self:emit(","); self:expr(s.limit)
    if s.step then self:emit(","); self:expr(s.step) end
    self:emit(" do "); self:block(s.body); self:emit("end")
  elseif k == "GenericForStat" then
    self:emit("for ")
    for i, d in ipairs(s.names) do
      if i > 1 then self:emit(",") end
      self:emit(self:name_of(d))
    end
    self:emit(" in ")
    self:expr_list(s.exprs)
    self:emit(" do "); self:block(s.body); self:emit("end")
  elseif k == "ReturnStat" then
    self:emit("return")
    if #s.exprs > 0 then
      self:emit(" ")
      self:expr_list(s.exprs)
    end
  elseif k == "BreakStat" then
    self:emit("break")
  elseif k == "GotoStat" then
    self:emit("goto " .. s.label)
  elseif k == "LabelStat" then
    self:emit("::" .. s.name .. "::")
  else
    error("unparser: unknown statement kind " .. tostring(k))
  end
end

function Unparser:expr_list(list)
  for i, e in ipairs(list) do
    if i > 1 then self:emit(",") end
    self:expr(e)
  end
end

function Unparser:func_tail(func)
  self:emit("(")
  local first = true
  for _, p in ipairs(func.params) do
    -- Skip the implicit 'self' of a method; the ':' in the name handles it.
    if func.is_method and p.name == "self" and first then
      first = false
    else
      if not first then self:emit(",") end
      first = false
      self:emit(self:name_of(p))
    end
  end
  if func.is_vararg then
    if not first then self:emit(",") end
    self:emit("...")
  end
  self:emit(")")
  self:block(func.body)
  self:emit("end")
end

function Unparser:generate(chunk)
  self.out = {}
  self:block(chunk.body)
  return table.concat(self.out)
end

local M = {}
function M.generate(chunk, opts)
  return Unparser.new(opts):generate(chunk)
end
M.Unparser = Unparser
M.is_ident = is_ident
return M
