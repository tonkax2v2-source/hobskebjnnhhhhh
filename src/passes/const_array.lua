-- const_array.lua
-- Hoists string literals into a single shuffled constant table and rewrites
-- each occurrence as an indexed lookup `C[k]`. Identical strings share a slot.
-- This runs after renaming, so it manages its own fresh, collision-free name.

local util = require("src.util")

local M = {}

local function new_string(v)
  return { kind = "StringExpr", value = v, _encrypted = true }
end

function M.run(chunk, ctx)
  if ctx.opts.disable and ctx.opts.disable.const_array then return chunk end

  -- Collect every real string literal node.
  local nodes = {}
  util.walk(chunk, {
    StringExpr = function(n)
      if not n.as_name then nodes[#nodes + 1] = n end
    end,
  })
  if #nodes < 2 then return chunk end

  -- Deduplicate by value -> slot, then shuffle the slot ordering.
  local values = {}       -- ordered unique values
  local slot_of = {}      -- value -> final index
  for _, n in ipairs(nodes) do
    if slot_of[n.value] == nil then
      values[#values + 1] = n.value
      slot_of[n.value] = true
    end
  end
  ctx.rng:shuffle(values)
  for i, v in ipairs(values) do slot_of[v] = i end

  -- Build the constant table declaration with its own stable name.
  local cname = ctx.namegen.fresh()
  local cdecl = { name = cname, newname = cname, kind = "local", no_rename = true, uses = {} }

  local fields = {}
  for _, v in ipairs(values) do
    fields[#fields + 1] = { kind = "list", value = new_string(v) }
  end
  local table_expr = { kind = "TableExpr", fields = fields }
  local decl_stat = { kind = "LocalStat", names = { cdecl }, exprs = { table_expr } }

  -- Rewrite each occurrence into C[slot].
  for _, n in ipairs(nodes) do
    local idx = slot_of[n.value]
    local repl = {
      kind = "IndexExpr",
      obj = { kind = "NameExpr", name = cname, ref = cdecl },
      index = { kind = "NumberExpr", text = tostring(idx) },
    }
    for k in pairs(n) do n[k] = nil end
    for k, v in pairs(repl) do n[k] = v end
  end

  table.insert(chunk.body.stats, 1, decl_stat)
  return chunk
end

return M
