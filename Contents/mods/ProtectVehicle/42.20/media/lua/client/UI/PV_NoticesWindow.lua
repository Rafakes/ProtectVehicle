--[[
    ProtectVehicle - PV_NoticesWindow.lua
    Caixa de avisos do dono (janela).
    B42.x - Multiplayer.

    Lista o que aconteceu com os veiculos do jogador, inclusive enquanto ele
    estava offline. Os dados vem do servidor pelo comando "pvNotices" e ficam
    em PV.notices; esta janela so desenha.

    Nao e um painel por veiculo: os avisos sao do JOGADOR. Por isso vive em
    janela propria, e nao como aba dentro do painel de permissoes, onde as
    abas existentes (Por nome / Safehouse / Faccao) sao todas por veiculo.

    Os avisos sao marcados como lidos no FECHAR, nao no abrir: assim o
    destaque dos novos continua visivel enquanto o jogador le a lista.
--]]

if not isClient() and isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISModalDialog"
require "UI/PV_UIShared"

PV = PV or {}
PV.UI = PV.UI or {}

PV.UI.NoticesWindow = ISCollapsableWindow:derive("PV.UI.NoticesWindow")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local PAD_TOP = FONT_HGT_SMALL + 1

-- ============================================================
-- Monta a linha de um aviso
--
-- Guardamos a chave de traducao, nao a frase: o texto e montado aqui, no
-- idioma de quem esta lendo.
-- ============================================================
local function noticeText(item)
    if type(item) ~= "table" or type(item.key) ~= "string" then return "?" end

    local p1 = item.p1 ~= nil and tostring(item.p1) or ""
    local p2 = item.p2 ~= nil and tostring(item.p2) or ""
    local text = getText(item.key, p1, p2)

    local n = tonumber(item.n) or 1
    if n > 1 then
        text = text .. " " .. getText("UI_PV_Notice_Count", tostring(n))
    end
    return text
end

--- Tempo relativo ("agora", "ha 5 min"). Evita fuso e formato de data.
local function noticeAge(item)
    local age = PV.UI.FormatLocationAge and PV.UI.FormatLocationAge(item and item.t)
    return age or "-"
end

-- ============================================================
-- Construcao
-- ============================================================
function PV.UI.NoticesWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:buildLayout()
end

