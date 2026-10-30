-- runtime.lua
-- Produces the SOURCE of the VM interpreter embedded into obfuscated output,
-- specialised for a per-build profile (randomised opcode numbers + decoys).
--
-- The interpreter is a bytecode dispatch loop. It delegates closures, upvalues,
-- metatables, coroutines and GC to the host Lua; it only encodes program
-- structure. Every local is a box {v=...}; CLOSURE captures boxes so that
-- per-iteration closure capture is preserved.
--
-- Each proto's instruction stream is stored encrypted (per-proto rolling key)
-- and decoded at load by __vmdec, which also verifies an integrity checksum so
-- tampering with the bytecode corrupts the load.

local opcodes = require("src.vm.opcodes")

local M = {}

-- Emits `local NAME = <emitted number>` for every opcode, using the profile's
-- permutation so the numbers differ per build.
local function opcode_prelude(profile)
  local t = {}
  for i, n in ipairs(opcodes.NAMES) do
    t[#t + 1] = "local " .. n .. "=" .. profile.perm[i]
  end
  return table.concat(t, " ") .. " "
end

-- The bytecode decoder + integrity check. Pure integer arithmetic (no bitwise),
-- so it runs on Lua 5.1 - 5.4.
local DECODER = [==[
local __vmdec=function(s,k1,k2,chk)
  local pos=0 local sum=0 local sb=string.byte
  local function g()
    local p=pos
    local b0=(sb(s,p+1)-(k1+(p+1)*k2))%256
    local b1=(sb(s,p+2)-(k1+(p+2)*k2))%256
    local b2=(sb(s,p+3)-(k1+(p+3)*k2))%256
    local b3=(sb(s,p+4)-(k1+(p+4)*k2))%256
    pos=p+4
    sum=(sum+b0+b1*2+b2*3+b3*4)%16777213
    local n=b0+256*(b1+256*(b2+256*b3))
    if n>=2147483648 then n=n-4294967296 end
    return n
  end
  local cnt=g()
  local code={}
  for i=1,cnt do local o=g() local a=g() code[i]={o,a} end
  if sum~=chk then return error("integrity") end
  return code
end
]==]

-- Interpreter body. `-- @DECOYS@` is where decoy branches are spliced in.
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
-- @DECOYS@
    end
  end
end
]==]

-- Builds decoy branches: harmless stack no-ops for opcode numbers the compiler
-- never emits, so they are pure noise in the dispatch.
local function decoy_branches(profile)
  local t = {}
  for _, num in ipairs(profile.decoys) do
    local forms = {
      "    elseif op==" .. num .. " then top=top+1 stk[top]=a top=top-1",
      "    elseif op==" .. num .. " then local _=marks[mtop]",
      "    elseif op==" .. num .. " then stk[top+1]=a",
      "    elseif op==" .. num .. " then pc=pc+0",
    }
    t[#t + 1] = forms[(num % #forms) + 1]
  end
  return table.concat(t, "\n")
end

-- Returns the interpreter source for a given profile.
function M.source(profile)
  local body = BODY:gsub("%-%- @DECOYS@", (decoy_branches(profile):gsub("%%", "%%%%")))
  return opcode_prelude(profile) .. DECODER .. body
end

return M
