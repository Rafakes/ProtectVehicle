--[[
    ProtectVehicle - PV_Client.lua
    Client-side core logic.
    Handles UI triggers, context menus, and server command responses.
    B42.14.x
--]]

if isServer() and not isClient() then return end

PV = PV or {}

require "PV_ClaimAction"
require "PV_UnclaimAction"

-- ============================================================
-- INITIAL SYNC (fires once on first tick after game start)
-- ============================================================
function PV.AfterGameStart()
    ModData.request("PVByVehicleSQLID")
    ModData.request("PVByPlayerID")
    sendClientCommand(getPlayer(), "ProtectVehicle", "logon", {})
    Events.OnServerCommand.Add(PV.OnServerCommand)
    Events.OnTick.Remove(PV.AfterGameStart)
end

-- ============================================================
-- SERVER -> CLIENT HANDLER
-- ============================================================
-- Caixa de avisos do jogador local. Preenchida pelo comando "pvNotices".
PV.notices = PV.notices or {}
PV.noticesUnread = PV.noticesUnread or 0

-- Slots de protecao do jogador local. Preenchido pelo comando "pvSlots".
PV.mySlots = PV.mySlots or nil

-- O limite em PV.getClaimLimit (shared) vale para qualquer jogador, mas o
-- cliente so conhece os slots DELE: para qualquer outro, zero.
--
-- Num servidor-host o cliente e o servidor rodam no mesmo estado Lua e os dois
-- arquivos definem este resolvedor. O do servidor le o ModData e vale para
-- todo mundo, entao ele tem de ganhar: aqui so preenchemos se ninguem
-- preencheu antes.
if type(PV.resolveBonusSlots) ~= "function" then
    PV.resolveBonusSlots = function(playerObj)
        if not PV.mySlots or not playerObj then return 0 end
        local me = getPlayer()
        if not me or playerObj ~= me then return 0 end
        return (tonumber(PV.mySlots.rented) or 0) + (tonumber(PV.mySlots.grace) or 0)
    end
end

