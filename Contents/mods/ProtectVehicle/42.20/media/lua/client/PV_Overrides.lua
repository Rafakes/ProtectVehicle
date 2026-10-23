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
    -- O capô do motor (EngineDoor) é aberto como parte do fluxo de mecânica;
    -- permitir se o jogador tem AllowViewMechanics para evitar falsa mensagem de bloqueio.
    local partId = part.getId and part:getId()
    if partId == "EngineDoor" then
        return PV_canUseFlag(character, vehicle, "AllowOpeningDoors")
            or PV_canUseFlag(character, vehicle, "AllowDrive")
            or PV_canUseFlag(character, vehicle, "AllowPassenger")
            or PV_canUseFlag(character, vehicle, "AllowViewMechanics")
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

-- Deep guards: isValid + perform for ISAttachTrailerToVehicle
-- Catches mods (e.g. PZK cars) that create the action bypassing onAttachTrailer.
if ISAttachTrailerToVehicle then
    if ISAttachTrailerToVehicle.isValid and not PV._oISAttachTrailerToVehicle_isValid then
        PV._oISAttachTrailerToVehicle_isValid = ISAttachTrailerToVehicle.isValid
        function ISAttachTrailerToVehicle:isValid()
            if not PV_canTowPair(self.character, self.vehicleA, self.vehicleB) then
                return false
            end
            return PV._oISAttachTrailerToVehicle_isValid(self)
        end
    end
    if ISAttachTrailerToVehicle.perform and not PV._oISAttachTrailerToVehicle_perform then
        PV._oISAttachTrailerToVehicle_perform = ISAttachTrailerToVehicle.perform
        function ISAttachTrailerToVehicle:perform()
            if not PV_canTowPair(self.character, self.vehicleA, self.vehicleB) then
                PV_showNoPermission(self.character)
                ISBaseTimedAction.perform(self)
                return
            end
            PV._oISAttachTrailerToVehicle_perform(self)
        end
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
        -- Resolve vehicleB (the trailer/vehicle to be towed) early so PV_canTowPair
        -- can check both sides. Even if nil, PV_canTowPair still checks vehicleA.
        local vehicleB = nil
        local square = vehicle and vehicle:getCurrentSquare()
        if square and ISVehicleTrailerUtils and ISVehicleTrailerUtils.getTowableVehicleNear then
            vehicleB = ISVehicleTrailerUtils.getTowableVehicleNear(square, vehicle, attachmentA, attachmentB)
        end
        -- NOTE: do NOT guard with "vehicleB and" — we must always check permission
        -- on the towing vehicle (vehicleA) even when vehicleB is not yet known.
        if not PV_canTowPair(playerObj, vehicle, vehicleB) then
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
-- PZK VanillaPlusCarPack tow/winch hooks (TAHookAttachVehicle)
-- O mod PZK usa sua própria timed action (TAHookAttachVehicle) e não
-- ISAttachTrailerToVehicle, então precisamos de hooks separados.
-- ============================================================
local function PV_HookPZKTow()
    -- 1) Bloquear no entry point do menu antes de enfileirar qualquer ação
    if TowTruckMod and TowTruckMod.Hook and TowTruckMod.Hook.attachTowTruckAction
       and not PV._oPZK_attachTowTruckAction then
        PV._oPZK_attachTowTruckAction = TowTruckMod.Hook.attachTowTruckAction
        TowTruckMod.Hook.attachTowTruckAction = function(playerObj, towingVehicle, towedVehicle, ...)
            if not PV_canTowPair(playerObj, towingVehicle, towedVehicle) then
                PV_showNoPermission(playerObj)
                return
            end
            return PV._oPZK_attachTowTruckAction(playerObj, towingVehicle, towedVehicle, ...)
        end
    end

    -- 2) Deep guards na timed action TAHookAttachVehicle
    if TAHookAttachVehicle then
        if TAHookAttachVehicle.isValid and not PV._oPZK_TAHookAttach_isValid then
            PV._oPZK_TAHookAttach_isValid = TAHookAttachVehicle.isValid
            function TAHookAttachVehicle:isValid()
                if not PV_canTowPair(self.character, self.vehicleA, self.vehicleB) then
                    return false
                end
                return PV._oPZK_TAHookAttach_isValid(self)
            end
        end
        if TAHookAttachVehicle.perform and not PV._oPZK_TAHookAttach_perform then
            PV._oPZK_TAHookAttach_perform = TAHookAttachVehicle.perform
            function TAHookAttachVehicle:perform()
                if not PV_canTowPair(self.character, self.vehicleA, self.vehicleB) then
                    PV_showNoPermission(self.character)
                    ISBaseTimedAction.perform(self)
                    return
                end
                PV._oPZK_TAHookAttach_perform(self)
            end
        end
    end
