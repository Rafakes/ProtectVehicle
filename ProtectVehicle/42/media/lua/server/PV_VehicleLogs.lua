--[[
    ProtectVehicle - PV_VehicleLogs.lua
    Logging system for vehicle actions.
    Saves to: Zomboid/Logs/ProtectVehicle/
    Separate files for each vehicle + global log.
    B42.14.0.
--]]

if not isServer() then return end

PV = PV or {}
PV.Log = {}

-- ============================================================
-- Write to Global Log
-- ============================================================
function PV.Log.writeGlobal(msg, level)
    level = level or "INFO"
    local timestamp = getTimestamp()
    local dateStr = os.date("%Y-%m-%d %H:%M:%S", timestamp)
    
    -- Format: [Level] [Date] message
    local line = string.format("[%s] [%s] %s", level, dateStr, msg)
    
    -- writeLog is the standard PZ logging function
    writeLog("ProtectVehicle", line)
end

-- ============================================================
-- Write to Vehicle Specific Log
-- ============================================================
function PV.Log.writeVehicle(sqlid, msg, level)
    if not SandboxVars.ProtectVehicle.EnablePerVehicleLogs then return end
    
    level = level or "INFO"
    local timestamp = getTimestamp()
    local dateStr = os.date("%Y-%m-%d %H:%M:%S", timestamp)
    
    local line = string.format("[%s] [%s] %s", level, dateStr, msg)
    
    -- We use a prefix to distinguish files in the logs folder
    -- Most servers will group these by the first argument
    writeLog("PV_Vehicle_" .. tostring(sqlid), line)
    
    -- Also duplicate to global for convenience
    PV.Log.writeGlobal(" {VEH:" .. tostring(sqlid) .. "} " .. msg, level)
end

-- ============================================================
-- Specialized log helpers
-- ============================================================

function PV.Log.claim(playerObj, vehicleObj, sqlid, success, reason)
    local username = playerObj:getUsername()
    local model = vehicleObj:getScript():getFullName()
    local coords = string.format("(%d, %d, %d)", math.floor(vehicleObj:getX()), math.floor(vehicleObj:getY()), math.floor(vehicleObj:getZ()))
    
    if success then
        local msg = string.format("PLAYER '%s' CLAIMED vehicle '%s' at %s", username, model, coords)
        PV.Log.writeVehicle(sqlid, msg, "ADMIN")
    else
        local msg = string.format("PLAYER '%s' DENIED CLAIM for vehicle '%s' at %s. Reason: %s", username, model, coords, reason or "Unknown")
        PV.Log.writeGlobal(msg, "WARNING")
    end
end

function PV.Log.actionDenied(playerObj, vehicleObj, sqlid, action)
    local username = playerObj:getUsername()
    local coords = string.format("(%d, %d, %d)", math.floor(vehicleObj:getX()), math.floor(vehicleObj:getY()), math.floor(vehicleObj:getZ()))
    local msg = string.format("PLAYER '%s' DENIED ACTION '%s' on vehicle at %s", username, action, coords)
    PV.Log.writeVehicle(sqlid, msg, "SECURITY")
end

function PV.Log.adminAction(adminObj, sqlid, action, details)
    local adminName = adminObj:getUsername()
    local msg = string.format("ADMIN '%s' PERFORMED '%s' on vehicle. Details: %s", adminName, action, details or "None")
    PV.Log.writeVehicle(sqlid, msg, "ADMIN")
end

function PV.Log.timeout(sqlid, owner, lastLogoff)
    local msg = string.format("AUTO-UNCLAIM for vehicle due to timeout. Previous owner: '%s'. Last logoff: %s", owner, os.date("%Y-%m-%d %H:%M:%S", lastLogoff))
    PV.Log.writeVehicle(sqlid, msg, "INFO")
end
