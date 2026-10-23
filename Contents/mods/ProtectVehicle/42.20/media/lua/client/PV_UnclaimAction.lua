--[[
    ProtectVehicle - PV_UnclaimAction.lua
    Timed action para remover proteÃ§Ã£o de veÃ­culo (5 segundos).
    Timed action de unclaim do ProtectVehicle.
    B42.14.x
--]]

if not isClient() and isServer() then return end

require "TimedActions/ISBaseTimedAction"

ISPVUnclaimAction = ISBaseTimedAction:derive("ISPVUnclaimAction")

function ISPVUnclaimAction:isValid()
    if not self.vehicle or self.vehicle:isRemovedFromWorld() then return false end
    -- Cancela se o jogador ficou longe do veículo (> 3.5 tiles)
    return self.character:DistTo(self.vehicle:getX(), self.vehicle:getY()) <= 3.5
end

function ISPVUnclaimAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function ISPVUnclaimAction:update()
    self.character:faceThisObject(self.vehicle)
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISPVUnclaimAction:start()
    self:setActionAnim("VehicleWorkOnMid")
end

function ISPVUnclaimAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISPVUnclaimAction:perform()
    sendClientCommand(self.character, "ProtectVehicle", "unclaim", { sqlid = self.sqlid })
    self.character:playSound("CarLock")
    ISBaseTimedAction.perform(self)
end

function ISPVUnclaimAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 300  -- 300 ticks = 6 segundos (mesmo padrÃ£o do claim: 300)
end

function ISPVUnclaimAction:new(character, vehicle, sqlid)
    local o = ISBaseTimedAction.new(self, character)
    setmetatable(o, self)
    self.__index  = self
    o.stopOnWalk  = true
    o.stopOnRun   = true
    o.character   = character
    o.vehicle     = vehicle
    o.sqlid       = sqlid
    o.maxTime     = character:isTimedActionInstant() and 1 or 300
    return o
end

