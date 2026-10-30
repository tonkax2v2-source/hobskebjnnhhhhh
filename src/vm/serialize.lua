-- serialize.lua
-- Serializes compiled protos into a runnable chunk. Each proto's instruction
-- stream is encoded into an encrypted string (per-proto rolling key) with an
-- integrity checksum, decoded at load by __vmdec. The proto's structure
-- (numparams / varargs / consts / upvalue descriptors / nested protos) stays a
-- table literal; the code is never visible as instructions.

local runtime = require("src.vm.runtime")

local M = {}

local function ser_string(s)
  local buf = { '"' }
  for i = 1, #s do
    local b = s:byte(i)
    if b == 34 then buf[#buf + 1] = '\\"'
    elseif b == 92 then buf[#buf + 1] = "\\\\"
    elseif b >= 32 and b < 127 then buf[#buf + 1] = string.char(b)
    else buf[#buf + 1] = string.format("\\%03d", b) end
  end
  buf[#buf + 1] = '"'
  return table.concat(buf)
end

local function ser_number(v)
  if v ~= v then return "(0/0)" end
  if v == math.huge then return "(1/0)" end
  if v == -math.huge then return "(-1/0)" end
  local mt = math.type and math.type(v)
  if mt == "integer" then return string.format("%d", v) end
  local s = string.format("%.17g", v)
  if not s:find("[.eEnN]") then s = s .. ".0" end
  return s
end

local function ser_value(v)
  local t = type(v)
  if t == "number" then return ser_number(v)
  elseif t == "string" then return ser_string(v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "nil" then return "nil"
  else error("vm: cannot serialize const of type " .. t) end
end

local function ser_consts(consts)
  local parts = {}
  for i = 1, #consts do parts[i] = ser_value(consts[i]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function ser_upvals(upvals)
  local parts = {}
  for i = 1, #upvals do
    local d = upvals[i]
    parts[i] = '{kind="' .. d.kind .. '",index=' .. d.index .. "}"
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Encodes a code array to an encrypted byte string + checksum.
-- Must mirror __vmdec in runtime.lua exactly.
local function encode_code(code, perm, k1, k2)
  local bytes = {}
  local sum = 0
  local p = 0
  local function put(n)
    n = n % 4294967296
    local b0 = n % 256
    local b1 = math.floor(n / 256) % 256
    local b2 = math.floor(n / 65536) % 256
    local b3 = math.floor(n / 16777216) % 256
    sum = (sum + b0 + b1 * 2 + b2 * 3 + b3 * 4) % 16777213
    local grp = { b0, b1, b2, b3 }
    for j = 1, 4 do
      p = p + 1
      local key = (k1 + p * k2) % 256
      bytes[#bytes + 1] = (grp[j] + key) % 256
    end
  end
  put(#code)
  for _, ins in ipairs(code) do
    put(perm[ins[1]])
    put(ins[2])
  end
  local chars = {}
  for i = 1, #bytes do chars[i] = string.char(bytes[i]) end
  return table.concat(chars), sum
end

local function ser_proto(p, profile, rng)
  local k1 = rng:int(0, 255)
  local k2 = rng:int(1, 255)
  local enc, chk = encode_code(p.code, profile.perm, k1, k2)
  local nested = {}
  for i = 1, #p.protos do nested[i] = ser_proto(p.protos[i], profile, rng) end
  return table.concat({
    "{numparams=", p.numparams,
    ",is_vararg=", p.is_vararg and "true" or "false",
    ",consts=", ser_consts(p.consts),
    ",code=__vmdec(", ser_string(enc), ",", k1, ",", k2, ",", chk, ")",
    ",upvals=", ser_upvals(p.upvals),
    ",protos={", table.concat(nested, ","), "}}",
  })
end

-- Builds the full chunk for a given profile. `rng` supplies per-proto keys.
function M.generate(mainproto, profile, rng)
  local parts = {}
  parts[#parts + 1] = runtime.source(profile)
  parts[#parts + 1] = "local __VMP=" .. ser_proto(mainproto, profile, rng) .. " "
  parts[#parts + 1] = "return exec(__VMP,{},(_ENV or _G),tpack(...))"
  return table.concat(parts)
end

M.ser_proto = ser_proto
M.encode_code = encode_code
return M
