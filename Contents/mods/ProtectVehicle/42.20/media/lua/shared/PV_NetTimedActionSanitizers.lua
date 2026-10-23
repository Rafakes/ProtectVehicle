--[[
    PV_NetTimedActionSanitizers.lua
    Fixes for potential exploits or crashes where TimedActions might have nil duration
    or invalid parameters when synced over network.
    B42.14.0 only.
--]]

if not isClient() and isServer() then return end

require "TimedActions/ISBaseTimedAction"

-- Guard against nil duration crashing NetTimedAction
if not ISBaseTimedAction.__pvDurationGuard then
    ISBaseTimedAction.__pvDurationGuard = true
    local _oldGetDuration = ISBaseTimedAction.getDuration
    local _logged = {}
    
    function ISBaseTimedAction:getDuration()
        local v = _oldGetDuration(self)
        if v == nil then
            local name = self.__className or self.Type or (self.getType and self:getType()) or "UnknownTimedAction"
            if not _logged[name] then
                _logged[name] = true
                print("[PV] Warning: getDuration() returned nil for action: " .. tostring(name) .. ". Defaulting to 1.")
            end
            return 1
        end
        return v
    end
end
