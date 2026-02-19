--[[
    ProtectVehicle - PV_Server.lua
    Core server-side logic and command handling.
    Compatible with AVCS Save Data.
    B42.14.x - Server is TRUTH.
--]]

if not isServer() then return end

PV = PV or {}

-- ============================================================
-- DB INITIALIZATION
-- ============================================================
function PV.InitDB()
    -- Compatible with AVCS global mod data names
    if not ModData.exists("AVCSByVehicleSQLID") then ModData.create("AVCSByVehicleSQLID") end
    if not ModData.exists("AVCSByPlayerID") then ModData.create("AVCSByPlayerID") end
    if not ModData.exists("PV_UsedVehicleIDs") then ModData.create("PV_UsedVehicleIDs") end

    PV.dbByVehicleSQLID = ModData.get("AVCSByVehicleSQLID")
    PV.dbByPlayerID     = ModData.get("AVCSByPlayerID")

    -- Fix up existing DB or init new
    PV.migrateDB()

    PV.Log.writeGlobal("DB initialized and migrated (AVCS Compatibility active).")
end

-- ============================================================
-- CLAIM LOGIC
-- ============================================================
function PV.ServerClaimVehicle(playerObj, vehicleObj)
    if not playerObj or not vehicleObj then return end

    -- 1. Check if already claimed
    local existingID = PV.getVehicleID(vehicleObj)
    if existingID and PV.dbByVehicleSQLID[existingID] then
        PV.Log.claim(playerObj, vehicleObj, existingID, false, "Already claimed")
        return
    end

    -- 2. Check Document requirement (New Feature)
    if SandboxVars.ProtectVehicle.RequireVehicleDocumentForClaim then
        local docType = SandboxVars.ProtectVehicle.VehicleDocumentItemType or "ProtectVehicle.VehicleDocument"
        local item = playerObj:getInventory():getFirstTypeRecurse(docType)
        if not item then
            PV.Log.claim(playerObj, vehicleObj, "NONE", false, "Missing document: " .. docType)
            sendServerCommand(playerObj, "ProtectVehicle", "haloNote", { text = "IGUI_PV_MissingDocument", r=1, g=0.2, b=0.2 })
            return
        end

        -- Consume if configured
        if SandboxVars.ProtectVehicle.ConsumeVehicleDocumentOnClaim then
            playerObj:getInventory():Remove(item)
        end
    end

    -- 3. Check Max Vehicle limit
    if not PV.checkMaxClaim(playerObj) then
        PV.Log.claim(playerObj, vehicleObj, "NONE", false, "Max vehicle limit reached")
        sendServerCommand(playerObj, "ProtectVehicle", "haloNote", { text = "IGUI_PV_LimitReached", r=1, g=1, b=0 })
        return
    end

    -- 4. Generate/Assign SQLID
    local sqlid = PV.ensureVehicleSQLID(vehicleObj)

    -- 5. Register in DB
    local username = playerObj:getUsername()
    local timestamp = getTimestamp()

    PV.dbByVehicleSQLID[sqlid] = {
        OwnerPlayerID = username,
        ClaimDateTime = timestamp,
        CarModel = vehicleObj:getScript():getFullName(),
        LastLocationX = math.floor(vehicleObj:getX()),
        LastLocationY = math.floor(vehicleObj:getY()),
        LastLocationZ = math.floor(vehicleObj:getZ()),
        LastLocationUpdateDateTime = timestamp,
        PublicFlags = {}, -- Default to all false per migration logic
        AllowList = {}
    }

    if not PV.dbByPlayerID[username] then
        PV.dbByPlayerID[username] = {
            LastKnownLogonTime = timestamp,
            LastKnownLogoffTime = timestamp,
            [sqlid] = true
        }
    else
        PV.dbByPlayerID[username][sqlid] = true
        PV.dbByPlayerID[username].LastKnownLogonTime = timestamp
    end

    ModData.add("AVCSByVehicleSQLID", PV.dbByVehicleSQLID)
    ModData.add("AVCSByPlayerID", PV.dbByPlayerID)

    PV.Log.claim(playerObj, vehicleObj, sqlid, true)

    -- Sync update to all clients
    sendServerCommand("ProtectVehicle", "updateVehicleData", { sqlid = sqlid, data = PV.dbByVehicleSQLID[sqlid] })
    sendServerCommand("ProtectVehicle", "updatePlayerData", { username = username, data = PV.dbByPlayerID[username] })
end

