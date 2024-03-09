-- periphemu.lua monitor implementation

if not (periphemu and periphemu.lua) then error("requires periphemu.lua",0) end

local expect = require"cc.expect"

local Monitor = periphemu.lua.Peripheral:subclass()

function Monitor:getType() return "monitor" end

local window_methods = {
  ["getLine"]=true,
  ["setVisible"]=true,
  ["isVisible"]=true,
  ["redraw"]=true,
  ["restoreCursor"]=true,
  ["getPosition"]=true,
  ["reposition"]=true
}

local function js_round(n)
  return math.floor(n+0.5)
end

local function clamp_scale(scale)
  local v = js_round(scale*2)/2
  if v<0.5 then return 0.5 end
  if v>5 then return 5 end
  return v
end

-- stub terminal object
local __stub=setmetatable({},{
  __index=function(t,k)
    local _type = type(term.current()[k])
    if _type=="function" then
      t[k]=function() end
      return t[k]
    end
    if _type=="nil" then return nil end
    error("stub can't handle type ".._type)
  end
})

function __stub.getPaletteColour(c)
  return term.getPaletteColour(c)
end
__stub.getPaletteColor = __stub.getPaletteColour

function __stub.isColour() return true end
__stub.isColor = __stub.isColour

function Monitor:attach()
  local w,h,block,scale,color=51,19,false,1,true
  if self.__arg then
    expect(1,self.__arg,"table")
    w=field(self.__arg,1,"number")
    h=field(self.__arg,2,"number")
    block=field(self.__arg,"block","boolean","nil")
    scale=field(self.__arg,"scale","number","nil") or 1
    color=field(self.__arg,"color","boolean","nil")
    if color==nil then color=true end
  end
  scale = clamp_scale(scale)
  if block then
    local cw,ch
    cw = js_round((64*w-20)/(6*scale))
    ch = js_round((64*h-20)/(9*scale))
    w=cw
    h=ch
  end
  self.__win = window.create(__stub,1,1,w,h,false)
  self.__scale = scale
  self.__color = color
  for k,v in pairs(self.__win) do
    if not window_methods[k] and not self[k] then self[k]=v end
  end
  self:__refresh_methods()
  return true
end

-- isColour/isColor override, since the stub will appear as color to preserve palette entries
function Monitor:isColour()
  return self.__color
end
function Monitor:isColor()
  return self.__color
end

-- setTextScale/getTextScale
function Monitor:setTextScale(scale)
  local scale = clamp_scale(scale)
  local w,h = self:getSize()
  w=math.floor(w*(self.__scale/scale))
  h=math.floor(h*(self.__scale/scale))
  self:setSize(w,h)
  self.__scale=scale
end
function Monitor:getTextScale(scale)
  return self.__scale
end

-- setSize/setBlockSize
function Monitor:setSize(w,h)
  self.__win.reposition(1,1,w,h)
end
function Monitor:setBlockSize(w,h)
  local cw,ch
  cw = js_round((64*w-20)/(6*self.__scale))
  ch = js_round((64*h-20)/(9*self.__scale))
  return self:setSize(cw,ch)
end

-- toRawMode: converts to rawmode packet
-- rle: run length encoding for rawmode packet
local function rle(s)
  local o = ""
  local curr_c, n
  for c in s:gfind("(.)") do
    if not curr_c then
      curr_c, n = c, 1
    elseif c~=curr_c then
      o = o .. curr_c .. string.char(n)
      curr_c, n = c, 1
    else -- c==curr_c
      n = n + 1
      if n==255 then
        o = o .. curr_c .. string.char(n)
        curr_c, n = nil
      end
    end
  end
  o = o .. curr_c .. string.char(n)
  return o
end

-- base64encode: encode base64
-- stolen from rawterm https://gist.github.com/MCJack123/50b211c55ceca4376e51d33435026006
local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64encode(str)
  local retval = ""
  for s in str:gmatch "..." do
    local n = s:byte(1) * 65536 + s:byte(2) * 256 + s:byte(3)
    local a, b, c, d = bit32.extract(n, 18, 6), bit32.extract(n, 12, 6), bit32.extract(n, 6, 6), bit32.extract(n, 0, 6)
    retval = retval .. b64str:sub(a+1, a+1) .. b64str:sub(b+1, b+1) .. b64str:sub(c+1, c+1) .. b64str:sub(d+1, d+1)
  end
  if #str % 3 == 1 then
    local n = str:byte(-1)
    local a, b = bit32.rshift(n, 2), bit32.lshift(bit32.band(n, 3), 4)
    retval = retval .. b64str:sub(a+1, a+1) .. b64str:sub(b+1, b+1) .. "=="
  elseif #str % 3 == 2 then
    local n = str:byte(-2) * 256 + str:byte(-1)
    local a, b, c, d = bit32.extract(n, 10, 6), bit32.extract(n, 4, 6), bit32.lshift(bit32.extract(n, 0, 4), 2)
    retval = retval .. b64str:sub(a+1, a+1) .. b64str:sub(b+1, b+1) .. b64str:sub(c+1, c+1) .. "="
  end
  return retval
end

-- crc32: crc32
-- also stolen from rawterm
local crctable
local function crc32(str)
  -- calculate CRC-table
  if not crctable then
    crctable = {}
    for i = 0, 0xFF do
      local rem = i
      for j = 1, 8 do
          if bit32.band(rem, 1) == 1 then
              rem = bit32.rshift(rem, 1)
              rem = bit32.bxor(rem, 0xEDB88320)
          else rem = bit32.rshift(rem, 1) end
      end
      crctable[i] = rem
    end
  end
  local crc = 0xFFFFFFFF
  for x = 1, #str do crc = bit32.bxor(bit32.rshift(crc, 8), crctable[bit32.bxor(bit32.band(crc, 0xFF), str:byte(x))]) end
  return bit32.bxor(crc, 0xFFFFFFFF)
end

function Monitor:toRawMode()
  -- type 0 packet, window 0, no graphics mode
  local data = "\0\0\0"
  -- cursor blinking? (technically cursor showing since we can't confirm 1.1 compat but shh)
  data = data .. (self.__win.getCursorBlink() and "\1" or "\0")
  -- size (width/height)
  data = data .. string.pack("<HH",self.__win.getSize())
  -- cursor pos (x/y)
  data = data .. string.pack("<HH",self.__win.getCursorPos())
  -- grayscale? (1=grayscale, 0=color)
  data = data .. (self.__color and "\0" or "\1")
  -- reserved (but we use the first reserved byte to store scale for a possible renderer app)
  data = data .. string.char(self.__scale*2) .. "\0\0"
  -- RLE encoded text/colors
  local text = ""
  local colors = ""
  local w,h = self.__win.getSize()
  for y=1,h do
    local _text, fg, bg = self.__win.getLine(y)
    text = text .. _text
    for i=1,#fg do
      colors = colors .. string.char(tonumber(bg:sub(i,i)..fg:sub(i,i),16))
    end
  end
  assert(#text==#colors,"you fucked up somewhere in here")
  data = data .. rle(text) .. rle(colors)
  -- palette
  for i=0,15 do
    r,g,b = self.__win.getPaletteColor(2^i)
    data = data .. string.char(r*255) .. string.char(g*255) .. string.char(b*255)
  end
  local payload = base64encode(data)
  local header = ""
  if #payload<65536 then
    header = "!CPC"..("%04X"):format(#payload)
  else
    header = "!CPD"..("%012X"):format(#payload)
  end
  return header .. payload .. ("%08X"):format(crc32(payload)) .. "\n"
end

periphemu.lua.register(Monitor)