PV.OnServerCommand = function(module, command, args)
    if module ~= "ProtectVehicle" then return end

    if command == "registerVehicleSQLID" then
        local v = getVehicleById(args.vehicleRuntimeId)
        if v then v:getModData().SQLID = args.sqlid end

    elseif command == "clearVehicleSQLID" then
        local target = PV.canonicalVehicleSqlid(args.sqlid)
        pcall(function()
            local cell = getCell()
            if not cell then return end
            local vehicles = cell:getVehicles()
            if not vehicles then return end
            PV.iterVehicles(vehicles, function(v)
                if v and PV.canonicalVehicleSqlid(PV.getVehicleID(v)) == target then
                    v:getModData().SQLID = nil
                end
            end)
        end)

    elseif command == "updateVehicleData" then
        if not PV.dbByVehicleSQLID then ModData.request("PVByVehicleSQLID") return end
        local sid = PV.canonicalVehicleSqlid(args.sqlid)
        PV.dbByVehicleSQLID[sid] = args.data
        if args.sqlid ~= sid then PV.dbByVehicleSQLID[args.sqlid] = nil end
        -- Refresh open UI panels
        if PV.UI.AdminInstance and PV.UI.AdminInstance:isVisible() then
            PV.UI.AdminInstance:initList()
            PV.UI.AdminInstance:onSelectionChange()
        end
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end

    elseif command == "updatePlayerData" then
        if not PV.dbByPlayerID then ModData.request("PVByPlayerID") return end
        PV.dbByPlayerID[args.username] = args.data
        -- Refresh user panel if it's the local player's data
        if args.username == getPlayer():getUsername() then
            if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
                PV.UI.UserInstance:refreshList()
            end
        end

    elseif command == "removeVehicle" then
        local sqlid = args and args.sqlid
        sqlid = PV.canonicalVehicleSqlid(sqlid)

        -- If global moddata isn't ready yet, request and let the next update refresh UI.
        if not PV.dbByVehicleSQLID or not PV.dbByPlayerID then
            ModData.request("PVByVehicleSQLID")
            ModData.request("PVByPlayerID")
        end

        if PV.dbByVehicleSQLID then PV.clearVehicleDBEntry(sqlid) end
        if args and args.owner then PV.clearPlayerVehicleIndex(args.owner, sqlid) end

        -- Refresh open UI panels
        if PV.UI.AdminInstance and PV.UI.AdminInstance:isVisible() then
            PV.UI.AdminInstance:initList()
            PV.UI.AdminInstance:onSelectionChange()
        end
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end

    elseif command == "updateCoord" then
        local sid = PV.canonicalVehicleSqlid(args.sqlid)
        local e = PV.getVehicleDBEntry(sid)
        if e then
            e.LastLocationX = args.x
            e.LastLocationY = args.y
            e.LastLocationZ = args.z
            e.LastLocationUpdateDateTime = args.t
        end
        -- Refresh admin panel location column
        if PV.UI.AdminInstance and PV.UI.AdminInstance:isVisible() then
            PV.UI.AdminInstance:initList()
        end

    elseif command == "updateFlags" then
        local e = PV.getVehicleDBEntry(PV.canonicalVehicleSqlid(args.sqlid))
        if e then e.PublicFlags = args.flags end

    elseif command == "pvSlots" then
        PV.mySlots = args
        if PV.UI.SlotsInstance and PV.UI.SlotsInstance:isVisible() then
            PV.UI.SlotsInstance:refreshAll()
        end
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:updateClaimStatus()
            PV.UI.UserInstance:updateSlotsButton()
        end

    elseif command == "pvNotices" then
        -- A caixa de avisos do proprio jogador. Chega sempre direcionada: o
        -- cliente nunca pede o ModData PVNotices, que tem a de todo mundo.
        PV.notices = (type(args.items) == "table") and args.items or {}
        PV.noticesUnread = tonumber(args.unread) or 0

        if PV.UI.NoticesInstance and PV.UI.NoticesInstance:isVisible() then
            PV.UI.NoticesInstance:refreshList()
        end
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:updateNoticesButton()
        end

    elseif command == "haloNote" then
        getPlayer():setHaloNote(getText(args.text), 255, 255, 255, 300)

    elseif command == "pvAlert" then
        -- Canal generico de alerta do servidor: chave de traducao + ate dois
        -- parametros (%1/%2) e cor opcional em 0..255.
        local pl = getPlayer()
        if pl then
            local p1 = args.p1 ~= nil and tostring(args.p1) or ""
            local p2 = args.p2 ~= nil and tostring(args.p2) or ""
            pl:setHaloNote(getText(args.text, p1, p2),
                tonumber(args.r) or 255, tonumber(args.g) or 160, tonumber(args.b) or 60, 450)
        end

    elseif command == "adminResponse" then
        getPlayer():setHaloNote(getText(args.msg), 255, 255, 255, 300)

    elseif command == "adminTpToVehicle" then
        -- Só exibe o haloNote de confirmação; o movimento real já foi feito
        -- pelo servidor (teleportTo) + pelo comando "forceTeleport" abaixo.
        local player = getPlayer()
        if player then
            player:setHaloNote(getText("IGUI_PV_Admin_TpToVehicle_Sent"), 255, 255, 255, 300)
        end

    elseif command == "forceTeleport" then
        -- Fallback idêntico ao AACS: cliente aplica teleporte localmente para garantir
        -- o movimento quando o chunk não estava carregado no servidor no momento do TP.
        local player = getPlayer()
        local x = tonumber(args.x)
        local y = tonumber(args.y)
        local z = tonumber(args.z) or 0
        if player and x and y then
            local did = false
            if player.teleportTo then
                local ok = pcall(function() player:teleportTo(x, y, z) end)
                did = ok == true
            end
            if not did then
                pcall(function() if player.setX then player:setX(x) end end)
                pcall(function() if player.setY then player:setY(y) end end)
                pcall(function() if player.setZ then player:setZ(z) end end)
            end
            pcall(function() if player.setLx then player:setLx(x) end end)
            pcall(function() if player.setLy then player:setLy(y) end end)
            pcall(function() if player.setLz then player:setLz(z) end end)
            pcall(function()
                local cell = getCell and getCell() or nil
                local sq = cell and cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z)) or nil
                if sq then
                    if player.setSquare then player:setSquare(sq) end
                    if player.setCurrentSquare then player:setCurrentSquare(sq) end
                    if player.setCurrent then player:setCurrent(sq) end
                end
            end)
            pcall(function() if player.transmitPosition then player:transmitPosition() end end)
        end

    end  -- fecha if/elseif chain
end  -- fecha PV.OnServerCommand

