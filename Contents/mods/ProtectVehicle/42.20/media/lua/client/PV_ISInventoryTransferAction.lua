--[[
    PV_ISInventoryTransferAction.lua
    Override for ISInventoryTransferAction to protect vehicle containers.
    Protects inventory transfers against unauthorized vehicle access.
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
    local function getVehicleFromContainer(container)
        if not container then return nil end
        local getVehiclePartFn = container.getVehiclePart
        local vehiclePart = getVehiclePartFn and container:getVehiclePart()
        return vehiclePart and vehiclePart:getVehicle() or nil
    end

    local srcVehicle = getVehicleFromContainer(self.srcContainer)
    if srcVehicle and not PV.canPerformAction(self.character, srcVehicle, "AllowContainersAccess") then
        if self.character then
            self.character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        end
        return false
    end

    local dstVehicle = getVehicleFromContainer(self.destContainer)
    if dstVehicle and not PV.canPerformAction(self.character, dstVehicle, "AllowContainersAccess") then
        if self.character then
            self.character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        end
        return false
    end

    return PV.oISInventoryTransferActionValid(self)
end

