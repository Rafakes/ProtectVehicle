--[[
    ProtectVehicle - PV_ClaimSlots.lua
    Aluguel de slots de protecao (lado servidor).
    B42.x - Multiplayer.

    O QUE FAZ
    ---------
    O jogador aluga slots extras de protecao pagando com os pontos do Server
    Shop. O aluguel dura SlotRentDays dias de tempo REAL e pode renovar
    sozinho. Os slots alugados somam em cima do limite da role dele (base ou
    apoiador), nao substituem.

    INTEGRACAO COM O SERVER SHOP
    ----------------------------
    O saldo vive no mod Server Shop, nao aqui. Pegamos o modulo dele por
    require protegido: se a loja nao estiver instalada, o recurso inteiro fica
    desligado em vez de quebrar. Nada de ler o ModData da loja na mao - usando
    o modulo dele, o arredondamento, o cache por personagem e a estatistica de
    "total ganho" continuam sendo responsabilidade de quem e dono deles.

    O VENCIMENTO E A PARTE PERIGOSA
    -------------------------------
    Quando um aluguel vence e o jogador fica com mais veiculos protegidos do
    que o limite, NAO soltamos o claim na hora. Entra uma carencia
    (SlotGraceHours, 24h de fabrica) em que ele continua com tudo e recebe
    aviso dizendo o que vai perder e quando. So no fim da carencia, se ele nao
    renovou nem desprotegeu nada, o veiculo mais RECENTE e liberado.

    Isso existe porque o vencimento quase sempre acontece com o jogador
    offline: sem carencia ele perderia o carro sem nenhuma chance de reagir.
    Com SlotGraceHours = 0 o comportamento vira "solta na hora".

    ARMAZENAMENTO
    -------------
    ModData global "PVClaimSlots". Chave propria de proposito: a contagem de
    veiculos em PV.getClaimCount conta TODA chave de PV.dbByPlayerID[user] que
    nao seja um dos dois campos de horario, entao guardar aluguel lah faria
    cada aluguel contar como um veiculo protegido.

    { ["username"] = {
        NextId = 3,
        Rentals = { { id=1, slots=2, expires=<ts>, auto=true }, ... },
        GraceUntil = <ts ou nil>,
        GraceSlots = <n ou nil>,
      } }
--]]

if not isServer() then return end

PV = PV or {}
PV.Slots = PV.Slots or {}

local MODDATA_KEY = "PVClaimSlots"

-- ============================================================
-- Ponte com o Server Shop
-- ============================================================
local _shop = nil
local _shopTried = false

local function shop()
    if _shopTried then return _shop end
    _shopTried = true
    local ok, mod = pcall(require, "ServerShopBalanceCore")
    -- No cliente o modulo da loja devolve {} de proposito; aqui so serve se
    -- vier com as funcoes de saldo.
    if ok and type(mod) == "table" and type(mod.getBalance) == "function" then
        _shop = mod
    else
        _shop = nil
        print("[PV] Server Shop nao encontrado: aluguel de slots desligado.")
    end
    return _shop
end

function PV.Slots.currencyName()
    local sv = SandboxVars and SandboxVars.ServerShop
    local n = sv and sv.zPointsName
    if type(n) == "string" and n ~= "" then return n end
    return "zPoints"
end

-- ============================================================
-- Opcoes
-- ============================================================
local function opt(name, default, min, max)
    local sv = SandboxVars.ProtectVehicle
    local v = tonumber(sv and sv[name])
    if v == nil then return default end
    if min and v < min then v = min end
    if max and v > max then v = max end
    return v
end

function PV.Slots.isEnabled()
    local sv = SandboxVars.ProtectVehicle
    if not (sv and sv.EnableSlotRental == true) then return false end
    return shop() ~= nil
end

function PV.Slots.rentDays()      return opt("SlotRentDays", 7, 1, 30) end
function PV.Slots.maxRented()     return opt("MaxRentedSlots", 4, 1, 20) end
function PV.Slots.graceSeconds()  return opt("SlotGraceHours", 24, 0, 168) * 3600 end

