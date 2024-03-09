-- periphemu.lua
-- CraftOS-PC style periphemu implemented in pure Lua
-- run file in order to "install"

if periphemu then
  if _HOST:find("CraftOS%-PC") then
    local tc = term.getTextColor()
    term.setTextColor(colors.red)
    print("periphemu already installed!")
    term.setTextColor(colors.yellow)
    print("You don't need to use periphemu.lua on CraftOS-PC.")
  else
    error("periphemu already installed!",0)
  end
end

if not (debug and debug.getupvalue) then
  error("periphemu.lua requires debug library",0)
end

local native
do
  local i = 1
  local name, value
  repeat
    name, value = debug.getupvalue(peripheral.call,i)
    i=i+1
  until name=="native" or name==nil
  if name=="native" then native=value end
end
if not native then error("unable to find native peripheral library") end

-- _native is the actual native, `native` gets its members replaced with override functions
local _native = {}
for k,v in pairs(native) do _native[k]=v end
-- module contains all the periphemu API functions
local module = {}
_G.periphemu = module
-- define override functions in `native`, periphemu functions in `module`
-- override functions are basically direct translations of the java code to lua
-- except they check with the real API first so actual peripherals are passed through explicitly

local peripherals = {}

function native.isPresent(sideName)
  -- passthrough actual peripherals
  if _native.isPresent(sideName) then return true end
  return peripherals[sideName]~=nil
end

function native.getType(sideName)
  -- passthrough actual peripherals
  if _native.isPresent(sideName) then return _native.getType(sideName) end
  if peripherals[sideName]==nil then return nil end
  return peripherals[sideName]:getType(), table.unpack(peripherals[sideName]:getAdditionalTypes())
end

function native.hasType(sideName,type)
  -- passthrough actual peripherals
  if _native.isPresent(sideName) then return _native.hasType(sideName,type) end
  if peripherals[sideName]==nil then return nil end
  if peripherals[sideName]:getType()==type then return true end
  for _, _type in ipairs(peripherals[sideName]:getAdditionalTypes()) do
    if type==_type then return true end
  end
  return nil
end

function native.getMethods(sideName)
  -- passthrough actual peripherals
  if _native.isPresent(sideName) then return _native.getMethods(sideName) end
  if peripherals[sideName]==nil then return nil end
  return peripherals[sideName]:getMethods()
end

local not_method -- forward declare
function native.call(sideName,method,...)
  -- passthrough actual peripherals
  if _native.isPresent(sideName) then return _native.call(sideName,method,...) end
  if peripherals[sideName]==nil then error("No peripheral attached",2) end
  if not_method[method] or (not peripherals[sideName][method]) then error("No such method "..method,2) end
  -- essentially peripherals[sideName]:[method](...) but Lua doesn't let us do that
  return peripherals[sideName][method](peripherals[sideName],...)
end

-- call detach methods on peripherals before shutting down computer
local os_shutdown = os.shutdown
function os.shutdown()
  module.uninstall()
  return os_shutdown()
end

local os_reboot = os.reboot
function os.reboot()
  module.uninstall()
  return os_reboot()
end

-- call on_event methods when events are pulled
local os_pullEventRaw = os.pullEventRaw
function os.pullEventRaw(filter)
  while true do
    local event = table.pack(os_pullEventRaw(filter))
    local keep = false
    for _,v in pairs(peripherals) do
      if v:on_event(event) then keep=true end
    end
    if not keep then return table.unpack(event,1,event.n) end
  end
end

-- module functions
function module.create(side,type,arg)
  if _native.isPresent(side) then return false, "Cowardly refusing to shadow actual peripheral on "..type end
  if not module.lua.peripheral_types[type] then return false, "No peripheral named "..type end
  local obj = module.lua.peripheral_types[type]:new(side,arg)
  local res = table.pack(obj:attach())
  if not res[1] then return table.unpack(res,1,res.n) end
  peripherals[side]=obj
  return true
end

function module.remove(side)
  if not peripherals[side] then return false end
  peripherals[side]:detach()
  peripherals[side]=nil
  return true
