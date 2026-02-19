--[[
    ProtectVehicle - PV_Client.lua
    Client-side core logic.
    Handles UI triggers, context menus, and server command responses.
    B42.14.x - Pattern based on AVCS4213.
--]]

if isServer() and not isClient() then return end

PV = PV or {}

-- ============================================================
-- INITIAL SYNC (fires once on first tick after game start)
-- ============================================================
function PV.AfterGameStart()
    ModData.request("AVCSByVehicleSQLID")
    ModData.request("AVCSByPlayerID")
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

    elseif command == "updateVehicleData" then
        if not PV.dbByVehicleSQLID then ModData.request("AVCSByVehicleSQLID") return end
        PV.dbByVehicleSQLID[args.sqlid] = args.data
        -- Refresh open UI panels
        if PV.UI.AdminInstance and PV.UI.AdminInstance:isVisible() then
            PV.UI.AdminInstance:initList()
            PV.UI.AdminInstance:onSelectionChange()
        end
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end

    elseif command == "updatePlayerData" then
        if not PV.dbByPlayerID then ModData.request("AVCSByPlayerID") return end
        PV.dbByPlayerID[args.username] = args.data
        -- Refresh user panel if it's the local player's data
        if args.username == getPlayer():getUsername() then
            if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
                PV.UI.UserInstance:refreshList()
            end
        end

    elseif command == "removeVehicle" then
        if PV.dbByVehicleSQLID then PV.dbByVehicleSQLID[args.sqlid] = nil end
        if PV.dbByPlayerID and PV.dbByPlayerID[args.owner] then
            PV.dbByPlayerID[args.owner][args.sqlid] = nil
        end
        -- Refresh open UI panels
        if PV.UI.AdminInstance and PV.UI.AdminInstance:isVisible() then
            PV.UI.AdminInstance:initList()
            PV.UI.AdminInstance:onSelectionChange()
        end
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end

    elseif command == "updateCoord" then
        if PV.dbByVehicleSQLID and PV.dbByVehicleSQLID[args.sqlid] then
            local e = PV.dbByVehicleSQLID[args.sqlid]
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
        if PV.dbByVehicleSQLID and PV.dbByVehicleSQLID[args.sqlid] then
            PV.dbByVehicleSQLID[args.sqlid].PublicFlags = args.flags
        end

    elseif command == "haloNote" then
        getPlayer():setHaloNote(getText(args.text), args.r or 1, args.g or 1, args.b or 1, 300)

    elseif command == "adminResponse" then
        getPlayer():setHaloNote(getText(args.msg), args.success and 0.5 or 1, 1, args.success and 0.5 or 0.5, 300)

    elseif command == "adminTpToVehicle" then
        -- Server tells us to teleport the player to a location
        local player = getPlayer()
        if player and args.x and args.y then
            player:setX(args.x)
            player:setY(args.y)
            player:setZ(args.z or 0)
            getPlayer():setHaloNote(getText("IGUI_PV_Admin_TpToVehicle_Sent"), 0.5, 1, 0.5, 300)
        end
    end
end

-- ============================================================
-- VEHICLE CONTEXT MENU (via ISVehicleMenu.FillMenuOutsideVehicle)
-- ============================================================
local function PV_addVehicleOptions(playerObj, context, vehicle)
    local vname = vehicle and vehicle:getScript() and vehicle:getScript():getName() or ""
    if string.match(string.lower(vname), "burnt") or string.match(string.lower(vname), "smashed") then
        return
    end

    local sqlid   = PV.getVehicleID(vehicle)
    local perm    = PV.checkPermission(playerObj, vehicle)
    local isOwner = (type(perm) == "table" and perm.ownerid == playerObj:getUsername())
    local isAdmin = playerObj:getAccessLevel() ~= "None"
    local toolTip = ISToolTip:new()
    toolTip:initialise()
    toolTip:setVisible(false)

    if sqlid == nil or PV.dbByVehicleSQLID == nil or PV.dbByVehicleSQLID[sqlid] == nil then
        -- UNCLAIMED
        local option = context:addOption(getText("IGUI_PV_ContextMenu_ClaimVehicle"), playerObj, function()
            sendClientCommand(playerObj, "ProtectVehicle", "claim", { vehicleId = vehicle:getId() })
        end)
        toolTip.description = getText("IGUI_PV_Tooltip_CanClaim")
        if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.RequireVehicleDocumentForClaim then
            local docType = SandboxVars.ProtectVehicle.VehicleDocumentItemType or "ProtectVehicle.VehicleDocument"
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
        if isOwner or isAdmin then
            context:addOption(getText("IGUI_PV_ContextMenu_UnclaimVehicle"), playerObj, function()
                sendClientCommand(playerObj, "ProtectVehicle", "unclaim", { sqlid = sqlid })
            end)
            context:addOption(getText("IGUI_PV_ContextMenu_ManageVehicle"), playerObj, function()
                PV.UI.OpenPermissionPanel(sqlid)
            end)
        else
            local entry  = PV.dbByVehicleSQLID[sqlid]
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
-- WORLD CONTEXT MENU (My Vehicles + Admin Panel)
-- ============================================================
function PV.OnPreFillWorldObjectContextMenu(player, context, worldObjects, test)
    local playerObj = getSpecificPlayer(player)
    local isAdmin   = playerObj:getAccessLevel() ~= "None"

    context:addOption(getText("IGUI_PV_ContextMenu_MyVehicles"), worldObjects, function()
        PV.UI.OpenUserManager()
    end)

    if isAdmin or (not isClient() and not isServer()) then
        context:addOption(getText("IGUI_PV_ContextMenu_AdminPanel"), worldObjects, function()
            PV.UI.OpenAdminManager()
        end)
    end
end

-- ============================================================
-- GLOBAL SYNC HELPERS
-- ============================================================
function PV.OnReceiveGlobalModData(key, modData)
    if key == "AVCSByVehicleSQLID" then
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
    if key == "AVCSByPlayerID" then
        PV.dbByPlayerID = modData
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end
    end
end

Events.OnTick.Add(PV.AfterGameStart)
Events.OnPreFillWorldObjectContextMenu.Add(PV.OnPreFillWorldObjectContextMenu)
Events.OnReceiveGlobalModData.Add(PV.OnReceiveGlobalModData)
