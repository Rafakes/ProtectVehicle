--[[
    ProtectVehicle - PV_Server.lua
    Core server-side logic and command handling.
    B42.14.x - Server is TRUTH.
--]]

if not isServer() then return end

PV = PV or {}

-- Coerce sqlid to number when possible (client may send as string)
function PV.toSQLID(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) or v end
    return v
end


-- ============================================================
-- DB INITIALIZATION
-- ============================================================
function PV.InitDB()
    -- Criar apenas as chaves nativas do ProtectVehicle.
    if not ModData.exists("PVByVehicleSQLID") then
        ModData.create("PVByVehicleSQLID")
        print("[PV] PVByVehicleSQLID: nova chave criada.")
    else
        print("[PV] PVByVehicleSQLID: chave encontrada.")
    end
    if not ModData.exists("PVByPlayerID") then
        ModData.create("PVByPlayerID")
        print("[PV] PVByPlayerID: nova chave criada.")
    else
        print("[PV] PVByPlayerID: chave encontrada.")
    end
    if not ModData.exists("PV_UsedVehicleIDs") then ModData.create("PV_UsedVehicleIDs") end
    if not ModData.exists("PVDocuments") then
        ModData.create("PVDocuments")
        ModData.add("PVDocuments", {})
        print("[PV] PVDocuments: nova chave criada.")
    end
    if not ModData.exists("PVDocumentsByPlayer") then
        ModData.create("PVDocumentsByPlayer")
        ModData.add("PVDocumentsByPlayer", {})
        print("[PV] PVDocumentsByPlayer: nova chave criada.")
    end
    if not ModData.exists("PV_DocMeta") then
        ModData.create("PV_DocMeta")
        ModData.add("PV_DocMeta", { nextId = 1 })
        print("[PV] PV_DocMeta: nova chave criada.")
    end

    PV.dbByVehicleSQLID = ModData.get("PVByVehicleSQLID")
    PV.dbByPlayerID     = ModData.get("PVByPlayerID")

    -- Garante que sÃƒÂ£o tabelas (ModData pode retornar nil em server dedicado limpo)
    if type(PV.dbByVehicleSQLID) ~= "table" then
        PV.dbByVehicleSQLID = {}
        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        print("[PV] PVByVehicleSQLID era nil/invÃƒÂ¡lido Ã¢â‚¬â€ reinicializado como tabela vazia.")
    end
    if type(PV.dbByPlayerID) ~= "table" then
        PV.dbByPlayerID = {}
        ModData.add("PVByPlayerID", PV.dbByPlayerID)
        print("[PV] PVByPlayerID era nil/invÃƒÂ¡lido Ã¢â‚¬â€ reinicializado como tabela vazia.")
    end
    -- Chaves numericas podem vir como string apos persistencia JSON do ModData - normalizar antes da validacao
    if PV.normalizeVehicleDatabaseKeys and PV.normalizeVehicleDatabaseKeys() then
        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        ModData.add("PVByPlayerID", PV.dbByPlayerID)
        print("[PV] Chaves SQLID normalizadas (number) apÃƒÂ³s deserialize.")
    end

    -- Normaliza estrutura do DB do proprio PV (campos novos, version bump)
    PV.normalizeDB()
    -- Auditoria pos-normalizacao: reportar veiculos com dono desconhecido
    local orphans = 0
    for sqlid, entry in pairs(PV.dbByVehicleSQLID) do
        local o = entry.OwnerPlayerID
        if o == nil or o == "" or o == "__UNKNOWN__" then
            orphans = orphans + 1
            print("[PV] AVISO: veÃƒÂ­culo sqlid=" .. tostring(sqlid) .. " sem OwnerPlayerID vÃƒÂ¡lido (valor='" .. tostring(o) .. "'). Use o painel Admin para corrigir ou remover.")
        end
    end
    if orphans > 0 then
        print("[PV] AVISO: " .. orphans .. " veÃƒÂ­culo(s) ÃƒÂ³rfÃƒÂ£o(s) detectado(s) apÃƒÂ³s migraÃƒÂ§ÃƒÂ£o. Apenas admins podem fazer unclaim desses veÃƒÂ­culos.")
    end

    local vCount = 0; for _ in pairs(PV.dbByVehicleSQLID) do vCount = vCount + 1 end
    local pCount = 0; for _ in pairs(PV.dbByPlayerID) do pCount = pCount + 1 end
    print(string.format("[PV] DB pronto. VeÃƒÂ­culos: %d | Jogadores: %d", vCount, pCount))
