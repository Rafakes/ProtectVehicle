--[[
    ProtectVehicle - PV_Notices.lua
    Caixa de avisos do dono (lado servidor).
    B42.x - Multiplayer.

    POR QUE ISSO EXISTE
    -------------------
    Todo aviso do mod era setHaloNote: texto que aparece na tela e morre.
    Se o dono nao estiver conectado no segundo exato do evento, o aviso nao
    existe em lugar nenhum que ele possa ler depois. Na pratica o dono nunca
    descobria o que aconteceu com o carro dele enquanto estava fora - e dois
    eventos (claim expirado por inatividade e unclaim feito por staff) nunca
    chegavam a ele nem estando online, so ficavam no log do servidor.

    Este modulo guarda esses eventos por jogador e entrega no logon.

    ONDE FICA
    ---------
    ModData global "PVNotices". O cliente NUNCA pede essa chave: cada jogador
    recebe apenas a propria lista, pelo comando direcionado "pvNotices".
    Ver a ressalva de privacidade no README: um cliente modificado consegue
    pedir qualquer ModData global, e isso ja valia para PVByVehicleSQLID.

    FORMATO DE UM AVISO
    -------------------
    { t = timestamp, key = "IGUI_PV_Notice_*", p1 = "", p2 = "",
      n = <quantas vezes>, gk = "<chave de agrupamento>", read = bool }

    Guardamos a CHAVE de traducao, nao a frase montada: assim o aviso sai no
    idioma de quem le, e nao no de quem estava logado quando o evento ocorreu.

    Mais novo no FIM da lista (append). Quem desenha inverte.
--]]

-- Mesmo guard dos outros arquivos de server do mod (PV_Server, PV_VehicleLogs):
-- carregar so no servidor, senao metade do modulo existiria sem a outra.
if not isServer() then return end

PV = PV or {}
PV.Notices = PV.Notices or {}

local MODDATA_KEY = "PVNotices"

-- ============================================================
-- Opcoes
-- ============================================================
local function optEnabled()
    local sv = SandboxVars.ProtectVehicle
    return not (sv and sv.NoticesEnabled == false)
end

local function optMaxPerPlayer()
    local sv = SandboxVars.ProtectVehicle
    local v = tonumber(sv and sv.NoticeMaxPerPlayer) or 50
    if v < 5 then v = 5 end
    if v > 200 then v = 200 end
    return v
end

local function optRetentionSeconds()
    local sv = SandboxVars.ProtectVehicle
    local v = tonumber(sv and sv.NoticeRetentionDays) or 30
    if v < 1 then v = 1 end
    return v * 86400
end

local function optGroupSeconds()
    local sv = SandboxVars.ProtectVehicle
    local v = tonumber(sv and sv.NoticeGroupMinutes) or 10
    if v < 1 then v = 1 end
    return v * 60
end

-- ============================================================
-- Acesso ao armazenamento
--
-- A tabela se chama PV.noticeStore, e nao PV.notices, de proposito: do lado
-- cliente PV.notices e a lista do proprio jogador, e num servidor-host o
-- cliente e o servidor rodam no MESMO estado Lua. Com o mesmo nome, duas
-- estruturas de formato diferente se sobrescreveriam.
-- ============================================================
function PV.Notices.ensureStore()
    if type(PV.noticeStore) == "table" then return PV.noticeStore end

    if ModData and ModData.exists and not ModData.exists(MODDATA_KEY) then
        ModData.create(MODDATA_KEY)
        ModData.add(MODDATA_KEY, {})
    end

    local store = ModData and ModData.get and ModData.get(MODDATA_KEY) or nil
    if type(store) ~= "table" then
        store = {}
        if ModData and ModData.add then ModData.add(MODDATA_KEY, store) end
    end

    PV.noticeStore = store
    return PV.noticeStore
end

local function persist()
    if ModData and ModData.add and type(PV.noticeStore) == "table" then
        ModData.add(MODDATA_KEY, PV.noticeStore)
    end
end

--- Lista crua de um jogador. Nao cria entrada se nao existir.
local function listOf(username)
    local store = PV.Notices.ensureStore()
    local rec = store[username]
    if type(rec) ~= "table" then return nil end
    return rec
end

