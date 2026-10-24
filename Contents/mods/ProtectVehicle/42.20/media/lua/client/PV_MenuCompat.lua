--[[
    ProtectVehicle - PV_MenuCompat.lua
    Compatibilidade de menu com outros mods de veículo (motos, carros custom etc.).

    PROBLEMA:
    As opções do ProtectVehicle ("Reivindicar Veículo" / "Gerenciar Veículo") e os
    bloqueios de container/scrap eram adicionados apenas dentro do override de
    ISVehicleMenu.FillMenuOutsideVehicle (client/PV_Client.lua e client/PV_Overrides.lua).

    Mods de veículo que:
      a) substituem ISVehicleMenu.FillMenuOutsideVehicle sem chamar a função anterior,
      b) chamam a anterior só para os veículos deles e dão return antes para os outros,
      c) montam o próprio menu para um tipo de veículo (ex.: motos),
    fazem com que o ProtectVehicle nunca rode naquele veículo. Resultado: a moto não
    aparece com opção de reivindicar/gerenciar (logo, as permissões não podem ser
    alteradas) e os bloqueios de permissão não são aplicados no menu dela.

    SOLUÇÃO:
    Injetar as mesmas opções e os mesmos bloqueios via Events.OnFillWorldObjectContextMenu,
    que é um evento do jogo e não pode ser sobrescrito por outro mod. Só roda quando o
    caminho normal (FillMenuOutsideVehicle) não rodou naquele menu, então nada duplica.
    B42.20
--]]

if not isClient() and isServer() then return end

PV = PV or {}

-- Distância máxima (tiles) entre jogador e veículo para considerar o clique válido.
local PV_MENU_MAX_DIST = 8

-- ============================================================
-- Detecção do veículo clicado (espelha o que o jogo faz em
-- ISWorldObjectContextMenu.createMenu antes de chamar FillMenuOutsideVehicle)
-- ============================================================
local function PV_vehicleFromObject(obj)
    if not obj then return nil end

    local ok, isVehicle = pcall(instanceof, obj, "BaseVehicle")
    if ok and isVehicle then return obj end

    if obj.getVehicle then
        local okV, v = pcall(function() return obj:getVehicle() end)
        if okV and v then return v end
    end

    if obj.getSquare then
        local okS, sq = pcall(function() return obj:getSquare() end)
        if okS and sq and sq.getVehicleContainer then
            local okC, v = pcall(function() return sq:getVehicleContainer() end)
            if okC and v then return v end
        end
    end

    return nil
end

-- Só considera veículo o que foi realmente clicado (mesmo critério do jogo em
-- ISWorldObjectContextMenu.createMenu). Não usar o veículo "mais próximo" aqui:
-- isso faria as opções do PV aparecerem ao clicar em qualquer coisa perto de um carro.
local function PV_findContextVehicle(worldObjects)
    if type(worldObjects) ~= "table" then return nil end
    for _, obj in ipairs(worldObjects) do
        local v = PV_vehicleFromObject(obj)
        if v then return v end
    end
    return nil
end

-- ============================================================
-- Rede de segurança: se as opções do PV já estão no menu (mesmo sem a
-- flag de contexto), não adiciona de novo.
-- ============================================================
local function PV_contextHasPVOption(context)
    local options = (context.getOptions and context:getOptions()) or context.options
    if not options then return false end

    local labels = {}
    local function addLabel(key)
        local t = getTextOrNull and getTextOrNull(key) or nil
        if t then labels[string.lower(t)] = true end
    end
    addLabel("IGUI_PV_ContextMenu_ClaimVehicle")
    addLabel("IGUI_PV_ContextMenu_UnclaimVehicle")
    addLabel("IGUI_PV_ContextMenu_ManageVehicle")

    local sz = options.size and options:size() or #options
    for i = 0, sz - 1 do
        local opt = (options.get and options:get(i)) or options[i + 1]
        if opt then
            local txt = opt.name or (opt.getText and opt:getText()) or ""
            if type(txt) == "string" and labels[string.lower(txt)] then return true end
        end
    end
    return false
end

-- ============================================================
-- Injeção tardia (roda depois de todo o resto do menu já montado)
-- ============================================================
local function PV_InjectVehicleMenu(player, context, worldObjects, test)
    if not context or not context.addOption then return end

    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    -- Dentro do veículo o jogo usa FillMenuInsideVehicle; o PV não adiciona opções lá.
    if playerObj:getVehicle() then return end

    -- Caminho normal já rodou neste menu: nada a fazer.
    if context.pvVehicleOptionsAdded and context.pvMenuBlocksApplied then return end

    local vehicle = PV_findContextVehicle(worldObjects)
    if not vehicle then return end
    if playerObj:DistTo(vehicle:getX(), vehicle:getY()) > PV_MENU_MAX_DIST then return end

    local okName, scriptName = pcall(function() return vehicle:getScript():getFullName() end)
    scriptName = tostring(okName and scriptName or "?")

    PV._pvLastMenuPath = "fallback (OnFillWorldObjectContextMenu) - outro mod substituiu o menu do veiculo"
    PV._pvLastMenuVehicle = scriptName

    local sv = SandboxVars.ProtectVehicle
    if sv and sv.EnableVerboseConsoleLogs then
        print("[PV] MenuCompat: FillMenuOutsideVehicle nao rodou para '" .. scriptName ..
              "' (outro mod substituiu o menu). Injetando opcoes do ProtectVehicle.")
    end

    if not context.pvVehicleOptionsAdded and PV.addVehicleContextOptions then
        if not PV_contextHasPVOption(context) then
            local ok, err = pcall(PV.addVehicleContextOptions, playerObj, context, vehicle)
            if not ok then
                print("[PV] MenuCompat: falha ao adicionar opcoes do veiculo: " .. tostring(err))
            end
        end
    end

    if not context.pvMenuBlocksApplied and PV.applyVehicleMenuBlocks then
        local ok, err = pcall(PV.applyVehicleMenuBlocks, playerObj, context, vehicle)
        if not ok then
            print("[PV] MenuCompat: falha ao aplicar bloqueios de menu: " .. tostring(err))
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(PV_InjectVehicleMenu)

-- ============================================================
-- Diagnóstico manual (console de debug):
--   clique com o botão direito no veículo e depois rode PV.diagVehicleMenu()
-- Mostra por qual caminho o menu daquele veículo passou.
-- ============================================================
function PV.diagVehicleMenu()
    local playerObj = getPlayer()
    print("[PV] --- diagVehicleMenu ---")
    print("[PV] ultimo menu de veiculo: " .. tostring(PV._pvLastMenuPath or "nenhum ainda"))
    print("[PV] ultimo veiculo no menu: " .. tostring(PV._pvLastMenuVehicle or "-"))

    local vehicle = nil
    if playerObj and ISVehicleMenu and ISVehicleMenu.getVehicleToInteractWith then
        local ok, v = pcall(ISVehicleMenu.getVehicleToInteractWith, playerObj)
        if ok then vehicle = v end
    end
    if not vehicle then
        print("[PV] nenhum veiculo proximo detectado.")
        return
    end
    local okName, scriptName = pcall(function() return vehicle:getScript():getFullName() end)
    print("[PV] veiculo: " .. tostring(okName and scriptName or "?"))
    print("[PV] SQLID no ModData: " .. tostring(PV.getVehicleID and PV.getVehicleID(vehicle)))
    print("[PV] DB carregado no cliente: " .. tostring(type(PV.dbByVehicleSQLID) == "table"))
end