end

-- ============================================================
-- CLAIM LOGIC
-- ============================================================
-- Forward declarations for local helpers used by ServerClaimVehicle.
local PV_vehicleIsNearPlayer
local PV_isClaimableVehicle

local function PV_getItemRemovalContainer(playerObj, item)
    if not playerObj or not item then return nil end

    local container = nil
    pcall(function()
        if item.getContainer then
            container = item:getContainer()
        end
    end)

    if container then return container end
    return playerObj:getInventory()
end

function PV.ServerClaimVehicle(playerObj, vehicleObj)
    if not playerObj or not vehicleObj then return end
    if type(PV.dbByVehicleSQLID) ~= "table" or type(PV.dbByPlayerID) ~= "table" then
        PV.Log.claim(playerObj, vehicleObj, "NONE", false, "DB not ready")
        sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_Error_DBNotReady", r=1, g=0.2, b=0.2 })
        return
    end
    if not PV_isClaimableVehicle(vehicleObj) then
        PV.Log.claim(playerObj, vehicleObj, "NONE", false, "Unsupported vehicle for claim")
        return
    end
    if not PV_vehicleIsNearPlayer(playerObj, vehicleObj, 6) then
        PV.Log.claim(playerObj, vehicleObj, "NONE", false, "Player too far from vehicle")
        return
    end

    -- 1. Check if already claimed
    local existingID = PV.getVehicleID(vehicleObj)
    if existingID and PV.getVehicleDBEntry(existingID) then
        PV.Log.claim(playerObj, vehicleObj, existingID, false, "Already claimed")
        sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_NoPermission", r=1, g=0.5, b=0.2 })
        return
    end
    if existingID and not PV.getVehicleDBEntry(existingID) then
        PV.Log.writeGlobal("[PV] Claim found orphan SQLID=" .. tostring(existingID) ..
            " on vehicle runtimeId=" .. tostring(vehicleObj:getId()) .. ". Clearing before claim.", "WARN")
        pcall(function()
            vehicleObj:getModData().SQLID = nil
        end)
        existingID = nil
    end

    -- 2. Check Max Vehicle limit before consuming any item
    if not PV.checkMaxClaim(playerObj) then
        PV.Log.claim(playerObj, vehicleObj, "NONE", false, "Max vehicle limit reached")
        sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_LimitReached", r=1, g=1, b=0 })
        return
    end

    -- 2. Check Document requirement
    -- PadrÃƒÂ£o AACS: validaÃƒÂ§ÃƒÂ£o APENAS depois de confirmar que o claim vai acontecer.
    -- Default: "Base.VehicleDocument" (module Base para compatibilidade MP).
    -- Admin pode configurar outro item via VehicleDocumentItemType no sandbox.
    if SandboxVars.ProtectVehicle.RequireVehicleDocumentForClaim then
        local docType = SandboxVars.ProtectVehicle.VehicleDocumentItemType or "Base.VehicleDocument"
        local inv = playerObj:getInventory()
        local item = inv and inv:getFirstTypeRecurse(docType) or nil
        if not item then
            PV.Log.claim(playerObj, vehicleObj, "NONE", false, "Missing document: " .. docType)
            sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_MissingDocument", r=1, g=0.2, b=0.2 })
            return
        end

        -- Consume if configured (padrÃƒÂ£o AACS: pcall + inv:Remove + sendRemoveItemFromContainer)
        if SandboxVars.ProtectVehicle.ConsumeVehicleDocumentOnClaim then
            local synced = false
            local ok, err = pcall(function()
                local removeContainer = PV_getItemRemovalContainer(playerObj, item)
                if not removeContainer then return end

                if isServer() then
                    removeContainer:Remove(item)
                    if sendRemoveItemFromContainer then
                        sendRemoveItemFromContainer(removeContainer, item)
                    end
                    synced = true
                else
                    removeContainer:Remove(item)
                    synced = true
                end
            end)
            if not ok then
                PV.Log.writeGlobal("ERROR consuming VehicleDocument: " .. tostring(err), "ERROR")
            else
                PV.Log.writeGlobal("VehicleDocument consumed for " .. playerObj:getUsername()
                    .. " (MP sync: " .. tostring(synced) .. ")", "INFO")
            end
        end
    end

    -- 3. Generate/Assign SQLID
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
        PublicFlags = {}, -- Default to all false per normalization logic
        AllowList = {},
        AllowSafehouse = false,
        AllowFaction = false,
        AllowSafehouseRV = false,
        AllowFactionRV = false,
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

    ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
    ModData.add("PVByPlayerID", PV.dbByPlayerID)

    PV.Log.claim(playerObj, vehicleObj, sqlid, true)

    -- Sync update to all clients
    sendServerCommand("ProtectVehicle", "updateVehicleData", { sqlid = sqlid, data = PV.getVehicleDBEntry(sqlid) })
    sendServerCommand("ProtectVehicle", "updatePlayerData", { username = username, data = PV.dbByPlayerID[username] })
