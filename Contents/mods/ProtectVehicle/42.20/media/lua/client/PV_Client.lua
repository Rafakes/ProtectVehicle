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

    elseif command == "haloNote" then
        getPlayer():setHaloNote(getText(args.text), 255, 255, 255, 300)

    elseif command == "adminResponse" then
        getPlayer():setHaloNote(getText(args.msg), 255, 255, 255, 300)

    elseif command == "adminTpToVehicle" then
        -- SÃ³ exibe o haloNote de confirmaÃ§Ã£o; o movimento real jÃ¡ foi feito
        -- pelo servidor (teleportTo) + pelo comando "forceTeleport" abaixo.
        local player = getPlayer()
        if player then
            player:setHaloNote(getText("IGUI_PV_Admin_TpToVehicle_Sent"), 255, 255, 255, 300)
        end

    elseif command == "forceTeleport" then
        -- Fallback idÃªntico ao AACS: cliente aplica teleporte localmente para garantir
        -- o movimento quando o chunk nÃ£o estava carregado no servidor no momento do TP.
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
    if not playerObj or not context or not vehicle then return end

    -- Marca o menu como já tratado pelo PV. PV_MenuCompat.lua usa essa flag para
    -- injetar as opções só quando outro mod de veículo (ex.: motos) substituiu
    -- ISVehicleMenu.FillMenuOutsideVehicle e este caminho nunca rodou.
    context.pvVehicleOptionsAdded = true

    -- Diagnóstico (PV.diagVehicleMenu): registra qual caminho montou o menu.
    PV._pvLastMenuPath = "normal (ISVehicleMenu.FillMenuOutsideVehicle)"
    PV._pvLastMenuVehicle = vehicle:getScript() and vehicle:getScript():getFullName() or "?"

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

-- Exposto para PV_MenuCompat.lua (injeção tardia via OnFillWorldObjectContextMenu)
PV.addVehicleContextOptions = PV_addVehicleOptions

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

    -- Build submenu "ProtectVehicle: [target] > [VeÃ­culo] > [aÃ§Ã£o]"
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

    -- For each owned vehicle: vehicle name â†’ sub-submenu with actions
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
        -- FIX #5: addOption(text, target, onSelect) â€” target nÃ£o pode ser nil em B42
        -- Passamos a funÃ§Ã£o como target E como onSelect (compatibilidade com variaÃ§Ãµes da API)
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
-- COORD SYNC: Entrada e saÃ­da de veÃ­culo
--
-- B42 NÃƒO tem Events.OnCharacterGetInVehicle/Out.
--
-- Entrada: override de ISEnterVehicle:perform() â€” roda no
--   cliente ao fim da timed action, veÃ­culo garantidamente vÃ¡lido.
--
-- SaÃ­da: watcher leve via OnTick â€” compara veÃ­culo atual com
--   o do tick anterior; quando muda de "dentro" para "fora"
--   dispara o sync. Custo mÃ­nimo: apenas 2 comparaÃ§Ãµes por tick.
-- ============================================================

-- ENTRADA: override ISEnterVehicle:perform()
if ISEnterVehicle then
    local _oPVEnterPerform = ISEnterVehicle.perform
    function ISEnterVehicle:perform()
        _oPVEnterPerform(self)
        -- Dispara sync apÃ³s entrar no veÃ­culo
        local veh = self.vehicle
        if not veh or not self.character then return end
        if self.character ~= getPlayer() then return end
        if not PV.dbByVehicleSQLID then return end
        local sqlid = PV.getVehicleID and PV.getVehicleID(veh)
        if sqlid and PV.getVehicleDBEntry(sqlid) then
            sendClientCommand(self.character, "ProtectVehicle", "syncCoord", { vehicleId = veh:getId() })
        end
    end
end

-- SAÃDA: watcher via OnTick (Ãºnica forma confiÃ¡vel em B42)
local _pvLastVehicle = nil

local function PV_WatchVehicleExit()
    local player = getPlayer()
    if not player then return end
    local curVeh = player:getVehicle()
    -- Detecta transiÃ§Ã£o: estava dentro â†’ agora fora
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