end
Events.OnGameStart.Add(PV_HookPZKTow)

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
-- AllowScrapVehicle Ã¢â‚¬â€ trÃƒÂªs camadas de proteÃƒÂ§ÃƒÂ£o
--
-- Camada 1: ISVehicleMenu.onVehicleSalvage (VRO B42)
--   Ponto de entrada do scrap no Vehicle Repair Overhaul.
--   ISVehicleSalvage ÃƒÂ© a timed action real usada pelo VRO no B42.
--
-- Camada 2: ISVehicleSalvage.isValid + perform (deep guard VRO)
--   Bloqueia durante a execuÃƒÂ§ÃƒÂ£o mesmo que o menu seja bypassado.
--
-- Camada 3: ISScrapVehicle (vanilla fallback)
--   Mantido para compatibilidade sem VRO.
-- ============================================================

-- Camada 1 + 2: VRO Ã¢â‚¬â€ ISVehicleMenu.onVehicleSalvage + ISVehicleSalvage
-- Hook aplicado via Events.OnGameStart para garantir que VRO jÃƒÂ¡ carregou.
local function PV_HookVROSalvage()
    -- onVehicleSalvage: ponto de entrada do menu context do VRO
    if ISVehicleMenu and ISVehicleMenu.onVehicleSalvage and not PV._oISVehicleMenu_onVehicleSalvage then
        PV._oISVehicleMenu_onVehicleSalvage = ISVehicleMenu.onVehicleSalvage

        function ISVehicleMenu.onVehicleSalvage(playerObj, vehicle, ...)
            if vehicle and not PV_canUseFlag(playerObj, vehicle, "AllowScrapVehicle") then
                if playerObj then
                    playerObj:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
                end
                return
            end
            PV._oISVehicleMenu_onVehicleSalvage(playerObj, vehicle, ...)
        end
    end

    -- ISVehicleSalvage.isValid: bloqueia durante a aÃƒÂ§ÃƒÂ£o (deep guard)
    if ISVehicleSalvage and ISVehicleSalvage.isValid and not PV._oISVehicleSalvage_isValid then
        PV._oISVehicleSalvage_isValid = ISVehicleSalvage.isValid

        function ISVehicleSalvage:isValid()
            if self.vehicle and not PV_canUseFlag(self.character, self.vehicle, "AllowScrapVehicle") then
                return false
            end
            return PV._oISVehicleSalvage_isValid(self)
        end
    end

    -- ISVehicleSalvage.perform: ÃƒÂºltima barreira antes do vehicle:remove
    if ISVehicleSalvage and ISVehicleSalvage.perform and not PV._oISVehicleSalvage_perform then
        PV._oISVehicleSalvage_perform = ISVehicleSalvage.perform

        function ISVehicleSalvage:perform()
            if self.vehicle and not PV_canUseFlag(self.character, self.vehicle, "AllowScrapVehicle") then
                if self.character then
                    self.character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
                end
                ISBaseTimedAction.perform(self)
                return
            end
            PV._oISVehicleSalvage_perform(self)
        end
    end
end

Events.OnGameStart.Add(PV_HookVROSalvage)

-- Camada 3: ISScrapVehicle (vanilla / mods sem VRO)
if ISScrapVehicle then
    if ISScrapVehicle.isValid and not PV._oISScrapVehicle_isValid then
        PV._oISScrapVehicle_isValid = ISScrapVehicle.isValid
        function ISScrapVehicle:isValid()
            if self.vehicle and not PV_canUseFlag(self.character, self.vehicle, "AllowScrapVehicle") then
                return false
            end
            return PV._oISScrapVehicle_isValid(self)
        end
    end

    if ISScrapVehicle.perform and not PV._oISScrapVehicle_perform then
        PV._oISScrapVehicle_perform = ISScrapVehicle.perform
        function ISScrapVehicle:perform()
            if self.vehicle and not PV_canUseFlag(self.character, self.vehicle, "AllowScrapVehicle") then
                if self.character then
                    self.character:setHaloNote(getText("IGUI_PV_NoPermission"), 250, 100, 100, 300)
                end
                ISBaseTimedAction.perform(self)
                return
            end
            PV._oISScrapVehicle_perform(self)
        end
    end
