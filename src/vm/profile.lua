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

-- Key schedule shared by the obf-time encoder and the emitted runtime.
-- IMPORTANT: the arithmetic here MUST byte-for-byte match the text emitted by
-- runtime.lua (__kx / __mk). All intermediate products stay < 2^53 so integer
-- and double hosts (Lua 5.1 - 5.4) agree exactly. The self-test guards drift:
-- any mismatch makes decoding fail.
local MOD = 16777213

function M.master_of(seed)
  local m = (seed * 16807 + 1) % MOD
  m = (m * 16807 + 1) % MOD
  return m
end

-- Derives a per-proto (k1, k2) key pair from the runtime master and a salt.
function M.derive(master, salt)
  local x = (master + salt) % MOD
  x = (x * 16807 + 1) % MOD
  x = (x * 16807 + 1) % MOD
  return x % 256, (math.floor(x / 256) % 255) + 1
end

-- rng: a util RNG. Returns { perm = {canonical->emitted}, decoys = {ints},
-- total = highest emitted number, dispatch = {...}, key_seed = n }.
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

  local key_seed = rng:int(1, 16777212)

  return { perm = perm, decoys = decoys, total = total, dispatch = dispatch,
           key_seed = key_seed }
end

return M
