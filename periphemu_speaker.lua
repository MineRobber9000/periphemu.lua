-- periphemu.lua speaker implementation

if not (periphemu and periphemu.lua) then error("requires periphemu.lua",0) end

local expect = require"cc.expect"

local Speaker = periphemu.lua.Peripheral:subclass()

function Speaker:getType() return "speaker" end

local dfpwm = require"cc.audio.dfpwm"

function Speaker:attach()
  self:reset()
  return true
end

function Speaker:playNote()
  error("Cannot play notes outside of Minecraft",2)
end

function Speaker:playSound()
  error("Cannot play sounds outside of Minecraft",2)
end

function Speaker:playAudio(buffer)
  self.__data = self.__data .. self.__encoder(buffer)
  return true
end

function Speaker:getDFPWM()
  return self.__data
end

function Speaker:reset()
  self.__encoder = dfpwm.make_encoder()
  self.__data = ""
end

periphemu.lua.register(Speaker)
