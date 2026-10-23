--[[
    ProtectVehicle - PV_VehicleLogs.lua
    Sistema de logging com escrita em arquivo por veiculo.

    ESTRUTURA (relativo a Zomboid/Lua/ do servidor):
        /ProtectVehicle/
            YYYY-MM-DD/
                global.log      -- claims, unclaims, erros, admin
                VEH_<sqlid>.log -- eventos de um veiculo especifico

    API correta (baseada no ServerShopAudit que funciona):
        getFileWriter(path, append, localFile)
            - path comeca com "/" -> escreve em Zomboid/Lua/
            - append    = true  (nao apaga ao reiniciar)
            - localFile = true  (pasta Lua/ do servidor)
        writer.write(writer, string)   -- chamada Java-style (ponto, nao dois-pontos)
        writer.write(writer, "\r\n")   -- newline explicito
        writer.close(writer)
--]]

if not isServer() then return end

PV     = PV or {}
PV.Log = {}

-- ============================================================
-- Constantes
-- ============================================================
local LOG_DIR = "/ProtectVehicle"

-- ============================================================
-- Internal: timestamp legivel via os.date (disponivel no servidor)
-- ============================================================
local function _ts()
    if os and os.date then
        return os.date("%Y-%m-%d %H:%M:%S")
    end
    return tostring(math.floor(getTimestamp()))
end

-- ============================================================
-- Internal: pasta diaria dos logs
-- ============================================================
local function _dateDir()
    if os and os.date then
        return LOG_DIR .. "/" .. os.date("%Y-%m-%d")
    end
    return LOG_DIR
end

-- ============================================================
-- Internal: caminho do log global do dia atual
-- ============================================================
local function _globalPath()
    return _dateDir() .. "/global.log"
end

-- ============================================================
-- Internal: escreve uma linha em arquivo e opcionalmente no console.
-- forceConsole=true: sempre echa (eventos criticos: claim, unclaim, admin).
-- echoConsole=true:  echa apenas se EnableVerboseConsoleLogs estiver ativo.
-- ============================================================
local function _write(filepath, level, msg, echoConsole, forceConsole)
    local line = "[" .. _ts() .. "] [" .. level .. "] " .. tostring(msg)

    local ok, writer = pcall(getFileWriter, filepath, true, true)
    if ok and writer then
        pcall(writer.write, writer, line)
        pcall(writer.write, writer, "\r\n")
        pcall(writer.close, writer)
    else
        print("[PV][ERROR] getFileWriter falhou para '" .. filepath .. "': " .. tostring(writer))
    end

    if forceConsole then
        print("[PV] " .. line)
    elseif echoConsole ~= false then
        local sv = SandboxVars and SandboxVars.ProtectVehicle
        if sv and sv.EnableVerboseConsoleLogs then
            print("[PV] " .. line)
        end
    end
end

-- ============================================================
-- Internal: caminho do log de um veiculo
-- ============================================================
local function _vpath(sqlid)
    return _dateDir() .. "/VEH_" .. tostring(sqlid) .. ".log"
end

-- ============================================================
-- API Publica
-- ============================================================

--- Loga no global.log. Sempre escreve (auditoria essencial).
--- forceConsole=true garante echo mesmo com verbose desligado (para eventos criticos).
function PV.Log.writeGlobal(msg, level, forceConsole)
    _write(_globalPath(), level or "INFO", tostring(msg), nil, forceConsole)
end

--- Loga no VEH_<sqlid>.log E no global.log.
--- Respeita sandbox EnablePerVehicleLogs.
--- forceConsole=true garante echo mesmo com verbose desligado (para eventos criticos).
function PV.Log.writeVehicle(sqlid, msg, level, forceConsole)
    local sv = SandboxVars and SandboxVars.ProtectVehicle
    if sv and sv.EnablePerVehicleLogs == false then
        return
    end
    local tag = "{VEH:" .. tostring(sqlid) .. "} "
    _write(_vpath(sqlid), level or "INFO", tag .. tostring(msg), false, false)
    _write(_globalPath(), level or "INFO", tag .. tostring(msg), true, forceConsole)
end

-- ============================================================
-- Helpers especializados
-- ============================================================