end

-- ============================================================
-- UNCLAIM LOGIC
-- ============================================================

-- Remove SQLID do IsoVehicle carregado (evita tratar como "sem dono" com DB vazio).
local function PV_tryClearVehicleWorldSQLID(sqlid)
    if sqlid == nil then return end
    local target = PV.toSQLID(sqlid)
    pcall(function()
        local cell = getCell()
        if not cell then return end
        local vehicles = cell:getVehicles()
        if not vehicles then return end
        PV.iterVehicles(vehicles, function(v)
            if v and PV.toSQLID(PV.getVehicleID(v)) == target then
                v:getModData().SQLID = nil
            end
        end)
    end)
end

-- Helper: devolve um VehicleDocument ao jogador ao fazer unclaim.
-- PadrÃƒÂ£o AACS: instanceItem() + pcall + sendAddItemToContainer.
-- Se inventÃƒÂ¡rio cheio, dropa no chÃƒÂ£o perto do jogador.
local function _giveDocumentToPlayer(playerObj)
    if not playerObj then return false end
    local inv = playerObj:getInventory()
    if not inv then return false end

    local docType = (SandboxVars.ProtectVehicle
        and SandboxVars.ProtectVehicle.VehicleDocumentItemType)
        or "Base.VehicleDocument"

    -- B42: instanceItem() ÃƒÂ© o mÃƒÂ©todo correto no servidor
    local item = nil
    pcall(function() item = instanceItem(docType) end)
    if not item then
        pcall(function() item = InventoryItemFactory.CreateItem(docType) end)
    end
    if not item then
        PV.Log.writeGlobal("_giveDocumentToPlayer: failed to create " .. docType, "ERROR")
        return false
    end

    -- Garantir item limpo
    pcall(function()
        if item.setActivated  then item:setActivated(false) end
        if item.setUsedDelta  then item:setUsedDelta(0) end
        if item.setCondition  then item:setCondition(100) end
    end)

    local added = false
    local ok, err = pcall(function()
        if isServer() then
            inv:AddItem(item)
            sendAddItemToContainer(inv, item)
            added = true
        else
            inv:AddItem(item)
            added = true
        end
    end)

    if not ok then
        PV.Log.writeGlobal("ERROR in _giveDocumentToPlayer: " .. tostring(err), "ERROR")
    end

    if not added then
        -- Fallback: dropar perto do jogador
        pcall(function()
            local sq = playerObj:getCurrentSquare()
            if sq then
                sq:AddWorldInventoryItem(item, 0, 0, 0)
                transmitCompleteItemToClients(item)
            end
        end)
    end
    return added
end

