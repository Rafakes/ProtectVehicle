--[[
    PV_Permissions.lua
    Shared permission resolution helpers.
    Centralizes all flag-based access decisions.
    B42.14.0 only.
--]]

PV = PV or {}

-- ============================================================
-- All known public flags with their defaults (all false = locked)
-- ============================================================
PV.DEFAULT_FLAGS = {
    AllowDrive            = false,
    AllowPassenger        = false,
    AllowContainersAccess = false,
    AllowSiphonFuel       = false,
    AllowUninstallParts   = false,
    AllowTakeEngineParts  = false,
    AllowOpeningDoors     = false,
    AllowOpeningTrunk     = false,
    AllowInflateTires     = false,
    AllowDeflateTires     = false,
    AllowTow              = false,
    AllowScrapVehicle     = false,
}

-- ============================================================
-- Check if player can perform a specific action on a vehicle.
-- Combines ownership check + public flag check.
-- Returns true = allowed, false = denied
-- ============================================================
function PV.canPerformAction(playerObj, vehicleObj, flagName)
    -- If unclaimed, allow everything
    local perm = PV.checkPermission(playerObj, vehicleObj)
    if perm == true then return true end

    -- Owner/admin/faction/safehouse: always allowed
    if PV.getSimpleBooleanPermission(perm) then return true end

    -- Not owner: check public flag
    return PV.getPublicFlag(vehicleObj, flagName)
end

-- ============================================================
-- Get effective flags for a vehicle (merges defaults with stored)
-- ============================================================
function PV.getEffectiveFlags(sqlid)
    local flags = {}
    for k, v in pairs(PV.DEFAULT_FLAGS) do
        flags[k] = v
    end
    if PV.dbByVehicleSQLID == nil then return flags end
    local entry = PV.dbByVehicleSQLID[sqlid]
    if entry and entry.PublicFlags then
        for k, v in pairs(entry.PublicFlags) do
            flags[k] = v
        end
    end
    return flags
end

-- ============================================================
-- Compute delta between current flags and new flags
-- Returns only changed keys (for minimal network payload)
-- ============================================================
function PV.computeFlagsDelta(sqlid, newFlags)
    local current = PV.getEffectiveFlags(sqlid)
    local delta = {}
    for k, v in pairs(newFlags) do
        if current[k] ~= v then
            delta[k] = v
        end
    end
    return delta
end

-- ============================================================
-- Validate a flags table: only known keys, only booleans
-- ============================================================
function PV.validateFlags(flags)
    if type(flags) ~= "table" then return false end
    for k, v in pairs(flags) do
        if PV.DEFAULT_FLAGS[k] == nil then return false end
        if type(v) ~= "boolean" then return false end
    end
    return true
end

-- ============================================================
-- Apply a flags delta to the DB entry (server-side)
-- ============================================================
function PV.applyFlagsDelta(sqlid, delta)
    if PV.dbByVehicleSQLID == nil then return false end
    local entry = PV.dbByVehicleSQLID[sqlid]
    if not entry then return false end
    if entry.PublicFlags == nil then entry.PublicFlags = {} end
    for k, v in pairs(delta) do
        if PV.DEFAULT_FLAGS[k] ~= nil then
            entry.PublicFlags[k] = v
        end
    end
    return true
end
