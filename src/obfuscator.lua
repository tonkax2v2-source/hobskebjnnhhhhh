-- obfuscator.lua
-- Orchestrates the pipeline: parse -> passes -> generate.
--
-- Each pass is a module in src/passes/ exposing:
--     run(chunk, ctx)   -- mutates `chunk` in place (or returns a new chunk)
-- where ctx = { rng = <Rng>, namegen = <namegen>, opts = <table> }.

local parser = require("src.parser")
local unparser = require("src.unparser")
local util = require("src.util")

local M = {}

-- Pass registry in default execution order. Order matters: renaming runs
-- before constant extraction, string encryption before VM wrapping, etc.
local PASS_ORDER = {
  "encrypt_strings",
  "number_mangle",
  "rename_vars",
  "const_array",
  "junk_code",
  "finalize",
}

local function load_pass(name)
  local ok, mod = pcall(require, "src.passes." .. name)
  if not ok then
    error("failed to load pass '" .. name .. "': " .. tostring(mod), 0)
  end
  return mod
end

-- opts:
--   seed        number   -- deterministic seed (default: os.time-derived)
--   chunkname   string
--   passes      table    -- list of pass names to run (default PASS_ORDER)
--   disable     table    -- set of pass names to skip
--   name_style  string   -- "confusing" | "hex" | "short"
--   <pass>      table    -- per-pass options, keyed by pass name
function M.obfuscate(src, opts)
  opts = opts or {}
  local seed = opts.seed or 0
  if seed == 0 then
    seed = (os and os.time and (os.time() % 2147483647)) or 123456789
  end

  local rng = util.new_rng(seed)
  local namegen = util.new_namegen(rng, { style = opts.name_style })

  local chunk = parser.parse(src, opts.chunkname or "input")

  local ctx = {
    rng = rng,
    namegen = namegen,
    opts = opts,
    parser = parser,
    util = util,
  }

  local order = opts.passes or PASS_ORDER
  local disable = opts.disable or {}
  for _, name in ipairs(order) do
    if not disable[name] then
      local pass = load_pass(name)
      local result = pass.run(chunk, ctx)
      if result ~= nil then chunk = result end
    end
  end

  local header = opts.no_header and "" or
    ("-- Obfuscated with luaobf (seed=" .. seed .. ")\n")
  return header .. unparser.generate(chunk, { keep_attribs = true })
end

M.PASS_ORDER = PASS_ORDER
return M
