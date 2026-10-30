-- serialize.lua
-- Serializes compiled protos into a runnable chunk. Each proto's constant pool
-- AND instruction stream are packed into one encrypted byte string (per-proto
-- rolling key) carrying an integrity checksum, decoded at load by __vmdec and
-- assembled by __mkproto. Neither the code nor the constants are ever visible.
--
-- The encoder here must mirror __vmdec in runtime.lua byte-for-byte.

local runtime = require("src.vm.runtime")

local M = {}

local function ser_string_lit(s)
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

-- Decimal text for a number such that tonumber() reproduces it exactly, with
-- integer/float type preserved. inf/-inf map to tonumber-able literals.
local function number_text(v)
  if v ~= v then error("vm: NaN constant cannot be serialized") end
  if v == math.huge then return "1e9999" end
  if v == -math.huge then return "-1e9999" end
  local mt = math.type and math.type(v)
  if mt == "integer" then return string.format("%d", v) end
  local s = string.format("%.17g", v)
  if not s:find("[.eEnN]") then s = s .. ".0" end
  return s
end

-- Encodes (consts, code) into an encrypted byte string + checksum.
local function encode_proto_data(consts, code, perm, k1, k2)
  local bytes = {}
  local sum = 0
  local p = 0
  local function emit_byte(pb)
    p = p + 1
    sum = (sum + pb * (((p - 1) % 7) + 1)) % 16777213
    local key = (k1 + p * k2) % 256
    bytes[#bytes + 1] = (pb + key) % 256
  end
  local function put(n)
    n = n % 4294967296
    emit_byte(n % 256)
    emit_byte(math.floor(n / 256) % 256)
    emit_byte(math.floor(n / 65536) % 256)
    emit_byte(math.floor(n / 16777216) % 256)
  end
  local function puts(str)
    put(#str)
    for i = 1, #str do emit_byte(str:byte(i)) end
  end

  put(#consts)
  for i = 1, #consts do
    local v = consts[i]
    local t = type(v)
    if t == "string" then emit_byte(0); puts(v)
    elseif t == "number" then emit_byte(1); puts(number_text(v))
    elseif t == "boolean" then emit_byte(v and 2 or 3)
    else error("vm: cannot serialize const of type " .. t) end
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

local function ser_upvals(upvals)
  local parts = {}
  for i = 1, #upvals do
    local d = upvals[i]
    parts[i] = '{kind="' .. d.kind .. '",index=' .. d.index .. "}"
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function ser_proto(p, profile, rng)
  local k1 = rng:int(0, 255)
  local k2 = rng:int(1, 255)
  local enc, chk = encode_proto_data(p.consts, p.code, profile.perm, k1, k2)
  local nested = {}
  for i = 1, #p.protos do nested[i] = ser_proto(p.protos[i], profile, rng) end
  return table.concat({
    "__mkproto(", p.numparams, ",", p.is_vararg and "true" or "false",
    ",", ser_upvals(p.upvals),
    ",{", table.concat(nested, ","), "}",
    ",", ser_string_lit(enc), ",", k1, ",", k2, ",", chk, ")",
  })
end

function M.generate(mainproto, profile, rng)
  local parts = {}
  parts[#parts + 1] = runtime.source(profile)
  parts[#parts + 1] = "local __VMP=" .. ser_proto(mainproto, profile, rng) .. " "
  parts[#parts + 1] = "return exec(__VMP,{},(_ENV or _G),tpack(...))"
  return table.concat(parts)
end

M.ser_proto = ser_proto
M.encode_proto_data = encode_proto_data
return M
