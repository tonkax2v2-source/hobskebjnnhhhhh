# luaobf

A source-to-source **Lua obfuscator** written in pure Lua, built the same way
the commercial services (Luraph / lura.ph / Prometheus) are: a real
**lexer → parser → AST → transformation passes → code generator** pipeline,
not regex hacks. Output is valid, runnable Lua that behaves identically to the
input but is hard to read and hard to recover.

It targets **Lua 5.1 – 5.4** (and LuaJIT): the transformations use only
portable constructs, and string decoding is pure integer arithmetic so no
bitwise operators are required at runtime.

> **Intended use:** protecting the intellectual property of *your own* Lua code
> (game scripts, plugins, commercial modules) before distribution — the same
> role as a JavaScript minifier/obfuscator. Don't use it to hide malicious
> code or to violate a platform's terms of service.

---

## Quick start

No system Lua? Use the Python front-end (it bundles a Lua runtime via `lupa`):

```bash
pip install lupa
python3 luaobf.py input.lua -o output.lua
python3 luaobf.py --level max input.lua -o output.lua   # maximum hardening
python3 luaobf.py input.lua --verify                    # prove behaviour is preserved
```

Have a Lua interpreter? Use the native CLI:

```bash
lua luaobf.lua input.lua -o output.lua
lua luaobf.lua -l max -s 1337 input.lua > output.lua
```

Both CLIs accept the same options.

### Hardening levels

| `--level` | What runs | Typical size |
|-----------|-----------|--------------|
| `min` | variable renaming only | ~1.3× |
| `balanced` *(default)* | renaming + string encryption + number mangling + constant array + junk code + IIFE wrap | ~3× |
| `max` | everything above **+ control-flow flattening + an encrypted runtime loader** | ~20–30× |

At `--level max` the entire program is flattened into state machines and then
encrypted into a blob that is decoded and `load()`-ed at runtime, so the output
contains no readable code or strings at all:

```lua
local I0III1=function(s,a,b) ... end            -- tiny arithmetic decoder
return assert((loadstring or load)(I0III1("\221M\217W\209Jy\254...",171,88)))(...)
```

You can also toggle the two heavy layers independently at any level:
`--cff` / `--no-cff` (control-flow flattening) and `--pack` / `--no-pack`
(encrypted loader).

---

## What it does (the passes)

The pipeline runs these passes in order. Each is individually switchable.

| Pass | Flag to disable | Effect |
|------|-----------------|--------|
| **encrypt_strings** | `--no-strings` | Every string literal is encoded and replaced by a call to an injected decoder. The encoding (`add/mod 256` with a random per-string key) is reversible with integer math only. Plaintext never appears in the output. |
| **number_mangle** | `--no-numbers` | Integer literals become equivalent arithmetic expressions, e.g. `100` → `(5843 - 5743)`. Floats/hex are left exact. |
| **rename_vars** | `--no-rename` | Scope-aware renaming of every local, parameter and loop variable to confusing identifiers (`Il_II0Iil`). Globals and table fields are provably untouched because each name was resolved to its declaration during parsing. |
| **const_array** | `--no-consts` | All string literals are hoisted into one shuffled constant table and referenced by index (`C[7]`) — the signature look of commercial obfuscators. |
| **control_flow** | `--no-cff` (max only) | Flattens each straight-line statement sequence into a shuffled state-machine dispatcher (`while true do if V==... end end`), so textual order no longer reflects execution order. |
| **junk_code** | `--no-junk` | Inserts dead branches guarded by opaque always-false predicates built from constant arithmetic. Harmless and never executed. |
| **finalize** | `--no-wrap` | Wraps the whole program in an immediately-invoked vararg closure `return (function(...) ... end)(...)`, forwarding arguments and return values. |
| **pack** *(loader)* | `--no-pack` (max only) | Encrypts the whole generated chunk and emits a runtime loader that decodes and `load()`s it. The program never appears as source. |

### Example

Input:

```lua
local function greet(name)
  print("Hello, " .. name)
end
greet("world")
```

Real output (`--no-junk --no-numbers -s 7` and reflowed; the tool emits one
line):

