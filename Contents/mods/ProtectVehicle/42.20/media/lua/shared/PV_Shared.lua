--[[
    ProtectVehicle - PV_Shared.lua
    Shared functions (client + server).
    Uses ProtectVehicle ModData keys only.
    B42.14.0 only.
--]]

PV = PV or {}
PV.UI = PV.UI or {}

-- ============================================================
-- DB references (set by server on init, by client on receive)
-- ============================================================
-- PVByVehicleSQLID[sqlid] = { OwnerPlayerID, ClaimDateTime, CarModel,
--   LastLocationX, LastLocationY, LastLocationZ, LastLocationUpdateDateTime,
--   PublicFlags={...}, AllowList={...} }
-- PVByPlayerID[username] = { LastKnownLogonTime, LastKnownLogoffTime, [sqlid]=true, ... }
PV.dbByVehicleSQLID = nil
PV.dbByPlayerID     = nil

-- ============================================================
-- TrunkParts helper
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
-- Vehicle display name helper
-- ============================================================
function PV.getVehicleDisplayNameFromModel(rawModel)
    if rawModel == nil then return "?" end
    rawModel = tostring(rawModel)

    local suffix = rawModel
    local dot = string.find(rawModel, "%.")
    if dot then
        suffix = string.sub(rawModel, dot + 1)
    end

    local key = "IGUI_VehicleName" .. suffix
    local t = getTextOrNull and getTextOrNull(key) or nil
    if t then return t end

    local nice = suffix
    nice = nice:gsub("_", " ")
    nice = nice:gsub("(%l)(%u)", "%1 %2")
    return nice ~= "" and nice or rawModel
end

-- ============================================================
-- Vehicle SQLID access
-- Accepts IsoVehicle, number, or string.
-- ============================================================
function PV.getVehicleID(vehicleObj)
    if vehicleObj == nil then return nil end
    if type(vehicleObj) == "number" then return vehicleObj end
    if type(vehicleObj) == "string" then
        return tonumber(vehicleObj) or vehicleObj
    end
    if not vehicleObj.getModData then return nil end
    local modData = vehicleObj:getModData()
    if not modData then return nil end
    local id = modData.SQLID
    if type(id) == "string" then
        local n = tonumber(id)
        if n ~= nil then return n end
    end
    return id
end

--- Lookup no ModData com fallback se a chave foi persistida como string (JSON).
function PV.getVehicleDBEntry(sqlid)
    if type(PV.dbByVehicleSQLID) ~= "table" or sqlid == nil then return nil end
    local e = PV.dbByVehicleSQLID[sqlid]
    if e ~= nil then return e end
    if type(sqlid) == "number" then
        return PV.dbByVehicleSQLID[tostring(sqlid)]
    end
    return nil
end

--- Coerce sqlid para número quando possível (rede / JSON / ModData).
function PV.canonicalVehicleSqlid(sqlid)
    if sqlid == nil then return nil end
    if type(sqlid) == "number" then return sqlid end
    if type(sqlid) == "string" then return tonumber(sqlid) or sqlid end
    return sqlid
end

--- Remove entrada do índice por veículo (todas as variantes de chave string/number).
function PV.clearVehicleDBEntry(sqlid)
    if type(PV.dbByVehicleSQLID) ~= "table" or sqlid == nil then return end
    local db = PV.dbByVehicleSQLID
    db[sqlid] = nil
    local n = PV.canonicalVehicleSqlid(sqlid)
    if n ~= nil then
        db[n] = nil
        if type(n) == "number" then
            db[tostring(n)] = nil
        end
    end
end

--- Remove índice [sqlid] na lista de veículos do jogador (variantes de chave).
function PV.clearPlayerVehicleIndex(username, sqlid)
    if type(PV.dbByPlayerID) ~= "table" or type(username) ~= "string" or sqlid == nil then return end
    local p = PV.dbByPlayerID[username]
    if type(p) ~= "table" then return end
    p[sqlid] = nil
    local n = PV.canonicalVehicleSqlid(sqlid)
    if n ~= nil then
        p[n] = nil
        if type(n) == "number" then
            p[tostring(n)] = nil
        end
    end
end

function PV.getAccessLevelName(playerObj)
    if not playerObj or not playerObj.getAccessLevel then
        return "none"
    end
    local level = string.lower(playerObj:getAccessLevel() or "none")
    if level == "" then
        level = "none"
    end
    return level