-- ============================================================
-- VEHICLE CONTEXT MENU (via ISVehicleMenu.FillMenuOutsideVehicle)
-- ============================================================
local function PV_addContextOption(context, text, fn)
    -- B42: ISContextMenu.addOption signature changed across versions/modpacks.
    -- Passing (text, fn, fn) keeps compatibility with both:
    --  - addOption(text, onSelect, param1)
    --  - addOption(text, target, onSelect)
    return context:addOption(text, fn, fn)
end

local function PV_addVehicleOptions(playerObj, context, vehicle)
    local vname = vehicle and vehicle:getScript() and vehicle:getScript():getName() or ""
    if string.match(string.lower(vname), "burnt") or string.match(string.lower(vname), "smashed") then
        return
    end

    local sqlid   = PV.getVehicleID(vehicle)
    local canManage = PV.canManageVehicle(playerObj, vehicle)
    local toolTip = ISToolTip:new()
    toolTip:initialise()
    toolTip:setVisible(false)

    if sqlid ~= nil and type(PV.dbByVehicleSQLID) ~= "table" then
        ModData.request("PVByVehicleSQLID")
        ModData.request("PVByPlayerID")
    end

    if sqlid == nil or not PV.getVehicleDBEntry(sqlid) then
        -- UNCLAIMED
        local fn = function()
            -- Se o jogador está longe, caminha até o veículo antes de claimar
            if playerObj:DistTo(vehicle:getX(), vehicle:getY()) > 1.5 then
                ISTimedActionQueue.add(ISWalkToTimedAction:new(playerObj, vehicle))
            end
            ISTimedActionQueue.add(ISPVClaimAction:new(playerObj, vehicle))
        end
        local option = PV_addContextOption(context, getText("IGUI_PV_ContextMenu_ClaimVehicle"), fn)
        toolTip.description = getText("IGUI_PV_Tooltip_CanClaim")
        if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.RequireVehicleDocumentForClaim then
            local docType = SandboxVars.ProtectVehicle.VehicleDocumentItemType or "Base.VehicleDocument"
            if not playerObj:getInventory():containsTypeRecurse(docType) then
                toolTip.description = toolTip.description .. " <LINE> <RGB:1,0.2,0.2> " .. getText("IGUI_PV_Tooltip_RequiresDoc")
                option.notAvailable = true
            end
        end
        if not PV.checkMaxClaim(playerObj) then
            toolTip.description = toolTip.description .. " <LINE> <RGB:1,0.2,0.2> " .. getText("IGUI_PV_Tooltip_LimitReached")
            option.notAvailable = true
        end
        option.toolTip = toolTip
    else
        -- CLAIMED
        if canManage then
            local entry = PV.getVehicleDBEntry(sqlid)
            local unclaimOption = PV_addContextOption(context, getText("IGUI_PV_ContextMenu_UnclaimVehicle"), function()
                if playerObj:DistTo(vehicle:getX(), vehicle:getY()) > 1.5 then
                    ISTimedActionQueue.add(ISWalkToTimedAction:new(playerObj, vehicle))
                end
                ISTimedActionQueue.add(ISPVUnclaimAction:new(playerObj, vehicle, sqlid))
            end)
            if entry and entry.OwnerPlayerID then
                toolTip.description = getText("IGUI_PV_ContextMenu_OwnedBy", entry.OwnerPlayerID)
                unclaimOption.toolTip = toolTip
            end
            PV_addContextOption(context, getText("IGUI_PV_ContextMenu_ManageVehicle"), function() PV.UI.OpenPermissionPanel(sqlid) end)
        else
            local entry  = PV.getVehicleDBEntry(sqlid)
            local option = context:addOption(getText("IGUI_PV_ContextMenu_OwnedBy", entry.OwnerPlayerID), nil, nil)
            toolTip.description = getText("IGUI_PV_ContextMenu_OwnedBy", entry.OwnerPlayerID)
            option.toolTip      = toolTip
            option.notAvailable = true
        end
    end
end

if not PV.oFillMenuOutsideVehicle then
    PV.oFillMenuOutsideVehicle = ISVehicleMenu.FillMenuOutsideVehicle
end

function ISVehicleMenu.FillMenuOutsideVehicle(player, context, vehicle, test)
    PV.oFillMenuOutsideVehicle(player, context, vehicle, test)
    PV_addVehicleOptions(getSpecificPlayer(player), context, vehicle)
end