function PV.ServerUnclaimVehicle(playerObj, sqlid, isTimeout)
    sqlid = PV.toSQLID(sqlid)

    -- Defensive: DB nÃƒÂ£o inicializado
    if not PV.dbByVehicleSQLID then
        PV.Log.writeGlobal("[PV] ServerUnclaimVehicle: dbByVehicleSQLID is nil for sqlid=" .. tostring(sqlid))
        if playerObj then
            sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_Error_DBNotReady", r=1, g=0.2, b=0.2 })
        end
        return
    end

    -- VeÃƒÂ­culo nÃƒÂ£o existe no DB
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then
        PV.Log.writeGlobal("[PV] ServerUnclaimVehicle: Vehicle " .. tostring(sqlid) .. " not found in DB")
        if playerObj then
            sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_Error_VehicleNotClaimed", r=1, g=0.5, b=0.2 })
        end
        return
    end

    local owner = entry.OwnerPlayerID

    -- Log it
    if isTimeout then
        PV.Log.timeout(sqlid, owner, (PV.dbByPlayerID[owner] and PV.dbByPlayerID[owner].LastKnownLogoffTime or 0))
    else
        local isAdmin = playerObj:getUsername() ~= owner
        PV.Log.unclaim(playerObj, sqlid, isAdmin)
    end

    PV.clearPlayerVehicleIndex(owner, sqlid)
    PV.clearVehicleDBEntry(sqlid)

    ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
    ModData.add("PVByPlayerID", PV.dbByPlayerID)

    sendServerCommand("ProtectVehicle", "removeVehicle", { sqlid = sqlid, owner = owner })

    PV_tryClearVehicleWorldSQLID(sqlid)
    sendServerCommand("ProtectVehicle", "clearVehicleSQLID", { sqlid = sqlid })

    -- DevoluÃƒÂ§ÃƒÂ£o do documento ao unclaim (padrÃƒÂ£o AACS: ReturnDocumentOnUnclaim)
    -- CondiÃƒÂ§ÃƒÂ£o: RequireDoc + ConsumeDoc + ReturnDoc + dono fazendo unclaim manual
    if not isTimeout and playerObj then
        local sv = SandboxVars.ProtectVehicle
        if sv
        and sv.RequireVehicleDocumentForClaim
        and sv.ConsumeVehicleDocumentOnClaim
        and sv.ReturnDocumentOnUnclaim
        and playerObj:getUsername() == owner
        then
            if _giveDocumentToPlayer(playerObj) then
                PV.Log.writeGlobal("VehicleDocument returned to " .. owner .. " on unclaim", "INFO")
            end
        end
    end

    -- Feedback visual para o jogador que executou o unclaim
    if not isTimeout and playerObj then
        sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_Unclaimed", r = 0.5, g = 1.0, b = 0.5 })
    end
end

-- ============================================================
-- Helper: check if a username is currently online (B42 safe)
-- ============================================================
local function _isUsernameOnline(username)
    if type(username) ~= "string" or username == "" then return false end

    if getPlayerFromUsername then
        return getPlayerFromUsername(username) ~= nil
    end
    if getPlayerByUsername then
        return getPlayerByUsername(username) ~= nil
    end

    if getOnlinePlayers then
        local op = getOnlinePlayers()
        if op then
            for i = 0, op:size() - 1 do
                local pl = op:get(i)
                if pl and pl.getUsername and pl:getUsername() == username then
                    return true
                end
            end
        end
    end
    return false
end

local function PV_buildOnlineUsernameSet()
    local online = {}
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return online end

    if type(players) == "table" then
        for _, pl in ipairs(players) do
            if pl and pl.getUsername then
                online[pl:getUsername()] = true
            end
        end
        return online
    end

    if players.size and players.get then
        for i = 0, players:size() - 1 do
            local pl = players:get(i)
            if pl and pl.getUsername then
                online[pl:getUsername()] = true
            end
        end
    end

    return online
end


-- ============================================================
-- TIMEOUT CHECK (Every 10 minutes)
-- ============================================================
function PV.CheckTimeouts()
    local timeoutHours = SandboxVars.ProtectVehicle.ClaimTimeoutHours or 0
    if timeoutHours <= 0 then return end

    local now = getTimestamp()
    local timeoutSeconds = timeoutHours * 3600

    local db = PV.dbByVehicleSQLID or {}
    local onlineUsers = PV_buildOnlineUsernameSet()
    for sqlid, entry in pairs(db) do
        local owner = entry.OwnerPlayerID
        local pData = PV.dbByPlayerID[owner]

        if pData and pData.LastKnownLogoffTime then
            local isOnline = onlineUsers[owner] == true

            if not isOnline and (now - pData.LastKnownLogoffTime) >= timeoutSeconds then
                PV.ServerUnclaimVehicle(nil, sqlid, true)
            end
        end
    end
end

-- ============================================================
-- COMMAND HANDLER HELPERS
-- ============================================================
PV_vehicleIsNearPlayer = function(playerObj, vehicleObj, maxDistance)
    if not playerObj or not vehicleObj then return false end
    local dx = playerObj:getX() - vehicleObj:getX()
    local dy = playerObj:getY() - vehicleObj:getY()
    local dz = math.abs((playerObj:getZ() or 0) - (vehicleObj:getZ() or 0))
    local maxDist = maxDistance or 6
    return dz <= 1 and ((dx * dx) + (dy * dy)) <= (maxDist * maxDist)
end

PV_isClaimableVehicle = function(vehicleObj)
    if not vehicleObj or vehicleObj:isRemovedFromWorld() then
        return false
    end
    local script = vehicleObj:getScript()
    local name = script and string.lower(script:getName() or "") or ""
    if string.find(name, "burnt", 1, true) or string.find(name, "smashed", 1, true) then
        return false
    end
    return true
