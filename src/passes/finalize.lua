-- finalize.lua
-- Wraps the whole program in an immediately-invoked vararg function:
--
--     return (function(...) <program> end)(...)
--
-- This adds an outer scope layer, hides all top-level locals inside a
-- closure, and transparently forwards both the script's varargs and its
-- return values. Behaviour is unchanged.

local M = {}

function M.run(chunk, ctx)
  if ctx.opts.disable and ctx.opts.disable.finalize then return chunk end
  if ctx.opts.finalize and ctx.opts.finalize.wrap == false then return chunk end

  local inner_block = { kind = "Block", stats = chunk.body.stats }

  local func = {
    kind = "FunctionExpr",
    params = {},
    is_vararg = true,
    is_method = false,
    body = inner_block,
    scope = {},
  }

  local call = {
    kind = "CallExpr",
    func = { kind = "ParenExpr", expr = func },
    args = { { kind = "VarargExpr" } },
  }

  chunk.body = {
    kind = "Block",
    stats = { { kind = "ReturnStat", exprs = { call } } },
  }
  return chunk
end

return M
