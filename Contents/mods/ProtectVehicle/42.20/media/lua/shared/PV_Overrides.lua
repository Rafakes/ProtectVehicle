--[[
    PV_Overrides.lua (client-side)
    Overrides for vanilla vehicle actions.
    Blocks unauthorized interactions using PV permission system.
    B42.14.x
--]]

if not isClient() and isServer() then return end

require "ISUI/ISModalDialog"
require "luautils"
require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISBaseTimedAction"

-- ============================================================
-- Denied timed action (instant, shows halo message)
-- ============================================================
ISPVDeniedTimedAction = ISBaseTimedAction:derive("ISPVDeniedTimedAction")

function ISPVDeniedTimedAction:new(character, msg)
    local o = ISBaseTimedAction.new(self, character)
    o.maxTime = 1
    o.stopOnWalk = false
    o.stopOnRun  = false
    o.stopOnAim  = false
    if msg and character then
        character:setHaloNote(msg, 250, 100, 100, 300)
    end
    return o
end

function ISPVDeniedTimedAction:isValid() return true end
function ISPVDeniedTimedAction:perform() ISBaseTimedAction.perform(self) end
function ISPVDeniedTimedAction:getDuration() return 1 end

local function PV_Deny(character)
    return ISPVDeniedTimedAction:new(character, getText("IGUI_PV_NoPermission"))
end

local function PV_canUseFlag(character, vehicle, flagName)
    return PV.canPerformAction(character, vehicle, flagName)
end

local function PV_showNoPermission(character)
    if character then
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
    end
end

local function PV_canOpenVehiclePart(character, vehicle, part)
    if PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle)) then
        return true
    end
    if not part then return false end
    if PV.isVehiclePartTrunk and PV.isVehiclePartTrunk(part) then
        return PV_canUseFlag(character, vehicle, "AllowOpeningTrunk")
    end
    return PV_canUseFlag(character, vehicle, "AllowOpeningDoors")
        or PV_canUseFlag(character, vehicle, "AllowDrive")
        or PV_canUseFlag(character, vehicle, "AllowPassenger")
end

local function PV_canTowPair(character, vehicleA, vehicleB)
    if not vehicleA then return false end
    local okA = PV_canUseFlag(character, vehicleA, "AllowTow")
    local okB = (vehicleB == nil) or PV_canUseFlag(character, vehicleB, "AllowTow")
    return okA and okB
end

local function PV_isVehicleActionAllowed(character, vehicle, flagName)
    if not vehicle then return true end
    if PV_canUseFlag(character, vehicle, flagName) then
        return true
    end
    PV_showNoPermission(character)
    return false
end

-- ============================================================
-- ISEnterVehicle override
-- ============================================================
if ISEnterVehicle and ISEnterVehicle.new then
    if not PV._oISEnterVehicle then
        PV._oISEnterVehicle = ISEnterVehicle.new
    end

    function ISEnterVehicle:new(character, vehicle, seat)
        -- Determina flag correta pelo assento (0 = motorista, outros = passageiro)
        local flagName = (seat == 0) and "AllowDrive" or "AllowPassenger"
        -- canPerformAction: owner/admin = true, public flag = true, per-player flag = true
        if PV_canUseFlag(character, vehicle, flagName) then
            return PV._oISEnterVehicle(self, character, vehicle, seat)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISSwitchVehicleSeat override
-- ============================================================
if ISSwitchVehicleSeat and ISSwitchVehicleSeat.new then
    if not PV._oISSwitchVehicleSeat then
        PV._oISSwitchVehicleSeat = ISSwitchVehicleSeat.new
    end

    function ISSwitchVehicleSeat:new(character, seatTo)
        if not character:getVehicle() then
            return PV._oISSwitchVehicleSeat(self, character, seatTo)
        end
        local veh = character:getVehicle()
        local flagName = (seatTo == 0) and "AllowDrive" or "AllowPassenger"
        if PV_canUseFlag(character, veh, flagName) then
            return PV._oISSwitchVehicleSeat(self, character, seatTo)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISOpenVehicleDoor override
