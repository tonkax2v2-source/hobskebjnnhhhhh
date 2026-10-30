#!/usr/bin/env python3
"""Helper to run the Lua obfuscator through the bundled lupa runtime.

Usage:
    python3 tools/run_lua.py roundtrip examples/hello.lua
    python3 tools/run_lua.py obf examples/hello.lua [out.lua]
    python3 tools/run_lua.py verify examples/hello.lua

`verify` runs the original and the obfuscated program, then deep-compares
their return values to prove the transformation preserved behaviour.
"""
import sys
import os
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def make_runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    # Make `require("src.xxx")` resolve against the project root.
    lua.execute(f'package.path = "{ROOT}/?.lua;{ROOT}/?/init.lua;" .. package.path')
    return lua


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def do_roundtrip(path):
    lua = make_runtime()
    src = read(path)
    gen = lua.eval(
        """
        function(src)
            local parser = require("src.parser")
            local unparser = require("src.unparser")
            local ast = parser.parse(src, "input")
            return unparser.generate(ast)
        end
        """
    )
    out = gen(src)
    print(out)


def do_obf(path, outpath=None):
    lua = make_runtime()
    src = read(path)
    gen = lua.eval(
        """
        function(src, seed)
            local obf = require("src.obfuscator")
            return obf.obfuscate(src, { seed = seed, chunkname = "input" })
        end
        """
    )
    out = gen(src, 1337)
    if outpath:
        with open(outpath, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"wrote {outpath} ({len(out)} bytes)")
    else:
        print(out)


def _normalize(lua, value):
    """Recursively convert a Lua value into a comparable Python structure."""
    dump = lua.eval(
        """
        function(v, seen)
            local t = type(v)
            if t == 'table' then return 'T' end
            return t
        end
        """
    )
    return value


def _deep_to_py(lua, v):
    t = lua.eval("function(x) return type(x) end")(v)
    if t == "table":
        d = {}
        for k in v.keys():
            d[_deep_to_py(lua, k)] = _deep_to_py(lua, v[k])
        return ("table", tuple(sorted(d.items(), key=lambda kv: repr(kv[0]))))
    return (t, v)


def do_verify(path):
    src = read(path)

    # Run original.
    lua1 = make_runtime()
    orig_val = lua1.execute(src)
    orig = _deep_to_py(lua1, orig_val)

    # Obfuscate (using the same runtime family) then run.
    lua2 = make_runtime()
    obf = lua2.eval(
        """
        function(src, seed)
            local o = require("src.obfuscator")
            return o.obfuscate(src, { seed = seed, chunkname = "input" })
        end
        """
    )(src, 1337)

    lua3 = make_runtime()
    obf_val = lua3.execute(obf)
    got = _deep_to_py(lua3, obf_val)

    if orig == got:
        print("VERIFY OK — obfuscated output is behaviourally identical.")
        print(f"  original size : {len(src)} bytes")
        print(f"  obfuscated    : {len(obf)} bytes")
        return 0
    else:
        print("VERIFY FAILED — outputs differ:")
        print("  original  :", orig)
        print("  obfuscated:", got)
        return 1


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, path = argv[1], argv[2]
    if cmd == "roundtrip":
        do_roundtrip(path)
    elif cmd == "obf":
        do_obf(path, argv[3] if len(argv) > 3 else None)
    elif cmd == "verify":
        return do_verify(path)
    else:
        print("unknown command:", cmd)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