end

-- Apenas níveis explícitos de staff (B42 pode retornar "Player", "User" etc. para não-admins —
-- tratar qualquer coisa ≠ "none" como staff quebrava permissões para todos).
local PV_STAFF_ACCESS_LEVELS = {
    admin = true,
    moderator = true,
    moderatorplus = true,
    gm = true,
    observer = true,
    overseer = true,
}

function PV.isStaffPlayer(playerObj)
    local level = PV.getAccessLevelName(playerObj)
    return PV_STAFF_ACCESS_LEVELS[level] == true
end

-- ============================================================
-- Supporter role detection (server whitelist role, e.g. "Apoiador").
-- Mirrors BetterSafehouse's RSE.getPlayerRoleName / isSupporterRoleName.
-- ============================================================
function PV.getPlayerRoleName(playerObj)
    if not playerObj or not playerObj.getRole then return nil end
    local ok, role = pcall(function() return playerObj:getRole() end)
    if not ok or not role or not role.getName then return nil end
    local okName, name = pcall(function() return role:getName() end)
    if okName and name and tostring(name) ~= "" then return tostring(name) end
    return nil
end

local _pvSupporterRoleLookupCache = nil
local _pvSupporterRoleLookupSource = nil

local function PV_getSupporterRoleLookup()
    local src = (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.SupporterRoleNames) or "Apoiador"
    if _pvSupporterRoleLookupCache and _pvSupporterRoleLookupSource == src then
        return _pvSupporterRoleLookupCache
    end
    local lookup = {}
    for name in string.gmatch(src, "([^,]+)") do
        local trimmed = string.lower(name:match("^%s*(.-)%s*$"))
        if trimmed ~= "" and trimmed ~= "user" then
            lookup[trimmed] = true
        end
    end
    _pvSupporterRoleLookupCache = lookup
    _pvSupporterRoleLookupSource = src
    return lookup
end

function PV.isSupporterPlayer(playerObj)
    local roleName = PV.getPlayerRoleName(playerObj)
    if not roleName then return false end
    local normalized = string.lower(roleName)
    if normalized == "" or normalized == "user" then return false end
    return PV_getSupporterRoleLookup()[normalized] == true
end

function PV.normalizeUsername(username)
    if type(username) ~= "string" then return nil end
    username = username:match("^%s*(.-)%s*$")
    if username == "" then return nil end
    return username
end

function PV.getVehicleEntry(vehicleObj)
    local sqlid = PV.getVehicleID(vehicleObj)
    if sqlid == nil then
        return nil, nil, true
    end
    if type(PV.dbByVehicleSQLID) ~= "table" then
        return sqlid, nil, false
    end
    return sqlid, PV.getVehicleDBEntry(sqlid), true
end

function PV.canManageVehicle(playerObj, vehicleObj)
    local _, entry, dbReady = PV.getVehicleEntry(vehicleObj)
    if not dbReady or not entry or not playerObj then
        return false
    end
    return PV.isStaffPlayer(playerObj) or entry.OwnerPlayerID == playerObj:getUsername()
end

-- Facção e Safehouse guardam o líder fora da lista de membros:
-- getPlayers() traz só os membros comuns, o dono fica em getOwner().
-- Sem checar getOwner() o líder nunca era reconhecido como membro e
-- ficava sem acesso aos veículos dos próprios liderados.
local function PV_isGroupMember(group, username)
    if not group or not username then return false end
    if group:getOwner() == username then return true end
    local members = group:getPlayers()
    if not members then return false end
    for i = 0, members:size() - 1 do
        if members:get(i) == username then
            return true
        end
    end
    return false
end

local function PV_isFactionMember(ownerID, username)
    local fac = ownerID and Faction.getPlayerFaction(ownerID) or nil
    return PV_isGroupMember(fac, username)
end

local function PV_isSafehouseMember(ownerID, username)
    local sh = ownerID and SafeHouse.hasSafehouse(ownerID) or nil
    return PV_isGroupMember(sh, username)
end

