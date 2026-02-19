--[[
    ProtectVehicle - PV_Shared.lua
    Shared functions (client + server).
    Compatible with AVCS save data: uses same ModData keys.
    B42.14.0 only.
--]]

PV = PV or {}
PV.UI = PV.UI or {}

-- ============================================================
-- DB references (set by server on init, by client on receive)
-- ============================================================
-- AVCSByVehicleSQLID[sqlid] = { OwnerPlayerID, ClaimDateTime, CarModel,
--   LastLocationX, LastLocationY, LastLocationZ, LastLocationUpdateDateTime,
--   PublicFlags={...}, AllowList={...} }
-- AVCSByPlayerID[username] = { LastKnownLogonTime, LastKnownLogoffTime, [sqlid]=true, ... }
PV.dbByVehicleSQLID = nil
PV.dbByPlayerID     = nil

-- ============================================================
-- TrunkParts helper (replaces AVCS MuleParts; uses TrunkParts only)
-- ============================================================
function PV.matchTrunkPart(partId)
    if type(partId) ~= "string" or #partId == 0 then return false end
    local cfg = SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.TrunkParts or "TrunkDoor;DoorRear"
    for s in string.gmatch(cfg, "([^;]+)") do
        if string.lower(s:match("^%s*(.-)%s*$")) == string.lower(partId) then
            return true
        end
    end
    return false
end

-- ============================================================
-- Vehicle SQLID access (compatible with AVCS: vehicle:getModData().SQLID)
-- ============================================================
function PV.getVehicleID(vehicleObj)
    if not vehicleObj then return nil end
    return vehicleObj:getModData().SQLID
end

-- ============================================================
-- Permission check
-- Returns:
--   true            = unclaimed (allow all)
--   { permissions=true,  ownerid=..., logoffTime=... } = has access
--   { permissions=false, ownerid=..., logoffTime=... } = no access
-- ============================================================
function PV.checkPermission(playerObj, vehicleObj)
    local sqlid
    if type(vehicleObj) == "number" then
        sqlid = vehicleObj
    else
        sqlid = PV.getVehicleID(vehicleObj)
    end

    -- No SQLID = unclaimed
    if sqlid == nil then return true end

    -- Not in DB = unclaimed
    if PV.dbByVehicleSQLID == nil then return true end
    if PV.dbByVehicleSQLID[sqlid] == nil then return true end

    local entry   = PV.dbByVehicleSQLID[sqlid]
    local ownerID = entry.OwnerPlayerID
    local logoffT = (PV.dbByPlayerID and PV.dbByPlayerID[ownerID] and PV.dbByPlayerID[ownerID].LastKnownLogoffTime) or 0

    local function makeResult(perm)
        return { permissions = perm, ownerid = ownerID, logoffTime = logoffT }
    end

    -- Admin bypass
    local level = string.lower(playerObj:getAccessLevel() or "none")
    if level == "admin" then return makeResult(true) end

    -- Owner
    if ownerID == playerObj:getUsername() then return makeResult(true) end

    -- AllowList
    if entry.AllowList then
        for _, name in pairs(entry.AllowList) do
            if name == playerObj:getUsername() then return makeResult(true) end
        end
    end

    -- Faction
    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowFaction then
        local fac = Faction.getPlayerFaction(ownerID)
        if fac then
            local members = fac:getPlayers()
            for i = 0, members:size() - 1 do
                if members:get(i) == playerObj:getUsername() then
                    return makeResult(true)
                end
            end
        end
    end

    -- Safehouse
    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowSafehouse then
        local sh = SafeHouse.hasSafehouse(ownerID)
        if sh then
            local members = sh:getPlayers()
            for i = 0, members:size() - 1 do
                if members:get(i) == playerObj:getUsername() then
                    return makeResult(true)
                end
            end
        end
    end

    return makeResult(false)
end

-- Simplify checkPermission result to boolean
function PV.getSimpleBooleanPermission(result)
    if type(result) == "boolean" then
        return result ~= false  -- false means "unsupported" -> treat as true
    end
    return result.permissions == true
end

-- Get a public flag for a vehicle (AllowDrive, AllowPassenger, etc.)
-- Returns true if unclaimed or flag is set
function PV.getPublicFlag(vehicleObj, flagName)
    local sqlid = PV.getVehicleID(vehicleObj)
    if sqlid == nil then return true end
    if PV.dbByVehicleSQLID == nil then return true end
    local entry = PV.dbByVehicleSQLID[sqlid]
    if entry == nil then return true end
    if entry.PublicFlags == nil then return false end
    return entry.PublicFlags[flagName] == true
end

-- ============================================================
-- Max claim check
-- ============================================================
function PV.checkMaxClaim(playerObj)
    local level = string.lower(playerObj:getAccessLevel() or "none")
    if level == "admin" then return true end
    if PV.dbByPlayerID == nil then return true end
    local pEntry = PV.dbByPlayerID[playerObj:getUsername()]
    if pEntry == nil then return true end
    local count = 0
    for k, v in pairs(pEntry) do
        if k ~= "LastKnownLogonTime" and k ~= "LastKnownLogoffTime" then
            count = count + 1
        end
    end
    local max = (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.MaxVehicle) or 3
    return count < max
end

-- ============================================================
-- UI font scale helper
-- ============================================================
function PV.getUIFontScale()
    return 1 + (getCore():getOptionFontSize() - 1) / 4
end

-- ============================================================
-- Update vehicle coordinate (server-side, called from hooks)
-- ============================================================
function PV.updateVehicleCoordinate(vehicleObj)
    if not (isServer() and not isClient()) then return end
    local sqlid = PV.getVehicleID(vehicleObj)
    if not sqlid then return end
    if PV.dbByVehicleSQLID == nil then return end
    local entry = PV.dbByVehicleSQLID[sqlid]
    if not entry then return end
    local nx = math.floor(vehicleObj:getX())
    local ny = math.floor(vehicleObj:getY())
    local nz = math.floor(vehicleObj:getZ())
    if entry.LastLocationX ~= nx or entry.LastLocationY ~= ny then
        entry.LastLocationX = nx
        entry.LastLocationY = ny
        entry.LastLocationZ = nz
        entry.LastLocationUpdateDateTime = getTimestamp()
        ModData.add("AVCSByVehicleSQLID", PV.dbByVehicleSQLID)
        sendServerCommand("ProtectVehicle", "updateCoord", {
            sqlid = sqlid,
            x = nx, y = ny, z = nz,
            t = entry.LastLocationUpdateDateTime
        })
    end
end
