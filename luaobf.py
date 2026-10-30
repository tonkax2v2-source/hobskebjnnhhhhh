#!/usr/bin/env python3
"""luaobf.py -- Python front-end for the Lua obfuscator.

Runs the pure-Lua obfuscator through the bundled `lupa` runtime, so it works
even without a system Lua interpreter installed.

Usage:
    python3 luaobf.py [options] <input.lua> [-o output.lua]

Options:
    -o, --out FILE     write to FILE (default: stdout)
    -s, --seed N       deterministic seed (default: random)
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
        --verify       run original vs obfuscated and compare return values
    -h, --help         show this help

Levels:
    min       variable renaming only
    balanced  renaming + string/number obfuscation + const array + junk + wrap
    max       everything + control-flow flattening + encrypted loader
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def make_runtime():
    try:
        from lupa import LuaRuntime
    except ImportError:
        sys.exit("luaobf: the 'lupa' package is required (pip install lupa), "
                 "or run the Lua CLI: lua luaobf.lua")
    lua = LuaRuntime(unpack_returned_tuples=True)
    esc = ROOT.replace("\\", "\\\\")
    lua.execute(f'package.path = "{esc}/?.lua;{esc}/?/init.lua;" .. package.path')
    return lua


def build_opts(lua, args):
    """Builds the Lua options table from parsed CLI args."""
    mk = lua.eval("function() return {} end")
    opts = mk()
    disable = mk()
    if args.no_strings: disable["encrypt_strings"] = True
    if args.no_numbers: disable["number_mangle"] = True
    if args.no_rename:  disable["rename_vars"] = True
    if args.no_consts:  disable["const_array"] = True
    if args.no_junk:    disable["junk_code"] = True
    if args.no_wrap:    disable["finalize"] = True
    opts["disable"] = disable
    if args.seed is not None:
        opts["seed"] = args.seed
    if args.names:
        opts["name_style"] = args.names
    if args.no_header:
        opts["no_header"] = True
    if args.level:
        opts["level"] = args.level
    if args.cff:
        disable["control_flow"] = False
    if args.no_cff:
        disable["control_flow"] = True
    if args.pack:
        opts["pack"] = True
    if args.no_pack:
        opts["pack"] = False
    opts["chunkname"] = args.input
    return opts


def obfuscate(lua, src, opts):
    fn = lua.eval('function(src, opts) return require("src.obfuscator").obfuscate(src, opts) end')
    return fn(src, opts)


def deep(lua, v):
    t = lua.eval("function(x) return type(x) end")(v)
    if t == "table":
        d = {}
        for k in v.keys():
            d[deep(lua, k)] = deep(lua, v[k])
        return ("table", tuple(sorted(d.items(), key=lambda kv: repr(kv[0]))))
    return (t, v)


def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("input", nargs="?")
    p.add_argument("-o", "--out")
    p.add_argument("-s", "--seed", type=int)
    p.add_argument("-l", "--level", choices=["min", "balanced", "max"])
    p.add_argument("--cff", action="store_true")
    p.add_argument("--no-cff", action="store_true")
    p.add_argument("--pack", action="store_true")
    p.add_argument("--no-pack", action="store_true")
    p.add_argument("--names", choices=["confusing", "hex", "short"])
    p.add_argument("--no-strings", action="store_true")
    p.add_argument("--no-numbers", action="store_true")
    p.add_argument("--no-rename", action="store_true")
    p.add_argument("--no-consts", action="store_true")
    p.add_argument("--no-junk", action="store_true")
    p.add_argument("--no-wrap", action="store_true")
    p.add_argument("--no-header", action="store_true")
    p.add_argument("--verify", action="store_true")
    p.add_argument("-h", "--help", action="store_true")
    args = p.parse_args()

    if args.help or not args.input:
        print(__doc__)
        return 0 if args.help else 2

    with open(args.input, "r", encoding="utf-8") as f:
        src = f.read()

    lua = make_runtime()
    opts = build_opts(lua, args)
    try:
        result = obfuscate(lua, src, opts)
    except Exception as e:  # lupa surfaces Lua errors as exceptions
        sys.exit(f"luaobf: obfuscation failed: {e}")

    if args.verify:
        import lupa
        r1 = make_runtime()
        try:
            orig = deep(r1, r1.execute(src))
        except Exception as e:
            sys.exit(f"luaobf: original program errored during --verify: {e}")
        r2 = make_runtime()
        got = deep(r2, r2.execute(result))
        if orig != got:
            sys.stderr.write("luaobf: VERIFY FAILED — behaviour differs!\n")
            sys.stderr.write(f"  original : {orig}\n  obfuscated: {got}\n")
            return 1
        sys.stderr.write("luaobf: verify OK — behaviour preserved.\n")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(result)
        sys.stderr.write(f"luaobf: wrote {args.out} ({len(result)} bytes)\n")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
