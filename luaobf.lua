#!/usr/bin/env lua
-- luaobf.lua -- command line interface for the Lua obfuscator.
--
-- Usage:
--   lua luaobf.lua [options] <input.lua> [-o output.lua]
--
-- Options:
--   -o, --out FILE     write to FILE (default: stdout)
--   -s, --seed N       deterministic seed (default: random by clock)
--   -l, --level LVL    preset: min | balanced | max   (default: balanced)
--       --cff          force-enable control-flow flattening
--       --no-cff       force-disable control-flow flattening
--       --pack         force-enable the encrypted loader layer
--       --no-pack      force-disable the encrypted loader layer
--       --names STYLE  identifier style: confusing | hex | short
--       --no-strings   disable string encryption
--       --no-numbers   disable number mangling
--       --no-rename    disable variable renaming
--       --no-consts    disable constant-array extraction
--       --no-junk      disable dead/junk code
--       --no-wrap      disable the outer IIFE wrapper
--       --no-header    omit the leading comment header
--   -h, --help         show this help
--
-- Make the project importable regardless of the current directory.
local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*[/\\])") or "./"
end
package.path = script_dir() .. "?.lua;" .. script_dir() .. "?/init.lua;" .. package.path

local obfuscator = require("src.obfuscator")

local HELP = [[
luaobf -- a Lua source obfuscator

Usage: lua luaobf.lua [options] <input.lua> [-o output.lua]

Options:
  -o, --out FILE     write to FILE (default: stdout)
  -s, --seed N       deterministic seed (default: random by clock)
  -l, --level LVL    preset: min | balanced | max   (default: balanced)
      --cff          force-enable control-flow flattening
      --no-cff       force-disable control-flow flattening
      --pack         force-enable the encrypted loader layer
      --no-pack      force-disable the encrypted loader layer
      --names STYLE  identifier style: confusing | hex | short
      --no-strings   disable string encryption
      --no-numbers   disable number mangling
      --no-rename    disable variable renaming
      --no-consts    disable constant-array extraction
      --no-junk      disable dead/junk code
      --no-wrap      disable the outer IIFE wrapper
      --no-header    omit the leading comment header
  -h, --help         show this help

Levels:
  min       variable renaming only (fast, light)
  balanced  renaming + string/number obfuscation + const array + junk + wrap
  max       everything above + control-flow flattening + encrypted loader
]]

local function die(msg)
  io.stderr:write("luaobf: " .. msg .. "\n")
  os.exit(1)
end

local function parse_args(argv)
  local opts = { disable = {} }
  local input, output
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "-h" or a == "--help" then
      io.write(HELP); os.exit(0)
    elseif a == "-o" or a == "--out" then
      i = i + 1; output = argv[i] or die("missing filename after " .. a)
    elseif a == "-s" or a == "--seed" then
      i = i + 1; opts.seed = tonumber(argv[i] or "") or die("invalid seed")
    elseif a == "-l" or a == "--level" then
      i = i + 1; opts.level = argv[i] or die("missing level")
      if not ({ min = 1, balanced = 1, max = 1 })[opts.level] then
        die("invalid level '" .. tostring(opts.level) .. "' (min|balanced|max)")
      end
    elseif a == "--cff" then opts.disable.control_flow = false
    elseif a == "--no-cff" then opts.disable.control_flow = true
    elseif a == "--pack" then opts.pack = true
    elseif a == "--no-pack" then opts.pack = false
    elseif a == "--names" then
      i = i + 1; opts.name_style = argv[i] or die("missing style")
    elseif a == "--no-strings" then opts.disable.encrypt_strings = true
    elseif a == "--no-numbers" then opts.disable.number_mangle = true
    elseif a == "--no-rename" then opts.disable.rename_vars = true
    elseif a == "--no-consts" then opts.disable.const_array = true
    elseif a == "--no-junk" then opts.disable.junk_code = true
    elseif a == "--no-wrap" then opts.disable.finalize = true
    elseif a == "--no-header" then opts.no_header = true
    elseif a:sub(1, 1) == "-" and a ~= "-" then
      die("unknown option '" .. a .. "' (try --help)")
    else
      if input then die("multiple input files given") end
      input = a
    end
    i = i + 1
  end
  if not input then die("no input file (try --help)") end
  return input, output, opts
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then die("cannot open '" .. path .. "': " .. tostring(err)) end
  local data = f:read("*a"); f:close()
  return data
end

local function main(argv)
  local input, output, opts = parse_args(argv)
  opts.chunkname = input
  local src = read_file(input)
  local ok, result = pcall(obfuscator.obfuscate, src, opts)
  if not ok then die("obfuscation failed: " .. tostring(result)) end
  if output then
    local f, err = io.open(output, "wb")
    if not f then die("cannot write '" .. output .. "': " .. tostring(err)) end
    f:write(result); f:close()
    io.stderr:write(string.format("luaobf: wrote %s (%d bytes)\n", output, #result))
  else
    io.write(result)
  end
end

main(arg or {})
