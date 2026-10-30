-- Demonstrates the per-function encryption macro LPH_ENCFUNC.
-- A no-op fallback lets the file run unobfuscated (and on targets where the
-- macro is stripped rather than interpreted).
local LPH_ENCFUNC = LPH_ENCFUNC or function(f) return f end

local R = {}

-- A sensitive function wrapped for encryption. Its body (and any nested
-- functions) are encrypted and only decrypted when the function is first called.
local secret = LPH_ENCFUNC(function(key)
  local acc = 0
  for i = 1, #key do
    acc = (acc * 31 + key:byte(i)) % 1000003
  end
  -- a nested function (a descendant: also encrypted)
  local function finish(x) return x * 2 + 7 end
  return finish(acc)
end)

-- An encrypted function that is never called must not affect results.
local unused = LPH_ENCFUNC(function()
  return "this never runs"
end)

R.a = secret("hello")
R.b = secret("world")
R.c = secret("")        -- empty key

-- Immediately-invoked encrypted function.
R.d = LPH_ENCFUNC(function(n)
  local t = {}
  for i = 1, n do t[i] = i * i end
  return t
end)(5)

return R