-- claim e unclaim sempre aparecem no console (forceConsole=true)
function PV.Log.claim(playerObj, vehicleObj, sqlid, success, reason)
    local username = "UNKNOWN"
    local model    = "unknown"
    local coords   = "(?,?,?)"
    if playerObj and playerObj.getUsername then
        pcall(function() username = playerObj:getUsername() end)
    end
    pcall(function()
        model  = vehicleObj:getScript():getFullName()
        coords = "(" .. math.floor(vehicleObj:getX()) .. ","
                     .. math.floor(vehicleObj:getY()) .. ","
                     .. math.floor(vehicleObj:getZ()) .. ")"
    end)
    if success then
        PV.Log.writeVehicle(sqlid,
            "CLAIM by '" .. username .. "' | vehicle '" .. model .. "' | coords " .. coords,
            "CLAIM", true)
    else
        PV.Log.writeGlobal(
            "CLAIM DENIED for '" .. username .. "' | vehicle '" .. model ..
            "' | coords " .. coords .. " | reason: " .. tostring(reason or "Unknown"),
            "WARNING", true)
    end
end

function PV.Log.unclaim(playerObj, sqlid, isAdmin)
    local username = "SERVER"
    if playerObj and playerObj.getUsername then
        pcall(function() username = playerObj:getUsername() end)
    end
    local suffix = isAdmin and " [ADMIN]" or ""
    PV.Log.writeVehicle(sqlid,
        "UNCLAIM by '" .. username .. "'" .. suffix, "CLAIM", true)
end

-- actionDenied: arquivo sempre, console apenas com verbose
function PV.Log.actionDenied(playerObj, vehicleObj, sqlid, action)
    local username = "UNKNOWN"
    local coords   = "(?,?,?)"
    if playerObj and playerObj.getUsername then
        pcall(function() username = playerObj:getUsername() end)
    end
    pcall(function()
        coords = "(" .. math.floor(vehicleObj:getX()) .. ","
                     .. math.floor(vehicleObj:getY()) .. ","
                     .. math.floor(vehicleObj:getZ()) .. ")"
    end)
    PV.Log.writeVehicle(sqlid,
        "ACTION DENIED '" .. tostring(action) .. "' for '" .. username ..
        "' | coords " .. coords, "SECURITY")
end

-- adminAction sempre aparece no console (forceConsole=true)
function PV.Log.adminAction(adminObj, sqlid, action, details)
    local adminName = "UNKNOWN"
    if adminObj and adminObj.getUsername then
        pcall(function() adminName = adminObj:getUsername() end)
    end
    PV.Log.writeVehicle(sqlid,
        "ADMIN '" .. adminName .. "' | action '" .. tostring(action) ..
        "' | " .. tostring(details or ""), "ADMIN", true)
end

-- timeout: arquivo sempre, console sem force (evento automatico, nao critico)
function PV.Log.timeout(sqlid, owner, lastLogoff)
    PV.Log.writeVehicle(sqlid,
        "AUTO-UNCLAIM timeout | owner '" .. tostring(owner) ..
        "' | lastLogoff=" .. tostring(lastLogoff), "INFO")
end

-- coordSync: gateado por EnableCoordSyncLogs; nunca echa no console
function PV.Log.coordSync(playerObj, vehicleObj, sqlid, source)
    local sv = SandboxVars and SandboxVars.ProtectVehicle
    if not sv or not sv.EnableCoordSyncLogs then return end

    local username = "SERVER"
    local coords   = "(?,?,?)"
    if playerObj and playerObj.getUsername then
        pcall(function() username = playerObj:getUsername() end)
    end
    pcall(function()
        coords = "(" .. math.floor(vehicleObj:getX()) .. ","
                     .. math.floor(vehicleObj:getY()) .. ","
                     .. math.floor(vehicleObj:getZ()) .. ")"
    end)
    -- echoConsole=false, forceConsole=false: nunca echa no console
    local tag  = "{VEH:" .. tostring(sqlid) .. "} "
    local msg  = "COORD_SYNC | player '" .. username .. "' | coords " .. coords ..
                 " | source=" .. tostring(source or "unknown")
    local lvl  = "INFO"
    if sv.EnablePerVehicleLogs ~= false then
        _write(_vpath(sqlid), lvl, tag .. msg, false, false)
    end
    _write(_globalPath(), lvl, tag .. msg, false, false)
