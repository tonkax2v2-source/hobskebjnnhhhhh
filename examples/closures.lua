local R = {}
-- The classic per-iteration closure-capture test. If control-flow flattening
-- wrongly hoisted the loop-body local to a shared slot, every closure would
-- return the same value. Each must capture its own 'i'.
local fns = {}
for i = 1, 5 do
  local captured = i * 10
  fns[i] = function() return captured end
end
local vals = {}
for i = 1, 5 do vals[i] = fns[i]() end
R.captures = vals            -- must be {10,20,30,40,50}

-- generic-for with closures
local words = { "a", "b", "c" }
local getters = {}
for idx, w in ipairs(words) do
  getters[idx] = function() return idx .. w end
end
R.getters = { getters[1](), getters[2](), getters[3]() }  -- {"1a","2b","3c"}

-- metatables / OOP with inheritance
local Base = {}; Base.__index = Base
function Base.new(x) return setmetatable({ x = x }, Base) end
function Base:val() return self.x end
local Derived = setmetatable({}, { __index = Base })
Derived.__index = Derived
function Derived.new(x, y) local o = Base.new(x); o.y = y; return setmetatable(o, Derived) end
function Derived:sum() return self:val() + self.y end
R.oop = Derived.new(7, 5):sum()   -- 12

-- coroutine producing a sequence
local function gen(n)
  return coroutine.wrap(function()
    for i = 1, n do coroutine.yield(i * i) end
  end)
end
local squares = {}
for sq in gen(4) do squares[#squares + 1] = sq end
R.squares = squares           -- {1,4,9,16}

-- nested loops with early-ish accumulation and a while
local acc = 0
local a = 0
while a < 3 do
  for b = 1, 3 do acc = acc + a * b end
  a = a + 1
end
R.acc = acc

return R