-- ============================================================
if ISVehicleMenu and ISVehicleMenu.FillMenuOutsideVehicle then
    local oldNew = ISOpenVehicleDoor.new

    local function isTrunkPart(part)
        return PV.isVehiclePartTrunk(part)
    end

    function ISOpenVehicleDoor:new(character, vehicle, part)
        if not part or not instanceof(part, "VehiclePart") then
            return oldNew(self, character, vehicle, part)
        end
        if PV_canOpenVehiclePart(character, vehicle, part) then
            return oldNew(self, character, vehicle, part)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISAttachTrailerToVehicle override (tow)
-- ============================================================
if ISAttachTrailerToVehicle and ISAttachTrailerToVehicle.new then
    if not PV._oISAttachTrailerToVehicle then
        PV._oISAttachTrailerToVehicle = ISAttachTrailerToVehicle.new
    end

    function ISAttachTrailerToVehicle:new(character, vehicleA, vehicleB, attachmentA, attachmentB)
        if PV_canTowPair(character, vehicleA, vehicleB) then
            return PV._oISAttachTrailerToVehicle(self, character, vehicleA, vehicleB, attachmentA, attachmentB)
        end
        PV_showNoPermission(character)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISDetachTrailerFromVehicle override
-- ============================================================
if ISDetachTrailerFromVehicle and ISDetachTrailerFromVehicle.new then
    if not PV._oISDetachTrailerFromVehicle then
        PV._oISDetachTrailerFromVehicle = ISDetachTrailerFromVehicle.new
    end

    function ISDetachTrailerFromVehicle:new(character, vehicle, attachment)
        local ok = PV_canUseFlag(character, vehicle, "AllowTow")
        if ok then
            return PV._oISDetachTrailerFromVehicle(self, character, vehicle, attachment)
        end
        PV_showNoPermission(character)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISVehicleMenu attach/detach overrides
-- Bloqueia antes de enfileirar a timed action vanilla.
-- ============================================================
if ISVehicleMenu and ISVehicleMenu.onAttachTrailer then
    if not PV._oISVehicleMenu_onAttachTrailer then
        PV._oISVehicleMenu_onAttachTrailer = ISVehicleMenu.onAttachTrailer
    end

    function ISVehicleMenu.onAttachTrailer(playerObj, vehicle, attachmentA, attachmentB)
        local square = vehicle and vehicle:getCurrentSquare()
        local vehicleB = nil
        if square and ISVehicleTrailerUtils and ISVehicleTrailerUtils.getTowableVehicleNear then
            vehicleB = ISVehicleTrailerUtils.getTowableVehicleNear(square, vehicle, attachmentA, attachmentB)
        end
        if vehicleB and not PV_canTowPair(playerObj, vehicle, vehicleB) then
            PV_showNoPermission(playerObj)
            return
        end
        return PV._oISVehicleMenu_onAttachTrailer(playerObj, vehicle, attachmentA, attachmentB)
    end
end

if ISVehicleMenu and ISVehicleMenu.onDetachTrailer then
    if not PV._oISVehicleMenu_onDetachTrailer then
        PV._oISVehicleMenu_onDetachTrailer = ISVehicleMenu.onDetachTrailer
    end

    function ISVehicleMenu.onDetachTrailer(playerObj, vehicle, attachmentA)
        if vehicle and not PV_canUseFlag(playerObj, vehicle, "AllowTow") then
            PV_showNoPermission(playerObj)
            return
        end
        return PV._oISVehicleMenu_onDetachTrailer(playerObj, vehicle, attachmentA)
    end
end

