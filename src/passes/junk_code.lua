-- junk_code.lua
-- Inserts dead branches guarded by opaque predicates that are always false,
-- built from constant arithmetic (no side effects, no globals). The branch
-- body is self-contained harmless code, so even a mis-analysis that executed
-- it could not change observable behaviour.
--
-- Insertions never go after a block terminator (return/break/goto), which
-- Lua requires to be the final statement of its block.

local util = require("src.util")

local M = {}

local function num(n) return { kind = "NumberExpr", text = tostring(n) } end

-- Always-false predicate of the form (a + b) ~= (b + a), or k < k, etc.
local function false_pred(rng)
  local a, b = rng:int(1, 9999), rng:int(1, 9999)
  local forms = {
    function()
      return {
        kind = "BinopExpr", op = "~=",
        lhs = { kind = "BinopExpr", op = "+", lhs = num(a), rhs = num(b) },
        rhs = { kind = "BinopExpr", op = "+", lhs = num(b), rhs = num(a) },
      }
    end,
    function()
      local k = rng:int(2, 9999)
      return { kind = "BinopExpr", op = "<", lhs = num(k), rhs = num(k) }
    end,
    function()
      local k = rng:int(2, 9999)
      return {
        kind = "BinopExpr", op = ">",
        lhs = { kind = "BinopExpr", op = "*", lhs = num(k), rhs = num(1) },
        rhs = { kind = "BinopExpr", op = "*", lhs = num(k), rhs = num(2) },
      }
    end,
  }
  return rng:choice(forms)()
end

local function junk_body(ctx)
  local jn = ctx.namegen.fresh()
  local decl = { name = jn, newname = jn, kind = "local", no_rename = true, uses = {} }
  local use = { kind = "NameExpr", name = jn, ref = decl }
  return {
    kind = "Block",
    stats = {
      { kind = "LocalStat", names = { decl }, exprs = { num(ctx.rng:int(1, 99999)) } },
      { kind = "AssignStat", targets = { use },
        exprs = { { kind = "BinopExpr", op = "+", lhs = use, rhs = num(ctx.rng:int(1, 999)) } } },
    },
  }
end

local function make_junk(ctx)
  return {
    kind = "IfStat",
    clauses = { { cond = false_pred(ctx.rng), body = junk_body(ctx) } },
    else_body = nil,
  }
end

local TERMINATORS = { ReturnStat = true, BreakStat = true, GotoStat = true }

function M.run(chunk, ctx)
  if ctx.opts.disable and ctx.opts.disable.junk_code then return chunk end
  local density = (ctx.opts.junk_code and ctx.opts.junk_code.density) or 0.55
  local rng = ctx.rng

  local blocks = {}
  util.walk(chunk, { Block = function(n) blocks[#blocks + 1] = n end })

  for _, blk in ipairs(blocks) do
    if rng:random() < density then
      local n = #blk.stats
      local maxpos = n + 1
      if n > 0 and TERMINATORS[blk.stats[n].kind] then
        maxpos = n  -- cannot insert at/after the terminator
      end
      local count = rng:int(1, 2)
      for _ = 1, count do
        local pos = rng:int(1, maxpos)
        table.insert(blk.stats, pos, make_junk(ctx))
        maxpos = maxpos + 1
      end
    end
  end
  return chunk
end

return M
