-- serialize.lua
-- Serializes compiled protos into a Lua data literal and assembles the final
-- runnable chunk: interpreter source + proto data + bootstrap call.

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
  -- float (or pre-5.3 number): keep it a float literal
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

local function ser_code(code)
  local parts = {}
  for i = 1, #code do
    parts[i] = "{" .. code[i][1] .. "," .. code[i][2] .. "}"
  end
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

local function ser_proto(p)
  local nested = {}
  for i = 1, #p.protos do nested[i] = ser_proto(p.protos[i]) end
  return table.concat({
    "{numparams=", p.numparams,
    ",is_vararg=", p.is_vararg and "true" or "false",
    ",consts=", ser_consts(p.consts),
    ",code=", ser_code(p.code),
    ",upvals=", ser_upvals(p.upvals),
    ",protos={", table.concat(nested, ","), "}}",
  })
end

-- Builds the full chunk. The result is ordinary Lua that can be run directly or
-- fed back through the source-level passes for an extra layer.
function M.generate(mainproto)
  local parts = {}
  parts[#parts + 1] = runtime.source()
  parts[#parts + 1] = "local __VMP=" .. ser_proto(mainproto) .. " "
  parts[#parts + 1] = "return exec(__VMP,{},(_ENV or _G),tpack(...))"
  return table.concat(parts)
end

M.ser_proto = ser_proto
return M
