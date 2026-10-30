-- profile.lua
-- A per-build "VM profile": a random bijection from canonical opcode numbers to
-- the numbers actually emitted in this build, plus a set of decoy opcode numbers
-- that the compiler never emits (pure noise handlers in the interpreter).
--
-- Because the opcode numbering is randomized every build, two obfuscations of
-- the same input share no recognisable VM — there is no universal devirtualizer
-- and signature matching on the dispatch is defeated.

local opcodes = require("src.vm.opcodes")

local M = {}

-- rng: a util RNG. Returns { perm = {canonical->emitted}, decoys = {ints},
-- total = highest emitted number }.
function M.build(rng)
  local n = #opcodes.NAMES
  local decoy_count = rng:int(6, 16)
  local total = n + decoy_count

  -- A shuffled list of all emitted numbers [1..total].
  local pool = {}
  for i = 1, total do pool[i] = i end
  rng:shuffle(pool)

  local perm = {}
  for i = 1, n do perm[i] = pool[i] end
  local decoys = {}
  for i = n + 1, total do decoys[#decoys + 1] = pool[i] end

  -- Dispatch order: the real handlers (by canonical opcode index) interleaved
  -- with the decoy numbers, all in one shuffled sequence, so the textual order
  -- of the if/elseif chain is randomised per build too.
  local dispatch = {}
  for i = 1, n do dispatch[#dispatch + 1] = { op = i } end
  for _, d in ipairs(decoys) do dispatch[#dispatch + 1] = { decoy = d } end
  rng:shuffle(dispatch)

  return { perm = perm, decoys = decoys, total = total, dispatch = dispatch }
end

return M