-- ============================================================
-- ISTakeGasolineFromVehicle override (siphon fuel)
-- ============================================================
if ISVehicleMenu and ISVehicleMenu.FillMenuOutsideVehicle then
    local oldNew = ISTakeGasolineFromVehicle.new
    function ISTakeGasolineFromVehicle:new(character, part, item, ...)
        local vehicle = part and part:getVehicle()
        local ok = PV_canUseFlag(character, vehicle, "AllowSiphonFuel")
        if ok then
            return oldNew(self, character, part, item, ...)
        end
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISInflateTire override
-- ============================================================
if ISVehicleMenu and ISVehicleMenu.FillMenuOutsideVehicle then
    local oldNew = ISInflateTire.new
    function ISInflateTire:new(character, part, item, psiTarget, ...)
        local vehicle = part and part:getVehicle()
        if not vehicle then return oldNew(self, character, part, item, psiTarget, ...) end
        local ok = PV_canUseFlag(character, vehicle, "AllowInflateTires")
        if ok then
            return oldNew(self, character, part, item, psiTarget, ...)
        end
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISDeflateTire override
-- ============================================================
if ISVehicleMenu and ISVehicleMenu.FillMenuOutsideVehicle then
    local oldNew = ISDeflateTire.new
    function ISDeflateTire:new(character, part, psiTarget, ...)
        local vehicle = part and part:getVehicle()
        local ok = PV_canUseFlag(character, vehicle, "AllowDeflateTires")
        if ok then
            return oldNew(self, character, part, psiTarget, ...)
        end
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISSmashVehicleWindow override
-- ============================================================
if ISSmashVehicleWindow and ISSmashVehicleWindow.new then
    if not PV._oISSmashVehicleWindow then
        PV._oISSmashVehicleWindow = ISSmashVehicleWindow.new
    end

    function ISSmashVehicleWindow:new(character, part, open)
        local vehicle = part and part.getVehicle and part:getVehicle()
        if not vehicle then return PV._oISSmashVehicleWindow(self, character, part, open) end
        if PV.getSimpleBooleanPermission(PV.checkPermission(character, vehicle)) then
            return PV._oISSmashVehicleWindow(self, character, part, open)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISVehicleMechanics.onUninstallPart override
-- ============================================================
if ISVehicleMechanics and ISVehicleMechanics.onUninstallPart then
    local oldFn = ISVehicleMechanics.onUninstallPart
    function ISVehicleMechanics.onUninstallPart(playerObj, part, item)
        local vehicle = part and part:getVehicle()
        local ok = PV_canUseFlag(playerObj, vehicle, "AllowUninstallParts")
        if not ok then
            playerObj:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
            return
        end
        oldFn(playerObj, part, item)
    end
end

-- ============================================================
-- ISVehiclePartMenu.onUninstallPart override
-- ============================================================
if ISVehiclePartMenu and ISVehiclePartMenu.onUninstallPart then
    local oldFn = ISVehiclePartMenu.onUninstallPart
    function ISVehiclePartMenu.onUninstallPart(playerObj, part, item)
        local vehicle = part and part:getVehicle()
        local ok = PV_canUseFlag(playerObj, vehicle, "AllowUninstallParts")
        if not ok then
            playerObj:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
            return
        end
        oldFn(playerObj, part, item)
    end
end

-- ============================================================
-- ISVehicleMechanics.onTakeEngineParts override
-- ============================================================
if ISVehicleMechanics and ISVehicleMechanics.onTakeEngineParts then
    local oldFn = ISVehicleMechanics.onTakeEngineParts
    function ISVehicleMechanics.onTakeEngineParts(playerObj, part)
        local vehicle = part and part:getVehicle()
        local ok = PV_canUseFlag(playerObj, vehicle, "AllowTakeEngineParts")
        if not ok then
            playerObj:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
            return
        end
        oldFn(playerObj, part)
    end
end

-- ============================================================
-- Deep timed-action guards for mechanics/fuel/tires
-- Rechecks permission inside the action before mutation happens.
-- ============================================================
if ISUninstallVehiclePart and ISUninstallVehiclePart.isValid then
    if not PV._oISUninstallVehiclePart_isValid then
        PV._oISUninstallVehiclePart_isValid = ISUninstallVehiclePart.isValid
    end
    if not PV._oISUninstallVehiclePart_complete then
        PV._oISUninstallVehiclePart_complete = ISUninstallVehiclePart.complete
    end

    function ISUninstallVehiclePart:isValid()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowUninstallParts") then
            return false
        end
        return PV._oISUninstallVehiclePart_isValid(self)
    end

    function ISUninstallVehiclePart:complete()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowUninstallParts") then
            return false
        end
        return PV._oISUninstallVehiclePart_complete(self)
    end
