-- encrypt_strings.lua
-- Replaces every genuine string literal with a call to an injected decoder.
-- The encoding is pure integer arithmetic (add/mod 256) so the output runs
-- unchanged on Lua 5.1 through 5.4 (no bitwise operators required).
--
--   encoded[i] = (byte[i] + (i*a + b) % 256) % 256
--   decoded[i] = (encoded[i] - (i*a + b) % 256) % 256
--
-- `a` and `b` are random per string, passed as call arguments, so identical
-- source strings produce different ciphertext.

local parser = require("src.parser")
local util = require("src.util")

local M = {}

local function encode(s, a, b)
  local out = {}
  for i = 1, #s do
    local k = (i * a + b) % 256
    out[i] = string.char((s:byte(i) + k) % 256)
  end
  return table.concat(out)
end

-- Builds the decoder prelude, parses it, and returns the spliced statements
-- plus the declaration of the decoder function (so call sites can reference
-- it and survive renaming).
local function build_decoder(ctx)
  local name = ctx.namegen.fresh()
  -- Capture the stdlib functions into locals up front so later shadowing of
  -- the `string`/`table` globals in user code cannot break decoding.
  local sbyte = ctx.namegen.fresh()
  local schar = ctx.namegen.fresh()
  local sconcat = ctx.namegen.fresh()
  local src = string.format([[
local %s = string.byte
local %s = string.char
local %s = table.concat
local function %s(s, a, b)
  local r = {}
  for i = 1, #s do
    local k = (i * a + b) %% 256
    r[i] = %s((%s(s, i) - k) %% 256)
  end
  return %s(r)
end
]], sbyte, schar, sconcat, name, schar, sbyte, sconcat)

  local snippet = parser.parse(src, "<decoder>")
  local stats = snippet.body.stats
  -- Grab the decoder's declaration so call sites can reference it directly.
  -- Its NameExpr refs are resolved within the snippet, and every prelude
  -- local is a normal declaration, so rename_vars will rename them all
  -- consistently (including this one, via the shared ref on each call site).
  local decl
  for _, st in ipairs(stats) do
    if st.kind == "LocalFunctionStat" and st.name.name == name then
      decl = st.name
    end
  end
  return stats, decl, name
end

function M.run(chunk, ctx)
  if ctx.opts.disable and ctx.opts.disable.encrypt_strings then return chunk end

  -- First collect the literals, so we only inject the decoder if it is used.
  local targets = {}
  util.walk(chunk, {
    StringExpr = function(n)
      if not n.as_name and not n._encrypted then
        targets[#targets + 1] = n
      end
    end,
  })
  if #targets == 0 then return chunk end

  local stats, decl, name = build_decoder(ctx)

  for _, node in ipairs(targets) do
    local a = ctx.rng:int(1, 255)
    local b = ctx.rng:int(0, 255)
    local enc = encode(node.value, a, b)
    -- Mutate the StringExpr node into a CallExpr in place.
    local call = {
      kind = "CallExpr",
      func = { kind = "NameExpr", name = name, ref = decl },
      args = {
        { kind = "StringExpr", value = enc, _encrypted = true },
        { kind = "NumberExpr", text = tostring(a) },
        { kind = "NumberExpr", text = tostring(b) },
      },
    }
    for k in pairs(node) do node[k] = nil end
    for k, v in pairs(call) do node[k] = v end
  end

  -- Splice the decoder statements at the front of the chunk.
  local body = chunk.body.stats
  for i = #stats, 1, -1 do
    table.insert(body, 1, stats[i])
  end
  return chunk
end

return M