function PV.UI.NoticesWindow:buildLayout()
    local theme = PV.UI.Theme
    local c = theme.colors
    local m = theme.metrics

    local PAD = m.pad
    local GAP = m.gap
    local btnH = math.floor(28 * m.scale)
    local rowH = FONT_HGT_SMALL + 8

    local contentY = PAD_TOP + PAD
    local cardW = self.width - (PAD * 2)
    local cardH = self.height - contentY - PAD

    self.card = PV.UI.CardPanel:new(PAD, contentY, cardW, cardH, getText("UI_PV_Notice_Title"))
    self.card:initialise(); self.card:instantiate()
    self:addChild(self.card)

    local ix, iy, iw, ih = self.card:getInnerRect()

    local listH = ih - btnH - GAP

    self.listNotices = ISScrollingListBox:new(ix, iy, iw, listH)
    self.listNotices:initialise(); self.listNotices:instantiate()
    self.listNotices:setFont(UIFont.NewSmall, 4)
    self.listNotices.itemheight = rowH
    self.listNotices.pvOwner = self
    PV.UI.ApplyListStyle(self.listNotices)

    -- Coluna de tempo a esquerda, texto a direita. A largura sai da medida das
    -- proprias chaves traduzidas: uma string fixa em portugues cortaria o
    -- texto em qualquer outro idioma.
    local tm = getTextManager()
    local timeW = 0
    for _, sample in ipairs({
        getText("UI_PV_User_LocAge_Now"),
        getText("UI_PV_User_LocAge_Min", "000"),
        getText("UI_PV_User_LocAge_Hour", "00"),
        getText("UI_PV_User_LocAge_Day", "000"),
    }) do
        local w = tm:MeasureStringX(UIFont.NewSmall, sample)
        if w > timeW then timeW = w end
    end
    timeW = timeW + 12

    self.listNotices.doDrawItem = function(list, y, item, alt)
        local h = list.itemheight
        local data = item.item

        local isHover = (list.mouseoverselected == item.index)
        local bg = alt and c.listAltBg or c.listBg
        if isHover then bg = c.listHover end
        list:drawRect(0, y, list:getWidth(), h, bg.a, bg.r, bg.g, bg.b)

        local unread = data and data.read ~= true
        if unread then
            -- Barra de acento marca o que o jogador ainda nao leu.
            local a = c.accent
            list:drawRect(0, y, 3, h, 1, a.r, a.g, a.b)
        end

        local textY = y + math.floor((h - FONT_HGT_SMALL) / 2)
        local mut = c.textMuted
        list:drawText(noticeAge(data), 10, textY, mut.r, mut.g, mut.b, 1, UIFont.NewSmall)

        local col = unread and c.text or mut
        local textX = 10 + timeW
        local avail = list:getWidth() - textX - 10
        local shown = PV.UI.TruncateText(item.text or "", avail, UIFont.NewSmall)
        list:drawText(shown, textX, textY, col.r, col.g, col.b, 1, UIFont.NewSmall)

        return y + h
    end

    self.card:addChild(self.listNotices)

    -- Rodape: limpar a caixa.
    local btnY = iy + listH + GAP
    local btnW = math.floor(120 * m.scale)

    self.lblEmpty = ISLabel:new(ix, btnY, btnH, "", c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
    self.lblEmpty:initialise(); self.lblEmpty:instantiate()
    self.card:addChild(self.lblEmpty)

    self.btnClear = ISButton:new(ix + iw - btnW, btnY, btnW, btnH,
        getText("UI_PV_Notice_Clear"), self, self.onClearClick)
    self.btnClear.internal = "btnClear"
    self.btnClear:initialise(); self.btnClear:instantiate()
    PV.UI.ApplyButtonStyle(self.btnClear, "danger")
    self.card:addChild(self.btnClear)

    self:refreshList()
end

-- ============================================================
-- Dados
-- ============================================================
function PV.UI.NoticesWindow:refreshList()
    if not self.listNotices then return end

    self.listNotices:clear()

    local items = (type(PV.notices) == "table") and PV.notices or {}

    -- O servidor manda do mais antigo pro mais novo; a leitura quer o
    -- contrario.
    local unread = 0
    for i = #items, 1, -1 do
        local it = items[i]
        if type(it) == "table" then
            self.listNotices:addItem(noticeText(it), it)
            if it.read ~= true then unread = unread + 1 end
        end
    end

    local total = #self.listNotices.items
    if self.lblEmpty then
        self.lblEmpty:setName(total == 0
            and getText("UI_PV_Notice_Empty")
            or getText("UI_PV_Notice_Summary", tostring(total), tostring(unread)))
    end
    if self.btnClear then self.btnClear:setEnable(total > 0) end
end

function PV.UI.NoticesWindow:onClearClick()
    if not self.listNotices or #self.listNotices.items == 0 then return end
    if self.modDialog ~= nil then
        self.modDialog:close(); self.modDialog:removeFromUIManager(); self.modDialog = nil
    end
    local w, h = 300, 110
    self.modDialog = ISModalDialog:new(
        getCore():getScreenWidth()  / 2 - w / 2,
        getCore():getScreenHeight() / 2 - h / 2,
        w, h, getText("UI_PV_Notice_ConfirmClear"),
        true, self, PV.UI.NoticesWindow.onConfirmClear,
        getPlayer():getPlayerNum(), nil)
    self.modDialog:initialise()
    self.modDialog:addToUIManager()
end

function PV.UI.NoticesWindow:onConfirmClear(btn)
    if btn and btn.internal == "NO" then return end
    self.modDialog = nil
    local pl = getPlayer()
    if not pl then return end
    sendClientCommand(pl, "ProtectVehicle", "noticesClear", {})
end

-- ============================================================
-- Ciclo de vida
-- ============================================================
function PV.UI.NoticesWindow:close()
    -- Marcar no fechar, e nao no abrir, deixa o destaque dos novos visivel
    -- durante a leitura.
    local pl = getPlayer()
    if pl then
        sendClientCommand(pl, "ProtectVehicle", "noticesMarkRead", {})
    end

    self:setVisible(false)
    self:removeFromUIManager()
    if PV.UI.NoticesInstance == self then PV.UI.NoticesInstance = nil end
end

function PV.UI.NoticesWindow:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    local c = PV.UI.Theme.colors
    o.backgroundColor = { r = c.windowBg.r, g = c.windowBg.g, b = c.windowBg.b, a = c.windowBg.a }
    o.borderColor = { r = c.windowBorder.r, g = c.windowBorder.g, b = c.windowBorder.b, a = 1 }
    o.title = getText("UI_PV_Notice_Title")
    o.resizable = false
    o.drawFrame = true
    o:setWantKeyEvents(true)
    return o
end

function PV.UI.OpenNotices()
    if PV.UI.NoticesInstance then
        PV.UI.NoticesInstance:setVisible(true)
        PV.UI.NoticesInstance:bringToTop()
        PV.UI.NoticesInstance:refreshList()
        return PV.UI.NoticesInstance
    end

    local m = PV.UI.Theme.metrics
    local w = math.floor(460 * m.scale)
    local h = math.floor(360 * m.scale)
    local x = math.floor((getCore():getScreenWidth() - w) / 2)
    local y = math.floor((getCore():getScreenHeight() - h) / 2)

    local win = PV.UI.NoticesWindow:new(x, y, w, h)
    win:initialise()
    win:instantiate()
    win:addToUIManager()
    PV.UI.NoticesInstance = win

    -- Pede a caixa de novo: garante lista fresca se o jogador abriu depois de
    -- muito tempo conectado.
    local pl = getPlayer()
    if pl then
        sendClientCommand(pl, "ProtectVehicle", "noticesRequest", {})
    end

    return win
end
