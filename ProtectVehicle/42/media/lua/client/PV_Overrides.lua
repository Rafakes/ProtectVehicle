--[[
    PV_Overrides.lua (client-side)
    Overrides for vanilla vehicle actions.
    Blocks unauthorized interactions using PV permission system.
    B42.14.x - Pattern based on AVCS4213 which works on B42.
--]]

if not isClient() and isServer() then return end

require "ISUI/ISModalDialog"
require "luautils"
require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISBaseTimedAction"

-- ============================================================
-- Denied timed action (instant, shows halo message)
-- ============================================================
ISPVDeniedTimedAction = ISBaseTimedAction:derive("ISPVDeniedTimedAction")

function ISPVDeniedTimedAction:new(character, msg)
    local o = ISBaseTimedAction.new(self, character)
    o.maxTime = 1
    o.stopOnWalk = false
    o.stopOnRun  = false
    o.stopOnAim  = false
    if msg and character then
        character:setHaloNote(msg, 250, 100, 100, 300)
    end
    return o
end

function ISPVDeniedTimedAction:isValid() return true end
function ISPVDeniedTimedAction:perform() ISBaseTimedAction.perform(self) end
function ISPVDeniedTimedAction:getDuration() return 1 end

local function PV_Deny(character)
    return ISPVDeniedTimedAction:new(character, getText("IGUI_PV_NoPermission"))
end

-- ============================================================
-- ISEnterVehicle override
-- ============================================================
if ISEnterVehicle and ISEnterVehicle.new then
    if not PV._oISEnterVehicle then
        PV._oISEnterVehicle = ISEnterVehicle.new
    end

    function ISEnterVehicle:new(character, vehicle, seat)
        if seat ~= 0 then
            if PV.getPublicFlag(vehicle, "AllowPassenger") then
                return PV._oISEnterVehicle(self, character, vehicle, seat)
            end
        end
        if seat == 0 then
            if PV.getPublicFlag(vehicle, "AllowDrive") then
                return PV._oISEnterVehicle(self, character, vehicle, seat)
            end
        end
        if PV.canPerformAction(character, vehicle, seat == 0 and "AllowDrive" or "AllowPassenger") then
            return PV._oISEnterVehicle(self, character, vehicle, seat)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISSwitchVehicleSeat override
-- ============================================================
if ISSwitchVehicleSeat and ISSwitchVehicleSeat.new then
    if not PV._oISSwitchVehicleSeat then
        PV._oISSwitchVehicleSeat = ISSwitchVehicleSeat.new
    end

    function ISSwitchVehicleSeat:new(character, seatTo)
        if not character:getVehicle() then
            return PV._oISSwitchVehicleSeat(self, character, seatTo)
        end
        local veh = character:getVehicle()
        if seatTo ~= 0 and PV.getPublicFlag(veh, "AllowPassenger") then
            return PV._oISSwitchVehicleSeat(self, character, seatTo)
        end
        if seatTo == 0 and PV.getPublicFlag(veh, "AllowDrive") then
            return PV._oISSwitchVehicleSeat(self, character, seatTo)
        end
        if PV.canPerformAction(character, veh, seatTo == 0 and "AllowDrive" or "AllowPassenger") then
            return PV._oISSwitchVehicleSeat(self, character, seatTo)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISOpenVehicleDoor override
-- ============================================================
do
    local oldNew = ISOpenVehicleDoor.new

    local function isTrunkPart(part)
        local id = string.lower(part:getId() or "")
        return PV.isVehiclePartTrunk(part)
    end

    function ISOpenVehicleDoor:new(character, vehicle, part)
        if not part or not instanceof(part, "VehiclePart") then
            return oldNew(self, character, vehicle, part)
        end
        -- Owner/admin always allowed
        if PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle)) then
            return oldNew(self, character, vehicle, part)
        end
        -- AllowPassenger = all doors
        if PV.getPublicFlag(vehicle, "AllowPassenger") then
            return oldNew(self, character, vehicle, part)
        end
        -- AllowOpeningTrunk = trunk only
        if PV.getPublicFlag(vehicle, "AllowOpeningTrunk") then
            if isTrunkPart(part) then
                return oldNew(self, character, vehicle, part)
            end
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISAttachTrailerToVehicle override (tow)
-- ============================================================
if ISAttachTrailerToVehicle and ISAttachTrailerToVehicle.new then
    if not PV._oISAttachTrailerToVehicle then
        PV._oISAttachTrailerToVehicle = ISAttachTrailerToVehicle.new
    end

    function ISAttachTrailerToVehicle:new(character, vehicleA, vehicleB, attachmentA, attachmentB)
        local okA = PV.getPublicFlag(vehicleA, "AllowTow") or PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicleA))
        local okB = PV.getPublicFlag(vehicleB, "AllowTow") or PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicleB))
        if okA and okB then
            return PV._oISAttachTrailerToVehicle(self, character, vehicleA, vehicleB, attachmentA, attachmentB)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISDetachTrailerFromVehicle override
