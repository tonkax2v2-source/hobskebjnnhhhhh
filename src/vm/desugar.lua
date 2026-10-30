-- desugar.lua
-- Lowers `for` loops into while + local before VM compilation, so the compiler
-- never has to deal with the iterator protocol or the fresh-per-iteration loop
-- variable. The original loop-variable declarations are reused unchanged, so
-- every NameExpr in the body keeps its resolved `ref`.
--
-- Numeric:
--   for v = e1, e2, e3 do B end
--   =>  do local i,limit,step = e1,e2,e3
--         while (step>0 and i<=limit) or (step<=0 and i>=limit) do
--           local v = i          -- fresh box each iteration
--           B
--           i = i + step
--         end
--       end
--
-- Generic:
--   for a,b,... in EXPR do B end
--   =>  do local f,s,ctrl = EXPR
--         while true do
--           local a,b,... = f(s, ctrl)     -- fresh boxes each iteration
--           if a == nil then break end
--           ctrl = a
--           B
--         end
--       end

local util = require("src.util")

local M = {}

local counter = 0
local function hidden_decl()
  counter = counter + 1
  return { name = "__vmfor" .. counter, kind = "local", uses = {} }
end

local function name_ref(decl)
  local n = { kind = "NameExpr", name = decl.name, ref = decl }
  decl.uses[#decl.uses + 1] = n
  return n
end

local function num(n) return { kind = "NumberExpr", text = tostring(n) } end
local function binop(op, l, r) return { kind = "BinopExpr", op = op, lhs = l, rhs = r } end

local function desugar_numeric(s)
  local di, dlimit, dstep = hidden_decl(), hidden_decl(), hidden_decl()
  local init = { kind = "LocalStat", names = { di, dlimit, dstep },
                 exprs = { s.start, s.limit, s.step or num(1) } }

  local cond = binop("or",
    binop("and", binop(">", name_ref(dstep), num(0)),
                 binop("<=", name_ref(di), name_ref(dlimit))),
    binop("and", binop("<=", name_ref(dstep), num(0)),
                 binop(">=", name_ref(di), name_ref(dlimit))))

  -- loop var is the original declaration, re-bound fresh each iteration
  local bind_v = { kind = "LocalStat", names = { s.var }, exprs = { name_ref(di) } }
  local incr = { kind = "AssignStat", targets = { name_ref(di) },
                 exprs = { binop("+", name_ref(di), name_ref(dstep)) } }

  local inner_stats = { bind_v }
  for _, st in ipairs(s.body.stats) do inner_stats[#inner_stats + 1] = st end
  inner_stats[#inner_stats + 1] = incr

  local while_stat = { kind = "WhileStat", cond = cond,
                       body = { kind = "Block", stats = inner_stats } }

  return { kind = "DoStat", body = { kind = "Block", stats = { init, while_stat } } }
end

local function desugar_generic(s)
  local df, ds, dctrl = hidden_decl(), hidden_decl(), hidden_decl()
  local init = { kind = "LocalStat", names = { df, ds, dctrl }, exprs = s.exprs }

  -- local a,b,... = f(s, ctrl)
  local call = { kind = "CallExpr", func = name_ref(df),
                 args = { name_ref(ds), name_ref(dctrl) } }
  local bind = { kind = "LocalStat", names = s.names, exprs = { call } }

  local first = s.names[1]
  local check = {
    kind = "IfStat",
    clauses = { {
      cond = binop("==", name_ref(first), { kind = "NilExpr" }),
      body = { kind = "Block", stats = { { kind = "BreakStat" } } },
    } },
    else_body = nil,
  }
  local advance = { kind = "AssignStat", targets = { name_ref(dctrl) },
                    exprs = { name_ref(first) } }

  local inner_stats = { bind, check, advance }
  for _, st in ipairs(s.body.stats) do inner_stats[#inner_stats + 1] = st end

  local while_stat = { kind = "WhileStat", cond = { kind = "TrueExpr" },
                       body = { kind = "Block", stats = inner_stats } }

  return { kind = "DoStat", body = { kind = "Block", stats = { init, while_stat } } }
end

local function desugar_in_block(block)
  local stats = block.stats
  for i = 1, #stats do
    local s = stats[i]
    if s.kind == "NumericForStat" then
      stats[i] = desugar_numeric(s)
    elseif s.kind == "GenericForStat" then
      stats[i] = desugar_generic(s)
    end
  end
end

-- Transforms the whole AST in place. Processing a block before walk recurses
-- means freshly created sub-blocks are themselves visited and desugared.
function M.run(chunk)
  util.walk(chunk, { Block = function(b) desugar_in_block(b) end })
  return chunk
end

return M
