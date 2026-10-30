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
| `heavy` | balanced **+ control-flow flattening + encrypted loader** | ~20–30× |
| `max` | **compile to a custom bytecode VM** (shuffled opcodes, encrypted instruction streams, per-proto keys, integrity checksum, decoy handlers), then obfuscate the VM itself and wrap it in the encrypted loader (lura.ph / Luraph style; strongest) | ~60–100× |

At `--level max` the program is compiled to a **custom bytecode virtual
machine**: your logic becomes data (an instruction array + constant pool)
executed by an embedded interpreter dispatch loop. The original control flow,
expressions and structure are gone — there is no Lua resembling your code left
to read. That VM is then itself run through the balanced passes (so even the
bytecode's string constants are encrypted and the interpreter is renamed) and
finally sealed in the encrypted loader:

```lua
local I0III1=function(s,a,b) ... end        -- tiny arithmetic decoder
return assert((loadstring or load)(I0III1("\221M\217W\209Jy\254...",171,88)))(...)
```

`heavy` is flattening + packing at the **source** level (your statements still
exist, just scrambled into state machines); `max` replaces your code with
bytecode entirely. You can also toggle each layer independently at any level:
`--vm` / `--no-vm`, `--cff` / `--no-cff`, `--pack` / `--no-pack`.

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
| **pack** *(loader)* | `--no-pack` | Encrypts the whole generated chunk and emits a runtime loader that decodes and `load()`s it. The program never appears as source. |

### The bytecode VM (`--vm`, enabled by `--level max`)

The strongest layer compiles the program to a **custom instruction set** and
ships a small interpreter that runs it — exactly the approach commercial
protectors like Luraph / lura.ph use.

* Each Lua function becomes a *proto*: an instruction stream, a `consts` pool,
  nested protos, and upvalue descriptors.
* A stack-based dispatch loop executes the opcodes. `for` loops are lowered to
  `while` + locals first, so the VM only handles a small core.
* **Correctness is structural, not re-implemented:** the VM delegates closures,
  upvalues, metatables, coroutines, varargs, multiple returns and GC to the host
  Lua. Every local is a boxed cell `{v=...}` allocated fresh on each scope entry,
  so closures capture exactly the right instance per iteration. A frame-marker
  stack handles variadic regions (`f(g())`, `{...}`, `return f()`).

Advanced hardening applied to the VM (all on by default at `--level max`):

* **Per-build opcode shuffling** — the numeric opcode assignment is randomised
  every build from the seed, so two obfuscations share no recognisable VM.
  There is no fixed signature to match and no universal devirtualizer.
* **Encrypted bytecode stream** — each proto's instructions AND its constant
  pool (every string and number) are packed into one encrypted byte string (not
  visible as instructions or data) and decoded at load. The structure of the
  program is gone even from the data.
* **Per-proto rolling keys** — every function's stream uses its own key, so the
  same opcode encodes to different bytes in different functions.
* **Randomised dispatch order** — the if/elseif branches of the interpreter are
  emitted in a shuffled, decoy-interleaved order per build, so even the VM's
  dispatch structure is polymorphic, not just the opcode numbers.
* **Integrity checksum (anti-tamper)** — each stream carries a checksum verified
  on decode; editing the bytecode corrupts the load instead of running modified
  logic.
* **Decoy opcodes** — the dispatch contains extra handlers for opcode numbers
  the compiler never emits, as pure noise against anyone mapping the VM.

Then the whole VM (interpreter + encrypted protos) is run through the balanced
passes — renaming it and encrypting its remaining string constants — and sealed
in the encrypted loader.

Source lives in `src/vm/` (`opcodes.lua`, `profile.lua`, `desugar.lua`,
`compiler.lua`, `runtime.lua`, `serialize.lua`). The interpreter's opcode
constants are generated from `opcodes.lua` and the build profile, so the
compiler and interpreter can never drift.

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
  vm/                   bytecode VM: opcodes, profile (opcode shuffle +
                        decoys), desugar, compiler, runtime (interpreter),
                        serialize (encrypted stream + checksum)
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

* No obfuscator is unbreakable. `max` raises the cost enormously — an analyst
  must recover your logic from a custom bytecode by understanding the embedded
  VM — but a determined reverser with the runtime can still, in principle, trace
  execution. This is true of every obfuscator, including the commercial ones.
* `load`/`loadstring` of *dynamically built* code inside your script is not
  itself obfuscated (only the literal that builds it).
* Debug info (`debug.getlocal`, variable names in tracebacks, accurate line
  numbers) is intentionally destroyed; at `--level max` stack traces point into
  the VM, not your source.
* `<close>` (to-be-closed) variables are not supported by the VM path (`max`);
  use `heavy` for code that relies on them.
* The VM adds interpretation overhead, so `max` is best for protecting logic
  that isn't in a tight performance-critical inner loop.