-- ============================================================
-- Permission check
-- Returns:
--   true            = sem SQLID no veículo (nunca claimado neste mod — liberado)
--   { permissions=true,  ownerid=..., logoffTime=... } = acesso total (dono/staff/facção/SH)
--   { permissions=false, ownerid=..., logoffTime=... } = sem acesso total (flags / AllowList)
-- Notes:
--   - SQLID sem entrada no DB (órfão / sync) falha fechado (dbPending), não como "sem dono".
--   - AllowList não concede acesso total; só flags por jogador.
-- ============================================================
function PV.checkPermission(playerObj, vehicleObj)
    local sqlid, entry, dbReady = PV.getVehicleEntry(vehicleObj)

    if sqlid == nil then return true end

    if not dbReady then
        return { permissions = false, ownerid = nil, logoffTime = 0, dbPending = true, sqlid = sqlid }
    end

    -- Veículo com SQLID no ModData mas sem entrada no DB: SQLID órfão
    -- (ex.: unclaim sem limpar ModData, ou chunk salvo de sessão anterior).
    -- DB está pronto (dbReady = true) então não é sync pendente — tratar como abandonado (livre).
    if entry == nil then
        return true
    end

    local ownerID = entry.OwnerPlayerID
    local logoffT = (PV.dbByPlayerID and PV.dbByPlayerID[ownerID] and PV.dbByPlayerID[ownerID].LastKnownLogoffTime) or 0

    local function makeResult(perm, extra)
        local result = { permissions = perm, ownerid = ownerID, logoffTime = logoffT, sqlid = sqlid }
        if type(extra) == "table" then
            for k, v in pairs(extra) do
                result[k] = v
            end
        end
        return result
    end

    if not playerObj then
        return makeResult(false)
    end

    local username = playerObj:getUsername()

    if PV.isStaffPlayer(playerObj) then
        return makeResult(true, { scope = "staff" })
    end

    if ownerID == username then
        return makeResult(true, { scope = "owner" })
    end

    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowFaction and entry.AllowFaction == true then
        if PV_isFactionMember(ownerID, username) then
            return makeResult(true, { scope = "faction" })
        end
    end

    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowSafehouse and entry.AllowSafehouse == true then
        if PV_isSafehouseMember(ownerID, username) then
            return makeResult(true, { scope = "safehouse" })
        end
    end

    if entry.AllowList then
        for name, _ in pairs(entry.AllowList) do
            if name == username then
                return makeResult(false, { listed = true })
            end
        end
    end

    return makeResult(false)
end

-- Simplify checkPermission result to boolean
function PV.getSimpleBooleanPermission(result)
    if type(result) == "boolean" then
        return result ~= false
    end
    return result and result.permissions == true
end

-- ============================================================
-- RV Interior specific permission check.
-- Owner/admin always yes.
-- Safehouse/faction use the RV-specific toggles.
-- AllowList uses the AllowEnterRV per-player flag.
-- Public AllowEnterRV still works as fallback.
-- ============================================================
function PV.canEnterRV(playerObj, vehicleObj)
    local sqlid, entry, dbReady = PV.getVehicleEntry(vehicleObj)

    if sqlid == nil then return true end
    if not dbReady then return false end
    if entry == nil then return true end  -- órfão: livre como abandonado
    if not playerObj then return false end

    if PV.isStaffPlayer(playerObj) then return true end

    local username = playerObj:getUsername()
    if entry.OwnerPlayerID == username then return true end

    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowFaction and entry.AllowFactionRV == true then
        if PV_isFactionMember(entry.OwnerPlayerID, username) then return true end
    end

    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowSafehouse and entry.AllowSafehouseRV == true then
        if PV_isSafehouseMember(entry.OwnerPlayerID, username) then return true end
    end

    return PV.getPlayerFlag(vehicleObj, username, "AllowEnterRV")
end

-- Get a public flag for a vehicle.
-- Returns true if unclaimed or flag is set.
-- Returns false while a claimed vehicle is waiting for DB sync.
function PV.getPublicFlag(vehicleObj, flagName)
    local sqlid = PV.getVehicleID(vehicleObj)
    if sqlid == nil then return true end
    if type(PV.dbByVehicleSQLID) ~= "table" then return false end
    local entry = PV.getVehicleDBEntry(sqlid)
    if entry == nil then return true end  -- órfão: livre como abandonado
    if entry.PublicFlags == nil then return false end
    return entry.PublicFlags[flagName] == true
end

