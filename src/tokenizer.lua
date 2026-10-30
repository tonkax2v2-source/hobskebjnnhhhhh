-- tokenizer.lua
-- A full Lua 5.1-5.4 compatible lexer.
-- Produces a flat list of tokens that the parser consumes.
--
-- Token = { type = <string>, value = <string>, line = <int> }
--   type is one of: "name", "number", "string", "keyword", "op", "eof"

local Tokenizer = {}
Tokenizer.__index = Tokenizer

local KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

-- Multi-character operators, longest first so the scanner is greedy.
local OPS = {
  "...", "..", "::", "<<", ">>", "//", "==", "~=", "<=", ">=",
  "+", "-", "*", "/", "%", "^", "#", "&", "~", "|", "<", ">", "=",
  "(", ")", "{", "}", "[", "]", ";", ":", ",", ".",
}

local function is_digit(c) return c >= "0" and c <= "9" end
local function is_hex(c)
  return (c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")
end
local function is_alpha(c)
  return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end
local function is_alnum(c) return is_alpha(c) or is_digit(c) end

function Tokenizer.new(src, chunkname)
  local pos, line = 1, 1
  -- Lua skips a first line that starts with '#' (shebang support).
  if src:sub(1, 1) == "#" then
    local nl = src:find("\n", 1, true)
    if nl then pos = nl + 1; line = 2 else pos = #src + 1 end
  end
  return setmetatable({
    src = src,
    pos = pos,
    line = line,
    len = #src,
    chunkname = chunkname or "?",
  }, Tokenizer)
end

function Tokenizer:error(msg)
  error(string.format("%s:%d: %s", self.chunkname, self.line, msg), 0)
end

function Tokenizer:peek(o)
  local i = self.pos + (o or 0)
  if i > self.len then return nil end
  return self.src:sub(i, i)
end

function Tokenizer:advance()
  local c = self.src:sub(self.pos, self.pos)
  self.pos = self.pos + 1
  if c == "\n" then self.line = self.line + 1 end
  return c
end

-- Reads a long bracket body [[ ... ]] / [==[ ... ]==].
-- Assumes the opening '[' is the current char. Returns the body, or nil if
-- this is not actually a long bracket (so the caller can treat '[' normally).
function Tokenizer:try_long_bracket()
  local start = self.pos
  if self:peek() ~= "[" then return nil end
  local level = 0
  local i = self.pos + 1
  while self.src:sub(i, i) == "=" do
    level = level + 1
    i = i + 1
  end
  if self.src:sub(i, i) ~= "[" then
    return nil -- not a long bracket, e.g. plain '[' index
  end
  -- Consume opening up to and including the second '['.
  self.pos = i + 1
  -- A newline immediately after the opening bracket is skipped.
  if self:peek() == "\r" then self:advance() end
  if self:peek() == "\n" then self:advance() end
  local close = "]" .. string.rep("=", level) .. "]"
  local body_start = self.pos
  local idx = self.src:find(close, self.pos, true)
  if not idx then
    self.pos = start
    self:error("unfinished long bracket")
  end
  local body = self.src:sub(body_start, idx - 1)
  -- Account for newlines inside the body.
  for _ in body:gmatch("\n") do self.line = self.line + 1 end
  self.pos = idx + #close
  return body
end

function Tokenizer:skip_whitespace_and_comments()
  while self.pos <= self.len do
    local c = self:peek()
    if c == " " or c == "\t" or c == "\r" or c == "\n" or c == "\f" or c == "\v" then
      self:advance()
    elseif c == "-" and self:peek(1) == "-" then
      self:advance(); self:advance()
      -- Long comment?
      if self:peek() == "[" then
        local save = self.pos
        local body = self:try_long_bracket()
        if body ~= nil then
          -- consumed a long comment
        else
          self.pos = save
          -- line comment
          while self.pos <= self.len and self:peek() ~= "\n" do self:advance() end
        end
      else
        while self.pos <= self.len and self:peek() ~= "\n" do self:advance() end
      end
    else
      break
    end
  end
end

function Tokenizer:read_string(quote)
  local line = self.line
  self:advance() -- opening quote
  local buf = {}
  while true do
    local c = self:peek()
    if c == nil then self:error("unfinished string") end
    if c == quote then
      self:advance()
      break
    elseif c == "\n" then
      self:error("unfinished string")
    elseif c == "\\" then
      self:advance()
      local e = self:peek()
      if e == "n" then buf[#buf+1] = "\n"; self:advance()
      elseif e == "t" then buf[#buf+1] = "\t"; self:advance()
      elseif e == "r" then buf[#buf+1] = "\r"; self:advance()
      elseif e == "a" then buf[#buf+1] = "\a"; self:advance()
      elseif e == "b" then buf[#buf+1] = "\b"; self:advance()
      elseif e == "f" then buf[#buf+1] = "\f"; self:advance()
      elseif e == "v" then buf[#buf+1] = "\v"; self:advance()
      elseif e == "\\" then buf[#buf+1] = "\\"; self:advance()
      elseif e == '"' then buf[#buf+1] = '"'; self:advance()
      elseif e == "'" then buf[#buf+1] = "'"; self:advance()
      elseif e == "\n" then buf[#buf+1] = "\n"; self:advance()
      elseif e == "\r" then
        self:advance()
        if self:peek() == "\n" then self:advance() end
        buf[#buf+1] = "\n"
      elseif e == "x" then
        self:advance()
        local hex = ""
        for _ = 1, 2 do
          if is_hex(self:peek() or "") then hex = hex .. self:advance() end
        end
        buf[#buf+1] = string.char(tonumber(hex, 16))
      elseif e == "z" then
        self:advance()
        while self.pos <= self.len do
          local w = self:peek()
          if w == " " or w == "\t" or w == "\n" or w == "\r" or w == "\f" or w == "\v" then
            self:advance()
          else break end
        end
      elseif e == "u" then
        -- \u{XXXX} -- keep the codepoint bytes via utf8-ish encoding
        self:advance()
        if self:peek() == "{" then self:advance() end
        local hex = ""
        while is_hex(self:peek() or "") do hex = hex .. self:advance() end
        if self:peek() == "}" then self:advance() end
        local cp = tonumber(hex, 16) or 0
        -- encode as UTF-8
        if cp < 0x80 then
          buf[#buf+1] = string.char(cp)
        elseif cp < 0x800 then
          buf[#buf+1] = string.char(0xC0 + math.floor(cp/0x40), 0x80 + cp%0x40)
        elseif cp < 0x10000 then
          buf[#buf+1] = string.char(0xE0 + math.floor(cp/0x1000),
            0x80 + math.floor(cp/0x40)%0x40, 0x80 + cp%0x40)
        else
          buf[#buf+1] = string.char(0xF0 + math.floor(cp/0x40000),
            0x80 + math.floor(cp/0x1000)%0x40,
            0x80 + math.floor(cp/0x40)%0x40, 0x80 + cp%0x40)
        end
      elseif e and is_digit(e) then
        local num = ""
        for _ = 1, 3 do
          if is_digit(self:peek() or "") then num = num .. self:advance() else break end
        end
        buf[#buf+1] = string.char(tonumber(num))
      else
        self:error("invalid escape sequence '\\" .. tostring(e) .. "'")
      end
    else
      buf[#buf+1] = self:advance()
    end
  end
  return { type = "string", value = table.concat(buf), line = line }
end

function Tokenizer:read_number()
  local line = self.line
  local start = self.pos
  local src = self.src
  if self:peek() == "0" and (self:peek(1) == "x" or self:peek(1) == "X") then
    self:advance(); self:advance()
    while is_hex(self:peek() or "") or self:peek() == "." do self:advance() end
    if self:peek() == "p" or self:peek() == "P" then
      self:advance()
      if self:peek() == "+" or self:peek() == "-" then self:advance() end
      while is_digit(self:peek() or "") do self:advance() end
    end
  else
    while is_digit(self:peek() or "") or self:peek() == "." do self:advance() end
    if self:peek() == "e" or self:peek() == "E" then
      self:advance()
      if self:peek() == "+" or self:peek() == "-" then self:advance() end
      while is_digit(self:peek() or "") do self:advance() end
    end
  end
  local text = src:sub(start, self.pos - 1)
  return { type = "number", value = text, line = line }
end

function Tokenizer:read_name()
  local line = self.line
  local start = self.pos
  while is_alnum(self:peek() or "") do self:advance() end
  local word = self.src:sub(start, self.pos - 1)
  if KEYWORDS[word] then
    return { type = "keyword", value = word, line = line }
  end
  return { type = "name", value = word, line = line }
end

function Tokenizer:next_token()
  self:skip_whitespace_and_comments()
  if self.pos > self.len then
    return { type = "eof", value = "<eof>", line = self.line }
  end
  local c = self:peek()

  if c == '"' or c == "'" then
    return self:read_string(c)
  end

  if c == "[" and (self:peek(1) == "[" or self:peek(1) == "=") then
    local line = self.line
    local save = self.pos
    local body = self:try_long_bracket()
    if body ~= nil then
      return { type = "string", value = body, line = line }
    end
    self.pos = save
  end

  if is_digit(c) or (c == "." and is_digit(self:peek(1) or "")) then
    return self:read_number()
  end

  if is_alpha(c) then
    return self:read_name()
  end

  -- operators
  for _, op in ipairs(OPS) do
    if self.src:sub(self.pos, self.pos + #op - 1) == op then
      local line = self.line
      for _ = 1, #op do self:advance() end
      return { type = "op", value = op, line = line }
    end
  end

  self:error("unexpected symbol near '" .. c .. "'")
end

function Tokenizer:tokenize()
  local toks = {}
  while true do
    local t = self:next_token()
    toks[#toks+1] = t
    if t.type == "eof" then break end
  end
  return toks
end

return Tokenizer