-- ============================================================
if ISDetachTrailerFromVehicle and ISDetachTrailerFromVehicle.new then
    if not PV._oISDetachTrailerFromVehicle then
        PV._oISDetachTrailerFromVehicle = ISDetachTrailerFromVehicle.new
    end

    function ISDetachTrailerFromVehicle:new(character, vehicle, attachment)
        local ok = PV.getPublicFlag(vehicle, "AllowTow") or PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle))
        if ok then
            return PV._oISDetachTrailerFromVehicle(self, character, vehicle, attachment)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISTakeGasolineFromVehicle override (siphon fuel)
-- ============================================================
do
    local oldNew = ISTakeGasolineFromVehicle.new
    function ISTakeGasolineFromVehicle:new(character, part, item, ...)
        local vehicle = part and part:getVehicle()
        local ok = PV.getPublicFlag(vehicle, "AllowSiphonFuel") or PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle))
        if ok then
            return oldNew(self, character, part, item, ...)
        end
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISInflateTire override
-- ============================================================
do
    local oldNew = ISInflateTire.new
    function ISInflateTire:new(character, part, item, psiTarget, ...)
        local vehicle = part and part:getVehicle()
        if not vehicle then return oldNew(self, character, part, item, psiTarget, ...) end
        local ok = PV.getPublicFlag(vehicle, "AllowInflateTires") or PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle))
        if ok then
            return oldNew(self, character, part, item, psiTarget, ...)
        end
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISDeflateTire override
-- ============================================================
do
    local oldNew = ISDeflateTire.new
    function ISDeflateTire:new(character, part, psiTarget, ...)
        local vehicle = part and part:getVehicle()
        local ok = PV.getPublicFlag(vehicle, "AllowDeflateTires") or PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle))
        if ok then
            return oldNew(self, character, part, psiTarget, ...)
        end
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISSmashVehicleWindow override
-- ============================================================
if ISSmashVehicleWindow and ISSmashVehicleWindow.new then
    if not PV._oISSmashVehicleWindow then
        PV._oISSmashVehicleWindow = ISSmashVehicleWindow.new
    end

    function ISSmashVehicleWindow:new(character, part, open)
        local vehicle = part and part.getVehicle and part:getVehicle()
        if not vehicle then return PV._oISSmashVehicleWindow(self, character, part, open) end
        if PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle)) then
            return PV._oISSmashVehicleWindow(self, character, part, open)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISVehicleMechanics.onUninstallPart override
-- ============================================================
do
    local oldFn = ISVehicleMechanics.onUninstallPart
    function ISVehicleMechanics.onUninstallPart(playerObj, part, item)
        local vehicle = part and part:getVehicle()
        local ok = PV.getPublicFlag(vehicle, "AllowUninstallParts") or PV.getSimpleBooleanPermission(PV.checkPermission(playerObj, vehicle))
        if not ok then
            playerObj:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
            return
        end
        oldFn(playerObj, part, item)
    end
end

-- ============================================================
-- ISVehiclePartMenu.onUninstallPart override
-- ============================================================
if ISVehiclePartMenu and ISVehiclePartMenu.onUninstallPart then
    local oldFn = ISVehiclePartMenu.onUninstallPart
    function ISVehiclePartMenu.onUninstallPart(playerObj, part, item)
        local vehicle = part and part:getVehicle()
        local ok = PV.getPublicFlag(vehicle, "AllowUninstallParts") or PV.getSimpleBooleanPermission(PV.checkPermission(playerObj, vehicle))
        if not ok then
            playerObj:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
            return
        end
        oldFn(playerObj, part, item)
    end
end

-- ============================================================
-- ISVehicleMechanics.onTakeEngineParts override
-- ============================================================
do
    local oldFn = ISVehicleMechanics.onTakeEngineParts
    function ISVehicleMechanics.onTakeEngineParts(playerObj, part)
        local vehicle = part and part:getVehicle()
        local ok = PV.getPublicFlag(vehicle, "AllowTakeEngineParts") or PV.getSimpleBooleanPermission(PV.checkPermission(playerObj, vehicle))
        if not ok then
            playerObj:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
            return
        end
        oldFn(playerObj, part)
    end
end
