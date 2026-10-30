#!/usr/bin/env python3
"""Self-test suite for the obfuscator.

1. Round-trips (parse -> unparse) every bundled Lua source file and checks the
   regenerated code still loads (proves the parser/unparser handle real code).
2. Runs behavioural verify on the example programs under several pass subsets.
"""
import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)


# Lua 5.3+ dropped bit32; Luau provides it natively. Shim it so luau-target
# output (which uses bit32.*) can be exercised under the lupa test host.
_BIT32_SHIM = """
bit32 = bit32 or {
  band=function(a,b) return (a & b) % 4294967296 end,
  bor=function(a,b) return (a | b) % 4294967296 end,
  bxor=function(a,b) return (a ~ b) % 4294967296 end,
  lshift=function(a,b) return (a << b) % 4294967296 end,
  rshift=function(a,b) return (a >> b) % 4294967296 end,
  bnot=function(a) return (~a) % 4294967296 end,
}
"""


def make_runtime(luau=False):
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{ROOT}/?.lua;{ROOT}/?/init.lua;" .. package.path')
    if luau:
        lua.execute(_BIT32_SHIM)
    return lua


def deep(lua, v):
    t = lua.eval("function(x) return type(x) end")(v)
    if t == "table":
        d = {}
        for k in v.keys():
            d[deep(lua, k)] = deep(lua, v[k])
        return ("table", tuple(sorted(d.items(), key=lambda kv: repr(kv[0]))))
    return (t, v)


def roundtrip_loads(lua, src, name):
    f = lua.eval(
        'function(s,n) local p=require("src.parser"); local u=require("src.unparser");'
        ' return u.generate(p.parse(s,n)) end'
    )
    out = f(src, name)
    # Does the regenerated source load?
    loader = lua.eval("function(code) local fn, err = load(code); return fn ~= nil, err end")
    ok, err = loader(out)
    return ok, err, out


def verify(src, disable=None, seed=7, level=None, target=None):
    luau = target == "luau"
    r1 = make_runtime(luau)
    orig = deep(r1, r1.execute(src))
    r2 = make_runtime(luau)
    fn = r2.eval('function(src, opts) return require("src.obfuscator").obfuscate(src, opts) end')
    mk = r2.eval("function() return {} end")
    opts = mk()
    opts["seed"] = seed
    if level:
        opts["level"] = level
    if target:
        opts["target"] = target
    d = mk()
    for k in (disable or []):
        d[k] = True
    opts["disable"] = d
    obf = str(fn(src, opts))
    r3 = make_runtime(luau)
    got = deep(r3, r3.execute(obf))
    return orig == got, len(src), len(obf)


def main():
    failures = 0
    lua = make_runtime()

    print("== round-trip: all bundled Lua sources load after regeneration ==")
    files = sorted(glob.glob(f"{ROOT}/src/**/*.lua", recursive=True))
    files += [f"{ROOT}/luaobf.lua"]
    for path in files:
        src = open(path, encoding="utf-8").read()
        rel = os.path.relpath(path, ROOT)
        try:
            ok, err, _ = roundtrip_loads(lua, src, rel)
        except Exception as e:
            ok, err = False, str(e)
        print(f"  [{'OK ' if ok else 'XXX'}] {rel}")
        if not ok:
            print(f"        -> {err}")
            failures += 1

    print("\n== behavioural verify across pass subsets ==")
    all_passes = ["encrypt_strings", "number_mangle", "rename_vars",
                  "const_array", "junk_code", "finalize"]
    subsets = {
        "full pipeline": [],
        "rename only": [p for p in all_passes if p != "rename_vars"],
        "strings only": [p for p in all_passes if p != "encrypt_strings"],
        "numbers only": [p for p in all_passes if p != "number_mangle"],
        "no wrap": ["finalize"],
        "no junk": ["junk_code"],
    }
    for ex in ("examples/hello.lua", "examples/edge.lua"):
        src = open(f"{ROOT}/{ex}", encoding="utf-8").read()
        for label, disable in subsets.items():
            for seed in (1, 2, 1337):
                ok, so, sz = verify(src, disable, seed)
                tag = f"{ex} [{label}] seed={seed}"
                if ok:
                    print(f"  [OK ] {tag}  {so}->{sz}b")
                else:
                    print(f"  [XXX] {tag}  MISMATCH")
                    failures += 1

    print("\n== Luau (Roblox) target: level max (VM, getfenv + bit32, no pack) ==")
    for ex in ("examples/hello.lua", "examples/edge.lua", "examples/closures.lua"):
        src = open(f"{ROOT}/{ex}", encoding="utf-8").read()
        for seed in (1, 7, 1337):
            ok, so, sz = verify(src, [], seed, "max", "luau")
            tag = f"{ex} target=luau level=max seed={seed}"
            if ok:
                print(f"  [OK ] {tag}  {so}->{sz}b")
            else:
                print(f"  [XXX] {tag}  MISMATCH")
                failures += 1

    print("\n== level presets (min / balanced / heavy / max incl. CFF, VM, pack) ==")
    for ex in ("examples/hello.lua", "examples/edge.lua", "examples/closures.lua"):
        src = open(f"{ROOT}/{ex}", encoding="utf-8").read()
        for level in ("min", "balanced", "heavy", "max"):
            for seed in (1, 7, 1337):
                ok, so, sz = verify(src, [], seed, level)
                tag = f"{ex} level={level} seed={seed}"
                if ok:
                    print(f"  [OK ] {tag}  {so}->{sz}b")
                else:
                    print(f"  [XXX] {tag}  MISMATCH")
                    failures += 1

    print()
    if failures == 0:
        print("ALL TESTS PASSED")
        return 0
    print(f"{failures} FAILURE(S)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
