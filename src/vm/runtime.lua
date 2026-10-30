-- runtime.lua
-- Produces the SOURCE of the VM interpreter embedded into obfuscated output,
-- specialised for a per-build profile:
--   * randomised opcode numbers (profile.perm)
--   * randomised dispatch branch order, interleaved with decoy handlers
--     (profile.dispatch)
--
-- Each proto's constants AND instruction stream are packed into one encrypted
-- byte string (per-proto rolling key) with an integrity checksum, decoded at
-- load by __vmdec. Nothing of the program is visible as code or constants.
--
-- The VM delegates closures, upvalues, metatables, coroutines, varargs,
-- multiple returns and GC to the host Lua; every local is a box {v=...} so
-- per-iteration closure capture is preserved.

local opcodes = require("src.vm.opcodes")

local M = {}

local function opcode_prelude(profile)
  local t = {}
  for i, n in ipairs(opcodes.NAMES) do
    t[#t + 1] = "local " .. n .. "=" .. profile.perm[i]
  end
  return table.concat(t, " ") .. " "
end

-- Decoder + proto assembler. Pure integer arithmetic (5.1 - 5.4 safe).
local DECODER = [==[
local __vmdec=function(s,k1,k2,chk)
  local pos=0 local sum=0 local sb=string.byte local sc=string.char
  local function gb()
    pos=pos+1
    local pb=(sb(s,pos)-(k1+pos*k2))%256
    sum=(sum+pb*(((pos-1)%7)+1))%16777213
    return pb
  end
  local function g()
    local b0=gb() local b1=gb() local b2=gb() local b3=gb()
    local n=b0+256*(b1+256*(b2+256*b3))
    if n>=2147483648 then n=n-4294967296 end
    return n
  end
  local function gstr()
    local len=g() local t={} for i=1,len do t[i]=sc(gb()) end return table.concat(t)
  end
  local kcount=g()
  local K={}
  for i=1,kcount do
    local tag=gb()
    if tag==0 then K[i]=gstr()
    elseif tag==1 then K[i]=tonumber(gstr())
    elseif tag==2 then K[i]=true
    elseif tag==3 then K[i]=false end
  end
  local ccount=g()
  local code={}
  for i=1,ccount do local o=g() local a=g() code[i]={o,a} end
  if sum~=chk then return error("integrity") end
  return K,code
end
local __mkproto=function(np,va,upvals,protos,s,k1,k2,chk)
  local K,code=__vmdec(s,k1,k2,chk)
  return {numparams=np,is_vararg=va,upvals=upvals,protos=protos,consts=K,code=code}
end
]==]

local HEAD = [==[
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
]==]

local TAIL = [==[
    end
  end
end
]==]

-- Per-opcode handler bodies (statements only; no `then`).
local HANDLERS = {
  PUSHK = "top=top+1 stk[top]=K[a]",
  PUSHNIL = "top=top+1 stk[top]=nil",
  PUSHTRUE = "top=top+1 stk[top]=true",
  PUSHFALSE = "top=top+1 stk[top]=false",
  PUSHVARARG = "if a==-1 then for i=1,van do top=top+1 stk[top]=va[i] end else for i=1,a do top=top+1 stk[top]=va[i] end end",
  NEWLOCAL = "local v=stk[top] top=top-1 frame[a]={v=v}",
  DECLLOCAL = "frame[a]={v=nil}",
  GETLOCAL = "top=top+1 stk[top]=frame[a].v",
  SETLOCAL = "frame[a].v=stk[top] top=top-1",
  GETUPVAL = "top=top+1 stk[top]=upvals[a].v",
  SETUPVAL = "upvals[a].v=stk[top] top=top-1",
  GETGLOBAL = "top=top+1 stk[top]=ENV[K[a]]",
  SETGLOBAL = "ENV[K[a]]=stk[top] top=top-1",
  GETTABLE = "local k=stk[top] local t=stk[top-1] top=top-1 stk[top]=t[k]",
  SETTABLE = "local v=stk[top] local k=stk[top-1] local t=stk[top-2] top=top-3 t[k]=v",
  NEWTABLE = "top=top+1 stk[top]={}",
  SETINDEXK = "local v=stk[top] local t=stk[top-1] top=top-2 t[K[a]]=v",
  SETINDEXI = "local v=stk[top] local t=stk[top-1] top=top-2 t[a]=v",
  SETLIST = "local base=marks[mtop] mtop=mtop-1 local t=stk[base] for i=base+1,top do t[a+(i-base)]=stk[i] end top=base-1",
  SELF = "local t=stk[top] local m=t[K[a]] stk[top]=m top=top+1 stk[top]=t",
  OPENFRAME = "mtop=mtop+1 marks[mtop]=top",
  ADJUST = "local base=marks[mtop] mtop=mtop-1 local have=top-base if have<a then for i=have+1,a do top=top+1 stk[top]=nil end elseif have>a then top=base+a end",
  CALL = "local base=marks[mtop] mtop=mtop-1 local fn=stk[base+1] local n=top-base-1 local args={} for i=1,n do args[i]=stk[base+1+i] end top=base local rets=tpack(fn(tunpack(args,1,n))) if a==-1 then for i=1,rets.n do top=top+1 stk[top]=rets[i] end elseif a~=0 then for i=1,a do top=top+1 stk[top]=rets[i] end end",
  RETURN = "local base=marks[mtop] mtop=mtop-1 local n=top-base local r={} for i=1,n do r[i]=stk[base+i] end return tunpack(r,1,n)",
  RETURN0 = "return",
  CLOSURE = "local p2=protos[a] local desc=p2.upvals local ups={} for i=1,#desc do local d=desc[i] if d.kind=='local' then ups[i]=frame[d.index] else ups[i]=upvals[d.index] end end top=top+1 stk[top]=function(...) return exec(p2,ups,ENV,tpack(...)) end",
  ADD = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x+b",
  SUB = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x-b",
  MUL = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x*b",
  DIV = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x/b",
  MOD = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x%b",
  POW = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x^b",
  IDIV = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x//b",
  CONCAT = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x..b",
  BAND = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x&b",
  BOR = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x|b",
  BXOR = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x~b",
  SHL = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x<<b",
  SHR = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=x>>b",
  EQ = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x==b)",
  NE = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x~=b)",
  LT = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x<b)",
  LE = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x<=b)",
  GT = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x>b)",
  GE = "local b=stk[top] local x=stk[top-1] top=top-1 stk[top]=(x>=b)",
  NEG = "stk[top]=-stk[top]",
  NOT = "stk[top]=not stk[top]",
  LEN = "stk[top]=#stk[top]",
  BNOT = "stk[top]=~stk[top]",
  JMP = "pc=a",
  JMPIFFALSE = "local v=stk[top] top=top-1 if not v then pc=a end",
  JMPIFTRUE = "local v=stk[top] top=top-1 if v then pc=a end",
  JMPIFFALSEK = "if not stk[top] then pc=a else top=top-1 end",
  JMPIFTRUEK = "if stk[top] then pc=a else top=top-1 end",
  POP = "top=top-a",
}

local DECOY_FORMS = {
  "top=top+1 stk[top]=a top=top-1",
  "local _=marks[mtop]",
  "stk[top+1]=a",
  "pc=pc+0",
  "local _=K[1]",
}

-- Builds the dispatch chain in the profile's randomised order.
local function build_dispatch(profile)
  local names = opcodes.NAMES
  local parts = {}
  local first = true
  for _, e in ipairs(profile.dispatch) do
    local kw = first and "    if " or "    elseif "
    first = false
    if e.op then
      local nm = names[e.op]
      parts[#parts + 1] = kw .. "op==" .. nm .. " then " .. HANDLERS[nm]
    else
      local frag = DECOY_FORMS[(e.decoy % #DECOY_FORMS) + 1]
      parts[#parts + 1] = kw .. "op==" .. e.decoy .. " then " .. frag
    end
  end
  return table.concat(parts, "\n")
end

function M.source(profile)
  return opcode_prelude(profile) .. DECODER .. HEAD .. build_dispatch(profile) .. "\n" .. TAIL
end

return M