--- Pacotes vendidos. Indice = o que o cliente manda.
function PV.Slots.packs()
    return {
        { slots = 1, price = opt("SlotRentPrice1", 200, 0, 1000000) },
        { slots = 2, price = opt("SlotRentPrice2", 300, 0, 1000000) },
    }
end

--- Preco de renovacao de um aluguel: o pacote do mesmo tamanho, se existir.
local function renewPriceFor(slots)
    for _, p in ipairs(PV.Slots.packs()) do
        if p.slots == slots then return p.price end
    end
    -- Tamanho sem pacote correspondente (admin mudou a config): cobra
    -- proporcional ao pacote de 1 slot em vez de dar de graca.
    return PV.Slots.packs()[1].price * slots
end

-- ============================================================
-- Armazenamento
-- ============================================================
function PV.Slots.ensureStore()
    if type(PV.slotStore) == "table" then return PV.slotStore end

    if ModData and ModData.exists and not ModData.exists(MODDATA_KEY) then
        ModData.create(MODDATA_KEY)
        ModData.add(MODDATA_KEY, {})
    end
    local store = ModData and ModData.get and ModData.get(MODDATA_KEY) or nil
    if type(store) ~= "table" then
        store = {}
        if ModData and ModData.add then ModData.add(MODDATA_KEY, store) end
    end

    PV.slotStore = store
    return PV.slotStore
end

local function persist()
    if ModData and ModData.add and type(PV.slotStore) == "table" then
        ModData.add(MODDATA_KEY, PV.slotStore)
    end
end

local function recordOf(username, create)
    local store = PV.Slots.ensureStore()
    local rec = store[username]
    if type(rec) ~= "table" then
        if not create then return nil end
        rec = { NextId = 1, Rentals = {} }
        store[username] = rec
    end
    if type(rec.Rentals) ~= "table" then rec.Rentals = {} end
    rec.NextId = tonumber(rec.NextId) or 1
    return rec
end

--- Devolve so os alugueis validos, ja normalizados (o ModData volta do disco
--- como JSON, entao nenhum tipo aqui e garantido).
local function activeRentals(rec, now)
    local out = {}
    if not rec then return out end
    for i = 1, #rec.Rentals do
        local r = rec.Rentals[i]
        if type(r) == "table" then
            local slots = tonumber(r.slots) or 0
            local exp = tonumber(r.expires) or 0
            if slots > 0 and exp > now then
                out[#out + 1] = {
                    id = tonumber(r.id) or i,
                    slots = math.floor(slots),
                    expires = exp,
                    auto = (r.auto == true),
                }
            end
        end
    end
    return out
end

-- ============================================================
-- Quantos slots extras o jogador tem agora
-- ============================================================
function PV.Slots.rentedSlots(username)
    if type(username) ~= "string" or username == "" then return 0 end
    local rec = recordOf(username, false)
    if not rec then return 0 end
    local now = getTimestamp()
    local n = 0
    for _, r in ipairs(activeRentals(rec, now)) do n = n + r.slots end
    return n
end

function PV.Slots.graceSlots(username)
    local rec = recordOf(username, false)
    if not rec then return 0 end
    local until_ = tonumber(rec.GraceUntil) or 0
    if until_ <= getTimestamp() then return 0 end
    return math.floor(tonumber(rec.GraceSlots) or 0)
end

--- Total somado ao limite da role. Ligado em PV.resolveBonusSlots (shared).
function PV.Slots.bonusFor(playerObj)
    if not playerObj or not playerObj.getUsername then return 0 end
    local u = playerObj:getUsername()
    return PV.Slots.rentedSlots(u) + PV.Slots.graceSlots(u)
end

