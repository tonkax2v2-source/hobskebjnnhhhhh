-- number_mangle.lua
-- Rewrites non-negative decimal integer literals as equivalent arithmetic
-- expressions, e.g. 100 -> (3843 - 3743) or (57 + 43). Only plain decimal
-- integers in a safe range are touched: floats, hex and scientific literals
-- are left intact so integer/float typing and exact values are preserved.

local util = require("src.util")

local M = {}

local MAX_SAFE = 2147483000  -- stay well inside 32-bit to avoid overflow math

local function is_plain_int(text)
  -- decimal digits only, no '.', 'e', 'x'
  return text:match("^%d+$") ~= nil
end

local function num(n)
  return { kind = "NumberExpr", text = tostring(n) }
end

-- Returns a BinopExpr equivalent to integer n (n >= 0).
local function mangle(n, rng, depth)
  depth = depth or 0
  if rng:random() < 0.5 then
    -- additive split: a + b, both >= 0
    local a = rng:int(0, n)
    local b = n - a
    local lhs = (depth < 1 and a > 3 and rng:random() < 0.4)
      and mangle(a, rng, depth + 1) or num(a)
    return { kind = "BinopExpr", op = "+", lhs = lhs, rhs = num(b) }
  else
    -- subtractive: (n + e) - e, both operands > 0 so no "--" token clash
    local e = rng:int(1, 10000)
    local c = n + e
    return { kind = "BinopExpr", op = "-", lhs = num(c), rhs = num(e) }
  end
end

function M.run(chunk, ctx)
  local rng = ctx.rng
  local ratio = (ctx.opts.number_mangle and ctx.opts.number_mangle.ratio) or 1.0
  local targets = {}
  util.walk(chunk, {
    NumberExpr = function(n)
      if not n._mangled and is_plain_int(n.text) then
        local v = tonumber(n.text)
        if v and v >= 2 and v <= MAX_SAFE then
          targets[#targets + 1] = n
        end
      end
    end,
  })
  for _, node in ipairs(targets) do
    if rng:random() <= ratio then
      local v = tonumber(node.text)
      local repl = mangle(v, rng)
      repl._mangled = true
      for k in pairs(node) do node[k] = nil end
      for k, val in pairs(repl) do node[k] = val end
      node._mangled = true
    end
  end
  return chunk
end

return M
