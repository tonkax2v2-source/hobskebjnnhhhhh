-- strip_encfunc.lua
-- Unwraps the per-function encryption macro for pipelines that are NOT the VM
-- (where the macro has no meaning). `LPH_ENCFUNC(function ... end)` /
-- `ENCFUNC(function ... end)` becomes just the inner function, so the output
-- still runs. The VM path handles the macro itself (marking the proto for
-- encryption); there it is consumed before this pass ever sees it.

local util = require("src.util")

local M = {}

local function is_macro(node)
  if node.kind ~= "CallExpr" then return false end
  local f = node.func
  if f.kind ~= "NameExpr" then return false end
  if f.name ~= "LPH_ENCFUNC" and f.name ~= "ENCFUNC" then return false end
  return #node.args == 1 and node.args[1].kind == "FunctionExpr"
end

function M.run(chunk, ctx)
  -- Phase 1: rewrite each macro call expression into its inner function,
  -- mutating the node in place so every reference to it is updated.
  util.walk(chunk, {
    CallExpr = function(node)
      if is_macro(node) then
        local fn = node.args[1]
        for k in pairs(node) do node[k] = nil end
        for k, v in pairs(fn) do node[k] = v end
      end
    end,
  })
  -- Phase 2: a bare `ENCFUNC(f)` statement now has a FunctionExpr as its call;
  -- a function expression is not a valid statement, and defining it has no
  -- side effects, so drop it to an empty do-block.
  util.walk(chunk, {
    Block = function(b)
      for i, s in ipairs(b.stats) do
        if s.kind == "CallStat" and s.call.kind == "FunctionExpr" then
          b.stats[i] = { kind = "DoStat", body = { kind = "Block", stats = {} }, scope = {} }
        end
      end
    end,
  })
  return chunk
end

return M
