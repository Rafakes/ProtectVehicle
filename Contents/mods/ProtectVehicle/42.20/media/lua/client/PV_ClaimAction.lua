--[[
    ProtectVehicle - PV_ClaimAction.lua
    Timed action for claiming a vehicle (5 seconds).
    Claim timed action for ProtectVehicle.
    B42.14.x
--]]

if not isClient() and isServer() then return end

require "TimedActions/ISBaseTimedAction"

ISPVClaimAction = ISBaseTimedAction:derive("ISPVClaimAction")

function ISPVClaimAction:isValid()
    if not self.vehicle or self.vehicle:isRemovedFromWorld() then return false end
    -- Cancela se o jogador ficou longe do veículo (> 3.5 tiles)
    return self.character:DistTo(self.vehicle:getX(), self.vehicle:getY()) <= 3.5
end

function ISPVClaimAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function ISPVClaimAction:update()
    self.character:faceThisObject(self.vehicle)
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISPVClaimAction:start()
    self:setActionAnim("VehicleWorkOnMid")
end

function ISPVClaimAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISPVClaimAction:perform()
    sendClientCommand(self.character, "ProtectVehicle", "claim", { vehicleId = self.vehicle:getId() })
    self.character:playSound("CarLock")
    ISBaseTimedAction.perform(self)
end

function ISPVClaimAction:new(character, vehicle)
    local o = ISBaseTimedAction.new(self, character)
    setmetatable(o, self)
    self.__index = self
    o.stopOnWalk = true
    o.stopOnRun  = true
    o.character  = character
    o.vehicle    = vehicle
    o.maxTime    = character:isTimedActionInstant() and 1 or 300
    return o
end



