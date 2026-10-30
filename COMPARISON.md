# How luaobf compares to commercial Lua obfuscators

This summarises publicly documented techniques of well-known Lua obfuscators
and how `luaobf --level max` compares. Luraph, MoonSec and IronBrew are
closed-source or community tools; the technical details below come from
third-party reverse-engineering write-ups and vendor docs, so treat them as
secondhand and possibly version-specific.

## What the big tools do

**Luraph / lura.ph** (commercial, VM-based, the strongest of the group)
- Compiles each function to a **custom VM bytecode**, packs constants/upvalues
  into a data heap, embeds a complex interpreter.
- Non-standard bytecode layout (v14 used structure-of-arrays) to defeat
  standard decompilers; **flattened dispatch loop** (v15).
- **Encrypted string/function buffers** (`LPH_ENCSTR`, `LPH_ENCFUNC`,
  `LPH_ENCBUF`) with **lazy, runtime-keyed decryption** — constants are decoded
  on demand with keys derived during execution.
- **Anti-tamper crash traps** (`LPH_CRASH()`); selective macros
  (`LPH_NO_VIRTUALIZE` / `VM(NONE)`, `PRESET(FAST)`).

**MoonSec V3** — control-flow flattening (state machines + opaque predicates)
plus bytecode virtualization with custom opcodes; the hardest variants key the
opcode permutation and constant decryptor from **runtime-derived** values.

**IronBrew2** (open source) — VM-based Lua 5.1; reimplements the interpreter and
runs custom/re-encoded bytecode. The common ancestor of many later tools.

**Prometheus** (open source) — AST-level: control-flow flattening, constant and
string encryption, anti-tamper. Not a full VM.

The recurring theme for "most hardened": a custom bytecode VM, **runtime-derived
keys**, **lazy constant decryption**, per-build opcode permutation, anti-tamper
feeding the decryptor, and per-build polymorphism.

## Feature comparison

| Technique | Commercial tools | luaobf (`--level max`) |
|-----------|:----------------:|:----------------------:|
| Custom bytecode VM | yes | **yes** |
| Encrypted bytecode + constant pool | yes | **yes** |
| Per-build opcode shuffling | yes | **yes** |
| Randomised dispatch / polymorphic VM | yes | **yes** |
| Per-proto / per-function keys | yes | **yes** |
| **Runtime-derived keys** | yes | **yes** (`__kx` key schedule) |
| **Lazy constant decryption** | yes | **yes** (metatable, cached) |
| Integrity / anti-tamper | yes (crash/garbage) | **yes** (checksum → abort) |
| Control-flow flattening | yes | yes (source level, `heavy`/`max`) |
| Decoy handlers / junk | yes | **yes** |
| Encrypted loader / stacked decode | yes | **yes** (`pack`) |
| Per-function selective encryption (ENCFUNC) | yes | **yes** (`LPH_ENCFUNC` / `ENCFUNC`) |
| Active anti-debugger / detection-evasion | some | **intentionally omitted** |

## Honest assessment

luaobf matches the **core architecture** of the strongest commercial tools and,
with runtime-derived keys and lazy constant decryption, closes the gaps that
third-party analyses cite as what actually stops static deobfuscation.

luaobf targets **standard Lua 5.1–5.4 / LuaJIT / FiveM** (`--target lua`) and
**Roblox Luau** (`--target luau`). The Luraph sample that motivated this is a
Luau/Roblox build (it uses `buffer`, `typeof`, `getfenv`); for that target
luaobf's VM uses `getfenv` for globals and `bit32.*` for bitwise operations,
and drops the `loadstring`-based loader since Roblox has no `loadstring`.

Remaining differences are incremental: a true dual/nested VM, and using Luau's
native `buffer` type for the bytecode (luaobf uses a string, which runs the
same). Active anti-debugging and detection-evasion are **deliberately not
implemented** — the included anti-tamper is a benign load-time integrity check
of your own bytecode.

**No obfuscator is unbreakable.** Luraph v15, MoonSec V3 and IronBrew all have
public deobfuscators/devirtualizers; obfuscation raises the cost of analysis, it
does not make recovery impossible. The variants that resist tooling best are
exactly the ones using runtime-derived keys, which luaobf now does.

## Sources

Third-party reverse-engineering projects and vendor docs (secondhand):
Deobfuscator-Luraph-V15 (caomod2077), Luraph dashboard macro docs,
ferib.dev Luraph devirtualization series, MoonsecDeobfuscator (tupsutumppu),
disrobe wiki, IronBrew-2 (Trollicus), Prometheus (prometheus-lua), MoonVeil docs,
PELock Lua Virtualizer. See the project discussion for links.