-- ============================================================
-- WORLD CONTEXT MENU (My Vehicles + Admin Panel + Player quick-allow)
-- ============================================================
function PV.OnPreFillWorldObjectContextMenu(player, context, worldObjects, test)
    local playerObj = getSpecificPlayer(player)
    local level     = string.lower(playerObj:getAccessLevel() or "none")
    local isAdmin   = (level == "admin" or level == "moderator")

    PV_addContextOption(context, getText("IGUI_PV_ContextMenu_MyVehicles"), function() PV.UI.OpenUserManager() end)

    if isAdmin then
        PV_addContextOption(context, getText("IGUI_PV_ContextMenu_AdminPanel"), function() PV.UI.OpenAdminManager() end)
    end

    -- ---- Quick-allow submenu when right-clicking another player ----
    -- Find IsoPlayer targets (other than self) in worldObjects
    -- worldObjects is a Lua table in B42 (not a Java ArrayList)
    local targetPlayer = nil
    for _, obj in ipairs(worldObjects) do
        if obj and instanceof(obj, "IsoPlayer") then
            if obj:getUsername() ~= playerObj:getUsername() then
                targetPlayer = obj:getUsername()
                break
            end
        end
    end

    if not targetPlayer then return end

    -- Check if local player owns any vehicles
    local username = playerObj:getUsername()
    local pData    = PV.dbByPlayerID and PV.dbByPlayerID[username]
    if not pData then return end

    -- Collect owned sqlids
    local ownedSqlids = {}
    for sqlid, v in pairs(pData) do
        if sqlid ~= "LastKnownLogonTime" and sqlid ~= "LastKnownLogoffTime" and v then
            table.insert(ownedSqlids, sqlid)
        end
    end
    if #ownedSqlids == 0 then return end

    -- Build submenu "ProtectVehicle: [target] > [Veículo] > [ação]"
    local pvOption = context:addOption("ProtectVehicle: " .. targetPlayer, nil, nil)
    local subMenu  = ISContextMenu:getNew(context)
    context:addSubMenu(pvOption, subMenu)

    local function sendQuickAllow(sqlid, flags)
        -- Ensure player is in AllowList
        sendClientCommand(playerObj, "ProtectVehicle", "addToAllowList",
            { sqlid = sqlid, targetPlayer = targetPlayer })
        -- Apply the specific flags
        sendClientCommand(playerObj, "ProtectVehicle", "updatePlayerFlags",
            { sqlid = sqlid, targetPlayer = targetPlayer, flags = flags })
    end

    local function allTrueFlags()
        local t = {}
        for k, _ in pairs(PV.DEFAULT_FLAGS or {}) do t[k] = true end
        return t
    end

    -- For each owned vehicle: vehicle name -> sub-submenu with actions
    for _, sqlid in ipairs(ownedSqlids) do
        local vData    = PV.getVehicleDBEntry(sqlid)
        local rawModel = vData and vData.CarModel or tostring(sqlid)
        local carName  = rawModel
        local idx = string.find(rawModel, "%.")
        if idx then
            carName = getTextOrNull("IGUI_VehicleName" .. string.sub(rawModel, idx+1)) or rawModel
        end

        local vOpt    = subMenu:addOption(carName, nil, nil)
        local vSubMenu = ISContextMenu:getNew(subMenu)
        subMenu:addSubMenu(vOpt, vSubMenu)

        local sid = sqlid -- capture for closures
        -- FIX #5: addOption(text, target, onSelect) - target não pode ser nil em B42
        -- Passamos a função como target E como onSelect (compatibilidade com variações da API)
        local function mkOpt(txt, flags)
            local fn = function() sendQuickAllow(sid, flags) end
            vSubMenu:addOption(txt, fn, fn)
        end
        mkOpt(getText("IGUI_PV_CtxAllow_Drive"),      { AllowDrive = true })
        mkOpt(getText("IGUI_PV_CtxAllow_Passenger"),  { AllowPassenger = true })
        mkOpt(getText("IGUI_PV_CtxAllow_Containers"), { AllowContainersAccess = true })
        mkOpt(getText("IGUI_PV_CtxAllow_All"),        allTrueFlags())
    end
end

-- ============================================================
-- GLOBAL SYNC HELPERS
-- ============================================================
function PV.OnReceiveGlobalModData(key, modData)
    if key == "PVByVehicleSQLID" then
        PV.dbByVehicleSQLID = modData
        -- Refresh panels if open with fresh DB
        if PV.UI.AdminInstance and PV.UI.AdminInstance:isVisible() then
            PV.UI.AdminInstance:initList()
            PV.UI.AdminInstance:onSelectionChange()
        end
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end
    end
    if key == "PVByPlayerID" then
        PV.dbByPlayerID = modData
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end
    end
