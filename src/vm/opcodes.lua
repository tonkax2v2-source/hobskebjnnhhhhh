-- opcodes.lua
-- Canonical numbering for the VM instruction set. Shared by the compiler and
-- used to generate the interpreter's opcode constants, so the two never drift.
--
-- Stack notation: the operand stack grows to the right; "pop" removes the
-- rightmost. A "box" is a single-cell table {v=...}; every local lives in one
-- so host closures can capture it and each scope entry gets a fresh cell.

local NAMES = {
  "PUSHK",        -- a: const idx          push consts[a]
  "PUSHNIL",      --                       push nil
  "PUSHTRUE",     --                       push true
  "PUSHFALSE",    --                       push false
  "PUSHVARARG",   -- a: want(-1=all)       push varargs (padded/truncated to want)
  "NEWLOCAL",     -- a: slot               pop v; frame[a] = {v=v}
  "DECLLOCAL",    -- a: slot               frame[a] = {v=nil}
  "GETLOCAL",     -- a: slot               push frame[a].v
  "SETLOCAL",     -- a: slot               frame[a].v = pop
  "GETUPVAL",     -- a: idx                push upvals[a].v
  "SETUPVAL",     -- a: idx                upvals[a].v = pop
  "GETGLOBAL",    -- a: const idx (name)   push ENV[name]
  "SETGLOBAL",    -- a: const idx (name)   ENV[name] = pop
  "GETTABLE",     --                       pop k; pop t; push t[k]
  "SETTABLE",     --                       pop v; pop k; pop t; t[k]=v
  "NEWTABLE",     --                       push {}
  "SETINDEXK",    -- a: const idx (key)    pop v; pop t; t[key]=v
  "SETINDEXI",    -- a: int key            pop v; pop t; t[a]=v
  "SETLIST",      -- a: start offset       marker-based bulk array assign
  "SELF",         -- a: const idx (method) pop t; push t[method]; push t
  "OPENFRAME",    --                       push current top as a marker
  "ADJUST",       -- a: n                  force region since marker to n values
  "CALL",         -- a: nret(-1=all,0=none) call using last marker
  "RETURN",       --                       return values since last marker
  "RETURN0",      --                       return no values
  "CLOSURE",      -- a: proto idx          push closure of protos[a]
  "ADD", "SUB", "MUL", "DIV", "MOD", "POW", "IDIV", "CONCAT",
  "BAND", "BOR", "BXOR", "SHL", "SHR",
  "EQ", "NE", "LT", "LE", "GT", "GE",
  "NEG", "NOT", "LEN", "BNOT",
  "JMP",          -- a: target
  "JMPIFFALSE",   -- a: target   pop; jump if falsy
  "JMPIFTRUE",    -- a: target   pop; jump if truthy
  "JMPIFFALSEK",  -- a: target   peek; if falsy jump (keep) else pop   (and)
  "JMPIFTRUEK",   -- a: target   peek; if truthy jump (keep) else pop  (or)
  "POP",          -- a: n
}

local OP = {}
for i, n in ipairs(NAMES) do OP[n] = i end

return { OP = OP, NAMES = NAMES }
