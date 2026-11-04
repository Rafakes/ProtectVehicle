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

    -- Caixa de avisos do dono (chave propria, entregue so ao dono).
    if PV.Notices and PV.Notices.ensureStore then
        local okN, errN = pcall(PV.Notices.ensureStore)
        if not okN then
            print("[PV] PVNotices: falha ao inicializar: " .. tostring(errN))
        end
    end

    -- Garante que são tabelas (ModData pode retornar nil em server dedicado limpo)
    if type(PV.dbByVehicleSQLID) ~= "table" then
        PV.dbByVehicleSQLID = {}
        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        print("[PV] PVByVehicleSQLID era nil/inválido - reinicializado como tabela vazia.")
    end
    if type(PV.dbByPlayerID) ~= "table" then
        PV.dbByPlayerID = {}
        ModData.add("PVByPlayerID", PV.dbByPlayerID)
        print("[PV] PVByPlayerID era nil/inválido - reinicializado como tabela vazia.")
    end
    -- Chaves numericas podem vir como string apos persistencia JSON do ModData - normalizar antes da validacao
    if PV.normalizeVehicleDatabaseKeys and PV.normalizeVehicleDatabaseKeys() then
        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        ModData.add("PVByPlayerID", PV.dbByPlayerID)
        print("[PV] Chaves SQLID normalizadas (number) após deserialize.")
    end

    -- Normaliza estrutura do DB do proprio PV (campos novos, version bump)
    PV.normalizeDB()
    -- Auditoria pos-normalizacao: reportar veiculos com dono desconhecido
    local orphans = 0
    for sqlid, entry in pairs(PV.dbByVehicleSQLID) do
        local o = entry.OwnerPlayerID
        if o == nil or o == "" or o == "__UNKNOWN__" then
            orphans = orphans + 1
            print("[PV] AVISO: veículo sqlid=" .. tostring(sqlid) .. " sem OwnerPlayerID válido (valor='" .. tostring(o) .. "'). Use o painel Admin para corrigir ou remover.")
        end
    end
    if orphans > 0 then
        print("[PV] AVISO: " .. orphans .. " veículo(s) órfão(s) detectado(s) após migração. Apenas admins podem fazer unclaim desses veículos.")
    end

    local vCount = 0; for _ in pairs(PV.dbByVehicleSQLID) do vCount = vCount + 1 end
    local pCount = 0; for _ in pairs(PV.dbByPlayerID) do pCount = pCount + 1 end
    print(string.format("[PV] DB pronto. Veículos: %d | Jogadores: %d", vCount, pCount))
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
    -- Padrão AACS: validação APENAS depois de confirmar que o claim vai acontecer.
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

        -- Consume if configured (padrão AACS: pcall + inv:Remove + sendRemoveItemFromContainer)
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
-- Padrão AACS: instanceItem() + pcall + sendAddItemToContainer.
-- Se inventário cheio, dropa no chão perto do jogador.
local function _giveDocumentToPlayer(playerObj)
    if not playerObj then return false end
    local inv = playerObj:getInventory()
    if not inv then return false end

    local docType = (SandboxVars.ProtectVehicle
        and SandboxVars.ProtectVehicle.VehicleDocumentItemType)
        or "Base.VehicleDocument"

    -- B42: instanceItem() é o método correto no servidor
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

