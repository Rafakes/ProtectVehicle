--[[
    ProtectVehicle - PV_SlotsWindow.lua
    Slots de protecao: limite da role e aluguel com pontos.
    B42.x - Multiplayer.

    Desenha o que o servidor mandou em PV.mySlots (comando "pvSlots"). Nenhuma
    decisao de preco, limite ou saldo acontece aqui: tudo isso e conferido de
    novo no servidor quando o botao e clicado. O cliente so pinta e pede.

    As linhas de aluguel sao botoes de verdade (renovar, auto-renovar), entao
    nao cabem num ISScrollingListBox: sao montadas como filhos de um painel e
    refeitas a cada atualizacao.
--]]

if not isClient() and isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTickBox"
require "UI/PV_UIShared"

PV = PV or {}
PV.UI = PV.UI or {}

PV.UI.SlotsWindow = ISCollapsableWindow:derive("PV.UI.SlotsWindow")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local PAD_TOP = FONT_HGT_SMALL + 1

-- ============================================================
-- Formatacao
-- ============================================================
local function fmtPoints(v)
    v = tonumber(v) or 0
    if v == math.floor(v) then return tostring(math.floor(v)) end
    return string.format("%.2f", v)
end

--- Quanto falta para vencer, em texto curto.
local function remainingText(expires)
    local now = (getTimestamp and getTimestamp()) or 0
    local secs = (tonumber(expires) or 0) - now
    if secs <= 0 then return getText("UI_PV_Slots_Expired") end
    if secs < 3600 then
        return getText("UI_PV_Slots_LeftMin", tostring(math.floor(secs / 60)))
    end
    if secs < 86400 then
        return getText("UI_PV_Slots_LeftHour", tostring(math.floor(secs / 3600)))
    end
    return getText("UI_PV_Slots_LeftDay", tostring(math.floor(secs / 86400)))
end

--- ISLabel pinta com self.r/g/b: mexer no campo evita depender de um
--- setColor que pode nao existir nesta versao.
local function tint(lbl, col, g, b)
    if not lbl then return end
    if type(col) == "table" then
        lbl.r, lbl.g, lbl.b = col.r, col.g, col.b
    else
        lbl.r, lbl.g, lbl.b = col, g, b
    end
end

local function slotsText(n)
    n = tonumber(n) or 0
    if n == 1 then return getText("UI_PV_Slots_OneSlot") end
    return getText("UI_PV_Slots_NSlots", tostring(n))
end

-- ============================================================
-- Construcao
-- ============================================================
function PV.UI.SlotsWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:buildLayout()
end

