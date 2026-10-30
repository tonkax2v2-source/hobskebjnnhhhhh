-- control_flow.lua
-- Control-flow flattening: rewrites a straight-line statement sequence into a
-- state-machine dispatcher:
--
--     local V = <entry>
--     while true do
--       if     V == <l1> then <stmt a>  V = <l2>
--       elseif V == <l7> then <stmt c>  V = <lend>
--       elseif V == <l4> then <stmt b>  V = <l7>
--       elseif V == <lend> then break end
--     end
--
-- The if-clauses are emitted in shuffled order, so the textual order no longer
-- reflects execution order.
--
-- Correctness is guaranteed by three rules:
--   * This runs AFTER rename_vars, so every declaration already has a globally
--     unique name. Splitting `local x = e` into a hoisted `local x` plus an
--     in-state `x = e` therefore can never re-capture a different variable.
--   * Only a block's *direct* statements are flattened; nested blocks (loop and
--     branch bodies) stay intact and are flattened independently, so a local
--     captured by a closure inside a loop keeps its per-iteration instance.
--   * Blocks that directly contain break / goto / labels, or a <const>/<close>
--     attributed local, are left untouched (a wrapping `while true` would steal
--     their break, and hoisting would change close/const semantics).

local util = require("src.util")

local M = {}

local function num(n) return { kind = "NumberExpr", text = tostring(n) } end

local function qualifies(block)
  local stats = block.stats
  if #stats < 3 then return false end
  for _, s in ipairs(stats) do
    local k = s.kind
    if k == "BreakStat" or k == "GotoStat" or k == "LabelStat" then
      return false
    end
    if k == "LocalStat" then
      for _, d in ipairs(s.names) do
        if d.attrib then return false end
      end
    end
  end
  return true
end

-- Builds the (hoisted declaration list, per-statement action) decomposition.
local function decompose(stats)
  local hoist = {}     -- declaration-only statements to emit before the loop
  local actions = {}   -- one entry per original statement: a stmt or false
  for _, s in ipairs(stats) do
    if s.kind == "LocalStat" then
      hoist[#hoist + 1] = { kind = "LocalStat", names = s.names, exprs = {} }
      if #s.exprs > 0 then
        local targets = {}
        for _, d in ipairs(s.names) do
          targets[#targets + 1] = { kind = "NameExpr", name = d.name, ref = d }
        end
        actions[#actions + 1] =
          { kind = "AssignStat", targets = targets, exprs = s.exprs }
      else
        actions[#actions + 1] = false
      end
    elseif s.kind == "LocalFunctionStat" then
      hoist[#hoist + 1] = { kind = "LocalStat", names = { s.name }, exprs = {} }
      actions[#actions + 1] = {
        kind = "AssignStat",
        targets = { { kind = "NameExpr", name = s.name.name, ref = s.name } },
        exprs = { s.func },
      }
    else
      actions[#actions + 1] = s
    end
  end
  return hoist, actions
end

local function flatten(block, ctx)
  local rng = ctx.rng
  local hoist, actions = decompose(block.stats)
  local n = #actions

  -- Distinct random labels for each state plus a terminal label.
  local labels = {}
  local seen = {}
  local total = n + 1
  while #labels < total do
    local v = rng:int(100000, 9999999)
    if not seen[v] then seen[v] = true; labels[#labels + 1] = v end
  end
  local terminal = labels[total]

  -- State variable.
  local vname = ctx.namegen.fresh()
  local vdecl = { name = vname, newname = vname, kind = "local", no_rename = true, uses = {} }
  local function vref() return { kind = "NameExpr", name = vname, ref = vdecl } end
  local function set_v(label)
    return { kind = "AssignStat", targets = { vref() }, exprs = { num(label) } }
  end

  -- Build one clause per state.
  local clauses = {}
  for i = 1, n do
    local body_stats = {}
    local act = actions[i]
    local is_return = act and act.kind == "ReturnStat"
    if act then body_stats[#body_stats + 1] = act end
    if not is_return then
      -- advance to the next state (terminal after the last one)
      local nextl = (i < n) and labels[i + 1] or terminal
      body_stats[#body_stats + 1] = set_v(nextl)
    end
    clauses[#clauses + 1] = {
      cond = { kind = "BinopExpr", op = "==", lhs = vref(), rhs = num(labels[i]) },
      body = { kind = "Block", stats = body_stats },
    }
  end
  -- Terminal clause: break out of the dispatcher.
  clauses[#clauses + 1] = {
    cond = { kind = "BinopExpr", op = "==", lhs = vref(), rhs = num(terminal) },
    body = { kind = "Block", stats = { { kind = "BreakStat" } } },
  }

  rng:shuffle(clauses)

  local dispatch_if = { kind = "IfStat", clauses = clauses, else_body = nil }
  local while_stat = {
    kind = "WhileStat",
    cond = { kind = "TrueExpr" },
    body = { kind = "Block", stats = { dispatch_if } },
  }

  -- Assemble: hoisted declarations, entry state, dispatcher loop.
  local new_stats = {}
  for _, h in ipairs(hoist) do new_stats[#new_stats + 1] = h end
  new_stats[#new_stats + 1] =
    { kind = "LocalStat", names = { vdecl }, exprs = { num(labels[1]) } }
  new_stats[#new_stats + 1] = while_stat

  block.stats = new_stats
end

function M.run(chunk, ctx)
  if ctx.opts.disable and ctx.opts.disable.control_flow then return chunk end
  -- Collect qualifying blocks first, then transform, so the dispatcher blocks
  -- we create are never themselves re-flattened.
  local blocks = {}
  util.walk(chunk, { Block = function(n) blocks[#blocks + 1] = n end })
  for _, b in ipairs(blocks) do
    if qualifies(b) then flatten(b, ctx) end
  end
  return chunk
end

return M