-- ============================================================
-- Limpeza: valida formato, aplica validade e teto
--
-- O ModData volta do disco como JSON, entao nada aqui pode confiar no tipo:
-- um save antigo ou editado a mao pode trazer qualquer coisa.
-- ============================================================
local function pruneList(username)
    local list = listOf(username)
    if not list then return nil end

    local now = getTimestamp()
    local maxAge = optRetentionSeconds()

    -- 1. Descarta entrada malformada e fora da validade.
    local kept = {}
    for i = 1, #list do
        local it = list[i]
        if type(it) == "table" and type(it.key) == "string" then
            local t = tonumber(it.t) or 0
            if t > 0 and (now - t) <= maxAge then
                it.t = t
                it.n = tonumber(it.n) or 1
                it.read = (it.read == true)
                kept[#kept + 1] = it
            end
        end
    end

    -- 2. Teto por jogador: o mais antigo sai primeiro.
    local cap = optMaxPerPlayer()
    while #kept > cap do
        table.remove(kept, 1)
    end

    local store = PV.Notices.ensureStore()
    if #kept == 0 then
        store[username] = nil
        return nil
    end

    store[username] = kept
    return kept
end

-- ============================================================
-- Registrar um aviso
--
-- params: { p1, p2, gk }
--   p1/p2  parametros da chave de traducao (ja em texto)
--   gk     chave de agrupamento. Eventos iguais dentro da janela viram UMA
--          entrada com contagem, em vez de 40 linhas repetidas. A contagem e
--          justamente o que separa um curioso que passou de alguem que ficou
--          uma hora trabalhando no carro.
-- ============================================================
function PV.Notices.add(username, key, params)
    if not optEnabled() then return false end
    if type(username) ~= "string" or username == "" then return false end
    if type(key) ~= "string" or key == "" then return false end

    params = params or {}
    local store = PV.Notices.ensureStore()
    local now = getTimestamp()

    if type(store[username]) ~= "table" then store[username] = {} end
    local list = store[username]

    -- Agrupamento: procura de tras pra frente, so dentro da janela. Varrer de
    -- tras e barato E correto porque a lista esta sempre ordenada por tempo -
    -- invariante que o bloco abaixo tem a obrigacao de manter.
    local gk = params.gk
    if type(gk) == "string" and gk ~= "" then
        local window = optGroupSeconds()
        for i = #list, 1, -1 do
            local it = list[i]
            if type(it) ~= "table" then break end
            local t = tonumber(it.t) or 0
            if (now - t) > window then break end
            if it.gk == gk then
                it.n = (tonumber(it.n) or 1) + 1
                it.t = now
                it.read = false  -- voltou a acontecer: conta como novo

                -- Mandar pro fim da lista, e nao so trocar o timestamp: a
                -- ordem do array E a ordem cronologica. Sem isso um aviso
                -- atualizado agora apareceria abaixo de um de duas horas
                -- atras, o teto removeria o item errado como "mais antigo", e
                -- a varredura acima pararia cedo e deixaria de agrupar.
                if i ~= #list then
                    table.remove(list, i)
                    list[#list + 1] = it
                end

                persist()
                return true
            end
        end
    end

    list[#list + 1] = {
        t    = now,
        key  = key,
        p1   = params.p1 ~= nil and tostring(params.p1) or nil,
        p2   = params.p2 ~= nil and tostring(params.p2) or nil,
        n    = 1,
        gk   = (type(gk) == "string" and gk ~= "") and gk or nil,
        read = false,
    }

    pruneList(username)
    persist()
    return true
end

-- ============================================================
-- Leitura
-- ============================================================
function PV.Notices.unreadCount(username)
    local list = listOf(username)
    if not list then return 0 end
    local n = 0
    for i = 1, #list do
        local it = list[i]
        if type(it) == "table" and it.read ~= true then n = n + 1 end
    end
    return n
end

--- Entrega a lista do jogador SO para ele.
function PV.Notices.sendTo(playerObj)
    if not playerObj or not playerObj.getUsername then return end
    local username = playerObj:getUsername()
    local list = pruneList(username) or {}

    local payload = {}
    for i = 1, #list do
        local it = list[i]
        payload[i] = {
            t = it.t, key = it.key, p1 = it.p1, p2 = it.p2,
            n = it.n, read = it.read,
        }
    end

    sendServerCommand(playerObj, "ProtectVehicle", "pvNotices", {
        items  = payload,
        unread = PV.Notices.unreadCount(username),
    })
end

--- Entrega so se o jogador estiver online agora. Usado pelos alertas.
function PV.Notices.sendToUsername(username)
    if type(username) ~= "string" or username == "" then return end
    local pl = PV.getOnlinePlayerByUsername and PV.getOnlinePlayerByUsername(username) or nil
    if pl then PV.Notices.sendTo(pl) end
end

-- ============================================================
-- Escrita vinda do cliente
-- ============================================================
function PV.Notices.markAllRead(username)
    local list = listOf(username)
    if not list then return end
    local changed = false
    for i = 1, #list do
        local it = list[i]
        if type(it) == "table" and it.read ~= true then
            it.read = true
            changed = true
        end
    end
    if changed then persist() end
end

function PV.Notices.clear(username)
    local store = PV.Notices.ensureStore()
    if store[username] == nil then return end
    store[username] = nil
    persist()
end

-- ============================================================
-- Atalho usado pelos pontos de alerta do PV_Server
--
-- Faz as duas coisas de uma vez: guarda o aviso (sempre) e, se o dono estiver
-- online, atualiza a caixa dele na hora. O halo note continua sendo
-- responsabilidade de quem chama, porque ele respeita cooldown e o aviso nao.
-- ============================================================
function PV.Notices.record(username, key, params)
    if PV.Notices.add(username, key, params) then
        PV.Notices.sendToUsername(username)
        return true
    end
    return false
end