end

if ISTakeEngineParts and ISTakeEngineParts.isValid then
    if not PV._oISTakeEngineParts_isValid then
        PV._oISTakeEngineParts_isValid = ISTakeEngineParts.isValid
    end
    if not PV._oISTakeEngineParts_complete then
        PV._oISTakeEngineParts_complete = ISTakeEngineParts.complete
    end

    function ISTakeEngineParts:isValid()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowTakeEngineParts") then
            return false
        end
        return PV._oISTakeEngineParts_isValid(self)
    end

    function ISTakeEngineParts:complete()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowTakeEngineParts") then
            return false
        end
        return PV._oISTakeEngineParts_complete(self)
    end
end

if ISTakeGasolineFromVehicle and ISTakeGasolineFromVehicle.isValid then
    if not PV._oISTakeGasolineFromVehicle_isValid then
        PV._oISTakeGasolineFromVehicle_isValid = ISTakeGasolineFromVehicle.isValid
    end
    if not PV._oISTakeGasolineFromVehicle_complete then
        PV._oISTakeGasolineFromVehicle_complete = ISTakeGasolineFromVehicle.complete
    end

    function ISTakeGasolineFromVehicle:isValid()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowSiphonFuel") then
            return false
        end
        return PV._oISTakeGasolineFromVehicle_isValid(self)
    end

    function ISTakeGasolineFromVehicle:complete()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowSiphonFuel") then
            return false
        end
        return PV._oISTakeGasolineFromVehicle_complete(self)
    end
end

if ISInflateTire and ISInflateTire.isValid then
    if not PV._oISInflateTire_isValid then
        PV._oISInflateTire_isValid = ISInflateTire.isValid
    end
    if not PV._oISInflateTire_complete then
        PV._oISInflateTire_complete = ISInflateTire.complete
    end

    function ISInflateTire:isValid()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowInflateTires") then
            return false
        end
        return PV._oISInflateTire_isValid(self)
    end

    function ISInflateTire:complete()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowInflateTires") then
            return false
        end
        return PV._oISInflateTire_complete(self)
    end
end

if ISDeflateTire and ISDeflateTire.isValid then
    if not PV._oISDeflateTire_isValid then
        PV._oISDeflateTire_isValid = ISDeflateTire.isValid
    end
    if not PV._oISDeflateTire_complete then
        PV._oISDeflateTire_complete = ISDeflateTire.complete
    end

    function ISDeflateTire:isValid()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowDeflateTires") then
            return false
        end
        return PV._oISDeflateTire_isValid(self)
    end

    function ISDeflateTire:complete()
        local vehicle = (self.part and self.part:getVehicle()) or self.vehicle
        if not PV_isVehicleActionAllowed(self.character, vehicle, "AllowDeflateTires") then
            return false
        end
        return PV._oISDeflateTire_complete(self)
    end
end

-- ============================================================
-- ISScrapVehicle override (AllowScrapVehicle)
-- B42: ISScrapVehicle ÃƒÂ© a timed action de desmanchar veÃƒÂ­culo.
-- Bloqueia o desmancho para quem nÃƒÂ£o tem permissÃƒÂ£o.
-- ============================================================
if ISScrapVehicle and ISScrapVehicle.new then
    if not PV._oISScrapVehicle then
        PV._oISScrapVehicle = ISScrapVehicle.new
    end

    function ISScrapVehicle:new(character, vehicle, ...)
        -- VeÃƒÂ­culo nÃƒÂ£o identificado: deixa passar (seguro)
        if not vehicle then
            return PV._oISScrapVehicle(self, character, vehicle, ...)
        end
        local ok = PV_canUseFlag(character, vehicle, "AllowScrapVehicle")
        if ok then
            return PV._oISScrapVehicle(self, character, vehicle, ...)
        end
        character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
        return PV_Deny(character)
    end