-- Get a per-player flag for a vehicle.
-- Returns true if the player is owner, or if a per-player override is true.
-- Falls back to the public flag when there is no per-player override.
-- Returns false while a claimed vehicle is waiting for DB sync.
function PV.getPlayerFlag(vehicleObj, username, flagName)
    local sqlid = PV.getVehicleID(vehicleObj)
    if sqlid == nil then return true end
    if type(PV.dbByVehicleSQLID) ~= "table" then return false end
    local entry = PV.getVehicleDBEntry(sqlid)
    if entry == nil then return true end  -- órfão: livre como abandonado
    if entry.OwnerPlayerID == username then return true end

    local al = entry.AllowList
    if al and al[username] and type(al[username]) == "table" then
        local pf = al[username][flagName]
        if pf ~= nil then return pf == true end
    end

    if entry.PublicFlags then
        return entry.PublicFlags[flagName] == true
    end
    return false
end

-- ============================================================
-- Max claim check
-- ============================================================
function PV.getClaimLimit(playerObj)
    if PV.isSupporterPlayer(playerObj) then
        return (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.MaxVehicleSupporter) or 6
    end
    return (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.MaxVehicle) or 3
end

function PV.getClaimCount(playerObj)
    if PV.dbByPlayerID == nil or not playerObj then return 0 end
    local pEntry = PV.dbByPlayerID[playerObj:getUsername()]
    if pEntry == nil then return 0 end
    local count = 0
    for k, v in pairs(pEntry) do
        if k ~= "LastKnownLogonTime" and k ~= "LastKnownLogoffTime" then
            count = count + 1
        end
    end
    return count
end

function PV.checkMaxClaim(playerObj)
    if PV.isStaffPlayer(playerObj) then return true end
    if PV.dbByPlayerID == nil then return true end
    if PV.dbByPlayerID[playerObj:getUsername()] == nil then return true end
    return PV.getClaimCount(playerObj) < PV.getClaimLimit(playerObj)
end

-- ============================================================
-- UI font scale helper
-- ============================================================
function PV.getUIFontScale()
    return 1 + (getCore():getOptionFontSize() - 1) / 4
end

-- ============================================================
-- Vehicle collection iterator — compatible with ArrayList (<=42.16)
-- and Set (>=42.17). Calls fn(vehicle) for each element.
-- ============================================================
function PV.iterVehicles(vehicles, fn)
    if not vehicles or not fn then return end
    if vehicles.iterator then
        local iter = vehicles:iterator()
        while iter:hasNext() do
            fn(iter:next())
        end
    elseif vehicles.get and vehicles.size then
        for i = 0, vehicles:size() - 1 do
            fn(vehicles:get(i))
        end
    end
end

-- ============================================================
-- Update vehicle coordinate (server-side, called from hooks)
-- ============================================================
local _coordPersistTimers = {}

function PV.updateVehicleCoordinate(vehicleObj, opts)
    if not (isServer() and not isClient()) then return false end
    if not vehicleObj then return false end
    opts = opts or {}

    local sqlid = PV.getVehicleID(vehicleObj)
    if not sqlid then return false end
    if PV.dbByVehicleSQLID == nil then return false end
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return false end

    local nx = math.floor(vehicleObj:getX())
    local ny = math.floor(vehicleObj:getY())
    local nz = math.floor(vehicleObj:getZ())

    local ox = tonumber(entry.LastLocationX)
    local oy = tonumber(entry.LastLocationY)
    local oz = tonumber(entry.LastLocationZ) or 0
    local moved = (ox == nil or oy == nil or ox ~= nx or oy ~= ny or oz ~= nz)
    if not moved then return false end

    local minDistance = tonumber(opts.minDistance) or 0
    if ox ~= nil and oy ~= nil and minDistance > 0 then
        local dx = nx - ox
        local dy = ny - oy
        local dz = nz - oz
        local distSq = (dx * dx) + (dy * dy) + (dz * dz)
        if distSq < (minDistance * minDistance) then
            return false
        end
    end

    local now = getTimestamp()
    entry.LastLocationX = nx
    entry.LastLocationY = ny
    entry.LastLocationZ = nz
    entry.LastLocationUpdateDateTime = now

    sendServerCommand("ProtectVehicle", "updateCoord", {
        sqlid = sqlid,
        x = nx, y = ny, z = nz,
        t = now
    })

    local persistCooldown = tonumber(opts.persistCooldownSeconds) or 30
    local lastPersist = _coordPersistTimers[sqlid] or 0
    if persistCooldown <= 0 or (now - lastPersist) >= persistCooldown then
        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        _coordPersistTimers[sqlid] = now
    end

    return true
end
