--[[
    PV_DB.lua
    Internal PV DB normalization layer.
    Keeps only ProtectVehicle's own ModData schema healthy.
    B42.14.0 only.
--]]

PV = PV or {}

-- ============================================================
-- Normalize a vehicle DB entry: add missing PV fields with defaults.
-- ============================================================
local function normalizeVehicleEntry(sqlid, entry)
    if entry.OwnerPlayerID == "" then
        entry.OwnerPlayerID = "__UNKNOWN__"
        print("[PV] normalizeVehicleEntry: AVISO - OwnerPlayerID vazio em sqlid=" .. tostring(sqlid) .. ". Marcado como __UNKNOWN__.")
    end

    if entry.PublicFlags == nil then
        entry.PublicFlags = {
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
            AllowEnterRV          = false,
        }
    elseif entry.PublicFlags.AllowEnterRV == nil then
        entry.PublicFlags.AllowEnterRV = false
    end

    if entry.AllowList == nil then
        entry.AllowList = {}
    end
    if entry.AllowSafehouse == nil then
        entry.AllowSafehouse = false
    end
    if entry.AllowFaction == nil then
        entry.AllowFaction = false
    end
    if entry.AllowSafehouseRV == nil then
        entry.AllowSafehouseRV = false
    end
    if entry.AllowFactionRV == nil then
        entry.AllowFactionRV = false
    end
    if entry.LastLocationZ == nil then
        entry.LastLocationZ = 0
    end

    local v = tonumber(entry.PV_Version) or 1
    if v < 3 then v = 3 end
    entry.PV_Version = v
    return entry
end

-- ============================================================
-- Normalize a player DB entry: add missing PV fields with defaults.
-- ============================================================
local function normalizePlayerEntry(username, entry)
    if entry.LastKnownLogoffTime == nil then
        entry.LastKnownLogoffTime = entry.LastKnownLogonTime or getTimestamp()
    end
    return entry
end