end

function module.names()
  local ret = {}
  for k in pairs(module.lua.peripheral_types) do ret[#ret+1]=k end
  return ret
end

-- Lua extension
-- this is how you add new peripherals
module.lua = {}
module.lua.peripheral_types = {}

function module.lua.register(periph_class,type)
  module.lua.peripheral_types[type or periph_class:getType()]=periph_class
end

-- base class of a peripheral
local Peripheral = {}
Peripheral.__index = Peripheral
module.lua.Peripheral = Peripheral

-- Creates a new instance of the peripheral object
not_method = setmetatable({
  ["attach"]=true,
  ["detach"]=true,
  ["getType"]=true,
  ["getAdditionalTypes"]=true,
  ["getMethods"]=true,
  ["new"]=true,
  ["subclass"]=true,
  ["on_event"]=true,
  ["__name"]=true,
  ["__arg"]=true,
  ["__methods"]=true,
  ["__index"]=true
},{__index=function(t,k)
  if k:find("^__")==1 then t[k]=true return t[k] end
  return false
end})
function Peripheral:new(name,arg)
  return setmetatable({__name=name,__arg=arg},self)
end

function Peripheral:__refresh_methods()
  local methods = {}
  for k in pairs(self) do
    if not not_method[k] then table.insert(methods,k) end
  end
  local __mt = getmetatable(self)
  if __mt and __mt.__index then
    for k in pairs(__mt.__index) do
      if not not_method[k] then table.insert(methods,k) end
    end
  end
  self.__methods = methods
end

-- Subclasses the peripheral
function Peripheral:subclass()
  local ret = {}
  for k,v in pairs(self) do ret[k]=v end
  ret.__index = ret
  return ret
end

-- Run whatever you need to set up the peripheral object
-- self is a fresh object
-- the passed argument from periphemu.create is self.__arg
-- the name the peripheral has been attached with is self.__name
-- return true if successful, false + error message if not
function Peripheral:attach()
  return true
end

-- Run whatever you need to teardown the peripheral object
function Peripheral:detach()
end

-- Run whatever you need to handle an event
-- event is the event packed into a table
-- if return value is truthy, event will be supressed
function Peripheral:on_event(event)
  return false
end

-- Returns the primary type of the peripheral (i.e; "modem").
function Peripheral:getType()
  error("NYI: Peripheral.getType")
end

-- Returns any additional types of the peripheral (i.e; "peripheral_hub")
function Peripheral:getAdditionalTypes()
  return {}
end

-- Returns a list of methods for the peripheral (just leave this one alone)
function Peripheral:getMethods()
  if not self.__methods then self:__refresh_methods() end
  local r={}
  for i,v in ipairs(self.__methods) do r[i]=v end
  return r
end

-- Monkeypatches peripheral.getNames to use custom peripherals
-- In the periphemu.lua namespace since periphemu proper doesn't do this
function module.lua.fix_getnames()
  local pgn = peripheral.getNames
  function peripheral.getNames()
    local t = {}
    for _,k in pairs(pgn()) do t[k]=true end
    for k in pairs(peripherals) do
      t[k]=true
    end
    local r = {}
    for k in pairs(t) do table.insert(r,k) end
    return r
  end
end

-- Uninstalls periphemu and all of the hooks into global functions
function module.lua.uninstall()
  -- remove periphemu table
  _G.periphemu = nil
  -- reset native peripheral methods
  for k in pairs(native) do native[k]=nil end
  for k,v in pairs(_native) do native[k]=v end
  -- cleanup all peripherals
  for k,v in pairs(peripherals) do
    v:detach()
  end
  -- restore os.shutdown/reboot
  os.shutdown = os_shutdown
  os.reboot = os_reboot
  -- restore peripheral.getNames if it was overwritten
  do
    local i, name, value = 1
    repeat
      name, value = debug.getupvalue(peripheral.getNames,i)
      i=i+1
    until name=="pgn" or name==nil
    if name=="pgn" then peripheral.getNames = value end
  end
end