function PV.ServerUnclaimVehicle(playerObj, sqlid, isTimeout, reason)
    sqlid = PV.toSQLID(sqlid)

    -- Defensive: DB não inicializado
    if not PV.dbByVehicleSQLID then
        PV.Log.writeGlobal("[PV] ServerUnclaimVehicle: dbByVehicleSQLID is nil for sqlid=" .. tostring(sqlid))
        if playerObj then
            sendServerCommand(playerObj, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_Error_DBNotReady", r=1, g=0.2, b=0.2 })
        end
        return
    end

    -- Veículo não existe no DB
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

    local unclaimVehicleName = tostring(PV.getVehicleDisplayNameFromModel(entry.CarModel) or "?")

    -- Log it
    if isTimeout then
        if reason then
            -- Unclaim automatico que nao e timeout (ex.: veiculo destruido).
            PV.Log.autoUnclaim(sqlid, owner, reason)
        else
            PV.Log.timeout(sqlid, owner, (PV.dbByPlayerID[owner] and PV.dbByPlayerID[owner].LastKnownLogoffTime or 0))

            -- Expirou por inatividade. So acontece com o dono offline, e ele
            -- voltava sem nada explicando por que o carro nao e mais dele.
            if PV.Notices and PV.Notices.record then
                pcall(PV.Notices.record, owner, "IGUI_PV_Notice_Expired",
                    { p1 = unclaimVehicleName })
            end
        end
    else
        local isAdmin = playerObj:getUsername() ~= owner
        PV.Log.unclaim(playerObj, sqlid, isAdmin)

        -- Staff liberou o carro de outra pessoa: hoje isso so existia no log
        -- do servidor, invisivel para o dono.
        if isAdmin and PV.Notices and PV.Notices.record then
            pcall(PV.Notices.record, owner, "IGUI_PV_Notice_AdminUnclaim", {
                p1 = unclaimVehicleName,
                p2 = tostring(playerObj:getUsername()),
            })
        end
    end

    PV.clearPlayerVehicleIndex(owner, sqlid)
    PV.clearVehicleDBEntry(sqlid)

    ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
    ModData.add("PVByPlayerID", PV.dbByPlayerID)

    sendServerCommand("ProtectVehicle", "removeVehicle", { sqlid = sqlid, owner = owner })

    PV_tryClearVehicleWorldSQLID(sqlid)
    sendServerCommand("ProtectVehicle", "clearVehicleSQLID", { sqlid = sqlid })

    -- Devolução do documento ao unclaim (padrão AACS: ReturnDocumentOnUnclaim)
    -- Condição: RequireDoc + ConsumeDoc + ReturnDoc + dono fazendo unclaim manual
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

-- Exposto em PV.* porque PV_Notices tambem precisa resolver o dono online.
function PV.getOnlinePlayerByUsername(username)
    if type(username) ~= "string" or username == "" then return nil end

    if getPlayerFromUsername then
        local ok, pl = pcall(getPlayerFromUsername, username)
        if ok and pl then return pl end
    end
    if getPlayerByUsername then
        local ok, pl = pcall(getPlayerByUsername, username)
        if ok and pl then return pl end
    end

    if getOnlinePlayers then
        local op = getOnlinePlayers()
        if op and op.size and op.get then
            for i = 0, op:size() - 1 do
                local pl = op:get(i)
                if pl and pl.getUsername and pl:getUsername() == username then
                    return pl
                end
            end
        end
    end
    return nil
end

local PV_getOnlinePlayerByUsername = PV.getOnlinePlayerByUsername

-- ============================================================
-- ALERTA DE TENTATIVA NEGADA
--
-- O cliente reporta que uma acao foi bloqueada (comando reportDenied).
-- Nada do que ele manda e aceito de graca: o nome do jogador vem do
-- proprio comando, a flag tem de existir em PV.DEFAULT_FLAGS e a
-- permissao e reconferida aqui. Se o jogador na verdade TEM permissao,
-- nao houve negacao e o alerta nao sai - e assim que um cliente
-- modificado nao consegue forjar aviso no nome de outra pessoa.
-- ============================================================
local _pvDeniedAlertAt = {}

local function PV_alertOwnerOfDeniedAttempt(player, vehicleObj, action)
    local sv = SandboxVars.ProtectVehicle
    if sv and sv.DeniedAttemptAlert == false then return end
    if not player or not vehicleObj then return end

    -- Flag desconhecida: report descartado.
    if type(action) ~= "string" or PV.DEFAULT_FLAGS[action] == nil then return end

    local sqlid = PV.getVehicleID(vehicleObj)
    local entry = sqlid and PV.getVehicleDBEntry(sqlid) or nil
    if not entry then return end

    local owner = entry.OwnerPlayerID
    local username = player:getUsername()
    if type(owner) ~= "string" or owner == "" or owner == username then return end

    -- Tem permissao: o report nao corresponde a uma negacao real.
    local ok, allowed = pcall(PV.canPerformAction, player, vehicleObj, action)
    if not ok or allowed == true then return end

    local vehicleName = tostring(PV.getVehicleDisplayNameFromModel(entry.CarModel) or "?")

    -- A caixa de avisos registra TODA tentativa, agrupando repeticao em uma
    -- entrada com contagem. O cooldown abaixo vale so para o log e o halo.
    if PV.Notices and PV.Notices.record then
        pcall(PV.Notices.record, owner, "IGUI_PV_Notice_Denied", {
            p1 = vehicleName,
            p2 = username,
            gk = "denied|" .. tostring(sqlid) .. "|" .. username,
        })
    end

    local cooldownMinutes = tonumber(sv and sv.TheftAlertCooldownMinutes) or 10
    if cooldownMinutes < 1 then cooldownMinutes = 1 end

    local now = getTimestamp()
    local key = tostring(sqlid) .. "|" .. username .. "|" .. action
    local last = _pvDeniedAlertAt[key] or 0
    if (now - last) < (cooldownMinutes * 60) then return end
    _pvDeniedAlertAt[key] = now

    PV.Log.actionDenied(player, vehicleObj, sqlid, action)

    local ownerObj = PV_getOnlinePlayerByUsername(owner)
    if ownerObj then
        sendServerCommand(ownerObj, "ProtectVehicle", "pvAlert", {
            text = "IGUI_PV_Alert_DeniedAttempt",
            p1 = vehicleName,
            p2 = tostring(username),
        })
    end
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

        -- Defensive: DB não pronto
        if type(PV.dbByVehicleSQLID) ~= "table" then
            sendServerCommand(player, "ProtectVehicle", "haloNote",
                { text = "IGUI_PV_Error_DBNotReady", r=1, g=0.2, b=0.2 })
            return
        end

        -- Veículo não existe
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

    elseif command == "transferOwner" then
        -- Troca de dono pedida pelo dono atual (ou por staff).
        --
        -- O alvo tem de estar ONLINE: assim da para ler a role dele (o
        -- limite de apoiador depende disso), avisar na hora, e nao corremos
        -- o risco de entregar o veiculo a quem esta inativo ha tanto tempo
        -- que o CheckTimeouts liberaria o claim em seguida.
        local sqlid  = PV.toSQLID(args.sqlid)
        local target = PV.normalizeUsername(args.targetPlayer)
        if not sqlid or not target then return end

        local function fail(msgKey)
            sendServerCommand(player, "ProtectVehicle", "haloNote", { text = msgKey })
        end

        if type(PV.dbByVehicleSQLID) ~= "table" or type(PV.dbByPlayerID) ~= "table" then
            fail("IGUI_PV_Error_DBNotReady")
            return
        end

        local entry = PV.getVehicleDBEntry(sqlid)
        if not entry then
            fail("IGUI_PV_Error_VehicleNotClaimed")
            return
        end
        if not PV_playerCanManageEntry(player, entry) then
            fail("IGUI_PV_Error_NotOwner")
            return
        end

        local oldOwner = entry.OwnerPlayerID
        if target == oldOwner then
            fail("IGUI_PV_Transfer_SameOwner")
            return
        end

        local targetObj = PV_getOnlinePlayerByUsername(target)
        if not targetObj then
            fail("IGUI_PV_Transfer_NotOnline")
            return
        end
        if not PV.checkMaxClaim(targetObj) then
            fail("IGUI_PV_Transfer_TargetLimit")
            return
        end

        local timestamp = getTimestamp()
        local vehicleName = PV.getVehicleDisplayNameFromModel(entry.CarModel)

        entry.OwnerPlayerID = target
        entry.ClaimDateTime = timestamp
        -- Permissao nao segue o carro: quem recebe decide de novo quem entra.
        entry.PublicFlags     = {}
        entry.AllowList       = {}
        entry.AllowSafehouse   = false
        entry.AllowFaction     = false
        entry.AllowSafehouseRV = false
        entry.AllowFactionRV   = false

        PV.clearPlayerVehicleIndex(oldOwner, sqlid)
        if not PV.dbByPlayerID[target] then
            PV.dbByPlayerID[target] = {
                LastKnownLogonTime  = timestamp,
                LastKnownLogoffTime = timestamp,
                [sqlid] = true,
            }
        else
            PV.dbByPlayerID[target][sqlid] = true
            PV.dbByPlayerID[target].LastKnownLogonTime = timestamp
        end

        ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
        ModData.add("PVByPlayerID", PV.dbByPlayerID)

        PV.Log.transfer(sqlid, oldOwner, target, player:getUsername())

        PV_syncVehicleData(sqlid)
        if PV.dbByPlayerID[oldOwner] then
            sendServerCommand("ProtectVehicle", "updatePlayerData",
                { username = oldOwner, data = PV.dbByPlayerID[oldOwner] })
        end
        sendServerCommand("ProtectVehicle", "updatePlayerData",
            { username = target, data = PV.dbByPlayerID[target] })

        sendServerCommand(player, "ProtectVehicle", "pvAlert", {
            text = "IGUI_PV_Transfer_Done",
            p1 = tostring(vehicleName or "?"),
            p2 = tostring(target),
            r = 120, g = 230, b = 120,
        })
        sendServerCommand(targetObj, "ProtectVehicle", "pvAlert", {
            text = "IGUI_PV_Transfer_Received",
            p1 = tostring(vehicleName or "?"),
            p2 = tostring(oldOwner),
            r = 120, g = 230, b = 120,
        })

        if PV.Notices and PV.Notices.record then
            pcall(PV.Notices.record, target, "IGUI_PV_Notice_TransferIn",
                { p1 = tostring(vehicleName or "?"), p2 = tostring(oldOwner) })
            pcall(PV.Notices.record, oldOwner, "IGUI_PV_Notice_TransferOut",
                { p1 = tostring(vehicleName or "?"), p2 = tostring(target) })
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
        -- não apenas quem já tem veículo. Isso permite rastrear
        -- logon/logoff de qualquer jogador para fins de auditoria e timeout.
        local username  = player:getUsername()
        local now       = getTimestamp()

        if PV.dbByPlayerID[username] then
            -- Jogador já existe: atualiza horários
            PV.dbByPlayerID[username].LastKnownLogonTime  = now
            PV.dbByPlayerID[username].LastKnownLogoffTime = now
        else
            -- Novo jogador: cria entrada mínima
            PV.dbByPlayerID[username] = {
                LastKnownLogonTime  = now,
                LastKnownLogoffTime = now,
            }
            PV.Log.writeGlobal("New player registered in DB: '" .. username .. "'", "INFO")
        end
        ModData.add("PVByPlayerID", PV.dbByPlayerID)

        -- Entrega a caixa de avisos: e aqui que o jogador descobre o que
        -- aconteceu com os carros dele enquanto estava fora.
        if PV.Notices and PV.Notices.sendTo then
            local okN = pcall(PV.Notices.sendTo, player)
            if okN then
                local unread = PV.Notices.unreadCount(username)
                if unread > 0 then
                    -- pvAlert, nao haloNote: o handler de haloNote no cliente
                    -- ignora parametro e cor.
                    sendServerCommand(player, "ProtectVehicle", "pvAlert", {
                        text = "IGUI_PV_Notice_LoginSummary",
                        p1 = tostring(unread),
                        r = 255, g = 205, b = 90,
                    })
                end
            end
        end

    elseif command == "noticesRequest" then
        if PV.Notices and PV.Notices.sendTo then
            pcall(PV.Notices.sendTo, player)
        end

    elseif command == "noticesMarkRead" then
        if PV.Notices and PV.Notices.markAllRead then
            pcall(PV.Notices.markAllRead, player:getUsername())
            pcall(PV.Notices.sendTo, player)
        end

    elseif command == "noticesClear" then
        if PV.Notices and PV.Notices.clear then
            pcall(PV.Notices.clear, player:getUsername())
            pcall(PV.Notices.sendTo, player)
        end

    elseif command == "reportDenied" then
        local vehicleId = tonumber(args.vehicleId)
        local vehicleObj = vehicleId and getVehicleById(vehicleId) or nil
        if vehicleObj then
            PV_alertOwnerOfDeniedAttempt(player, vehicleObj, args.action)
        end

    elseif command == "syncCoord" then
        -- Forçar atualização de coordenada (enter/exit veículo).
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

-- ============================================================
-- AUTO-UNCLAIM DE VEICULO DESTRUIDO
--
-- Sem isto um carro queimado/destruido fica no DB para sempre e segue
-- ocupando um dos MaxVehicle do dono, que nao tem como desproteger um
-- veiculo que nao existe mais.
--
-- Sinais de "destruido", em ordem de confianca:
--   1. vehicleObj:isBurnt() quando a build expoe o metodo;
--   2. nome do script contendo "burnt" (variante queimada do veiculo);
--   3. condicao geral <= AutoUnclaimConditionPercent, apenas se o admin
--      ligar a opcao (default 0 = desligado).
--
-- O caminho 3 e opt-in de proposito: getPartCount inclui pecas ausentes,
-- entao um carro em obras (todas as pecas removidas pelo dono) poderia
-- ser lido como sucata.
-- ============================================================

--- Media da condicao das pecas, 0..100. Devolve 100 quando nao da para medir.
local function PV_getVehicleConditionPercent(vehicleObj)
    if not vehicleObj then return 100 end

    local total, count = 0, 0
    pcall(function()
        local partCount = vehicleObj:getPartCount()
        for i = 0, partCount - 1 do
            local part = vehicleObj:getPartByIndex(i)
            if part and part.getCondition then
                local c = tonumber(part:getCondition())
                if c ~= nil then
                    if c < 0 then c = 0 end
                    if c > 100 then c = 100 end
                    total = total + c
                    count = count + 1
                end
            end
        end
    end)

    if count <= 0 then return 100 end
    return total / count
end

--- Motivo da sucata ("burnt", "burnt_script", "condition") ou nil.
local function PV_getVehicleWreckReason(vehicleObj)
    if not vehicleObj then return nil end

    -- A: metodo explicito da build, quando existe.
    if vehicleObj.isBurnt then
        local ok, burnt = pcall(function() return vehicleObj:isBurnt() end)
        if ok and burnt == true then return "burnt" end
    end

    local cond = PV_getVehicleConditionPercent(vehicleObj)

    -- B: variante queimada do script. Exige condicao no chao como
    -- confirmacao: existem mods com "burnt" no nome de carros que andam.
    local okScript, fullName = pcall(function()
        return tostring(vehicleObj:getScript():getFullName())
    end)
    if okScript and type(fullName) == "string"
       and string.find(string.lower(fullName), "burnt", 1, true)
       and cond <= 1 then
        return "burnt_script(cond=" .. string.format("%.1f", cond) .. ")"
    end

    -- C: limiar de condicao, opt-in do admin.
    local sv = SandboxVars.ProtectVehicle
    local threshold = tonumber(sv and sv.AutoUnclaimConditionPercent) or 0
    if threshold > 0 and cond <= threshold then
        return "condition(cond=" .. string.format("%.1f", cond) .. ")"
    end

    return nil
end

--- true quando a entrada foi removida do DB (o chamador para de tratar
--- este veiculo neste ciclo).
local function PV_AutoUnclaimIfWreck(vehicleObj, sqlid)
    local sv = SandboxVars.ProtectVehicle
    if sv and sv.AutoUnclaimDestroyed == false then return false end

    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return false end

    local reason = PV_getVehicleWreckReason(vehicleObj)
    if not reason then return false end

    local owner = entry.OwnerPlayerID
    local vehicleName = PV.getVehicleDisplayNameFromModel(entry.CarModel)

    PV.ServerUnclaimVehicle(nil, sqlid, true, "destroyed:" .. reason)

    if PV.Notices and PV.Notices.record then
        pcall(PV.Notices.record, owner, "IGUI_PV_Notice_Wreck",
            { p1 = tostring(vehicleName or "?") })
    end

    local ownerObj = PV_getOnlinePlayerByUsername(owner)
    if ownerObj then
        sendServerCommand(ownerObj, "ProtectVehicle", "pvAlert", {
            text = "IGUI_PV_Alert_VehicleWreck",
            p1 = tostring(vehicleName or "?"),
        })
    end

    return true
end

-- ============================================================
-- DETECCAO DE INTRUSO (camada de servidor)
--
-- Todos os bloqueios de dirigir/entrar vivem em overrides de cliente,
-- entao um cliente modificado (ou um mod que substitua as mesmas
-- timed actions) passa por eles sem o servidor saber. O sweep abaixo
-- roda no servidor e olha quem esta de fato sentado nos veiculos
-- protegidos: se o ocupante nao tem permissao, gera log de seguranca,
-- avisa o intruso e avisa o dono se ele estiver online.
--
-- Nao e bloqueio: o servidor nao tira ninguem do carro de forma
-- confiavel em B42. O objetivo e deixar rastro auditavel.
-- ============================================================
local _pvIntrusionAlertAt = {}

local function PV_getIntrusionCooldownSeconds()
    local sv = SandboxVars.ProtectVehicle
    local minutes = tonumber(sv and sv.TheftAlertCooldownMinutes) or 10
    if minutes < 1 then minutes = 1 end
    return minutes * 60
end

--- Ocupantes do veiculo como { character=, username=, seat= }.
--- Usa getDriver() e getCharacter(seat) com feature detection: se a build
--- nao expor nenhum dos dois, devolve lista vazia e o sweep nao faz nada.
local function PV_collectVehicleOccupants(vehicleObj)
    local out, seen = {}, {}

    local function add(chr, seat)
        if not chr or not chr.getUsername then return end
        local ok, name = pcall(function() return chr:getUsername() end)
        if not ok or type(name) ~= "string" or name == "" then return end
        if seen[name] then return end
        seen[name] = true
        out[#out + 1] = { character = chr, username = name, seat = seat }
    end

    if vehicleObj.getDriver then
        local ok, drv = pcall(function() return vehicleObj:getDriver() end)
        if ok then add(drv, 0) end
    end

    if vehicleObj.getMaxPassengers and vehicleObj.getCharacter then
        local okMax, maxSeats = pcall(function() return vehicleObj:getMaxPassengers() end)
        if okMax and type(maxSeats) == "number" then
            for seat = 0, maxSeats - 1 do
                local okChr, chr = pcall(function() return vehicleObj:getCharacter(seat) end)
                if okChr then add(chr, seat) end
            end
        end
    end

    return out
end

local function PV_CheckVehicleIntruders(vehicleObj, sqlid, entry)
    local sv = SandboxVars.ProtectVehicle
    if sv and sv.TheftAlertEnabled == false then return end

    local ownerID = entry and entry.OwnerPlayerID or nil
    if type(ownerID) ~= "string" or ownerID == "" then return end

    local occupants = PV_collectVehicleOccupants(vehicleObj)
    if #occupants == 0 then return end

    local now = getTimestamp()
    local cooldown = PV_getIntrusionCooldownSeconds()
    local vehicleName = PV.getVehicleDisplayNameFromModel(entry.CarModel)

    for _, occ in ipairs(occupants) do
        if occ.username ~= ownerID then
            local flagName = (occ.seat == 0) and "AllowDrive" or "AllowPassenger"
            -- Em caso de erro no check NAO acusa ninguem: so alerta quando a
            -- permissao foi avaliada e deu negada.
            local ok, allowed = pcall(PV.canPerformAction, occ.character, vehicleObj, flagName)
            if ok and allowed ~= true then
                local key = tostring(sqlid) .. "|" .. occ.username
                local last = _pvIntrusionAlertAt[key] or 0
                -- Mesma regra da tentativa negada: o aviso sempre entra
                -- (agrupado), o log e o halo respeitam o cooldown.
                if PV.Notices and PV.Notices.record then
                    pcall(PV.Notices.record, ownerID, "IGUI_PV_Notice_Intruder", {
                        p1 = tostring(vehicleName or "?"),
                        p2 = tostring(occ.username),
                        gk = "intruder|" .. tostring(sqlid) .. "|" .. tostring(occ.username),
                    })
                end

                if (now - last) >= cooldown then
                    _pvIntrusionAlertAt[key] = now

                    PV.Log.intrusion(occ.character, vehicleObj, sqlid, ownerID, occ.seat)

                    sendServerCommand(occ.character, "ProtectVehicle", "haloNote",
                        { text = "IGUI_PV_NoPermission" })

                    local ownerObj = PV_getOnlinePlayerByUsername(ownerID)
                    if ownerObj then
                        sendServerCommand(ownerObj, "ProtectVehicle", "pvAlert", {
                            text = "IGUI_PV_Alert_VehicleIntruder",
                            p1 = tostring(vehicleName or "?"),
                            p2 = tostring(occ.username),
                        })
                    end
                end
            end
        end
    end
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

                local okWreck, wreckRes = pcall(PV_AutoUnclaimIfWreck, vehicleObj, sqlid)
                if not okWreck then
                    PV.Log.writeGlobal("Wreck check failed for sqlid " .. tostring(sqlid)
                        .. ": " .. tostring(wreckRes), "ERROR")
                elseif wreckRes == true then
                    -- Entrada ja saiu do DB: nada mais a checar neste veiculo.
                    return
                end

                local okIntr, errIntr = pcall(PV_CheckVehicleIntruders,
                    vehicleObj, sqlid, PV.getVehicleDBEntry(sqlid))
                if not okIntr then
                    PV.Log.writeGlobal("Intrusion check failed for sqlid " .. tostring(sqlid)
                        .. ": " .. tostring(errIntr), "ERROR")
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

        -- Os hooks de cliente já bloqueiam o attach antes da timed action
        -- vanilla na maior parte dos casos. Evitamos forçar um breakConstraint
        -- tardio aqui porque isso pode gerar picos de física e "carro voando".
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

    -- Localizar o veículo pelo ID enviado pelo cliente
    local vehicleId = args.vehicleId and (tonumber(args.vehicleId) or args.vehicleId) or nil
    local vehicle = vehicleId and getVehicleById(vehicleId) or nil

    if not vehicle then
        -- Sem veículo identificado: bloquear por segurança
        sendServerCommand(player, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_NoPermission_RV", r=1, g=0.2, b=0.2 })
        -- Zeramos args para invalidar o comando para handlers subsequentes
        for k in pairs(args) do args[k] = nil end
        PV.Log.writeGlobal("[PV] RV enterRV BLOCKED (vehicle not found) for '" .. player:getUsername() .. "'", "WARN")
        return
    end
    
    -- Verificar permissão PV
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
-- Events.OnVehicleAdded NÃO existe na B42 - removido.
