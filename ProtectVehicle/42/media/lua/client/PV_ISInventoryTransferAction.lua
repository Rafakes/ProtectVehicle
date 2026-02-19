--[[
    PV_ISInventoryTransferAction.lua
    Override for ISInventoryTransferAction to protect vehicle containers.
    Pattern based on AVCS4213 AVCSISInventoryTransferAction.lua.
    B42.14.x
--]]

if not isClient() and isServer() then return end

-- Guard: class must exist
if not ISInventoryTransferAction or not ISInventoryTransferAction.isValid then
    return
end

PV = PV or {}

PV.oISInventoryTransferActionValid = PV.oISInventoryTransferActionValid or ISInventoryTransferAction.isValid

function ISInventoryTransferAction:isValid()
    if not self.srcContainer then
        return PV.oISInventoryTransferActionValid(self)
    end

    -- Check if source container belongs to a vehicle part
    local getVehiclePartFn = self.srcContainer.getVehiclePart
    local vehiclePart = getVehiclePartFn and self.srcContainer:getVehiclePart()
    if vehiclePart then
        local vehicle = vehiclePart:getVehicle()
        if vehicle then
            -- Check public flag first
            local ok = PV.getPublicFlag(vehicle, "AllowContainersAccess")
            if not ok then
                ok = PV.getSimpleBooleanPermission(PV.checkPermission(self.character, vehicle))
            end
            if ok then
                return PV.oISInventoryTransferActionValid(self)
            else
                return false
            end
        end
    end

    return PV.oISInventoryTransferActionValid(self)
end
