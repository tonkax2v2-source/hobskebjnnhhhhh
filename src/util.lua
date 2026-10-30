-- util.lua
-- Shared helpers: a seedable PRNG (deterministic across Lua versions),
-- confusing-name generators, and a generic AST visitor.

local Util = {}

----------------------------------------------------------------------
-- Deterministic PRNG (xorshift-ish, 32-bit) so a given seed always
-- yields the same obfuscation regardless of the host's math.random.
----------------------------------------------------------------------

local Rng = {}
Rng.__index = Rng

local function band(a, b)
  local r, bit = 0, 1
  for _ = 0, 31 do
    if (a % 2 == 1) and (b % 2 == 1) then r = r + bit end
    a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
  end
  return r
end

local function bxor(a, b)
  local r, bit = 0, 1
  for _ = 0, 31 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + bit end
    a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
  end
  return r
end
Util.bxor = bxor
Util.band = band

function Util.new_rng(seed)
  seed = math.floor(seed or 0) % 2147483647
  if seed == 0 then seed = 2147483646 end
  return setmetatable({ state = seed }, Rng)
end

-- Park-Miller minimal standard generator: deterministic and portable.
function Rng:next()
  self.state = (self.state * 16807) % 2147483647
  return self.state
end

-- Float in [0, 1).
function Rng:random()
  return (self:next() - 1) / 2147483646
end

-- Integer in [lo, hi] inclusive.
function Rng:int(lo, hi)
  if hi == nil then lo, hi = 1, lo end
  return lo + (self:next() % (hi - lo + 1))
end

function Rng:choice(list)
  return list[self:int(1, #list)]
end

-- Fisher-Yates shuffle, in place.
function Rng:shuffle(list)
  for i = #list, 2, -1 do
    local j = self:int(1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

----------------------------------------------------------------------
-- Name generation
----------------------------------------------------------------------

-- Builds identifiers from an alphabet of visually confusing characters.
-- Guaranteed to start with a letter/underscore and to be unique within
-- a generator instance.
function Util.new_namegen(rng, opts)
  opts = opts or {}
  local style = opts.style or "confusing"
  local used = {}
  local counter = 0

  local alphabets = {
    confusing = { "I", "l", "i", "_" },  -- I, lowercase L, i, underscore
    hex       = { "a", "b", "c", "d", "e", "f", "_" },
    short     = { "a", "b", "c", "d", "e", "f", "g", "h", "x", "y", "z", "_" },
  }
  local alpha = alphabets[style] or alphabets.confusing
  local tail = {}
  for _, c in ipairs(alpha) do tail[#tail+1] = c end
  tail[#tail+1] = "0"; tail[#tail+1] = "1"

  local function gen_once()
    counter = counter + 1
    local len = rng:int(6, 14)
    local buf = { rng:choice(alpha) }
    for _ = 2, len do buf[#buf+1] = rng:choice(tail) end
    -- Mix in the counter so collisions are impossible even if the random
    -- body repeats; encode it in the confusing alphabet too.
    local n = counter
    local enc = {}
    repeat
      enc[#enc+1] = alpha[(n % #alpha) + 1]
      n = math.floor(n / #alpha)
    until n == 0
    buf[#buf+1] = table.concat(enc)
    return table.concat(buf)
  end

  return {
    fresh = function()
      local name
      repeat name = gen_once() until not used[name]
      used[name] = true
      return name
    end,
    reserve = function(n) used[n] = true end,
  }
end

----------------------------------------------------------------------
-- Generic AST visitor. Calls visitor[node.kind](node, parent) pre-order
-- for every node reachable from `root`. Used by passes that only need to
-- observe or mutate nodes in place.
----------------------------------------------------------------------

local CHILD_KEYS = {
  Chunk = { "body" },
  Block = {},  -- handled specially (stats list)
  LocalStat = { "exprs" },
  LocalFunctionStat = { "func" },
  FunctionStat = { "target", "func" },
  AssignStat = { "targets", "exprs" },
  CallStat = { "call" },
  DoStat = { "body" },
  WhileStat = { "cond", "body" },
  RepeatStat = { "body", "cond" },
  IfStat = {},  -- special
  NumericForStat = { "start", "limit", "step", "body" },
  GenericForStat = { "exprs", "body" },
  ReturnStat = { "exprs" },
  BreakStat = {},
  GotoStat = {},
  LabelStat = {},
  -- expressions
  NilExpr = {}, TrueExpr = {}, FalseExpr = {}, VarargExpr = {},
  NumberExpr = {}, StringExpr = {}, NameExpr = {},
  ParenExpr = { "expr" },
  IndexExpr = { "obj", "index" },
  CallExpr = { "func", "args" },
  MethodCallExpr = { "obj", "args" },
  FunctionExpr = { "body" },
  TableExpr = {},  -- special (fields)
  BinopExpr = { "lhs", "rhs" },
  UnopExpr = { "operand" },
}

local function walk(node, visitor, parent)
  if type(node) ~= "table" or not node.kind then return end
  local v = visitor[node.kind]
  if v then v(node, parent) end
  local pre = visitor["*"]
  if pre then pre(node, parent) end

  local k = node.kind
  if k == "Block" then
    for _, s in ipairs(node.stats) do walk(s, visitor, node) end
    return
  end
  if k == "IfStat" then
    for _, c in ipairs(node.clauses) do
      walk(c.cond, visitor, node)
      walk(c.body, visitor, node)
    end
    if node.else_body then walk(node.else_body, visitor, node) end
    return
  end
  if k == "TableExpr" then
    for _, f in ipairs(node.fields) do
      if f.key and type(f.key) == "table" then walk(f.key, visitor, node) end
      walk(f.value, visitor, node)
    end
    return
  end

  local keys = CHILD_KEYS[k]
  if not keys then return end
  for _, key in ipairs(keys) do
    local child = node[key]
    if child then
      if child.kind then
        walk(child, visitor, node)
      elseif type(child) == "table" then
        for _, c in ipairs(child) do walk(c, visitor, node) end
      end
    end
  end
end

Util.walk = walk
Util.CHILD_KEYS = CHILD_KEYS

return Util
