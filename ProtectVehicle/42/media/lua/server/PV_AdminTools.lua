--[[
    ProtectVehicle - PV_AdminTools.lua
    Server-side administrative functions.
    Force locate, teleport, and DB maintenance.
    B42.14.0.
--]]

if not isServer() then return end

PV = PV or {}

-- ============================================================
-- Force Locate Real Position
-- ============================================================
function PV.AdminForceLocate(admin, sqlid)
    if not admin or admin:getAccessLevel() == "None" then return end
    
    local found = false
    local vehicleObj = nil
    
    -- Scan loaded vehicles on server
    local vehicles = getCell():getVehicles()
    for i=0, vehicles:size()-1 do
        local v = vehicles:get(i)
        if PV.getVehicleID(v) == sqlid then
            found = true
            vehicleObj = v
            break
        end
    end
    
    if found then
        PV.updateVehicleCoordinate(vehicleObj)
        PV.Log.adminAction(admin, sqlid, "ForceLocate", "Success (Vehicle was loaded)")
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = true, msg = "IGUI_PV_Admin_LocateSuccess" })
    else
        PV.Log.adminAction(admin, sqlid, "ForceLocate", "Failed (Vehicle not loaded)")
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_LocateFailed_NotLoaded" })
    end
end

-- ============================================================
-- Teleport Vehicle
-- ============================================================
function PV.AdminTeleportVehicle(admin, sqlid, x, y, z)
    if not admin or admin:getAccessLevel() == "None" then return end
    if not SandboxVars.ProtectVehicle.AdminTeleportEnabled then return end

    local targetSquare = getSquare(x, y, z)
    if not targetSquare then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_TpFailed_InvalidSquare" })
        return
    end

    -- Find vehicle in loaded cellar
    local vehicles = getCell():getVehicles()
    local veh = nil
    for i=0, vehicles:size()-1 do
        local v = vehicles:get(i)
        if PV.getVehicleID(v) == sqlid then
            veh = v
            break
        end
    end

    if not veh then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_TpFailed_NotLoaded" })
        return
    end

    -- Safety checks
    if veh:getDriver() or veh:getAnyPassenger() then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_TpFailed_Occupied" })
        return
    end
    
    if veh:getVehicleTowedBy() or veh:getVehicleTowing() then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_TpFailed_Towing" })
        return
    end

    -- Execute Teleport
    local oldPos = string.format("(%d, %d)", math.floor(veh:getX()), math.floor(veh:getY()))
    
    -- In B42, setPosition and update physics
    veh:setX(x + 0.5)
    veh:setY(y + 0.5)
    veh:setZ(z)
    
    -- Force sync DB
    PV.updateVehicleCoordinate(veh)
    
    PV.Log.adminAction(admin, sqlid, "Teleport", string.format("From %s to (%d, %d, %d)", oldPos, x, y, z))
    sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = true, msg = "IGUI_PV_Admin_TpSuccess" })
end

-- ============================================================
-- ADMIN COMMAND HANDLER (Extensions to Server.lua)
-- ============================================================
local baseOnClientCommand = PV.OnClientCommand
PV.OnClientCommand = function(module, command, player, args)
    if module ~= "ProtectVehicle" then return end
    
    -- Admin restricted commands
    if command == "adminLocate" then
        PV.AdminForceLocate(player, args.sqlid)
        
    elseif command == "adminTeleport" then
        PV.AdminTeleportVehicle(player, args.sqlid, args.x, args.y, args.z or 0)
        
    elseif command == "adminRebuildDB" then
        if player:getAccessLevel() == "admin" then
            PV.rebuildDB()
            PV.Log.adminAction(player, "GLOBAL", "RebuildDB", "Success")
            sendServerCommand(player, "ProtectVehicle", "adminResponse", { success = true, msg = "IGUI_PV_Admin_RebuildSuccess" })
        end
    else
        -- Fallback to base handler
        if baseOnClientCommand then
            baseOnClientCommand(module, command, player, args)
        end
    end
end