```lua
return (function(...)
  local __0010lIli_lIl = { "\220\165yD\r", "\203\\\215K\194\243[" }
  local IiiIl10il_i__ = string.byte
  local I_li1_lI00i_  = string.char
  local l0__liIlIIIl  = table.concat
  local function I___1Ii_1__I_li(I0__I1lI_1I0_i, l10_i0ll_, l__li__l)
    local li0Ii0I_ = {}
    for _III00__1l0__il = 1, #I0__I1lI_1I0_i do
      local Il0II_l0Ii = (_III00__1l0__il * l10_i0ll_ + l__li__l) % 256
      li0Ii0I_[_III00__1l0__il] =
        I_li1_lI00i_((IiiIl10il_i__(I0__I1lI_1I0_i, _III00__1l0__il) - Il0II_l0Ii) % 256)
    end
    return l0__liIlIIIl(li0Ii0I_)
  end
  local function i10iIIll1IlIll(IIIili1_ii)
    print(I___1Ii_1__I_li(__0010lIli_lIl[2], 116, 15) .. IIIili1_ii)
  end
  i10iIIll1IlIll(I___1Ii_1__I_li(__0010lIli_lIl[1], 209, 148))
end)(...)
```

With numbers and junk enabled (the default), the `256`/`116`/`148` constants
also become arithmetic (`(2218 - 1962)` …) and dead opaque-predicate branches
are sprinkled throughout.

---

## Options

```
-o, --out FILE     write to FILE (default: stdout)
-s, --seed N       deterministic seed (same seed -> identical output)
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
    --verify       (Python CLI) run both versions and compare results
-h, --help         show help
```

Seeding is deterministic: `-s 1337` always yields byte-identical output, which
is useful for reproducible builds. Omit it for a different result every run.

---

## Project layout

```
luaobf.lua              native Lua CLI
luaobf.py               Python CLI (uses bundled lupa runtime)
src/
  tokenizer.lua         Lua 5.1-5.4 lexer (long strings, hex floats, shebang…)
  parser.lua            recursive-descent parser; resolves names to scopes
  unparser.lua          AST -> source with precedence & token-boundary safety
  obfuscator.lua        pipeline orchestration
  util.lua              seedable PRNG, name generator, AST visitor
  passes/               one module per transformation
                        (encrypt_strings, number_mangle, rename_vars,
                         control_flow, const_array, junk_code, finalize)
examples/
  hello.lua, edge.lua   sample inputs (edge.lua stresses tricky syntax)
tools/
  run_lua.py            helper: roundtrip / obf / verify a single file
  selftest.py           full regression suite
```

---

## Correctness

Obfuscation that changes behaviour is worthless, so correctness is tested hard:

```bash
python3 tools/selftest.py
```

This (1) parses and regenerates **every bundled Lua source file** and checks the
result still compiles, and (2) runs each example through many pass-subset, level
(`min`/`balanced`/`max`) and seed combinations, executing original vs obfuscated
and deep-comparing their return values. The obfuscator can even obfuscate its
**own output repeatedly** (triple-obfuscation) with identical behaviour.

Control-flow flattening is designed to be provably safe: it runs *after*
renaming (so every declaration name is unique and splitting `local x = e` into
a hoisted `local x` plus `x = e` can never re-capture another variable), it only
flattens a block's direct statements (nested loop/branch bodies stay intact, so
closures keep their per-iteration captures), and it refuses blocks containing
`break`/`goto`/labels or `<const>`/`<close>` locals.

Tricky cases covered: multiple-return passthrough (never wrongly truncated by
parentheses), `repeat`/`until` seeing body locals, `goto`/labels, method chains,
operator precedence (`-2^2`, right-associative `..`), long strings, `\ddd`
escape boundaries, `<const>`/`<close>` attributes, varargs, and upvalue capture.

---

## Limitations

* It's a **source** obfuscator, not a bytecode VM. It raises the cost of reading
  and casual copying significantly, but a determined analyst with the runtime
  can still recover logic — true of every obfuscator.
* `load`/`loadstring` of *dynamically built* code inside your script is not
  itself obfuscated (only the literal that builds it).
* Debug info (`debug.getlocal`, variable names in tracebacks) is intentionally
  destroyed by renaming.
