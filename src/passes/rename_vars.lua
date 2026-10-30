-- rename_vars.lua
-- Renames every local, parameter and loop variable to a fresh confusing
-- identifier. Globals and table fields are never touched because the parser
-- resolved each NameExpr to its declaration (or to nil for a global), and the
-- unparser emits `ref.newname` when a ref exists.
--
-- A declaration is skipped when it already carries `newname` (so synthetic
-- helpers injected by earlier passes keep their chosen names) or an explicit
-- `no_rename` flag.

local util = require("src.util")

local M = {}

local function collect(chunk)
  local decls = {}
  local seen = {}
  local function add(d)
    if d and not seen[d] and not d.newname and not d.no_rename then
      seen[d] = true
      decls[#decls + 1] = d
    end
  end
  util.walk(chunk, {
    LocalStat = function(n) for _, d in ipairs(n.names) do add(d) end end,
    LocalFunctionStat = function(n) add(n.name) end,
    NumericForStat = function(n) add(n.var) end,
    GenericForStat = function(n) for _, d in ipairs(n.names) do add(d) end end,
    FunctionExpr = function(n) for _, d in ipairs(n.params) do add(d) end end,
  })
  return decls
end

function M.run(chunk, ctx)
  local decls = collect(chunk)
  -- Shuffle so names are not assigned in source order (defeats trivial
  -- "first local is aaa" assumptions).
  ctx.rng:shuffle(decls)
  for _, d in ipairs(decls) do
    d.newname = ctx.namegen.fresh()
  end
  return chunk
end

return M