-- ============================================================
-- Veiculos do jogador, do mais recente para o mais antigo
--
-- PV.dbByPlayerID[user] mistura os sqlid com dois campos de horario, entao a
-- varredura tem de pular esses dois nomes - mesma regra do PV.getClaimCount.
-- ============================================================
local function ownedVehiclesNewestFirst(username)
    local out = {}
    local pData = PV.dbByPlayerID and PV.dbByPlayerID[username]
    if type(pData) ~= "table" then return out end

    for k, _v in pairs(pData) do
        if k ~= "LastKnownLogonTime" and k ~= "LastKnownLogoffTime" then
            local entry = PV.getVehicleDBEntry(k)
            if entry then
                out[#out + 1] = {
                    sqlid = k,
                    claimed = tonumber(entry.ClaimDateTime) or 0,
                    name = tostring(PV.getEntryDisplayName(entry) or "?"),
                }
            end
        end
    end

    table.sort(out, function(a, b)
        if a.claimed ~= b.claimed then return a.claimed > b.claimed end
        return tostring(a.sqlid) < tostring(b.sqlid)  -- desempate estavel
    end)
    return out
end

local function countOwned(username)
    return #ownedVehiclesNewestFirst(username)
end

--- Limite da role, SEM aluguel nem carencia.
---
--- A role so se le com o objeto do jogador, e o vencimento quase sempre
--- acontece com ele offline. Por isso o patamar dele fica gravado no proprio
--- registro de slots, atualizado toda vez que ele aparece online.
---
--- Sem isso o calculo oscila: um jogador comum offline seria tratado como
--- apoiador, a carencia dele seria encerrada por engano ("voce voltou para
--- dentro do limite") e reaberta com 24h novas no proximo login - ou seja, o
--- veiculo nunca seria liberado enquanto ele ficasse fora, que e exatamente
--- quando a regra precisa valer.
local function baseLimitFor(username)
    local sv = SandboxVars.ProtectVehicle
    local supLimit = tonumber(sv and sv.MaxVehicleSupporter) or 6
    local baseLimit = tonumber(sv and sv.MaxVehicle) or 3

    local pl = PV.getOnlinePlayerByUsername and PV.getOnlinePlayerByUsername(username)
    if pl then
        return PV.isSupporterPlayer(pl) and supLimit or baseLimit
    end

    local rec = recordOf(username, false)
    if rec and rec.Supporter ~= nil then
        return rec.Supporter == true and supLimit or baseLimit
    end

    -- Nunca visto online: o lado seguro e tratar como apoiador, para nao
    -- soltar o carro de ninguem por falta de informacao. Na pratica nao
    -- acontece, porque so existe registro para quem alugou estando online.
    return supLimit
end

--- Guarda o patamar da role enquanto da para ler. Chamado no logon e na
--- compra; nao cria registro para quem nunca alugou nada.
function PV.Slots.rememberTier(playerObj)
    if not playerObj or not playerObj.getUsername then return end
    local rec = recordOf(playerObj:getUsername(), false)
    if not rec then return end
    local isSup = PV.isSupporterPlayer(playerObj) == true
    if rec.Supporter ~= isSup then
        rec.Supporter = isSup
        persist()
    end
end

local function notice(username, key, p1, p2)
    if PV.Notices and PV.Notices.record then
        pcall(PV.Notices.record, username, key, { p1 = p1, p2 = p2 })
    end
end

-- ============================================================
-- Envio do estado para o dono
-- ============================================================
function PV.Slots.buildPayload(playerObj)
    local username = playerObj:getUsername()
    local rec = recordOf(username, false)
    local now = getTimestamp()

    local rentals = {}
    for _, r in ipairs(activeRentals(rec, now)) do
        rentals[#rentals + 1] = {
            id = r.id,
            slots = r.slots,
            expires = r.expires,
            auto = r.auto,
            price = renewPriceFor(r.slots),
        }
    end
    table.sort(rentals, function(a, b) return a.expires < b.expires end)

    local packs = {}
    for i, p in ipairs(PV.Slots.packs()) do
        packs[i] = { slots = p.slots, price = p.price }
    end

    local sh = shop()
    local grace = PV.Slots.graceSlots(username)
    local sv = SandboxVars.ProtectVehicle

    return {
        enabled    = PV.Slots.isEnabled(),
        base       = baseLimitFor(username),
        supporter  = PV.isSupporterPlayer(playerObj) == true,
        -- Os DOIS limites da configuracao, nao so o do jogador: o painel
        -- mostra lado a lado quanto vale ser apoiador.
        tierBase      = tonumber(sv and sv.MaxVehicle) or 3,
        tierSupporter = tonumber(sv and sv.MaxVehicleSupporter) or 6,
        rented     = PV.Slots.rentedSlots(username),
        grace      = grace,
        graceUntil = (grace > 0 and rec and tonumber(rec.GraceUntil)) or nil,
        used       = countOwned(username),
        maxRented  = PV.Slots.maxRented(),
        days       = PV.Slots.rentDays(),
        currency   = PV.Slots.currencyName(),
        balance    = sh and sh.getBalance(playerObj) or 0,
        packs      = packs,
        rentals    = rentals,
    }
end

function PV.Slots.sendTo(playerObj)
    if not playerObj or not playerObj.getUsername then return end
    sendServerCommand(playerObj, "ProtectVehicle", "pvSlots", PV.Slots.buildPayload(playerObj))
end

local function sendToUsername(username)
    local pl = PV.getOnlinePlayerByUsername and PV.getOnlinePlayerByUsername(username)
    if pl then PV.Slots.sendTo(pl) end
end

local function fail(playerObj, key, p1)
    sendServerCommand(playerObj, "ProtectVehicle", "pvAlert", {
        text = key, p1 = p1 and tostring(p1) or "", r = 235, g = 90, b = 90,
    })
end

-- ============================================================
-- Alugar
-- ============================================================
function PV.Slots.rent(playerObj, packIndex)
    if not PV.Slots.isEnabled() then return end
    local sh = shop()
    if not sh then return end

    local pack = PV.Slots.packs()[tonumber(packIndex) or 0]
    if not pack then return end

    local username = playerObj:getUsername()
    if PV.Slots.rentedSlots(username) + pack.slots > PV.Slots.maxRented() then
        fail(playerObj, "IGUI_PV_Slots_MaxReached", PV.Slots.maxRented())
        return
    end

    if sh.getBalance(playerObj) < pack.price then
        fail(playerObj, "IGUI_PV_Slots_NoFunds", sh.formatPoints(pack.price))
        return
    end

    sh.addBalance(playerObj, -pack.price, "protectvehicle_slot_rent")

    local rec = recordOf(username, true)
    -- Registro novo: grava o patamar da role agora, enquanto da para ler.
    rec.Supporter = PV.isSupporterPlayer(playerObj) == true
    local id = rec.NextId
    rec.NextId = id + 1
    rec.Rentals[#rec.Rentals + 1] = {
        id = id,
        slots = pack.slots,
        expires = getTimestamp() + (PV.Slots.rentDays() * 86400),
        auto = false,
    }
    -- Comprou slot: a carencia pode ter deixado de ser necessaria.
    PV.Slots.reconcile(username)
    persist()

    PV.Log.writeGlobal("[PV] SLOT RENT | user=" .. username .. " | slots=" ..
        tostring(pack.slots) .. " | price=" .. tostring(pack.price) ..
        " | days=" .. tostring(PV.Slots.rentDays()), "INFO", true)

    if sh.sendBalance then pcall(sh.sendBalance, playerObj) end
    PV.Slots.sendTo(playerObj)
end

-- ============================================================
-- Renovar (manual)
-- ============================================================
function PV.Slots.renew(playerObj, rentalId)
    if not PV.Slots.isEnabled() then return end
    local sh = shop()
    if not sh then return end

    local username = playerObj:getUsername()
    local rec = recordOf(username, false)
    if not rec then return end

    rentalId = tonumber(rentalId)
    for i = 1, #rec.Rentals do
        local r = rec.Rentals[i]
        if type(r) == "table" and (tonumber(r.id) or -1) == rentalId then
            local slots = math.floor(tonumber(r.slots) or 0)
            local price = renewPriceFor(slots)
            if sh.getBalance(playerObj) < price then
                fail(playerObj, "IGUI_PV_Slots_NoFunds", sh.formatPoints(price))
                return
            end
            sh.addBalance(playerObj, -price, "protectvehicle_slot_renew")

            -- Renova a partir do vencimento, nao de agora: quem renova cedo
            -- nao perde os dias que ainda tinha.
            local now = getTimestamp()
            local from = tonumber(r.expires) or now
            if from < now then from = now end
            r.expires = from + (PV.Slots.rentDays() * 86400)

            PV.Slots.reconcile(username)
            persist()

            PV.Log.writeGlobal("[PV] SLOT RENEW | user=" .. username ..
                " | id=" .. tostring(rentalId) .. " | price=" .. tostring(price), "INFO", true)

            if sh.sendBalance then pcall(sh.sendBalance, playerObj) end
            PV.Slots.sendTo(playerObj)
            return
        end
    end
end

-- ============================================================
-- Ligar/desligar a auto-renovacao
-- ============================================================
function PV.Slots.setAuto(playerObj, rentalId, enabled)
    local rec = recordOf(playerObj:getUsername(), false)
    if not rec then return end

    rentalId = tonumber(rentalId)
    for i = 1, #rec.Rentals do
        local r = rec.Rentals[i]
        if type(r) == "table" and (tonumber(r.id) or -1) == rentalId then
            r.auto = (enabled == true)
            persist()
            PV.Slots.sendTo(playerObj)
            return
        end
    end
end

-- ============================================================
-- Carencia: abre, mantem ou fecha conforme a conta do momento
--
-- Chamada depois de qualquer coisa que mude a conta (comprar, renovar,
-- desproteger, vencer). Nunca solta veiculo: so decide se a carencia
-- precisa existir.
-- ============================================================
function PV.Slots.reconcile(username)
    local rec = recordOf(username, false)
    if not rec then return end

    local now = getTimestamp()
    local base = baseLimitFor(username)
    local rented = PV.Slots.rentedSlots(username)
    local used = countOwned(username)
    local over = used - (base + rented)

    if over <= 0 then
        -- Dentro do limite sem ajuda: encerra a carencia, se havia.
        if rec.GraceUntil then
            rec.GraceUntil = nil
            rec.GraceSlots = nil
            notice(username, "IGUI_PV_Notice_SlotGraceOver")
        end
        return
    end

    if not rec.GraceUntil then
        local secs = PV.Slots.graceSeconds()
        rec.GraceUntil = now + secs
        rec.GraceSlots = over

        local list = ownedVehiclesNewestFirst(username)
        local atRisk = list[1] and list[1].name or "?"
        notice(username, "IGUI_PV_Notice_SlotGraceStart",
            atRisk, tostring(math.floor(secs / 3600)))
    else
        -- Ja em carencia e ficou MAIS acima do limite (improvavel, porque o
        -- claim e barrado; sobra o caso de admin mudar a config). Cobre o
        -- novo excesso sem reiniciar o relogio.
        if over > (tonumber(rec.GraceSlots) or 0) then
            rec.GraceSlots = over
        end
    end
end

-- ============================================================
-- Vencimento: renova o que da, encerra o resto, aplica a carencia
--
-- Roda no sweep de 10 em 10 minutos e no logon do jogador.
-- ============================================================
local function processPlayer(username, rec, now)
    local sh = shop()
    local dirty = false

    -- 1. Alugueis vencidos: tenta auto-renovar, senao encerra.
    local keep = {}
    for i = 1, #rec.Rentals do
        local r = rec.Rentals[i]
        if type(r) == "table" and (tonumber(r.slots) or 0) > 0 then
            local exp = tonumber(r.expires) or 0
            if exp > now then
                keep[#keep + 1] = r
            else
                local slots = math.floor(tonumber(r.slots))
                local renewed = false

                if r.auto == true and sh then
                    local pl = PV.getOnlinePlayerByUsername and
                        PV.getOnlinePlayerByUsername(username)
                    local price = renewPriceFor(slots)

                    -- Offline tambem renova: o saldo vive por conta, nao por
                    -- personagem, e o jogador ligou a auto-renovacao
                    -- justamente para nao depender de estar online.
                    local bal = pl and sh.getBalance(pl) or sh.getBalanceByKey(username)
                    if bal >= price then
                        if pl then
                            sh.addBalance(pl, -price, "protectvehicle_slot_autorenew")
                            if sh.sendBalance then pcall(sh.sendBalance, pl) end
                        else
                            sh.addBalanceByKey(username, -price, "protectvehicle_slot_autorenew")
                        end
                        r.expires = now + (PV.Slots.rentDays() * 86400)
                        keep[#keep + 1] = r
                        renewed = true
                        notice(username, "IGUI_PV_Notice_SlotRenewed",
                            tostring(slots), sh.formatPoints(price))
                        PV.Log.writeGlobal("[PV] SLOT AUTO-RENEW | user=" .. username ..
                            " | slots=" .. tostring(slots) .. " | price=" .. tostring(price),
                            "INFO", true)
                    else
                        notice(username, "IGUI_PV_Notice_SlotNoFunds",
                            tostring(slots), sh.formatPoints(price))
                    end
                end

                if not renewed then
                    dirty = true
                    if r.auto ~= true then
                        notice(username, "IGUI_PV_Notice_SlotExpired", tostring(slots))
                    end
                    PV.Log.writeGlobal("[PV] SLOT EXPIRED | user=" .. username ..
                        " | slots=" .. tostring(slots), "INFO", true)
                else
                    dirty = true
                end
            end
        else
            dirty = true  -- entrada invalida: sai da lista
        end
    end
    if #keep ~= #rec.Rentals then dirty = true end
    rec.Rentals = keep

    -- 2. Carencia vencida: agora sim o claim e liberado.
    local graceUntil = tonumber(rec.GraceUntil) or 0
    if graceUntil > 0 and now >= graceUntil then
        rec.GraceUntil = nil
        rec.GraceSlots = nil
        dirty = true

        local base = baseLimitFor(username)
        local rented = PV.Slots.rentedSlots(username)
        local limit = base + rented
        local list = ownedVehiclesNewestFirst(username)

        -- Do mais recente para o mais antigo: quem chegou por ultimo sai
        -- primeiro, que e o que o jogador espera.
        local toRelease = #list - limit
        for i = 1, toRelease do
            local v = list[i]
            if v then
                notice(username, "IGUI_PV_Notice_SlotReleased", v.name)
                PV.Log.writeGlobal("[PV] SLOT RELEASE | user=" .. username ..
                    " | sqlid=" .. tostring(v.sqlid) .. " | motivo=carencia vencida",
                    "WARN", true)
                pcall(PV.ServerUnclaimVehicle, nil, v.sqlid, true, "slot_expired")
            end
        end
    end

    -- 3. Reabre a carencia se ainda estiver acima do limite.
    PV.Slots.reconcile(username)

    return dirty
end

function PV.Slots.processExpiries()
    local store = PV.Slots.ensureStore()
    local now = getTimestamp()
    local dirty = false

    for username, rec in pairs(store) do
        if type(rec) == "table" and type(username) == "string" then
            if type(rec.Rentals) ~= "table" then rec.Rentals = {} end
            local ok, res = pcall(processPlayer, username, rec, now)
            if not ok then
                PV.Log.writeGlobal("[PV] Falha ao processar slots de " ..
                    username .. ": " .. tostring(res), "ERROR")
            elseif res then
                dirty = true
                sendToUsername(username)
            end
        end
    end

    if dirty then persist() end
end

--- Chamada quando o jogador desprotege um veiculo por conta propria: pode
--- encerrar a carencia antes da hora.
function PV.Slots.onClaimCountChanged(username)
    if type(username) ~= "string" or username == "" then return end
    local rec = recordOf(username, false)
    if not rec then return end
    PV.Slots.reconcile(username)
    persist()
    sendToUsername(username)
end

-- Liga o calculo de limite do shared a este modulo.
PV.resolveBonusSlots = PV.Slots.bonusFor