end

Events.OnTick.Add(PV.AfterGameStart)
Events.OnPreFillWorldObjectContextMenu.Add(PV.OnPreFillWorldObjectContextMenu)
Events.OnReceiveGlobalModData.Add(PV.OnReceiveGlobalModData)

-- ============================================================
-- COORD SYNC: Entrada e saída de veículo
--
-- B42 NÃO tem Events.OnCharacterGetInVehicle/Out.
--
-- Entrada: override de ISEnterVehicle:perform() - roda no
--   cliente ao fim da timed action, veículo garantidamente válido.
--
-- Saída: watcher leve via OnTick - compara veículo atual com
--   o do tick anterior; quando muda de "dentro" para "fora"
--   dispara o sync. Custo mínimo: apenas 2 comparações por tick.
-- ============================================================

-- ============================================================
-- REPORT DE TENTATIVA NEGADA
--
-- Os bloqueios acontecem no cliente, entao sem isto o dono nunca fica
-- sabendo que alguem tentou mexer no carro dele. Mandamos so o id do
-- veiculo e o nome da flag; quem o jogador e, o servidor sabe pelo
-- proprio comando, e e lá que a permissao e reconferida.
--
-- Throttle local porque alguns isValid() rodam a cada frame enquanto a
-- acao esta na fila.
-- ============================================================
local PV_DENIED_REPORT_COOLDOWN_MS = 30000
local _pvDeniedReportAt = {}

function PV.reportDeniedAction(character, vehicleObj, action)
    local sv = SandboxVars.ProtectVehicle
    if sv and sv.DeniedAttemptAlert == false then return end
    if not character or not vehicleObj or not action then return end
    if character ~= getPlayer() then return end

    -- Sem DB ou sem dono nao ha quem avisar.
    if type(PV.dbByVehicleSQLID) ~= "table" then return end
    local sqlid = PV.getVehicleID and PV.getVehicleID(vehicleObj) or nil
    if not sqlid or not PV.getVehicleDBEntry(sqlid) then return end

    local vid = vehicleObj.getId and vehicleObj:getId() or nil
    if not vid then return end

    local key = tostring(sqlid) .. "|" .. tostring(action)
    local now = (getTimestampMs and getTimestampMs()) or 0
    local last = _pvDeniedReportAt[key] or 0
    if (now - last) < PV_DENIED_REPORT_COOLDOWN_MS then return end
    _pvDeniedReportAt[key] = now

    sendClientCommand(character, "ProtectVehicle", "reportDenied", {
        vehicleId = vid,
        action = tostring(action),
    })
end

-- ============================================================
-- AVISO: veiculo sem protecao
--
-- Ao entrar num veiculo que nao esta protegido pelo mod
-- (sem SQLID, ou SQLID orfao sem entrada no DB) mostra um
-- halo note avisando que qualquer jogador pode roubar o carro.
--
-- Nao avisa quando o DB ainda nao chegou ao cliente: nesse
-- caso nao da para saber se o veiculo tem dono.
-- Cooldown por veiculo para nao repetir a cada entrada.
-- ============================================================
local PV_UNPROTECTED_WARN_COOLDOWN_MS = 300000  -- 5 min de tempo real por veiculo
local _pvUnprotectedWarnAt = {}

local function PV_nowMs()
    if getTimestampMs then return getTimestampMs() end
    if getTimestamp then return getTimestamp() * 1000 end
    return 0
end

--- true quando o veiculo nao tem protecao do mod (livre para qualquer um).
function PV.isVehicleUnprotected(vehicleObj)
    if not vehicleObj then return false end
    -- DB ainda nao sincronizado: fica em silencio em vez de avisar errado.
    if type(PV.dbByVehicleSQLID) ~= "table" then return false end
    local sqlid = PV.getVehicleID and PV.getVehicleID(vehicleObj) or nil
    if sqlid == nil then return true end
    return PV.getVehicleDBEntry(sqlid) == nil
end

