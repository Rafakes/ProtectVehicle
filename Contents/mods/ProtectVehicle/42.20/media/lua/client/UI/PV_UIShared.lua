--[[
    ProtectVehicle - PV_UIShared.lua
    Modern UI helpers (client-only).
    B42.x - Multiplayer safe (UI only).
--]]

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"

PV = PV or {}
PV.UI = PV.UI or {}

-- ============================================================
-- Theme
-- ============================================================
local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end

PV.UI.Theme = PV.UI.Theme or {}

PV.UI.Theme.colors = {
    windowBg     = {r=0.06, g=0.06, b=0.08, a=0.96},
    windowBorder = {r=0.30, g=0.31, b=0.35, a=1.00},

    cardBg       = {r=0.09, g=0.09, b=0.12, a=0.95},
    cardBorder   = {r=0.22, g=0.23, b=0.27, a=1.00},
    cardShadow   = {r=0.00, g=0.00, b=0.00, a=0.35},

    headerBg     = {r=0.12, g=0.12, b=0.16, a=0.98},
    divider      = {r=0.26, g=0.27, b=0.31, a=1.00},

    text         = {r=0.92, g=0.92, b=0.94, a=1.00},
    textMuted    = {r=0.65, g=0.65, b=0.70, a=1.00},

    accent       = {r=0.80, g=0.35, b=0.30, a=1.00},

    listBg       = {r=0.08, g=0.08, b=0.10, a=1.00},
    listAltBg    = {r=0.10, g=0.10, b=0.13, a=1.00},
    listHover    = {r=0.16, g=0.16, b=0.20, a=1.00},
    listSelected = {r=0.20, g=0.26, b=0.32, a=1.00},

    btnDefault   = {r=0.25, g=0.25, b=0.30, a=1.00},
    btnHover     = {r=0.32, g=0.32, b=0.38, a=1.00},

    btnPrimary   = {r=0.28, g=0.45, b=0.70, a=1.00},
    btnSuccess   = {r=0.25, g=0.55, b=0.35, a=1.00},
    btnDanger    = {r=0.65, g=0.25, b=0.25, a=1.00},
}

PV.UI.Theme.metrics = PV.UI.Theme.metrics or {}
PV.UI.Theme.metrics.scale  = (PV.getUIFontScale and PV.getUIFontScale()) or 1
PV.UI.Theme.metrics.pad    = math.floor(10 * PV.UI.Theme.metrics.scale)
PV.UI.Theme.metrics.gap    = math.floor(10 * PV.UI.Theme.metrics.scale)
PV.UI.Theme.metrics.radius = math.floor(6  * PV.UI.Theme.metrics.scale)
PV.UI.Theme.metrics.headerH= math.floor(28 * PV.UI.Theme.metrics.scale)

-- ============================================================
-- Card panel
-- ============================================================
PV.UI.CardPanel = ISPanel:derive("PV.UI.CardPanel")

function PV.UI.CardPanel:new(x, y, w, h, title, accentColor)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self

    o.title = title
    o.accentColor = accentColor -- optional {r,g,b,a}
    o.drawHeader = (title ~= nil)
    o.padding = PV.UI.Theme.metrics.pad
    o.headerH = PV.UI.Theme.metrics.headerH

    o.backgroundColor = { r=0, g=0, b=0, a=0 }
    o.borderColor = { r=0, g=0, b=0, a=0 }
    o.moveWithMouse = false
    return o
end

function PV.UI.CardPanel:getInnerRect()
    local pad = self.padding
    local top = pad + (self.drawHeader and self.headerH or 0)
    return pad, top, self.width - pad * 2, self.height - top - pad
end

