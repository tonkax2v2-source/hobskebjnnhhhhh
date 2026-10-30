-- runtime.lua
-- Produces the SOURCE of the VM interpreter that is embedded into obfuscated
-- output. The opcode constants are generated from opcodes.lua so the
-- interpreter and the compiler can never disagree on numbering.
--
-- The interpreter is a classic bytecode dispatch loop. It leans on the host
-- Lua for closures, upvalues, metatables, coroutines and GC; it only encodes
-- program structure. Every local is a box {v=...}; CLOSURE captures boxes, so
-- per-iteration closure capture is preserved.

local opcodes = require("src.vm.opcodes")

local M = {}

local function opcode_prelude(names)
  local t = {}
  for i, n in ipairs(names) do t[#t + 1] = "local " .. n .. "=" .. i end
  return table.concat(t, " ") .. " "
end

-- Interpreter body. Uses the opcode names defined by the prelude.
local BODY = [==[
local tpack=function(...) return {n=select('#',...),...} end
local tunpack=table.unpack or unpack
local exec
exec=function(proto,upvals,ENV,argpack)
  local code=proto.code
  local K=proto.consts
  local protos=proto.protos
  local np=proto.numparams
  local frame={}
  local nargs=argpack.n
  for i=1,np do frame[i]={v=argpack[i]} end
  local va={} local van=0
  if proto.is_vararg then
    for i=np+1,nargs do van=van+1 va[van]=argpack[i] end
  end
  local stk={} local top=0
  local marks={} local mtop=0
  local pc=1
  while true do
    local ins=code[pc] local op=ins[1] local a=ins[2] pc=pc+1
    if op==PUSHK then top=top+1 stk[top]=K[a]
    elseif op==PUSHNIL then top=top+1 stk[top]=nil
    elseif op==PUSHTRUE then top=top+1 stk[top]=true
    elseif op==PUSHFALSE then top=top+1 stk[top]=false
    elseif op==PUSHVARARG then
      if a==-1 then for i=1,van do top=top+1 stk[top]=va[i] end
      else for i=1,a do top=top+1 stk[top]=va[i] end end
    elseif op==NEWLOCAL then local v=stk[top] top=top-1 frame[a]={v=v}
    elseif op==DECLLOCAL then frame[a]={v=nil}
    elseif op==GETLOCAL then top=top+1 stk[top]=frame[a].v
    elseif op==SETLOCAL then frame[a].v=stk[top] top=top-1
    elseif op==GETUPVAL then top=top+1 stk[top]=upvals[a].v
    elseif op==SETUPVAL then upvals[a].v=stk[top] top=top-1
    elseif op==GETGLOBAL then top=top+1 stk[top]=ENV[K[a]]
    elseif op==SETGLOBAL then ENV[K[a]]=stk[top] top=top-1
    elseif op==GETTABLE then local k=stk[top] local t=stk[top-1] top=top-1 stk[top]=t[k]
    elseif op==SETTABLE then local v=stk[top] local k=stk[top-1] local t=stk[top-2] top=top-3 t[k]=v
    elseif op==NEWTABLE then top=top+1 stk[top]={}
    elseif op==SETINDEXK then local v=stk[top] local t=stk[top-1] top=top-2 t[K[a]]=v
    elseif op==SETINDEXI then local v=stk[top] local t=stk[top-1] top=top-2 t[a]=v
    elseif op==SETLIST then
      local base=marks[mtop] mtop=mtop-1 local t=stk[base]
      for i=base+1,top do t[a+(i-base)]=stk[i] end
      top=base-1
    elseif op==SELF then local t=stk[top] local m=t[K[a]] stk[top]=m top=top+1 stk[top]=t
    elseif op==OPENFRAME then mtop=mtop+1 marks[mtop]=top
    elseif op==ADJUST then
      local base=marks[mtop] mtop=mtop-1 local have=top-base
      if have<a then for i=have+1,a do top=top+1 stk[top]=nil end
      elseif have>a then top=base+a end
    elseif op==CALL then
      local base=marks[mtop] mtop=mtop-1
      local fn=stk[base+1] local n=top-base-1
      local args={} for i=1,n do args[i]=stk[base+1+i] end
      top=base
      local rets=tpack(fn(tunpack(args,1,n)))
      if a==-1 then for i=1,rets.n do top=top+1 stk[top]=rets[i] end
      elseif a~=0 then for i=1,a do top=top+1 stk[top]=rets[i] end end
    elseif op==RETURN then
      local base=marks[mtop] mtop=mtop-1 local n=top-base
      local r={} for i=1,n do r[i]=stk[base+i] end
      return tunpack(r,1,n)
    elseif op==RETURN0 then return
    elseif op==CLOSURE then
      local p2=protos[a] local desc=p2.upvals local ups={}
      for i=1,#desc do local d=desc[i]
        if d.kind=="local" then ups[i]=frame[d.index] else ups[i]=upvals[d.index] end
      end
      top=top+1 stk[top]=function(...) return exec(p2,ups,ENV,tpack(...)) end
    elseif op==ADD then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x+b
    elseif op==SUB then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x-b
    elseif op==MUL then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x*b
    elseif op==DIV then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x/b
    elseif op==MOD then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x%b
    elseif op==POW then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x^b
    elseif op==IDIV then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x//b
    elseif op==CONCAT then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x..b
    elseif op==BAND then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x&b
    elseif op==BOR then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x|b
    elseif op==BXOR then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x~b
    elseif op==SHL then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x<<b
    elseif op==SHR then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x>>b
    elseif op==EQ then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x==b)
    elseif op==NE then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x~=b)
    elseif op==LT then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x<b)
    elseif op==LE then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x<=b)
    elseif op==GT then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x>b)
    elseif op==GE then local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x>=b)
    elseif op==NEG then stk[top]=-stk[top]
    elseif op==NOT then stk[top]=not stk[top]
    elseif op==LEN then stk[top]=#stk[top]
    elseif op==BNOT then stk[top]=~stk[top]
    elseif op==JMP then pc=a
    elseif op==JMPIFFALSE then local v=stk[top] top=top-1 if not v then pc=a end
    elseif op==JMPIFTRUE then local v=stk[top] top=top-1 if v then pc=a end
    elseif op==JMPIFFALSEK then if not stk[top] then pc=a else top=top-1 end
    elseif op==JMPIFTRUEK then if stk[top] then pc=a else top=top-1 end
    elseif op==POP then top=top-a
    end
  end
end
]==]

-- Returns the interpreter source (opcode prelude + body). `exec` is left as a
-- local for the bootstrap to call.
function M.source()
  return opcode_prelude(opcodes.NAMES) .. BODY
end

return M
