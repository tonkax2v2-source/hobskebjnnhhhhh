-- A small program exercising many language features, used as a smoke test.
local function factorial(n)
  if n <= 1 then return 1 end
  return n * factorial(n - 1)
end

local Account = {}
Account.__index = Account

function Account.new(owner, balance)
  local self = setmetatable({}, Account)
  self.owner = owner
  self.balance = balance or 0
  return self
end

function Account:deposit(amount)
  self.balance = self.balance + amount
  return self.balance
end

function Account:describe()
  return string.format("%s has %d coins", self.owner, self.balance)
end

local function sum(...)
  local total = 0
  for _, v in ipairs({ ... }) do
    total = total + v
  end
  return total
end

local results = {}
for i = 1, 5 do
  results[i] = factorial(i)
end

local acc = Account.new("Nong", 100)
acc:deposit(55)

local msg = "factorials: "
local j = 1
while j <= #results do
  msg = msg .. tostring(results[j])
  if j < #results then msg = msg .. "," end
  j = j + 1
end

local bits = (0xF0 | 0x0F) & 0xFF
local flag = (bits == 255) and "ok" or "bad"

return {
  msg = msg,
  account = acc:describe(),
  total = sum(1, 2, 3, 4, 5),
  bits = bits,
  flag = flag,
  nested = factorial(6),
}
