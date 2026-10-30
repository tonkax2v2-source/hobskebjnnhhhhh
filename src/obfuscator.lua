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
  "control_flow",
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

-- Escapes an arbitrary byte string into a Lua double-quoted literal, using
-- 3-digit decimal escapes so a trailing literal digit cannot merge in.
local function lua_quote(s)
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

-- The outer "pack" layer: encrypts the whole generated chunk and emits a
-- runtime loader that decodes and load()s it. The actual program never
-- appears as source in the output. Reversible with integer math only, so it
-- runs on Lua 5.1 (loadstring) through 5.4 (load).
local function pack(code, rng, namegen)
  local a = rng:int(1, 255)
  local b = rng:int(0, 255)
  local out = {}
  for i = 1, #code do
    local k = (i * a + b) % 256
    out[i] = string.char((code:byte(i) + k) % 256)
  end
  local blob = table.concat(out)

  local D = namegen.fresh()
  local loader = string.format(
    "local %s=function(s,a,b)local t={}for i=1,#s do t[i]=string.char((string.byte(s,i)-((i*a+b)%%256))%%256)end return table.concat(t)end;" ..
    "return assert((loadstring or load)(%s(%s,%d,%d),\"=?\"))(...);",
    D, D, lua_quote(blob), a, b)
  return loader
end

-- Compiles the chunk to VM bytecode and returns a fresh parsed chunk of the
-- generated interpreter+bytecode source, so the normal passes can obfuscate it
-- as a second layer.
local function vm_transform(chunk)
  local desugar = require("src.vm.desugar")
  local compiler = require("src.vm.compiler")
  local serialize = require("src.vm.serialize")
  desugar.run(chunk)
  local mainproto = compiler.compile(chunk)
  local vmsrc = serialize.generate(mainproto)
  return parser.parse(vmsrc, "vm")
end

-- Level presets. Explicit opts (passes/disable/pack/vm) always win.
local LEVELS = {
  min = { passes = { "rename_vars" } },
  balanced = {
    disable = { control_flow = true },
    pack = false,
  },
  -- Source-level heavy: control-flow flattening + encrypted loader.
  heavy = {
    pack = true,
    junk_density = 0.9,
  },
  -- lura.ph-style: compile to a custom bytecode VM, then obfuscate the VM
  -- (rename + encrypt the bytecode strings + junk) and wrap in the loader.
  max = {
    vm = true,
    pack = true,
    disable = { control_flow = true },
    junk_density = 0.6,
  },
}

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

  -- Apply a level preset (default: balanced) without clobbering explicit opts.
  local level = LEVELS[opts.level or "balanced"] or LEVELS.balanced
  local disable = opts.disable or {}
  if level.disable then
    for k, v in pairs(level.disable) do
      if disable[k] == nil then disable[k] = v end
    end
  end
  local do_pack = opts.pack
  if do_pack == nil then do_pack = level.pack end
  local do_vm = opts.vm
  if do_vm == nil then do_vm = level.vm end
  if level.junk_density and not (opts.junk_code and opts.junk_code.density) then
    opts.junk_code = opts.junk_code or {}
    opts.junk_code.density = level.junk_density
  end

  local rng = util.new_rng(seed)
  local namegen = util.new_namegen(rng, { style = opts.name_style })

  local chunk = parser.parse(src, opts.chunkname or "input")

  if do_vm then
    chunk = vm_transform(chunk)
  end

  local ctx = {
    rng = rng,
    namegen = namegen,
    opts = opts,
    parser = parser,
    util = util,
  }

  local order = opts.passes or level.passes or PASS_ORDER
  for _, name in ipairs(order) do
    if not disable[name] then
      local pass = load_pass(name)
      local result = pass.run(chunk, ctx)
      if result ~= nil then chunk = result end
    end
  end

  local code = unparser.generate(chunk, { keep_attribs = true })

  if do_pack then
    code = pack(code, rng, namegen)
  end

  local header = opts.no_header and "" or
    ("-- Obfuscated with luaobf (level=" .. (opts.level or "balanced") ..
     ", seed=" .. seed .. ")\n")
  return header .. code
end

M.PASS_ORDER = PASS_ORDER
return M
