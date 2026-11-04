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

    -- isValid roda repetidamente enquanto a acao esta na fila; o throttle
    -- de PV.reportDeniedAction evita inundar o servidor e o dono.
    local function denied(vehicleObj)
        if self.character then
            self.character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
            if PV.reportDeniedAction then
                pcall(PV.reportDeniedAction, self.character, vehicleObj, "AllowContainersAccess")
            end
        end
        return false
    end

    local srcVehicle = getVehicleFromContainer(self.srcContainer)
    if srcVehicle and not PV.canPerformAction(self.character, srcVehicle, "AllowContainersAccess") then
        return denied(srcVehicle)
    end

    local dstVehicle = getVehicleFromContainer(self.destContainer)
    if dstVehicle and not PV.canPerformAction(self.character, dstVehicle, "AllowContainersAccess") then
        return denied(dstVehicle)
    end

    return PV.oISInventoryTransferActionValid(self)
end

