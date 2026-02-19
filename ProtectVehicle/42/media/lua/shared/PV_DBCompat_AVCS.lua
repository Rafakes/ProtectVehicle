--[[
    PV_DBCompat_AVCS.lua
    DB compatibility layer: reads existing AVCS save data and migrates
    missing fields with safe defaults. Does NOT destroy old data.
    B42.14.0 only.
--]]

PV = PV or {}

-- ============================================================
-- Migrate a vehicle DB entry: add missing fields with defaults
-- ============================================================
local function migrateVehicleEntry(sqlid, entry)
    -- PublicFlags: all false by default (locked vehicle)
    if entry.PublicFlags == nil then
        entry.PublicFlags = {
            AllowDrive           = false,
            AllowPassenger       = false,
            AllowContainersAccess= false,
            AllowSiphonFuel      = false,
            AllowUninstallParts  = false,
            AllowTakeEngineParts = false,
            AllowOpeningDoors    = false,
            AllowOpeningTrunk    = false,
            AllowInflateTires    = false,
            AllowDeflateTires    = false,
            AllowTow             = false,
            AllowScrapVehicle    = false,
        }
    end
    -- AllowList: optional, nil is fine
    if entry.AllowList == nil then
        entry.AllowList = {}
    end
    -- LastLocationZ: new field
    if entry.LastLocationZ == nil then
        entry.LastLocationZ = 0
    end
    -- PV_Version marker
    entry.PV_Version = entry.PV_Version or 1
    return entry
end

-- ============================================================
-- Migrate a player DB entry: add missing fields with defaults
-- ============================================================
local function migratePlayerEntry(username, entry)
    -- LastKnownLogoffTime: new field (default to logon time or now)
    if entry.LastKnownLogoffTime == nil then
        entry.LastKnownLogoffTime = entry.LastKnownLogonTime or getTimestamp()
    end
    return entry
end

-- ============================================================
-- Run migration on all existing entries (called once on server init)
-- ============================================================
function PV.migrateDB()
    if PV.dbByVehicleSQLID == nil or PV.dbByPlayerID == nil then return end

    local changed = false

    for sqlid, entry in pairs(PV.dbByVehicleSQLID) do
        local before = entry.PV_Version
        migrateVehicleEntry(sqlid, entry)
        if entry.PV_Version ~= before then changed = true end
    end

    for username, entry in pairs(PV.dbByPlayerID) do
        if type(entry) == "table" then
            local before = entry.LastKnownLogoffTime
            migratePlayerEntry(username, entry)
            if entry.LastKnownLogoffTime ~= before then changed = true end
        end
    end

    if changed then
        ModData.add("AVCSByVehicleSQLID", PV.dbByVehicleSQLID)
        ModData.add("AVCSByPlayerID", PV.dbByPlayerID)
        print("[PV] DB migration complete.")
    else
        print("[PV] DB already up to date, no migration needed.")
    end
end

-- ============================================================
-- Rebuild DB: repair missing indices without destroying data
-- Uses AVCSByVehicleSQLID as source of truth (same as AVCS)
-- ============================================================
function PV.rebuildDB()
    if PV.dbByVehicleSQLID == nil then return end
    local newPlayerDB = {}

    for sqlid, entry in pairs(PV.dbByVehicleSQLID) do
        local owner = entry.OwnerPlayerID
        if owner then
            if not newPlayerDB[owner] then
                newPlayerDB[owner] = {}
                -- Preserve logon/logoff times if available
                if PV.dbByPlayerID and PV.dbByPlayerID[owner] then
                    newPlayerDB[owner].LastKnownLogonTime  = PV.dbByPlayerID[owner].LastKnownLogonTime  or getTimestamp()
                    newPlayerDB[owner].LastKnownLogoffTime = PV.dbByPlayerID[owner].LastKnownLogoffTime or getTimestamp()
                else
                    newPlayerDB[owner].LastKnownLogonTime  = getTimestamp()
                    newPlayerDB[owner].LastKnownLogoffTime = getTimestamp()
                end
            end
            newPlayerDB[owner][sqlid] = true
        end
    end

    PV.dbByPlayerID = newPlayerDB
    ModData.add("AVCSByPlayerID", PV.dbByPlayerID)
    print("[PV] DB rebuild complete.")
end

-- ============================================================
-- Ensure vehicle has a SQLID (generate if missing)
-- Server-side only. Returns the SQLID.
-- ============================================================
function PV.ensureVehicleSQLID(vehicleObj)
    if not (isServer() and not isClient()) then return nil end
    local existing = vehicleObj:getModData().SQLID
    if existing then return existing end

    -- Generate unique ID using timestamp + vehicle runtime id
    local usedIDs = ModData.exists("PV_UsedVehicleIDs") and ModData.get("PV_UsedVehicleIDs") or {}
    local newID
    local attempts = 0
    repeat
        attempts = attempts + 1
        newID = tonumber(tostring(getTimestamp()):gsub("%.", "") .. tostring(vehicleObj:getId()):sub(-4))
        if newID == nil then
            newID = math.floor(getTimestamp() * 1000) + vehicleObj:getId() + attempts
        end
    until not usedIDs[newID] or attempts > 20

    -- Mark as used immediately
    usedIDs[newID] = true
    ModData.add("PV_UsedVehicleIDs", usedIDs)

    -- Persist on vehicle
    vehicleObj:getModData().SQLID = newID

    -- Sync to clients in same cell
    sendServerCommand("ProtectVehicle", "registerVehicleSQLID", {
        vehicleRuntimeId = vehicleObj:getId(),
        sqlid = newID
    })

    return newID
end