function PV.UI.SlotsWindow:buildLayout()
    local theme = PV.UI.Theme
    local c = theme.colors
    local m = theme.metrics

    local PAD = m.pad
    local GAP = m.gap
    local rowH = FONT_HGT_SMALL + 6
    local btnH = math.floor(26 * m.scale)
    if btnH < 22 then btnH = 22 end

    self.rowH = rowH
    self.btnH = btnH

    local contentY = PAD_TOP + PAD
    local cardW = self.width - (PAD * 2)
    local x = PAD

    -- ========================================================
    -- 1. Seu limite
    -- ========================================================
    local limitH = PAD + math.floor(28 * m.scale) + (rowH * 4) + PAD
    self.cardLimit = PV.UI.CardPanel:new(x, contentY, cardW, limitH,
        getText("UI_PV_Slots_SectionLimit"))
    self.cardLimit:initialise(); self.cardLimit:instantiate()
    self:addChild(self.cardLimit)

    local lx, ly, lw, _lh = self.cardLimit:getInnerRect()

    self.lblHeadline = ISLabel:new(lx, ly, math.floor(28 * m.scale), "",
        c.text.r, c.text.g, c.text.b, 1, UIFont.Medium, true)
    self.lblHeadline:initialise(); self.lblHeadline:instantiate()
    self.cardLimit:addChild(self.lblHeadline)

    local function addLine(i, font)
        local lbl = ISLabel:new(lx, ly + math.floor(28 * m.scale) + (rowH * i), rowH, "",
            c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, font or UIFont.NewSmall, true)
        lbl:initialise(); lbl:instantiate()
        self.cardLimit:addChild(lbl)
        return lbl
    end

    -- Os dois patamares aparecem sempre, lado a lado: o jogador precisa ver
    -- quanto vale ser apoiador mesmo quando nao e.
    self.lblTierBase      = addLine(0)
    self.lblTierSupporter = addLine(1)
    self.lblRented        = addLine(2)
    self.lblGrace         = addLine(3)

    -- ========================================================
    -- 2. Alugar
    -- ========================================================
    local buyY = contentY + limitH + GAP
    local buyH = PAD + (btnH * 2) + GAP + rowH + PAD
    self.cardBuy = PV.UI.CardPanel:new(x, buyY, cardW, buyH,
        getText("UI_PV_Slots_SectionRent"))
    self.cardBuy:initialise(); self.cardBuy:instantiate()
    self:addChild(self.cardBuy)

    local bx, by, bw, _bh = self.cardBuy:getInnerRect()
    local buyBtnW = math.floor(150 * m.scale)

    self.buyButtons = {}
    self.buyLabels = {}
    for i = 1, 2 do
        local yy = by + ((i - 1) * (btnH + 4))
        local btn = ISButton:new(bx, yy, buyBtnW, btnH, "", self, self.onRentClick)
        btn.internal = "pack" .. i
        btn.pvPack = i
        btn:initialise(); btn:instantiate()
        btn.font = UIFont.NewSmall
        PV.UI.ApplyButtonStyle(btn, "success")
        self.cardBuy:addChild(btn)
        self.buyButtons[i] = btn

        local lbl = ISLabel:new(bx + buyBtnW + GAP, yy + math.floor((btnH - rowH) / 2), rowH,
            "", c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
        lbl:initialise(); lbl:instantiate()
        self.cardBuy:addChild(lbl)
        self.buyLabels[i] = lbl
    end

    self.lblBuyNote = ISLabel:new(bx, by + (btnH * 2) + GAP, rowH, "",
        c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
    self.lblBuyNote:initialise(); self.lblBuyNote:instantiate()
    self.cardBuy:addChild(self.lblBuyNote)

    -- ========================================================
    -- 3. Meus alugueis
    -- ========================================================
    local listY = buyY + buyH + GAP
    local listH = self.height - listY - PAD - rowH - GAP
    self.cardRentals = PV.UI.CardPanel:new(x, listY, cardW, listH,
        getText("UI_PV_Slots_SectionMine"))
    self.cardRentals:initialise(); self.cardRentals:instantiate()
    self:addChild(self.cardRentals)

    local rx, ry, rw, rh = self.cardRentals:getInnerRect()
    self.rentalsBox = ISPanel:new(rx, ry, rw, rh)
    self.rentalsBox.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.rentalsBox.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.rentalsBox:initialise(); self.rentalsBox:instantiate()
    self.cardRentals:addChild(self.rentalsBox)
    self.rentalRows = {}

    -- ========================================================
    -- 4. Rodape: saldo e atualizar
    -- ========================================================
    local footY = self.height - PAD - rowH
    self.lblBalance = ISLabel:new(x, footY, rowH, "",
        c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall, true)
    self.lblBalance:initialise(); self.lblBalance:instantiate()
    self:addChild(self.lblBalance)

    local refreshW = math.floor(100 * m.scale)
    self.btnRefresh = ISButton:new(self.width - PAD - refreshW, footY - 2, refreshW, rowH + 4,
        getText("UI_PV_Slots_Refresh"), self, self.onRefreshClick)
    self.btnRefresh.internal = "btnRefresh"
    self.btnRefresh:initialise(); self.btnRefresh:instantiate()
    self.btnRefresh.font = UIFont.NewSmall
    PV.UI.ApplyButtonStyle(self.btnRefresh)
    self:addChild(self.btnRefresh)

    self:refreshAll()
end

-- ============================================================
-- Atualizacao
-- ============================================================
function PV.UI.SlotsWindow:refreshAll()
    local s = PV.mySlots
    local c = PV.UI.Theme.colors

    if type(s) ~= "table" then
        if self.lblHeadline then self.lblHeadline:setName(getText("UI_PV_Slots_Loading")) end
        return
    end

    local base      = tonumber(s.base) or 0
    local rented    = tonumber(s.rented) or 0
    local grace     = tonumber(s.grace) or 0
    local used      = tonumber(s.used) or 0
    local total     = base + rented + grace
    local currency  = tostring(s.currency or "zPoints")

    self.lblHeadline:setName(getText("UI_PV_Slots_Headline",
        tostring(total), tostring(used)))

    -- Patamar ativo em destaque; o outro fica apagado.
    local isSup = (s.supporter == true)
    local on, off = c.accent, c.textMuted

    self.lblTierBase:setName(getText("UI_PV_Slots_TierBase", tostring(s.tierBase or 0)))
    tint(self.lblTierBase, isSup and off or on)

    self.lblTierSupporter:setName(getText("UI_PV_Slots_TierSupporter", tostring(s.tierSupporter or 0)))
    tint(self.lblTierSupporter, isSup and on or off)

    self.lblRented:setName(getText("UI_PV_Slots_RentedLine",
        tostring(rented), tostring(s.maxRented or 0)))
    tint(self.lblRented, c.textMuted)

    -- Aviso de carencia: e a unica coisa nesta janela que pode custar um
    -- veiculo ao jogador, entao vai em vermelho e com o prazo na frente.
    if grace > 0 then
        self.lblGrace:setName(getText("UI_PV_Slots_GraceWarn",
            remainingText(s.graceUntil)))
        tint(self.lblGrace, 0.95, 0.35, 0.35)
    else
        self.lblGrace:setName("")
    end

    -- Botoes de aluguel
    local packs = (type(s.packs) == "table") and s.packs or {}
    local canRent = (s.enabled == true)
    for i = 1, 2 do
        local p = packs[i]
        local btn, lbl = self.buyButtons[i], self.buyLabels[i]
        if p then
            btn:setTitle(getText("UI_PV_Slots_RentBtn", slotsText(p.slots)))
            lbl:setName(getText("UI_PV_Slots_RentPrice",
                fmtPoints(p.price) .. " " .. currency, tostring(s.days or 7)))
            local fits = (rented + (tonumber(p.slots) or 0)) <= (tonumber(s.maxRented) or 0)
            local affords = (tonumber(s.balance) or 0) >= (tonumber(p.price) or 0)
            btn:setEnable(canRent and fits and affords)
            btn:setVisible(true)
            lbl:setVisible(true)
        else
            btn:setVisible(false)
            lbl:setVisible(false)
        end
    end

    if not canRent then
        self.lblBuyNote:setName(getText("UI_PV_Slots_Unavailable"))
        tint(self.lblBuyNote, 0.95, 0.60, 0.35)
    else
        self.lblBuyNote:setName("")
    end

    self.lblBalance:setName(getText("UI_PV_Slots_Balance",
        currency, fmtPoints(s.balance)))

    self:rebuildRentalRows()
end

--- Refaz as linhas de aluguel. Cada uma tem botoes proprios, entao o painel e
--- esvaziado e montado de novo em vez de atualizado no lugar.
function PV.UI.SlotsWindow:rebuildRentalRows()
    local box = self.rentalsBox
    if not box then return end

    for _, child in ipairs(self.rentalRows) do
        box:removeChild(child)
    end
    self.rentalRows = {}

    local c = PV.UI.Theme.colors
    local m = PV.UI.Theme.metrics
    local rowH, btnH = self.rowH, self.btnH
    local s = PV.mySlots or {}
    local rentals = (type(s.rentals) == "table") and s.rentals or {}

    local function track(el)
        el:initialise(); el:instantiate()
        box:addChild(el)
        self.rentalRows[#self.rentalRows + 1] = el
        return el
    end

    if #rentals == 0 then
        local lbl = ISLabel:new(0, 0, rowH, getText("UI_PV_Slots_NoRentals"),
            c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
        track(lbl)
        return
    end

    local lineH = btnH + 6
    local maxRows = math.floor(box.height / lineH)
    if maxRows < 1 then maxRows = 1 end

    local renewW = math.floor(84 * m.scale)
    local autoW  = math.floor(110 * m.scale)

    for i = 1, math.min(#rentals, maxRows) do
        local r = rentals[i]
        local y = (i - 1) * lineH

        local txt = slotsText(r.slots) .. "  " .. getText("UI_PV_Slots_Dot") .. "  " ..
            remainingText(r.expires)
        local lbl = ISLabel:new(0, y + math.floor((btnH - rowH) / 2), rowH, txt,
            c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall, true)
        track(lbl)

        local btnRenew = ISButton:new(box.width - autoW - renewW - 8, y, renewW, btnH,
            getText("UI_PV_Slots_Renew"), self, self.onRenewClick)
        btnRenew.internal = "renew"
        btnRenew.pvRentalId = r.id
        btnRenew.font = UIFont.NewSmall
        track(btnRenew)
        PV.UI.ApplyButtonStyle(btnRenew, "primary")
        btnRenew:setEnable((tonumber(s.balance) or 0) >= (tonumber(r.price) or 0))

        -- O id vai como arg1 do ISTickBox: o callback dele recebe
        -- (target, index, selected, arg1, arg2) e nao o proprio widget.
        local tick = ISTickBox:new(box.width - autoW, y + math.floor((btnH - rowH) / 2),
            autoW, rowH, "", self, self.onAutoTicked, r.id)
        tick:initialise(); tick:instantiate()
        tick:addOption(getText("UI_PV_Slots_Auto"))
        tick:setSelected(1, r.auto == true)
        box:addChild(tick)
        self.rentalRows[#self.rentalRows + 1] = tick
    end

    if #rentals > maxRows then
        local lbl = ISLabel:new(0, maxRows * lineH, rowH,
            getText("UI_PV_Slots_More", tostring(#rentals - maxRows)),
            c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
        track(lbl)
    end
end

-- ============================================================
-- Acoes: todas so pedem. Preco, limite e saldo sao conferidos no servidor.
-- ============================================================
function PV.UI.SlotsWindow:onRentClick(btn)
    local pl = getPlayer()
    if not pl or not btn or not btn.pvPack then return end
    sendClientCommand(pl, "ProtectVehicle", "slotsRent", { pack = btn.pvPack })
end

function PV.UI.SlotsWindow:onRenewClick(btn)
    local pl = getPlayer()
    if not pl or not btn or not btn.pvRentalId then return end
    sendClientCommand(pl, "ProtectVehicle", "slotsRenew", { id = btn.pvRentalId })
end

function PV.UI.SlotsWindow:onAutoTicked(index, selected, rentalId)
    local pl = getPlayer()
    if not pl or not rentalId then return end
    sendClientCommand(pl, "ProtectVehicle", "slotsAuto",
        { id = rentalId, enabled = selected == true })
end

function PV.UI.SlotsWindow:onRefreshClick()
    local pl = getPlayer()
    if pl then sendClientCommand(pl, "ProtectVehicle", "slotsRequest", {}) end
end

-- ============================================================
-- Ciclo de vida
-- ============================================================
function PV.UI.SlotsWindow:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if PV.UI.SlotsInstance == self then PV.UI.SlotsInstance = nil end
end

function PV.UI.SlotsWindow:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    local c = PV.UI.Theme.colors
    o.backgroundColor = { r = c.windowBg.r, g = c.windowBg.g, b = c.windowBg.b, a = c.windowBg.a }
    o.borderColor = { r = c.windowBorder.r, g = c.windowBorder.g, b = c.windowBorder.b, a = 1 }
    o.title = getText("UI_PV_Slots_Title")
    o.resizable = false
    o.drawFrame = true
    o.rentalRows = {}
    return o
end

function PV.UI.OpenSlots()
    if PV.UI.SlotsInstance then
        PV.UI.SlotsInstance:setVisible(true)
        PV.UI.SlotsInstance:bringToTop()
        PV.UI.SlotsInstance:refreshAll()
    else
        local m = PV.UI.Theme.metrics
        local w = math.floor(520 * m.scale)
        local h = math.floor(430 * m.scale)
        local x = math.floor((getCore():getScreenWidth() - w) / 2)
        local y = math.floor((getCore():getScreenHeight() - h) / 2)

        local win = PV.UI.SlotsWindow:new(x, y, w, h)
        win:initialise()
        win:instantiate()
        win:addToUIManager()
        PV.UI.SlotsInstance = win
    end

    -- O saldo muda fora daqui (loja, recompensas): sempre pede o estado atual
    -- ao abrir, em vez de confiar no que chegou da ultima vez.
    local pl = getPlayer()
    if pl then sendClientCommand(pl, "ProtectVehicle", "slotsRequest", {}) end

    return PV.UI.SlotsInstance
end