function PV.UI.CardPanel:prerender()
    ISPanel.prerender(self)

    local c = PV.UI.Theme.colors
    -- shadow
    self:drawRect(2, 2, self.width, self.height, c.cardShadow.a, c.cardShadow.r, c.cardShadow.g, c.cardShadow.b)

    -- body
    self:drawRect(0, 0, self.width, self.height, c.cardBg.a, c.cardBg.r, c.cardBg.g, c.cardBg.b)
    self:drawRectBorder(0, 0, self.width, self.height, c.cardBorder.a, c.cardBorder.r, c.cardBorder.g, c.cardBorder.b)

    if self.drawHeader then
        self:drawRect(0, 0, self.width, self.headerH, c.headerBg.a, c.headerBg.r, c.headerBg.g, c.headerBg.b)
        self:drawRect(0, self.headerH - 1, self.width, 1, c.divider.a, c.divider.r, c.divider.g, c.divider.b)

        local accent = self.accentColor or c.accent
        self:drawRect(0, 0, 4, self.headerH, clamp01(accent.a or 1), accent.r, accent.g, accent.b)

        local font = UIFont.NewMedium
        local fH = getTextManager():getFontHeight(font)
        local y = math.floor((self.headerH - fH) / 2)
        self:drawText(self.title, self.padding + 4, y, c.text.r, c.text.g, c.text.b, c.text.a, font)
    end
end

-- ============================================================
-- Button styling helpers
-- ============================================================
function PV.UI.ApplyButtonStyle(btn, variant)
    if not btn then return end
    local c = PV.UI.Theme.colors

    local base = c.btnDefault
    if variant == "primary" then base = c.btnPrimary
    elseif variant == "success" then base = c.btnSuccess
    elseif variant == "danger" then base = c.btnDanger
    end

    btn.backgroundColor = { r = base.r, g = base.g, b = base.b, a = base.a }
    btn.backgroundColorMouseOver = { r = c.btnHover.r, g = c.btnHover.g, b = c.btnHover.b, a = c.btnHover.a }
    btn.borderColor = { r = c.cardBorder.r, g = c.cardBorder.g, b = c.cardBorder.b, a = 1 }
    btn.backgroundColorDisabled = { r = base.r * 0.55, g = base.g * 0.55, b = base.b * 0.55, a = 1 }
    btn.textColor = { r = c.text.r, g = c.text.g, b = c.text.b, a = 1 }
end

-- ============================================================
-- List styling (ISScrollingListBox)
-- ============================================================
function PV.UI.ApplyListStyle(list)
    if not list then return end
    list.drawBorder = false
    list.backgroundColor = { r=0, g=0, b=0, a=0 }
end

function PV.UI.DrawSimpleListItem(list, y, item, alt)
    local c = PV.UI.Theme.colors
    local h = list.itemheight or (getTextManager():getFontHeight(list.font) + 6)

    local isSel = (list.selected == item.index)
    local isHover = (list.mouseoverselected == item.index) and not isSel

    local bg = c.listBg
    if isSel then bg = c.listSelected
    elseif isHover then bg = c.listHover
    elseif alt then bg = c.listAltBg end

    list:drawRect(0, y, list:getWidth(), h, bg.a, bg.r, bg.g, bg.b)
    list:drawText(item.text or "", 10, y + 2, c.text.r, c.text.g, c.text.b, 1, list.font)

    return y + h
end

-- ============================================================
-- Texture helpers
-- ============================================================
function PV.UI.GetTextureSize(texture)
    if not texture then return 0, 0 end

    local okW, w = pcall(function()
        if texture.getWidthOrig then return texture:getWidthOrig() end
        if texture.getWidth then return texture:getWidth() end
        return 0
    end)
    local okH, h = pcall(function()
        if texture.getHeightOrig then return texture:getHeightOrig() end
        if texture.getHeight then return texture:getHeight() end
        return 0
    end)

    return (okW and w) or 0, (okH and h) or 0
end

function PV.UI.DrawCenteredWatermark(host, texture, areaX, areaY, areaW, areaH, alpha, scale, tint)
    if not host or not texture then return end
    if areaW <= 0 or areaH <= 0 then return end

    local texW, texH = PV.UI.GetTextureSize(texture)
    if texW <= 0 or texH <= 0 then return end

    local fit = math.min(areaW / texW, areaH / texH)
    local drawScale = (scale or 1) * fit
    local drawW = math.floor(texW * drawScale)
    local drawH = math.floor(texH * drawScale)
    if drawW <= 0 or drawH <= 0 then return end

    local x = areaX + math.floor((areaW - drawW) / 2)
    local y = areaY + math.floor((areaH - drawH) / 2)

    tint = tint or { r = 1, g = 1, b = 1 }
    host:drawTextureScaled(texture, x, y, drawW, drawH, alpha or 0.1, tint.r or 1, tint.g or 1, tint.b or 1)
end
