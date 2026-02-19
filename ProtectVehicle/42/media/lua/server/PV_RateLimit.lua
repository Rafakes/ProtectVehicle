--[[
    ProtectVehicle - PV_RateLimit.lua
    Multiplayer anti-spam system.
    Handles cooldowns and burst limits per player/command.
    B42.14.0 - Mandatory for MP Server Safety.
--]]

if not isServer() then return end

PV = PV or {}
PV.RateLimit = {}

-- Store: [playerUsername][commandName] = { lastTime, burstCount, penalizationUntil }
local requesterData = {}

-- ============================================================
-- Check if a request is allowed
-- Returns: true (allowed), false (denied)
-- ============================================================
function PV.RateLimit.isAllowed(playerObj, command)
    local username = playerObj:getUsername()
    local now = getTimestampMs()
    
    if not requesterData[username] then requesterData[username] = {} end
    if not requesterData[username][command] then
        requesterData[username][command] = { lastTime = 0, burstCount = 0, penalizationUntil = 0 }
    end
    
    local data = requesterData[username][command]
    
    -- Admin bypass
    if playerObj:getAccessLevel() ~= "None" and playerObj:getAccessLevel() ~= "" then
        return true
    end

    -- 1. Penalization check
    if data.penalizationUntil > now then
        return false
    end

    local cooldownMs = SandboxVars.ProtectVehicle.CommandCooldownMs or 500
    local maxRequests = SandboxVars.ProtectVehicle.MaxRequestsPer10s or 10

    -- 2. Base Cooldown check
    if now - data.lastTime < cooldownMs then
        data.burstCount = data.burstCount + 1
        -- If spamming really hard, penalize
        if data.burstCount > maxRequests then
            data.penalizationUntil = now + 10000 -- 10 seconds penalty
            PV.Log.writeGlobal("RateLimit: Penalizing " .. username .. " for spamming " .. command, "WARNING")
        end
        return false
    end

    -- 3. Burst check (window of 10s)
    if now - data.lastTime > 10000 then
        data.burstCount = 1
    else
        data.burstCount = data.burstCount + 1
        if data.burstCount > maxRequests then
            data.penalizationUntil = now + 5000 -- 5 seconds penalty
            return false
        end
    end

    data.lastTime = now
    return true
end

-- ============================================================
-- Cleanup old data periodically to avoid memory leak
-- ============================================================
function PV.RateLimit.cleanup()
    requesterData = {} -- Simple wipe, called EveryDays
end

Events.EveryDays.Add(PV.RateLimit.cleanup)