-- ============================================================
-- UNCLAIM LOGIC
-- ============================================================
function PV.ServerUnclaimVehicle(playerObj, sqlid, isTimeout)
    if not PV.dbByVehicleSQLID[sqlid] then return end

    local entry = PV.dbByVehicleSQLID[sqlid]
    local owner = entry.OwnerPlayerID

    -- Log it
    if isTimeout then
        PV.Log.timeout(sqlid, owner, (PV.dbByPlayerID[owner] and PV.dbByPlayerID[owner].LastKnownLogoffTime or 0))
    else
        local adminStr = playerObj:getUsername() ~= owner and " (ADMIN)" or ""
        PV.Log.writeVehicle(sqlid, string.format("UNCLAIMED by %s%s", playerObj:getUsername(), adminStr), "ADMIN")
    end

    -- Remove from Player DB
    if PV.dbByPlayerID[owner] then
        PV.dbByPlayerID[owner][sqlid] = nil
    end

    -- Remove from Vehicle DB
    PV.dbByVehicleSQLID[sqlid] = nil

    ModData.add("AVCSByVehicleSQLID", PV.dbByVehicleSQLID)
    ModData.add("AVCSByPlayerID", PV.dbByPlayerID)

    sendServerCommand("ProtectVehicle", "removeVehicle", { sqlid = sqlid, owner = owner })
end

-- ============================================================
-- TIMEOUT CHECK (Every 10 minutes)
-- ============================================================
function PV.CheckTimeouts()
    local timeoutHours = SandboxVars.ProtectVehicle.ClaimTimeoutHours or 0
    if timeoutHours <= 0 then return end

    local now = getTimestamp()
    local timeoutSeconds = timeoutHours * 3600

    for sqlid, entry in pairs(PV.dbByVehicleSQLID) do
        local owner = entry.OwnerPlayerID
        local pData = PV.dbByPlayerID[owner]

        if pData and pData.LastKnownLogoffTime then
            local isOnline = getPlayerByUsername(owner) ~= nil

            if not isOnline and (now - pData.LastKnownLogoffTime) >= timeoutSeconds then
                PV.ServerUnclaimVehicle(nil, sqlid, true)
            end
        end
    end
end

-- ============================================================
-- COMMAND HANDLER
-- ============================================================
PV.OnClientCommand = function(module, command, player, args)
    if module ~= "ProtectVehicle" then return end

    -- 1. Rate Limit check
    if not PV.RateLimit.isAllowed(player, command) then
        return
    end

    -- 2. Command routing
    if command == "claim" then
        local vehicle = getVehicleById(args.vehicleId)
        PV.ServerClaimVehicle(player, vehicle)

    elseif command == "unclaim" then
        local sqlid = args.sqlid
        local perm = PV.checkPermission(player, sqlid)
        if PV.getSimpleBooleanPermission(perm) then
            PV.ServerUnclaimVehicle(player, sqlid)
        else
            PV.Log.actionDenied(player, {getX=function()return 0 end, getY=function()return 0 end, getZ=function()return 0 end}, sqlid, "unclaim_attempt")
        end

    elseif command == "updateFlags" then
        local sqlid = args.sqlid
        local delta = args.delta
        local perm = PV.checkPermission(player, sqlid)
        if perm.permissions and perm.ownerid == player:getUsername() or player:getAccessLevel() ~= "None" then
            if PV.validateFlags(delta) then
                PV.applyFlagsDelta(sqlid, delta)
                ModData.add("AVCSByVehicleSQLID", PV.dbByVehicleSQLID)
                sendServerCommand("ProtectVehicle", "updateFlags", { sqlid = sqlid, flags = PV.dbByVehicleSQLID[sqlid].PublicFlags })
                PV.Log.writeVehicle(sqlid, "Flags updated by " .. player:getUsername(), "INFO")
            end
        end

    elseif command == "logon" then
        -- Update logon/logoff times
        local username = player:getUsername()
        if PV.dbByPlayerID[username] then
            PV.dbByPlayerID[username].LastKnownLogonTime = getTimestamp()
            PV.dbByPlayerID[username].LastKnownLogoffTime = getTimestamp()
            ModData.add("AVCSByPlayerID", PV.dbByPlayerID)
        end
    end
end

-- ============================================================
-- EVENTS
-- B42 does not have Events.OnPlayerQuit.
-- Use polling via EveryOneMinute to detect disconnects.
-- ============================================================
local PV_onlinePlayers = {}

local function PV_PollPlayerDisconnect()
    if not PV.dbByPlayerID then return end

    -- Build current online set
    local currentOnline = {}
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then currentOnline[p:getUsername()] = true end
    end

    -- Detect who left since last poll
    for username, _ in pairs(PV_onlinePlayers) do
        if not currentOnline[username] then
            if PV.dbByPlayerID[username] then
                PV.dbByPlayerID[username].LastKnownLogoffTime = getTimestamp()
                ModData.add("AVCSByPlayerID", PV.dbByPlayerID)
                PV.Log.writeGlobal("Player logged off: " .. username .. ". Logoff time updated.")
            end
        end
    end

    PV_onlinePlayers = currentOnline
end

Events.OnInitGlobalModData.Add(PV.InitDB)
Events.OnClientCommand.Add(PV.OnClientCommand)
Events.EveryOneMinute.Add(PV_PollPlayerDisconnect)
Events.EveryTenMinutes.Add(PV.CheckTimeouts)