end

-- ============================================================
-- ISInventoryTransferAction override (mover item de container de veÃƒÂ­culo)
-- ============================================================
-- Este override estÃƒÂ¡ em PV_ISInventoryTransferAction.lua

-- ============================================================
-- REMOVIDO: FillMenuOutsideVehicle hook movido para client/PV_Overrides.lua.
-- shared/ carrega antes de ISVehicleMenu existir, causando crash ao conectar.
-- ============================================================
--[[ REMOVIDO - ver client/PV_Overrides.lua
do
    local _pvOrigFillMenuFull = ISVehicleMenu.FillMenuOutsideVehicle

    local function _isVehicleContainerAllowed(playerObj, vehicle)
        -- Unclaimed = permitido
        local sqlid = PV.getVehicleID(vehicle)
        if sqlid == nil then return true end
        if PV.dbByVehicleSQLID == nil then return false end
        if PV.dbByVehicleSQLID[sqlid] == nil then return true end
        -- canPerformAction para AllowContainersAccess
        return PV_canUseFlag(playerObj, vehicle, "AllowContainersAccess")
    end

    -- Palavras-chave dos textos de menu que abrem containers (inglÃƒÂªs + portuguÃƒÂªs)
    -- Cobrimos "Open", "Search", "Loot", "Take All" referentes a partes do veÃƒÂ­culo
    local _containerMenuKeywords = {
        "open",         -- Open Trunk, Open Door (pode levar ao inventÃƒÂ¡rio)
        "search",       -- Search Vehicle
        "loot",         -- Loot All
        "take all",     -- Take All Items
        "pegar tudo",
        "abrir",
        "pesquisar",
        "saquear",
    }

    local function _isContainerMenuOption(optText)
        if type(optText) ~= "string" then return false end
        local lower = string.lower(optText)
        for _, kw in ipairs(_containerMenuKeywords) do
            if string.find(lower, kw, 1, true) then return true end
        end
        return false
    end

    function ISVehicleMenu.FillMenuOutsideVehicle(player, context, vehicle, test)
        _pvOrigFillMenuFull(player, context, vehicle, test)

        local playerObj = type(player) == "number" and getSpecificPlayer(player) or player
        if not playerObj or not vehicle then return end

        -- Se o jogador tem permissÃƒÂ£o para containers, nÃƒÂ£o precisa filtrar
        if _isVehicleContainerAllowed(playerObj, vehicle) then return end

        -- Sem permissÃƒÂ£o: remover opÃƒÂ§ÃƒÂµes de container do menu
        -- B42: context:getOptions() retorna ArrayList Java
        local options = context.getOptions and context:getOptions()
        if not options then return end

        local toRemove = {}
        local sz = options.size and options:size() or #options
        for i = 0, sz - 1 do
            local opt = options.get and options:get(i) or options[i + 1]
            if opt then
                local optText = opt.name or (opt.getText and opt:getText()) or ""
                if _isContainerMenuOption(optText) then
                    table.insert(toRemove, opt)
                end
            end
        end

        for _, opt in ipairs(toRemove) do
            -- Marcar como nÃƒÂ£o disponÃƒÂ­vel em vez de remover (mais seguro na B42)
            opt.notAvailable = true
            opt.toolTip = opt.toolTip or ISToolTip:new()
            opt.toolTip.description = getText("IGUI_PV_NoPermission")
        end
    end
end
--]] -- fim do bloco removido
-- NOTE: PV_HookRVMenu foi movido para client/PV_Overrides.lua para evitar
-- duplo-hook (shared/ carrega antes de client/, gerando conflito com outros mods).
-- ============================================================
--[[ REMOVIDO - ver client/PV_Overrides.lua
local function PV_HookRVMenu()
    if not ISVehicleMenu or not ISVehicleMenu.showRadialMenu then return end
    if not VehicleTypes then return end  -- RVInterior nÃƒÂ£o carregado

    local RV_originalShowRadialMenu = ISVehicleMenu.showRadialMenu

    function ISVehicleMenu.showRadialMenu(player, ...)
        -- FIX CRÃƒÂTICO: checar permissÃƒÂ£o ANTES de chamar o original.
        -- O original (RVInterior) adiciona o slice de "Entrar no RV" internamente.
        -- Se chamarmos o original primeiro, o slice jÃƒÂ¡ foi adicionado e nÃƒÂ£o hÃƒÂ¡ como remover.
        -- SoluÃƒÂ§ÃƒÂ£o: verificar permissÃƒÂ£o agora e apenas chamar o original se permitido,
        -- ou remover o slice de RV do menu depois (se a API permitir).

        -- B42: `player` ÃƒÂ© ÃƒÂ­ndice numÃƒÂ©rico (0, 1...), nÃƒÂ£o IsoPlayer
        local playerObj = getSpecificPlayer(player)
        if not playerObj then
            RV_originalShowRadialMenu(player, ...)
            return
        end

        local vehicle = ISVehicleMenu.getVehicleToInteractWith(player)
        if not vehicle then
            RV_originalShowRadialMenu(player, ...)
            return
        end

        -- Verificar se ÃƒÂ© veÃƒÂ­culo RV
        local vehicleScriptName = tostring(vehicle:getScript():getFullName())
        local isRVVehicle = false
        for _, def in pairs(VehicleTypes) do
            if def.scripts then
                for _, s in ipairs(def.scripts) do
                    if s == vehicleScriptName then
                        isRVVehicle = true
                        break
                    end
                end
            end
            if isRVVehicle then break end
        end

        -- NÃƒÂ£o ÃƒÂ© RV: chama original normalmente
        if not isRVVehicle then
            RV_originalShowRadialMenu(player, ...)
            return
        end

        -- Ãƒâ€° RV: verificar permissÃƒÂ£o PV
        local allowed = (PV and PV.canEnterRV) and PV.canEnterRV(playerObj, vehicle) or true

        if allowed then
            -- PermissÃƒÂ£o concedida: chama original (ele adiciona o slice de RV)
            RV_originalShowRadialMenu(player, ...)
        else
            -- BLOQUEADO: precisamos chamar o original mas sem o slice de RV.
            -- EstratÃƒÂ©gia: substituir temporariamente a funÃƒÂ§ÃƒÂ£o de addSlice de RV para ser no-op,
            -- depois restaurar. Isso previne que o RVInterior adicione o slice.
            local menu = getPlayerRadialMenu and getPlayerRadialMenu(playerObj:getPlayerNum())
            if menu and menu.addSlice then
                local originalAddSlice = menu.addSlice
                local blocked = false
                -- Interceptar chamadas de addSlice que sejam do RV (texto identificador)
                menu.addSlice = function(m, label, texture, fn, ...)
                    -- Identificar slice do RV pelo texto de traduÃƒÂ§ÃƒÂ£o
                    local rvLabel = getText and getText("ContextMenu_GetInToRV") or "GetInToRV"
                    if label == rvLabel then
                        blocked = true
                        return -- descarta o slice
                    end
                    return originalAddSlice(m, label, texture, fn, ...)
                end

                RV_originalShowRadialMenu(player, ...)

                -- Restaurar addSlice original
                menu.addSlice = originalAddSlice

                if blocked then
                    playerObj:setHaloNote(getText("IGUI_PV_NoPermission_RV"), 250, 100, 100, 300)
                end
            else
                playerObj:setHaloNote(getText("IGUI_PV_NoPermission_RV"), 250, 100, 100, 300)
                return
            end
        end
    end
end

-- Hook depois que o mundo inicia (garante que VehicleTypes já foi carregado pelo RVInterior)
Events.OnInitWorld.Add(PV_HookRVMenu)
--]] -- fim do bloco removido