end

-- ============================================================
-- ISInventoryTransferAction override (mover item de container de veÃƒÂ­culo)
-- ============================================================
-- Este override estÃƒÂ¡ em PV_ISInventoryTransferAction.lua

-- ============================================================
-- Bloqueio de abertura de inventÃƒÂ¡rio de veÃƒÂ­culo (context menu "Open")
-- B42: ISVehicleMenu.FillMenuOutsideVehicle adiciona opÃƒÂ§ÃƒÂµes de "Open Trunk",
-- "Search Vehicle" etc. Precisamos filtrar essas opÃƒÂ§ÃƒÂµes para containers
-- bloqueados. Fazemos isso interceptando DEPOIS do original para remover
-- opÃƒÂ§ÃƒÂµes proibidas do context menu.
-- ============================================================
do
    -- Salva referÃƒÂªncia ao original (jÃƒÂ¡ pode ter sido hooked por PV_Client.lua)
    -- Usamos um nome diferente para nÃƒÂ£o conflitar com PV.oFillMenuOutsideVehicle
    local _pvOrigFillMenuFull = ISVehicleMenu.FillMenuOutsideVehicle

    local function _isVehicleContainerAllowed(playerObj, vehicle)
        -- Unclaimed = permitido
        local sqlid = PV.getVehicleID(vehicle)
        if sqlid == nil then return true end
        if PV.dbByVehicleSQLID == nil then return false end
        if PV.getVehicleDBEntry(sqlid) == nil then return true end
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

    -- Palavras-chave para opÃƒÂ§ÃƒÂµes de scrap/salvage no context menu.
    -- "salvage" cobre o texto do VRO (ContextMenu_SalvageVehicle = "Salvage Vehicle").
    -- "scrap" cobre o vanilla e mods sem VRO.
    -- B42 vanilla key: ContextMenu_Mechanics → EN="Mechanics", PTBR="Mecânica"
    -- Build the keyword list from the actual translation at load time so it
    -- always matches regardless of language, then fall back to hardcoded strings.
    local _mechanicsMenuKeywords = { "mechanics", "mechanic" }
    do
        local t = getTextOrNull and getTextOrNull("ContextMenu_Mechanics")
        if t then
            local low = string.lower(t)
            local found = false
            for _, kw in ipairs(_mechanicsMenuKeywords) do
                if kw == low then found = true; break end
            end
            if not found then table.insert(_mechanicsMenuKeywords, low) end
        end
        -- Hardcoded UTF-8 variants as safety net
        table.insert(_mechanicsMenuKeywords, "mec\195\162nica")  -- mecânica
        table.insert(_mechanicsMenuKeywords, "mecanica")
    end

    local function _isMechanicsMenuOption(optText)
        if type(optText) ~= "string" then return false end
        local lower = string.lower(optText)
        for _, kw in ipairs(_mechanicsMenuKeywords) do
            if string.find(lower, kw, 1, true) then return true end
        end
        return false
    end

    local _scrapMenuKeywords = {
        "salvage",      -- VRO: "Salvage Vehicle"
        "scrap",        -- vanilla / outros mods
        "desmanchar",
        "desmontar",
    }

    local function _isScrapMenuOption(optText)
        if type(optText) ~= "string" then return false end
        local lower = string.lower(optText)
        for _, kw in ipairs(_scrapMenuKeywords) do
            if string.find(lower, kw, 1, true) then return true end
        end
        return false
    end

    local function _blockMenuOptions(context, matchFn)
        -- B42: ISContextMenu stores options in context.options (Lua table, 1-indexed).
        -- getOptions() may not exist; fall back to direct field access.
        local options = (context.getOptions and context:getOptions()) or context.options
        if not options then return end
        local sz = options.size and options:size() or #options
        for i = 0, sz - 1 do
            local opt = (options.get and options:get(i)) or options[i + 1]
            if opt then
                local optText = opt.name or (opt.getText and opt:getText()) or ""
                if matchFn(optText) then
                    opt.notAvailable = true
                    if not opt.toolTip then
                        opt.toolTip = ISToolTip:new()
                        opt.toolTip:initialise()
                        opt.toolTip:setVisible(false)
                    end
                    opt.toolTip.description = getText("IGUI_PV_NoPermission")
                end
            end
        end
    end

    function ISVehicleMenu.FillMenuOutsideVehicle(player, context, vehicle, test)
        _pvOrigFillMenuFull(player, context, vehicle, test)

        local playerObj = type(player) == "number" and getSpecificPlayer(player) or player
        if not playerObj or not vehicle then return end

        if not _isVehicleContainerAllowed(playerObj, vehicle) then
            _blockMenuOptions(context, _isContainerMenuOption)
        end

        if not PV_canUseFlag(playerObj, vehicle, "AllowScrapVehicle") then
            _blockMenuOptions(context, _isScrapMenuOption)
        end

        -- NOTE: mechanics is in the radial menu (addSlice), not the context menu.
        -- Blocking is handled via ISVehicleMenu.onMechanic hook below.
    end