-- ============================================================
-- ModData JSON roundtrip: numeric keys may come back as strings.
-- Normalize to numbers when possible.
-- ============================================================
local function mergeVehicleEntriesOnKeyCollision(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a or b
    end
    local function validOwner(e)
        local o = e.OwnerPlayerID
        return o ~= nil and o ~= "" and o ~= "__UNKNOWN__"
    end
    if validOwner(b) and not validOwner(a) then return b end
    if validOwner(a) and not validOwner(b) then return a end
    return a
end

function PV.normalizeVehicleDatabaseKeys()
    local changed = false

    if type(PV.dbByVehicleSQLID) == "table" then
        local db = PV.dbByVehicleSQLID
        local toScan = {}
        for k in pairs(db) do
            toScan[#toScan + 1] = k
        end
        for _, k in ipairs(toScan) do
            if type(k) == "string" then
                local n = tonumber(k)
                if n ~= nil then
                    local v = db[k]
                    if db[n] == nil then
                        db[n] = v
                    else
                        db[n] = mergeVehicleEntriesOnKeyCollision(db[n], v)
                    end
                    db[k] = nil
                    changed = true
                end
            end
        end
    end

    if type(PV.dbByPlayerID) == "table" then
        for _, entry in pairs(PV.dbByPlayerID) do
            if type(entry) == "table" then
                local toScan = {}
                for k in pairs(entry) do
                    toScan[#toScan + 1] = k
                end
                for _, k in ipairs(toScan) do
                    if type(k) == "string" then
                        local n = tonumber(k)
                        if n ~= nil then
                            if entry[n] == nil then
                                entry[n] = entry[k]
                            else
                                entry[n] = entry[n] or entry[k]
                            end
                            entry[k] = nil
                            changed = true
                        end
                    end
                end
            end
        end
    end

    if ModData.exists("PV_UsedVehicleIDs") then
        local used = ModData.get("PV_UsedVehicleIDs")
        if type(used) == "table" then
            local usedChanged = false
            local toScan = {}
            for k in pairs(used) do
                toScan[#toScan + 1] = k
            end
            for _, k in ipairs(toScan) do
                if type(k) == "string" then
                    local n = tonumber(k)
                    if n ~= nil then
                        if used[n] == nil then
                            used[n] = used[k]
                        end
                        used[k] = nil
                        usedChanged = true
                    end
                end
            end
            if usedChanged then
                ModData.add("PV_UsedVehicleIDs", used)
                changed = true
            end
        end
    end

    return changed
end

-- ============================================================
-- Run normalization on all existing PV entries.
-- ============================================================
function PV.normalizeDB()
    if PV.dbByVehicleSQLID == nil or PV.dbByPlayerID == nil then return end

    local changed = false

    for sqlid, entry in pairs(PV.dbByVehicleSQLID) do
        local beforeV = entry.PV_Version
        local beforeOwner = entry.OwnerPlayerID
        local beforeSH = entry.AllowSafehouse
        local beforeF = entry.AllowFaction
        local beforeSHRV = entry.AllowSafehouseRV
        local beforeFRV = entry.AllowFactionRV
        local beforeRVFlag = entry.PublicFlags and entry.PublicFlags.AllowEnterRV

        normalizeVehicleEntry(sqlid, entry)

        if entry.PV_Version ~= beforeV
        or entry.OwnerPlayerID ~= beforeOwner
        or entry.AllowSafehouse ~= beforeSH
        or entry.AllowFaction ~= beforeF
        or entry.AllowSafehouseRV ~= beforeSHRV
        or entry.AllowFactionRV ~= beforeFRV
        or (entry.PublicFlags and entry.PublicFlags.AllowEnterRV ~= beforeRVFlag)
        then
            changed = true
        end
    end

    for username, entry in pairs(PV.dbByPlayerID) do
        if type(entry) == "table" then
            local before = entry.LastKnownLogoffTime
            normalizePlayerEntry(username, entry)
            if entry.LastKnownLogoffTime ~= before then changed = true end
        end
    end

    if changed then
        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        ModData.add("PVByPlayerID", PV.dbByPlayerID)
        print("[PV] DB normalization complete.")
    else
        print("[PV] DB already up to date, no normalization needed.")
    end
end

-- ============================================================
-- Rebuild DB: repair missing indices without destroying data.
-- Uses PVByVehicleSQLID as source of truth.
-- ============================================================
function PV.rebuildDB()
    if PV.dbByVehicleSQLID == nil then return end
    local newPlayerDB = {}

    for sqlid, entry in pairs(PV.dbByVehicleSQLID) do
        local owner = entry.OwnerPlayerID
        if owner then
            if not newPlayerDB[owner] then
                newPlayerDB[owner] = {}
                if PV.dbByPlayerID and PV.dbByPlayerID[owner] then
                    newPlayerDB[owner].LastKnownLogonTime = PV.dbByPlayerID[owner].LastKnownLogonTime or getTimestamp()
                    newPlayerDB[owner].LastKnownLogoffTime = PV.dbByPlayerID[owner].LastKnownLogoffTime or getTimestamp()
                else
                    newPlayerDB[owner].LastKnownLogonTime = getTimestamp()
                    newPlayerDB[owner].LastKnownLogoffTime = getTimestamp()
                end
            end
            newPlayerDB[owner][sqlid] = true
        end
    end

    PV.dbByPlayerID = newPlayerDB
    ModData.add("PVByPlayerID", PV.dbByPlayerID)
    print("[PV] DB rebuild complete.")
end

-- ============================================================
-- PVDocuments DB helpers (Vehicle Conversion Document system).
-- ============================================================

local function PV_nowEpoch()
    local now = nil
    pcall(function()
        if getTimestamp then now = tonumber(getTimestamp()) end
    end)
    if not now then
        now = os.time()
    end
    return now
end

function PV.isDocumentExpired(docEntry, nowEpoch)
    if type(docEntry) ~= "table" then return false end
    local expiresAt = tonumber(docEntry.expiresAt)
    if not expiresAt or expiresAt <= 0 then return false end
    local now = tonumber(nowEpoch) or PV_nowEpoch()
    return now >= expiresAt
end

-- Generate the next sequential document ID string ("pvdoc-N").
function PV.nextDocId()
    local meta = ModData.exists("PV_DocMeta") and ModData.get("PV_DocMeta") or { nextId = 1 }
    local id = meta.nextId or 1
    meta.nextId = id + 1
    ModData.add("PV_DocMeta", meta)
    return "pvdoc-" .. tostring(id)
end

-- Register a document entry in PVDocuments and PVDocumentsByPlayer.
function PV.registerDocument(docEntry)
    local docs = ModData.exists("PVDocuments") and ModData.get("PVDocuments") or {}
    docs[docEntry.docId] = docEntry
    ModData.add("PVDocuments", docs)

    if docEntry.ownerName then
        local byPlayer = ModData.exists("PVDocumentsByPlayer") and ModData.get("PVDocumentsByPlayer") or {}
        byPlayer[docEntry.ownerName] = byPlayer[docEntry.ownerName] or {}
        byPlayer[docEntry.ownerName][docEntry.docId] = true
        ModData.add("PVDocumentsByPlayer", byPlayer)
    end
end

-- Remove a document entry from both indexes.
function PV.unregisterDocument(docId)
    local docs = ModData.exists("PVDocuments") and ModData.get("PVDocuments") or {}
    local entry = docs[docId]
    if entry and entry.ownerName then
        local byPlayer = ModData.exists("PVDocumentsByPlayer") and ModData.get("PVDocumentsByPlayer") or {}
        if byPlayer[entry.ownerName] then
            byPlayer[entry.ownerName][docId] = nil
        end
        ModData.add("PVDocumentsByPlayer", byPlayer)
    end
    docs[docId] = nil
    ModData.add("PVDocuments", docs)
end

-- Get a document entry by ID (nil if not found).
function PV.getDocumentEntry(docId)
    if not docId then return nil end
    local docs = ModData.exists("PVDocuments") and ModData.get("PVDocuments") or {}
    return docs[docId]
end

-- Update the status field of a document (and persist).
function PV.setDocumentStatus(docId, status)
    local docs = ModData.exists("PVDocuments") and ModData.get("PVDocuments") or {}
    if docs[docId] then
        docs[docId].status = status
        ModData.add("PVDocuments", docs)
    end
end

-- Count how many active documents a player currently has.
function PV.countPlayerDocuments(username)
    local byPlayer = ModData.exists("PVDocumentsByPlayer") and ModData.get("PVDocumentsByPlayer") or {}
    local playerDocs = byPlayer[username]
    if not playerDocs then return 0 end
    local count = 0
    local docs = ModData.exists("PVDocuments") and ModData.get("PVDocuments") or {}
    local now = PV_nowEpoch()
    for docId in pairs(playerDocs) do
        local entry = docs[docId]
        if entry
        and entry.status ~= "redeemed"
        and entry.status ~= "expired"
        and not PV.isDocumentExpired(entry, now)
        then
            count = count + 1
        end
    end
    return count
end

-- ============================================================
-- Ensure vehicle has a SQLID (generate if missing).
-- Server-side only. Returns the SQLID.
-- ============================================================
function PV.ensureVehicleSQLID(vehicleObj)
    if not (isServer() and not isClient()) then return nil end
    local existing = vehicleObj:getModData().SQLID
    if existing then return existing end

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

    usedIDs[newID] = true
    ModData.add("PV_UsedVehicleIDs", usedIDs)

    vehicleObj:getModData().SQLID = newID

    sendServerCommand("ProtectVehicle", "registerVehicleSQLID", {
        vehicleRuntimeId = vehicleObj:getId(),
        sqlid = newID
    })

    return newID
end