end

local function PV_playerCanManageEntry(playerObj, entry)
    if not playerObj or not entry then return false end
    return PV.isStaffPlayer(playerObj) or entry.OwnerPlayerID == playerObj:getUsername()
end

local function PV_syncVehicleData(sqlid)
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return end
    sendServerCommand("ProtectVehicle", "updateVehicleData", { sqlid = sqlid, data = entry })
end

local function PV_applyGroupAccessValue(entry, key, value)
    if type(value) ~= "boolean" then return false end
    if (key == "AllowSafehouse" or key == "AllowSafehouseRV")
    and SandboxVars.ProtectVehicle
    and SandboxVars.ProtectVehicle.AllowSafehouse == false then
        value = false
    end
    if (key == "AllowFaction" or key == "AllowFactionRV")
    and SandboxVars.ProtectVehicle
    and SandboxVars.ProtectVehicle.AllowFaction == false then
        value = false
    end
    if entry[key] == value then return false end
    entry[key] = value
    return true
end

-- ============================================================
-- COMMAND HANDLER
-- ============================================================
PV.OnClientCommand = function(module, command, player, args)
    if module ~= "ProtectVehicle" then return end
    if not player then return end
    args = args or {}

    -- Document-system commands are handled in PV_DocumentSystem.lua.
    -- Avoid duplicate routing/rate-limit checks across two OnClientCommand listeners.
    if command == "vehicleConvertToDoc" or command == "vehicleSpawnFromDoc" then
        return
    end

    -- 1. Rate Limit check
    if not PV.RateLimit.isAllowed(player, command) then
        return
    end

    -- 2. Command routing
    if command == "claim" then
        local vehicleId = args.vehicleId and (tonumber(args.vehicleId) or args.vehicleId) or nil
        local vehicle = vehicleId and getVehicleById(vehicleId) or nil
        if not vehicle then
            PV.Log.writeGlobal("[PV] Claim failed: runtime vehicle not found for '" .. player:getUsername() .. "'")
            return
        end
        if not PV_isClaimableVehicle(vehicle) then
            PV.Log.claim(player, vehicle, "NONE", false, "Unsupported vehicle for claim")
            return
        end
        if not PV_vehicleIsNearPlayer(player, vehicle, 6) then
            PV.Log.claim(player, vehicle, "NONE", false, "Player too far from vehicle")
            return
        end
        PV.ServerClaimVehicle(player, vehicle)

    elseif command == "unclaim" then
        local sqlid = PV.toSQLID(args.sqlid)

        -- Defensive: DB nÃƒÂ£o pronto
        if type(PV.dbByVehicleSQLID) ~= "table" then
            sendServerCommand(player, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_Error_DBNotReady", r=1, g=0.2, b=0.2 })
            return
        end

        -- VeÃƒÂ­culo nÃƒÂ£o existe
        local entry = PV.getVehicleDBEntry(sqlid)
        if not entry then
            sendServerCommand(player, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_Error_VehicleNotFound", r=1, g=0.2, b=0.2 })
            PV.Log.writeGlobal("[PV] Unclaim failed: Vehicle " .. tostring(sqlid) .. " not found in DB by " .. player:getUsername())
            return
        end

        -- CRITICAL: OwnerPlayerID nil/vazio/desconhecido = apenas admin pode unclaim
        PV.Log.writeGlobal("[PV] UNCLAIM REQUEST | user='" .. player:getUsername() .. "' | accessLevel='" .. tostring(player:getAccessLevel()) .. "' | isStaff=" .. tostring(PV.isStaffPlayer(player)) .. " | owner='" .. tostring(entry.OwnerPlayerID) .. "' | sqlid=" .. tostring(sqlid), "DEBUG")
        if PV_playerCanManageEntry(player, entry) then
            PV.ServerUnclaimVehicle(player, sqlid, false)
        else
            sendServerCommand(player, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_Error_NotOwner", r=1, g=0.2, b=0.2 })
            PV.Log.writeGlobal("[PV] ACTION DENIED 'unclaim_not_owner' for '" .. player:getUsername() .. "' | Vehicle " .. tostring(sqlid) .. " | owner='" .. tostring(entry.OwnerPlayerID) .. "'")
        end

    elseif command == "updateFlags" then
        local sqlid = PV.toSQLID(args.sqlid)
        local delta = args.delta
        local entry = PV.getVehicleDBEntry(sqlid)
        if entry and PV_playerCanManageEntry(player, entry) and PV.validateFlags(delta) then
            if PV.applyFlagsDelta(sqlid, delta) then
                ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
                local eFlags = PV.getVehicleDBEntry(sqlid)
                if eFlags and eFlags.PublicFlags then
                    sendServerCommand("ProtectVehicle", "updateFlags", { sqlid = sqlid, flags = eFlags.PublicFlags })
                end
                local changed = {}
                for key, value in pairs(delta) do
                    table.insert(changed, tostring(key) .. "=" .. tostring(value))
                end
                table.sort(changed)
                PV.Log.writeVehicle(sqlid,
                    "PublicFlags UPDATE by '" .. player:getUsername() .. "' | " .. table.concat(changed, ", "),
                    "INFO")
            end
        end

    elseif command == "addToAllowList" then
        local sqlid        = PV.toSQLID(args.sqlid)
        local targetPlayer = PV.normalizeUsername(args.targetPlayer)
        if not sqlid or not targetPlayer then return end
        local entry = PV.getVehicleDBEntry(sqlid)
        if not entry then return end
        if not PV_playerCanManageEntry(player, entry) then return end
        if targetPlayer == entry.OwnerPlayerID then return end
        entry.AllowList = entry.AllowList or {}
        if not entry.AllowList[targetPlayer] then
            entry.AllowList[targetPlayer] = {}
            ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
            PV_syncVehicleData(sqlid)
            PV.Log.writeVehicle(sqlid, "AllowList ADD '" .. targetPlayer .. "' by '" .. player:getUsername() .. "'", "INFO")
        end

    elseif command == "removeFromAllowList" then
        local sqlid        = PV.toSQLID(args.sqlid)
        local targetPlayer = PV.normalizeUsername(args.targetPlayer)
        if not sqlid or not targetPlayer then return end
        local entry = PV.getVehicleDBEntry(sqlid)
        if not entry then return end
        if not PV_playerCanManageEntry(player, entry) then return end
        if entry.AllowList and entry.AllowList[targetPlayer] ~= nil then
            entry.AllowList[targetPlayer] = nil
            ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
            PV_syncVehicleData(sqlid)
            PV.Log.writeVehicle(sqlid, "AllowList REMOVE '" .. targetPlayer .. "' by '" .. player:getUsername() .. "'", "INFO")
        end

    elseif command == "updatePlayerFlags" then
        local sqlid        = PV.toSQLID(args.sqlid)
        local targetPlayer = PV.normalizeUsername(args.targetPlayer)
        local flags        = args.flags
        if not sqlid or not targetPlayer or type(flags) ~= "table" then return end
        local entry = PV.getVehicleDBEntry(sqlid)
        if not entry then return end
        if not PV_playerCanManageEntry(player, entry) then return end
        if targetPlayer == entry.OwnerPlayerID then return end
        -- Validate: only known boolean flags
        for k, v in pairs(flags) do
            if PV.DEFAULT_FLAGS[k] == nil or type(v) ~= "boolean" then return end
        end
        entry.AllowList = entry.AllowList or {}
        local pFlags = entry.AllowList[targetPlayer]
        if type(pFlags) ~= "table" then
            entry.AllowList[targetPlayer] = {}
            pFlags = entry.AllowList[targetPlayer]
        end
        for k, v in pairs(flags) do pFlags[k] = v end
        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        PV_syncVehicleData(sqlid)
        PV.Log.writeVehicle(sqlid, "PlayerFlags UPDATE for '" .. targetPlayer .. "' by '" .. player:getUsername() .. "'", "INFO")



    elseif command == "setGroupAccess" then
        local sqlid = PV.toSQLID(args.sqlid)
        if not sqlid then return end
        local entry = PV.getVehicleDBEntry(sqlid)
        if not entry then return end

        if not PV_playerCanManageEntry(player, entry) then return end

        local changed = false
        changed = PV_applyGroupAccessValue(entry, "AllowSafehouse", args.allowSafehouse) or changed
        changed = PV_applyGroupAccessValue(entry, "AllowFaction", args.allowFaction) or changed
        changed = PV_applyGroupAccessValue(entry, "AllowSafehouseRV", args.allowSafehouseRV) or changed
        changed = PV_applyGroupAccessValue(entry, "AllowFactionRV", args.allowFactionRV) or changed

        if changed then
            ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
            PV_syncVehicleData(sqlid)
            PV.Log.writeVehicle(sqlid, "GroupAccess UPDATE by '" .. player:getUsername() ..
                "' safehouse=" .. tostring(entry.AllowSafehouse) ..
                " faction=" .. tostring(entry.AllowFaction) ..
                " safehouseRV=" .. tostring(entry.AllowSafehouseRV) ..
                " factionRV=" .. tostring(entry.AllowFactionRV), "INFO")
        end
    elseif command == "logon" then
        -- FIX #7: registra TODOS os jogadores no DB ao conectar,
        -- nÃƒÂ£o apenas quem jÃƒÂ¡ tem veÃƒÂ­culo. Isso permite rastrear
        -- logon/logoff de qualquer jogador para fins de auditoria e timeout.
        local username  = player:getUsername()
        local now       = getTimestamp()

        if PV.dbByPlayerID[username] then
            -- Jogador jÃƒÂ¡ existe: atualiza horÃƒÂ¡rios
            PV.dbByPlayerID[username].LastKnownLogonTime  = now
            PV.dbByPlayerID[username].LastKnownLogoffTime = now
        else
            -- Novo jogador: cria entrada mÃƒÂ­nima
            PV.dbByPlayerID[username] = {
                LastKnownLogonTime  = now,
                LastKnownLogoffTime = now,
            }
            PV.Log.writeGlobal("New player registered in DB: '" .. username .. "'", "INFO")
        end
        ModData.add("PVByPlayerID", PV.dbByPlayerID)

    elseif command == "syncCoord" then
        -- ForÃƒÂ§ar atualizaÃƒÂ§ÃƒÂ£o de coordenada (enter/exit veÃƒÂ­culo).
        local vehicleId = args.vehicleId and (tonumber(args.vehicleId) or args.vehicleId) or nil
        local vehicleObj = vehicleId and getVehicleById(vehicleId) or nil
        if vehicleObj and PV_vehicleIsNearPlayer(player, vehicleObj, 12) then
            local sqlid = PV.getVehicleID(vehicleObj)
            local entry = sqlid and PV.getVehicleDBEntry(sqlid)
            if entry then
                local changed = PV.updateVehicleCoordinate(vehicleObj, {
                    persistCooldownSeconds = 30,
                })
                if changed then
                    PV.Log.coordSync(player, vehicleObj, sqlid, args.source or "enter_exit")
                end
                return
            end
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
    if type(PV_onlinePlayers) ~= "table" then PV_onlinePlayers = {} end

    local currentOnline = PV_buildOnlineUsernameSet()
    local changed = false

    -- Detect who left since last poll
    for username, _ in pairs(PV_onlinePlayers) do
        if not currentOnline[username] then
            if PV.dbByPlayerID[username] then
                PV.dbByPlayerID[username].LastKnownLogoffTime = getTimestamp()
                changed = true
                PV.Log.writeGlobal("Player logged off: " .. username .. ". Logoff time updated.")
            end
        end
    end

    if changed then
        ModData.add("PVByPlayerID", PV.dbByPlayerID)
    end

    PV_onlinePlayers = currentOnline
end

local function PV_ScanLoadedClaimedVehicles()
    if type(PV.dbByVehicleSQLID) ~= "table" then return end
    local cell = getCell and getCell() or nil
    if not cell or not cell.getVehicles then return end

    local vehicles = cell:getVehicles()
    if not vehicles then return end

    PV.iterVehicles(vehicles, function(vehicleObj)
        if vehicleObj and not vehicleObj:isRemovedFromWorld() then
            local sqlid = PV.getVehicleID(vehicleObj)
            if sqlid and PV.getVehicleDBEntry(sqlid) then
                local changed = PV.updateVehicleCoordinate(vehicleObj, {
                    minDistance = 4,
                    persistCooldownSeconds = 30,
                })
                if changed then
                    PV.Log.coordSync(nil, vehicleObj, sqlid, "server_sweep")
                end
            end
        end
    end)
end

local PV_VehicleTowGuard = function(module, command, player, args)
    if module ~= "vehicle" or not player or not args then return end

    local function PV_canTowVehicleForPlayer(vehicleObj)
        if not vehicleObj then return false end
        local sqlid = PV.getVehicleID(vehicleObj)
        local entry = sqlid and PV.getVehicleDBEntry(sqlid) or nil

        -- Sem claim ativo no DB: liberar reboque.
        if not entry then return true end

        return PV.canPerformAction(player, vehicleObj, "AllowTow")
    end

    if command == "attachTrailer" then
        local vehicleAId = args.vehicleA and (tonumber(args.vehicleA) or args.vehicleA) or nil
        local vehicleBId = args.vehicleB and (tonumber(args.vehicleB) or args.vehicleB) or nil
        local vehicleA = vehicleAId and getVehicleById(vehicleAId) or nil
        local vehicleB = vehicleBId and getVehicleById(vehicleBId) or nil
        if not vehicleA or not vehicleB then return end

        local okA = PV_canTowVehicleForPlayer(vehicleA)
        local okB = PV_canTowVehicleForPlayer(vehicleB)
        if okA and okB then return end

        -- Os hooks de cliente jÃ¡ bloqueiam o attach antes da timed action
        -- vanilla na maior parte dos casos. Evitamos forÃ§ar um breakConstraint
        -- tardio aqui porque isso pode gerar picos de fÃ­sica e "carro voando".
        sendServerCommand(player, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_NoPermission", r=1, g=0.2, b=0.2 })

        local sidA = PV.getVehicleID(vehicleA)
        local sidB = PV.getVehicleID(vehicleB)
        if sidA and PV.getVehicleDBEntry(sidA) then
            PV.Log.actionDenied(player, vehicleA, sidA, "attachTrailer")
        end
        if sidB and PV.getVehicleDBEntry(sidB) then
            PV.Log.actionDenied(player, vehicleB, sidB, "attachTrailer")
        end

    elseif command == "detachTrailer" then
        local vehicleId = args.vehicle and (tonumber(args.vehicle) or args.vehicle) or nil
        local vehicle = vehicleId and getVehicleById(vehicleId) or nil
        if not vehicle then return end
        if PV_canTowVehicleForPlayer(vehicle) then return end

        sendServerCommand(player, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_NoPermission", r=1, g=0.2, b=0.2 })

        local sid = PV.getVehicleID(vehicle)
        local trailer = vehicle:getVehicleTowing()
        local trailerSid = trailer and PV.getVehicleID(trailer) or nil
        if sid and PV.getVehicleDBEntry(sid) then
            PV.Log.actionDenied(player, vehicle, sid, "detachTrailer")
        end
        if trailer and trailerSid and PV.getVehicleDBEntry(trailerSid) then
            PV.Log.actionDenied(player, trailer, trailerSid, "detachTrailer")
        end
    end
end

local PV_RVServerGuard = function(module, command, player, args)
    if module ~= "RVServer" or command ~= "enterRV" then return end
    if not args then return end

    -- Localizar o veÃƒÂ­culo pelo ID enviado pelo cliente
    local vehicleId = args.vehicleId and (tonumber(args.vehicleId) or args.vehicleId) or nil
    local vehicle = vehicleId and getVehicleById(vehicleId) or nil

    if not vehicle then
        -- Sem veÃƒÂ­culo identificado: bloquear por seguranÃƒÂ§a
        sendServerCommand(player, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_NoPermission_RV", r=1, g=0.2, b=0.2 })
        -- Zeramos args para invalidar o comando para handlers subsequentes
        for k in pairs(args) do args[k] = nil end
        PV.Log.writeGlobal("[PV] RV enterRV BLOCKED (vehicle not found) for '" .. player:getUsername() .. "'", "WARN")
        return
    end
    
    -- Verificar permissÃ£o PV
    local allowed = true
    if PV.canEnterRV then
        allowed = PV.canEnterRV(player, vehicle)
    end
    if not allowed then
        sendServerCommand(player, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_NoPermission_RV", r=1, g=0.2, b=0.2 })
        for k in pairs(args) do args[k] = nil end
        PV.Log.writeGlobal("[PV] RV enterRV BLOCKED for '" .. player:getUsername() .. "' | vehicleId=" .. tostring(vehicleId), "WARN")
    end
end

Events.OnClientCommand.Add(PV_VehicleTowGuard)
Events.OnClientCommand.Add(PV_RVServerGuard)
Events.OnInitGlobalModData.Add(PV.InitDB)
Events.OnClientCommand.Add(PV.OnClientCommand)
Events.EveryOneMinute.Add(PV_PollPlayerDisconnect)
Events.EveryOneMinute.Add(PV_ScanLoadedClaimedVehicles)
Events.EveryTenMinutes.Add(PV.CheckTimeouts)
-- Events.OnVehicleAdded NÃƒÆ’O existe na B42 Ã¢â‚¬â€ removido.