end

-- ============================================================
-- Mechanics: hook ISVehicleMenu.onMechanic (radial menu callback)
-- and ISOpenMechanicsUIAction as deep guard.
-- B42: callback is onMechanic (no trailing 's').
-- ============================================================
local function PV_HookMechanicsMenu()
    -- Layer 1: block at radial-menu callback level
    if ISVehicleMenu and ISVehicleMenu.onMechanic and not PV._oISVehicleMenu_onMechanic then
        PV._oISVehicleMenu_onMechanic = ISVehicleMenu.onMechanic

        function ISVehicleMenu.onMechanic(playerObj, vehicle, ...)
            if vehicle and not PV_canUseFlag(playerObj, vehicle, "AllowViewMechanics") then
                PV_showNoPermission(playerObj)
                return
            end
            PV._oISVehicleMenu_onMechanic(playerObj, vehicle, ...)
        end
    end

    -- Layer 2: deep guard on the timed action that actually opens the panel
    if ISOpenMechanicsUIAction and not PV._oISOpenMechanicsUIAction_new then
        PV._oISOpenMechanicsUIAction_new = ISOpenMechanicsUIAction.new

        function ISOpenMechanicsUIAction:new(character, vehicle, ...)
            if vehicle and not PV_canUseFlag(character, vehicle, "AllowViewMechanics") then
                PV_showNoPermission(character)
                return PV_Deny(character)
            end
            return PV._oISOpenMechanicsUIAction_new(self, character, vehicle, ...)
        end
    end
end

Events.OnGameStart.Add(PV_HookMechanicsMenu)
-- Bloqueia o botÃƒÂ£o "Entrar no RV" no menu radial para jogadores
-- sem permissÃƒÂ£o AllowEnterRV no veÃƒÂ­culo protegido.
-- SÃƒÂ³ aplica se o mod RVInterior estiver carregado.
-- ============================================================
local function PV_HookRVMenu()
    if PV._pvHookedRVMenu then return end  -- guard contra duplo-hook (shared/ + client/)
    if not ISVehicleMenu or not ISVehicleMenu.showRadialMenu then return end
    if not VehicleTypes then return end  -- RVInterior nÃƒÂ£o carregado
    PV._pvHookedRVMenu = true

    local RV_originalShowRadialMenu = ISVehicleMenu.showRadialMenu

    function ISVehicleMenu.showRadialMenu(player, ...)
        -- FIX CRÃƒÂTICO: checar permissÃƒÂ£o ANTES de chamar o original.
        -- O original (RVInterior) adiciona o slice de "Entrar no RV" internamente.
        -- Se chamarmos o original primeiro, o slice jÃƒÂ¡ foi adicionado e nÃƒÂ£o hÃƒÂ¡ como remover.
        -- SoluÃƒÂ§ÃƒÂ£o: verificar permissÃƒÂ£o agora e apenas chamar o original se permitido,
        -- ou remover o slice de RV do menu depois (se a API permitir).

        -- B42.16: `player` pode ser IsoPlayer ou ÃƒÂ­ndice numÃƒÂ©rico dependendo da versÃƒÂ£o
        local playerObj, playerNum
        if type(player) == "number" then
            playerNum = player
            playerObj = getSpecificPlayer(player)
        else
            playerObj = player
            playerNum = player:getPlayerNum()
        end

        if not playerObj then
            RV_originalShowRadialMenu(player, ...)
            return
        end

        local vehicle = ISVehicleMenu.getVehicleToInteractWith(playerObj)
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

        -- É RV: verificar permissão PV
        local allowed = true
        if PV and PV.canEnterRV then
            allowed = PV.canEnterRV(playerObj, vehicle)
        end

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

            else
                return
            end
        end
    end
end

-- Hook depois que o mundo inicia (garante que VehicleTypes jÃƒÂ¡ foi carregado pelo RVInterior)
Events.OnInitWorld.Add(PV_HookRVMenu)

