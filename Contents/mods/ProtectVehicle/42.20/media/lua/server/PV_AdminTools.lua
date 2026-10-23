--[[
    ProtectVehicle - PV_AdminTools.lua
    Server-side administrative functions.
    Force locate, teleport, and DB maintenance.
    B42.14.0.
--]]

if not isServer() then return end

PV = PV or {}

local function PV_findLoadedVehicleBySqlid(sqlid)
    local target = PV.canonicalVehicleSqlid and PV.canonicalVehicleSqlid(sqlid) or sqlid
    local cell = getCell and getCell() or nil
    local vehicles = cell and cell:getVehicles() or nil
    local vehicleObj = nil

    PV.iterVehicles(vehicles, function(v)
        if vehicleObj or not v then return end
        local vehicleId = PV.getVehicleID(v)
        if PV.canonicalVehicleSqlid then
            vehicleId = PV.canonicalVehicleSqlid(vehicleId)
        end
        if vehicleId == target or tostring(vehicleId) == tostring(target) then
            vehicleObj = v
        end
    end)

    return vehicleObj
end

-- ============================================================
-- Force Locate Real Position
-- ============================================================
function PV.AdminForceLocate(admin, sqlid)
    if not PV.isStaffPlayer(admin) then return end

    local vehicleObj = PV_findLoadedVehicleBySqlid(sqlid)
    local found = vehicleObj ~= nil
    
    if found then
        PV.updateVehicleCoordinate(vehicleObj)
        PV.Log.adminAction(admin, sqlid, "ForceLocate", "Success (Vehicle was loaded)")
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = true, msg = "IGUI_PV_Admin_LocateSuccess" })
    else
        PV.Log.adminAction(admin, sqlid, "ForceLocate", "Failed (Vehicle not loaded)")
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_LocateFailed_NotLoaded" })
    end
end

-- ============================================================
-- Teleport Player to Vehicle
-- ============================================================

-- Helper: tenta obter o square na posição (equivalente ao _getSquare do AACS)
local function PV_getSquare(x, y, z)
    local sq = nil
    pcall(function()
        sq = getCell():getGridSquare(math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0), math.floor(tonumber(z) or 0))
    end)
    return sq
end

-- Executa o teleporte do IsoPlayer para (x, y, z) no servidor.
-- Padrão idêntico ao _teleportPlayerTo do AACS:
--   1) teleportTo() - API oficial B42 para IsoPlayer
--   2) Fallback: setX/Y/Z + setLx/Ly/Lz (coordenadas lastX para suavidade)
--   3) Best-effort: bind ao square se disponível
--   4) Nudge de sync de rede: transmitPosition
--   5) forceTeleport via sendServerCommand para o cliente aplicar localmente
--      (garante o movimento mesmo quando o chunk ainda não está carregado no servidor)
local function PV_teleportAdminTo(admin, x, y, z)
    if not admin then return false end
    x = tonumber(x)
    y = tonumber(y)
    z = tonumber(z) or 0
    if not x or not y then return false end

    local px, py = x + 0.5, y + 0.5
    local did = false

    -- 1) Tenta teleportTo - o mais confiável no B42
    if admin.teleportTo then
        local ok = pcall(function() admin:teleportTo(px, py, z) end)
        if ok then did = true end
    end

    -- 2) Fallback: coordenadas brutas
    if not did then
        pcall(function() if admin.setX then admin:setX(px) end end)
        pcall(function() if admin.setY then admin:setY(py) end end)
        pcall(function() if admin.setZ then admin:setZ(z) end end)
        -- lastX/Y/Z ajudam a suavizar movimento de câmera no cliente
        pcall(function() if admin.setLx then admin:setLx(px) end end)
        pcall(function() if admin.setLy then admin:setLy(py) end end)
        pcall(function() if admin.setLz then admin:setLz(z) end end)
        did = true
    end

    -- 3) Bind ao square se disponível (ajuda alguns caminhos de sync do MP)
    local sq = PV_getSquare(x, y, z)
    if sq then
        pcall(function() if admin.setSquare        then admin:setSquare(sq) end end)
        pcall(function() if admin.setCurrentSquare then admin:setCurrentSquare(sq) end end)
        pcall(function() if admin.setCurrent       then admin:setCurrent(sq) end end)
    end

    -- 4) Nudge de sync de rede
    pcall(function() if admin.transmitPosition then admin:transmitPosition() end end)

    -- 5) Fallback no cliente: garante movimento mesmo se chunk não estava carregado no servidor
    sendServerCommand(admin, "ProtectVehicle", "forceTeleport", { x = px, y = py, z = z })

    return did
end

function PV.AdminTpPlayerToVehicle(admin, sqlid)
    if not PV.isStaffPlayer(admin) then return end

    -- FIX: respeita a opção sandbox AdminTeleportEnabled
    if SandboxVars.ProtectVehicle
    and SandboxVars.ProtectVehicle.AdminTeleportEnabled == false then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse",
            { success = false, msg = "IGUI_PV_Admin_TpDisabled" })
        return
    end

    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_TpFailed_NotLoaded" })
        return
    end

    -- Tenta usar coordenadas precisas do veículo se estiver carregado na célula
    local x = tonumber(entry.LastLocationX)
    local y = tonumber(entry.LastLocationY)
    local z = tonumber(entry.LastLocationZ) or 0
    local loadedVehicle = PV_findLoadedVehicleBySqlid(sqlid)
    if loadedVehicle then
        x = math.floor(loadedVehicle:getX())
        y = math.floor(loadedVehicle:getY())
        z = math.floor(loadedVehicle:getZ())
    end

    if not x or not y then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_TpFailed_NotLoaded" })
        return
    end

    local ok = PV_teleportAdminTo(admin, x, y, z)
    if not ok then
        sendServerCommand(admin, "ProtectVehicle", "adminResponse", { success = false, msg = "IGUI_PV_Admin_TpFailed_NotLoaded" })
        return
    end

    PV.Log.adminAction(admin, sqlid, "TpToVehicle",
        string.format("Teleported admin to (%s, %s, %s) teleportTo_ok=%s", tostring(x), tostring(y), tostring(z), tostring(ok)))

    -- Notificação de sucesso (adminTpToVehicle ainda tratado no cliente para haloNote)
    sendServerCommand(admin, "ProtectVehicle", "adminTpToVehicle", { x = x, y = y, z = z, success = true })
end

-- ============================================================
-- ADMIN COMMAND HANDLER (Extensions to Server.lua)
-- NOTE: Registered as a separate event listener to avoid
-- overwriting the already-registered PV.OnClientCommand ref.
-- ============================================================
local function PV_AdminOnClientCommand(module, command, player, args)
    if module ~= "ProtectVehicle" then return end

    if command == "adminLocate" then
        PV.AdminForceLocate(player, args.sqlid)

    elseif command == "adminTpToVehicle" then
        PV.AdminTpPlayerToVehicle(player, args.sqlid)

    elseif command == "adminRebuildDB" then
        if PV.isStaffPlayer(player) then
            PV.rebuildDB()
            PV.Log.writeGlobal("ADMIN '" .. player:getUsername() .. "' PERFORMED 'RebuildDB'. Details: Success", "ADMIN")
            sendServerCommand(player, "ProtectVehicle", "adminResponse", { success = true, msg = "IGUI_PV_Admin_RebuildSuccess" })
        end
    end
end

Events.OnClientCommand.Add(PV_AdminOnClientCommand)