function PV.warnIfVehicleUnprotected(playerObj, vehicleObj)
    local sv = SandboxVars.ProtectVehicle
    if sv and sv.WarnUnprotectedVehicle == false then return end
    if not playerObj or not vehicleObj then return end
    if playerObj ~= getPlayer() then return end
    if not PV.isVehicleUnprotected(vehicleObj) then return end

    local now = PV_nowMs()
    local key = vehicleObj.getId and vehicleObj:getId() or nil
    if key ~= nil then
        local last = _pvUnprotectedWarnAt[key]
        if last and (now - last) < PV_UNPROTECTED_WARN_COOLDOWN_MS then return end
        _pvUnprotectedWarnAt[key] = now
    end

    local requiresDoc = sv and sv.RequireVehicleDocumentForClaim == true
    local msgKey = requiresDoc and "IGUI_PV_Warn_Unprotected_Doc" or "IGUI_PV_Warn_Unprotected"
    playerObj:setHaloNote(getText(msgKey), 255, 200, 80, 400)
end

-- ENTRADA: override ISEnterVehicle:perform()
if ISEnterVehicle then
    local _oPVEnterPerform = ISEnterVehicle.perform
    function ISEnterVehicle:perform()
        _oPVEnterPerform(self)
        local veh = self.vehicle
        if not veh or not self.character then return end
        if self.character ~= getPlayer() then return end

        -- Aviso de veiculo sem protecao (so no assento do motorista)
        if type(self.seat) ~= "number" or self.seat == 0 then
            pcall(PV.warnIfVehicleUnprotected, self.character, veh)
        end

        -- Dispara sync apos entrar no veiculo
        if not PV.dbByVehicleSQLID then return end
        local sqlid = PV.getVehicleID and PV.getVehicleID(veh)
        if sqlid and PV.getVehicleDBEntry(sqlid) then
            sendClientCommand(self.character, "ProtectVehicle", "syncCoord", { vehicleId = veh:getId() })
        end
    end
end

-- SAÍDA: watcher via OnTick (única forma confiável em B42)
local _pvLastVehicle = nil

local function PV_WatchVehicleExit()
    local player = getPlayer()
    if not player then return end
    local curVeh = player:getVehicle()
    -- Detecta transição: estava dentro -> agora fora
    if _pvLastVehicle and not curVeh then
        if PV.dbByVehicleSQLID then
            local sqlid = PV.getVehicleID and PV.getVehicleID(_pvLastVehicle)
            if sqlid and PV.getVehicleDBEntry(sqlid) then
                sendClientCommand(player, "ProtectVehicle", "syncCoord", { vehicleId = _pvLastVehicle:getId() })
            end
        end
    end
    _pvLastVehicle = curVeh
end

Events.OnTick.Add(PV_WatchVehicleExit)

-- ============================================================
-- ATALHO DE TECLADO: abre "Meus Veiculos Protegidos"
--
-- Entra em Opcoes > Teclas SEM tecla definida: assim nao briga com
-- atalho do jogo nem de outro mod, e cada jogador escolhe a sua. A
-- opcao no menu de contexto continua existindo.
--
-- O texto mostrado na lista de teclas vem de
-- UI_optionscreen_binding_<value>; sem a chave, o jogo cai no proprio
-- value, que por isso ja e legivel.
-- ============================================================
local PV_KEYBIND_NAME = "Protect Vehicle"

if keyBinding then
    table.insert(keyBinding, { value = "[Protect Vehicle]" })
    table.insert(keyBinding, {
        value = PV_KEYBIND_NAME,
        key = (Keyboard and Keyboard.KEY_NONE) or 0,
    })
end

local function PV_isTypingInChat()
    local entry = ISChat and ISChat.instance and ISChat.instance.textEntry
    if not entry or not entry.isFocused then return false end
    local ok, focused = pcall(function() return entry:isFocused() end)
    return ok and focused == true
end

local function PV_OnKeyPressed(key)
    local core = getCore and getCore()
    if not core or not core.getKey then return end

    local ok, bound = pcall(function() return core:getKey(PV_KEYBIND_NAME) end)
    if not ok or not bound or bound == 0 or key ~= bound then return end

    local player = getPlayer()
    if not player or player:isDead() then return end
    if PV_isTypingInChat() then return end

    -- Toggle: a mesma tecla fecha a janela ja aberta.
    if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
        PV.UI.UserInstance:close()
        return
    end

    if PV.UI.OpenUserManager then PV.UI.OpenUserManager() end
end

Events.OnKeyPressed.Add(PV_OnKeyPressed)
