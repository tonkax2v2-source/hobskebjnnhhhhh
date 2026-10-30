-- runtime.lua
-- Produces the SOURCE of the VM interpreter embedded into obfuscated output.
--
-- Dispatch style (Luraph v15-like): instead of one if/elseif loop, each opcode
-- is a separate handler closure stored in a shared handler table `__H`, keyed by
-- its (shuffled) opcode number and interleaved with decoy entries. The driver
-- loop indexes `__H[op]` and calls it with a per-activation state object `S`.
-- A handler returns nil to continue, or a packed result table to return from
-- the function (RETURN / RETURN0).
--
-- Per-build profile controls: randomised opcode numbers (profile.perm),
-- randomised handler-table order + decoys (profile.dispatch), runtime-derived
-- keys (profile.key_seed).
--
-- The VM delegates closures, upvalues, metatables, coroutines, varargs,
-- multiple returns and GC to the host Lua; every local is a box {v=...} so
-- per-iteration closure capture is preserved. Constants are decrypted lazily.

local opcodes = require("src.vm.opcodes")

local M = {}

local function opcode_prelude(profile)
  local t = {}
  for i, n in ipairs(opcodes.NAMES) do
    t[#t + 1] = "local " .. n .. "=" .. profile.perm[i]
  end
  return table.concat(t, " ") .. " "
end

-- Decoder + lazy constant table. Integrity is a checksum over the ENCRYPTED
-- bytes (no decryption needed to verify). Instructions decode eagerly; each
-- constant is decrypted on first access via a metatable, then cached.
local DECODER = [==[
local __vmdec=function(s,k1,k2,chk)
  local sb=string.byte local sc=string.char
  local cs=0 for i=1,#s do cs=(cs+sb(s,i)*(((i-1)%7)+1))%16777213 end
  if cs~=chk then return error("integrity") end
  local pos=0
  local function gb() pos=pos+1 return (sb(s,pos)-(k1+pos*k2))%256 end
  local function g()
    local b0=gb() local b1=gb() local b2=gb() local b3=gb()
    local n=b0+256*(b1+256*(b2+256*b3))
    if n>=2147483648 then n=n-4294967296 end
    return n
  end
  local function payload(off,len)
    local t={} for j=1,len do local p=off+j t[j]=sc((sb(s,p)-(k1+p*k2))%256) end
    return table.concat(t)
  end
  local kcount=g()
  local meta={}
  for i=1,kcount do
    local tag=gb()
    if tag==0 or tag==1 then local len=g() meta[i]={tag,pos,len} pos=pos+len
    else meta[i]={tag} end
  end
  local ccount=g()
  local code={}
  for i=1,ccount do local o=g() local a=g() code[i]={o,a} end
  local K=setmetatable({},{__index=function(tb,i)
    local m=meta[i] local tag=m[1] local v
    if tag==0 then v=payload(m[2],m[3])
    elseif tag==1 then v=tonumber(payload(m[2],m[3]))
    elseif tag==2 then v=true else v=false end
    rawset(tb,i,v) return v
  end})
  return K,code
end
]==]

-- Runtime key schedule (must match profile.master_of / derive).
local function keysched(profile)
  return string.format(
    "local __ms=%d " ..
    "local __mk=(__ms*16807+1)%%16777213 __mk=(__mk*16807+1)%%16777213 " ..
    "local __kx=function(salt) local x=(__mk+salt)%%16777213 " ..
    "x=(x*16807+1)%%16777213 x=(x*16807+1)%%16777213 " ..
    "return x%%256,(math.floor(x/256)%%255)+1 end " ..
    "local __mkproto=function(np,va,upvals,protos,s,salt,chk) " ..
    "local k1,k2=__kx(salt) local K,code=__vmdec(s,k1,k2,chk) " ..
    "return {numparams=np,is_vararg=va,upvals=upvals,protos=protos,consts=K,code=code} end ",
    profile.key_seed)
end

-- Shared prologue: packing helpers, the handler table, and the driver.
local PROLOGUE = [==[
local tpack=function(...) return {n=select('#',...),...} end
local tunpack=table.unpack or unpack
local __EMPTY={n=0}
local exec
local __H={}
]==]

local DRIVER = [==[
exec=function(proto,upvals,ENV,argpack)
  local S={c=proto.code,k=proto.consts,p=proto.protos,u=upvals,e=ENV,
           f={},s={},t=0,m={},mt=0,pc=1,v={},vn=0}
  local np=proto.numparams
  local n=argpack.n
  for i=1,np do S.f[i]={v=argpack[i]} end
  if proto.is_vararg then for i=np+1,n do S.vn=S.vn+1 S.v[S.vn]=argpack[i] end end
  local H=__H
  while true do
    local ins=S.c[S.pc] S.op=ins[1] S.a=ins[2] S.pc=S.pc+1
    local r=H[S.op](S)
    if r then return tunpack(r,1,r.n) end
  end
end
]==]

-- Per-opcode handler bodies operating on the state object S.
local HANDLERS = {
  PUSHK = "S.t=S.t+1 S.s[S.t]=S.k[S.a]",
  PUSHNIL = "S.t=S.t+1 S.s[S.t]=nil",
  PUSHTRUE = "S.t=S.t+1 S.s[S.t]=true",
  PUSHFALSE = "S.t=S.t+1 S.s[S.t]=false",
  PUSHVARARG = "if S.a==-1 then for i=1,S.vn do S.t=S.t+1 S.s[S.t]=S.v[i] end else for i=1,S.a do S.t=S.t+1 S.s[S.t]=S.v[i] end end",
  NEWLOCAL = "local x=S.s[S.t] S.t=S.t-1 S.f[S.a]={v=x}",
  DECLLOCAL = "S.f[S.a]={v=nil}",
  GETLOCAL = "S.t=S.t+1 S.s[S.t]=S.f[S.a].v",
  SETLOCAL = "S.f[S.a].v=S.s[S.t] S.t=S.t-1",
  GETUPVAL = "S.t=S.t+1 S.s[S.t]=S.u[S.a].v",
  SETUPVAL = "S.u[S.a].v=S.s[S.t] S.t=S.t-1",
  GETGLOBAL = "S.t=S.t+1 S.s[S.t]=S.e[S.k[S.a]]",
  SETGLOBAL = "S.e[S.k[S.a]]=S.s[S.t] S.t=S.t-1",
  GETTABLE = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x[b]",
  SETTABLE = "local v=S.s[S.t] local kk=S.s[S.t-1] local tt=S.s[S.t-2] S.t=S.t-3 tt[kk]=v",
  NEWTABLE = "S.t=S.t+1 S.s[S.t]={}",
  SETINDEXK = "local v=S.s[S.t] local tt=S.s[S.t-1] S.t=S.t-2 tt[S.k[S.a]]=v",
  SETINDEXI = "local v=S.s[S.t] local tt=S.s[S.t-1] S.t=S.t-2 tt[S.a]=v",
  SETLIST = "local base=S.m[S.mt] S.mt=S.mt-1 local tt=S.s[base] for i=base+1,S.t do tt[S.a+(i-base)]=S.s[i] end S.t=base-1",
  SELF = "local tt=S.s[S.t] local mth=tt[S.k[S.a]] S.s[S.t]=mth S.t=S.t+1 S.s[S.t]=tt",
  OPENFRAME = "S.mt=S.mt+1 S.m[S.mt]=S.t",
  ADJUST = "local base=S.m[S.mt] S.mt=S.mt-1 local have=S.t-base if have<S.a then for i=have+1,S.a do S.t=S.t+1 S.s[S.t]=nil end elseif have>S.a then S.t=base+S.a end",
  CALL = "local base=S.m[S.mt] S.mt=S.mt-1 local fn=S.s[base+1] local n=S.t-base-1 local args={} for i=1,n do args[i]=S.s[base+1+i] end S.t=base local rets=tpack(fn(tunpack(args,1,n))) if S.a==-1 then for i=1,rets.n do S.t=S.t+1 S.s[S.t]=rets[i] end elseif S.a~=0 then for i=1,S.a do S.t=S.t+1 S.s[S.t]=rets[i] end end",
  RETURN = "local base=S.m[S.mt] S.mt=S.mt-1 local n=S.t-base local r={} for i=1,n do r[i]=S.s[base+i] end r.n=n return r",
  RETURN0 = "return __EMPTY",
  CLOSURE = "local p2=S.p[S.a] local desc=p2.upvals local ups={} for i=1,#desc do local d=desc[i] if d.kind=='local' then ups[i]=S.f[d.index] else ups[i]=S.u[d.index] end end S.t=S.t+1 S.s[S.t]=function(...) return exec(p2,ups,S.e,tpack(...)) end",
  ADD = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x+b",
  SUB = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x-b",
  MUL = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x*b",
  DIV = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x/b",
  MOD = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x%b",
  POW = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x^b",
  IDIV = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x//b",
  CONCAT = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x..b",
  BAND = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x&b",
  BOR = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x|b",
  BXOR = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x~b",
  SHL = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x<<b",
  SHR = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=x>>b",
  EQ = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=(x==b)",
  NE = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=(x~=b)",
  LT = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=(x<b)",
  LE = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=(x<=b)",
  GT = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=(x>b)",
  GE = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=(x>=b)",
  NEG = "S.s[S.t]=-S.s[S.t]",
  NOT = "S.s[S.t]=not S.s[S.t]",
  LEN = "S.s[S.t]=#S.s[S.t]",
  BNOT = "S.s[S.t]=~S.s[S.t]",
  JMP = "S.pc=S.a",
  JMPIFFALSE = "local v=S.s[S.t] S.t=S.t-1 if not v then S.pc=S.a end",
  JMPIFTRUE = "local v=S.s[S.t] S.t=S.t-1 if v then S.pc=S.a end",
  JMPIFFALSEK = "if not S.s[S.t] then S.pc=S.a else S.t=S.t-1 end",
  JMPIFTRUEK = "if S.s[S.t] then S.pc=S.a else S.t=S.t-1 end",
  POP = "S.t=S.t-S.a",
}

-- Luau (Roblox) lacks the 5.3 bitwise operators; it provides bit32 instead.
-- These override the operator-based handlers when targeting Luau so bitwise
-- operations still run on Roblox. (Floor division `//` exists in Luau, so IDIV
-- is unchanged.)
local HANDLERS_LUAU = {
  BAND = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=bit32.band(x,b)",
  BOR = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=bit32.bor(x,b)",
  BXOR = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=bit32.bxor(x,b)",
  SHL = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=bit32.lshift(x,b)",
  SHR = "local b=S.s[S.t] local x=S.s[S.t-1] S.t=S.t-1 S.s[S.t]=bit32.rshift(x,b)",
  BNOT = "S.s[S.t]=bit32.bnot(S.s[S.t])",
}

-- Decoy handlers: never dispatched (their opcode numbers are never emitted),
-- pure noise that pads the handler table like a real VM's.
local DECOY_FORMS = {
  "function(S) return end",
  "function(S) S.t=S.t end",
  "function(S) local _=S.m end",
  "function(S) return nil end",
  "function(S) S.pc=S.pc end",
}

-- Builds the handler-table assignments in the profile's randomised order.
-- `used` (optional) restricts real handlers to the opcodes the program uses.
local function build_handlers(profile, used, target)
  local names = opcodes.NAMES
  local parts = {}
  for _, e in ipairs(profile.dispatch) do
    if e.op then
      if (not used) or used[e.op] then
        local nm = names[e.op]
        local body = (target == "luau" and HANDLERS_LUAU[nm]) or HANDLERS[nm]
        parts[#parts + 1] = "__H[" .. nm .. "]=function(S) " .. body .. " end"
      end
    else
      local frag = DECOY_FORMS[(e.decoy % #DECOY_FORMS) + 1]
      parts[#parts + 1] = "__H[" .. e.decoy .. "]=" .. frag
    end
  end
  return table.concat(parts, " ")
end

function M.source(profile, used, target)
  return opcode_prelude(profile) .. DECODER .. keysched(profile) ..
         PROLOGUE .. build_handlers(profile, used, target) .. " " .. DRIVER
end

return M
