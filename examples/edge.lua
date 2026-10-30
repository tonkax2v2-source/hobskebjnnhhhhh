-- Edge-case stress test: unusual but valid Lua the obfuscator must preserve.
local R = {}

-- repeat/until where the condition reads a body-local
do
  local n, acc = 0, 0
  repeat
    local step = n + 1
    acc = acc + step
    n = n + 1
  until step and n >= 5     -- 'step' is visible here
  R.repeat_acc = acc
end

-- goto / labels
do
  local total = 0
  local i = 1
  ::top::
  if i <= 4 then
    total = total + i
    i = i + 1
    goto top
  end
  R.goto_total = total
end

-- operator precedence corners
R.prec1 = -2 ^ 2            -- -(2^2) = -4
R.prec2 = 2 ^ -2           -- 0.25
R.prec3 = not (1 == 2) and 3 or 4
R.prec4 = 1 .. 2 .. 3      -- right assoc concat -> "123"
R.prec5 = 5 - 3 - 1        -- left assoc -> 1
R.prec6 = 2 + 3 * 4        -- 14

-- multi-return passthrough (must NOT be truncated by spurious parens)
local function two() return 10, 20 end
local function addall(...)
  local s = 0
  for _, v in ipairs({ ... }) do s = s + v end
  return s
end
R.multi = addall(two(), two())     -- 10+20+10+20? no: first two() truncated to 10, last expands
R.paren_trunc = addall((two()), two()) -- (two()) truncates to 10

-- method chains and paren-call on literals
local s = ("Hello, World"):gsub("o", "0"):lower()
R.chain = s

-- long strings & escapes
R.long = [[line1
line2]]
R.esc = "tab\tend\65\x42\u{48}"

-- table constructor variety
R.tbl = { 1, 2, three = 3, ["four space"] = 4, [10] = "ten"; 5 }

-- varargs in the middle of a call
local function pack3(a, b, c) return { a, b, c } end
R.midvararg = pack3(1, 2, 3)

-- numeric literals
R.nums = { 0, 7, 255, 1000000, 3.5, 0x1F, 1e3 }

-- nested closures capturing upvalues
local function counter()
  local c = 0
  return function() c = c + 1; return c end
end
local inc = counter()
inc(); inc()
R.closure = inc()   -- 3

return R