end

-- ============================================================
-- Hooks de eventos vanilla (servidor)
-- ============================================================

local function _getSQLID(vehicleObj)
    if not vehicleObj then return nil end
    local ok, id = pcall(function() return PV.getVehicleID(vehicleObj) end)
    return ok and id or nil
end

local function _getUser(playerObj)
    if not playerObj then return "UNKNOWN" end
    local ok, name = pcall(function() return playerObj:getUsername() end)
    return (ok and name) or "UNKNOWN"
end

local function PV_LogVanillaVehicleCommands(module, command, player, args)
    if not PV.dbByVehicleSQLID then return end
    if module ~= "vehicle" then return end

    local u = _getUser(player)

    if command == "attachTrailer" then
        local vehicleA = args and getVehicleById(args.vehicleA or args.vehicleId or args.id)
        local vehicleB = args and getVehicleById(args.vehicleB or args.trailerVehicleId or args.trailer)
        local sidA = _getSQLID(vehicleA)
        local sidB = _getSQLID(vehicleB)
        local claimedA = sidA and PV.getVehicleDBEntry(sidA)
        local claimedB = sidB and PV.getVehicleDBEntry(sidB)
        if not claimedA and not claimedB then return end

        if claimedA then
            PV.Log.writeVehicle(sidA,
                "ATTACH_TRAILER | player '" .. u .. "' | trailerSQLID=" .. tostring(sidB or "?"), "EVENT")
        end
        if claimedB then
            PV.Log.writeVehicle(sidB,
                "ATTACHED_AS_TRAILER | by '" .. u .. "' | towSQLID=" .. tostring(sidA or "?"), "EVENT")
        end
        return
    elseif command == "detachTrailer" then
        local vehicle = args and getVehicleById(args.vehicle or args.vehicleId or args.id)
        local sid = _getSQLID(vehicle)
        if not sid or not PV.getVehicleDBEntry(sid) then return end

        local trailer = vehicle and vehicle:getVehicleTowing() or nil
        local trailerSid = _getSQLID(trailer) or "?"
        PV.Log.writeVehicle(sid,
            "DETACH_TRAILER | player '" .. u .. "' | trailerSQLID=" .. tostring(trailerSid), "EVENT")
        if trailer and trailerSid ~= "?" and PV.getVehicleDBEntry(trailerSid) then
            PV.Log.writeVehicle(trailerSid,
                "DETACHED_AS_TRAILER | by '" .. u .. "' | towSQLID=" .. tostring(sid), "EVENT")
        end
        return
    end

    local vid  = args and (args.vehicleId or args.vehicle or args.id or args.vehicleA)
    local vobj = vid and getVehicleById(vid)
    local sid  = _getSQLID(vobj)
    if not sid or not PV.getVehicleDBEntry(sid) then return end

    if command == "partInstalled" then
        PV.Log.writeVehicle(sid,
            "INSTALL_PART | player '" .. u .. "' | partId=" ..
            tostring((args and args.partId) or "?"), "EVENT")

    elseif command == "partUninstalled" then
        PV.Log.writeVehicle(sid,
            "REMOVE_PART | player '" .. u .. "' | partId=" ..
            tostring((args and args.partId) or "?"), "EVENT")

    elseif command == "getIn" or command == "enterVehicle" then
        PV.Log.writeVehicle(sid,
            "ENTER_VEHICLE | player '" .. u .. "' | seat=" ..
            tostring((args and (args.seat or args.seatIndex)) or "?"), "EVENT")

    elseif command == "getOut" or command == "exitVehicle" then
        PV.Log.writeVehicle(sid,
            "EXIT_VEHICLE | player '" .. u .. "'", "EVENT")

    elseif command == "repairPart" or command == "fixFlat" then
        PV.Log.writeVehicle(sid,
            "REPAIR_PART | player '" .. u .. "' | partId=" ..
            tostring((args and (args.part or args.partId)) or "?"), "EVENT")
    end
end

Events.OnClientCommand.Add(PV_LogVanillaVehicleCommands)
