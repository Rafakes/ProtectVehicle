--[[
    ProtectVehicle - PV_PermissionPanel.lua
    UI for managing vehicle permission flags.
    Supports two modes:
      - Public flags  (targetPlayer == nil)
      - Per-player flags (targetPlayer == "username")
    Uses ISCollapsableWindow.
    B42.14.x
    
    FIXED:
    - onSave agora funciona corretamente com fallback seguro
    - ProteÃ§Ã£o contra chamadas de funÃ§Ãµes nÃ£o disponÃ­veis
--]]

if not isClient() and isServer() then return end

require "UI/PV_UIShared"
require "ISUI/ISRichTextPanel"

PV = PV or {}
PV.UI = PV.UI or {}

local FONT_HGT_SMALL  = getTextManager():getFontHeight(UIFont.NewSmall)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.NewMedium)
local PAD_TOP = FONT_HGT_SMALL + 1

-- ============================================================
-- Flag definitions (key â†’ translation key â†’ description key)
-- ============================================================
local FLAG_DEFS = {
    { key = "AllowDrive",           label = "UI_PV_Flag_Drive",        desc = "IGUI_PV_FlagDesc_Drive"        },
    { key = "AllowPassenger",       label = "UI_PV_Flag_Passenger",    desc = "IGUI_PV_FlagDesc_Passenger"    },
    { key = "AllowOpeningDoors",    label = "UI_PV_Flag_Doors",        desc = "IGUI_PV_FlagDesc_Doors"        },
    { key = "AllowOpeningTrunk",    label = "UI_PV_Flag_Trunk",        desc = "IGUI_PV_FlagDesc_Trunk"        },
    { key = "AllowContainersAccess",label = "UI_PV_Flag_Containers",   desc = "IGUI_PV_FlagDesc_Containers"   },
    { key = "AllowEnterRV",         label = "UI_PV_Flag_EnterRV",      desc = "IGUI_PV_FlagDesc_EnterRV"      },
    { key = "AllowSiphonFuel",      label = "UI_PV_Flag_Siphon",       desc = "IGUI_PV_FlagDesc_Siphon"       },
    { key = "AllowInflateTires",    label = "UI_PV_Flag_Inflate",      desc = "IGUI_PV_FlagDesc_Inflate"      },
    { key = "AllowDeflateTires",    label = "UI_PV_Flag_Deflate",      desc = "IGUI_PV_FlagDesc_Deflate"      },
    { key = "AllowUninstallParts",  label = "UI_PV_Flag_Uninstall",    desc = "IGUI_PV_FlagDesc_Uninstall"    },
    { key = "AllowTakeEngineParts", label = "UI_PV_Flag_Engine",       desc = "IGUI_PV_FlagDesc_Engine"       },
    { key = "AllowTow",             label = "UI_PV_Flag_Tow",          desc = "IGUI_PV_FlagDesc_Tow"          },
    { key = "AllowScrapVehicle",    label = "UI_PV_Flag_Scrap",        desc = "IGUI_PV_FlagDesc_Scrap"        },
    { key = "AllowViewMechanics",   label = "UI_PV_Flag_Mechanics",    desc = "IGUI_PV_FlagDesc_Mechanics"    },
}

-- ============================================================
-- Class definition
-- ============================================================
PV.UI.PermissionPanel = ISCollapsableWindow:derive("PV.UI.PermissionPanel")

-- ============================================================
-- Build children
-- ============================================================
function PV.UI.PermissionPanel:initialise()
    ISCollapsableWindow.initialise(self)
end

function PV.UI.PermissionPanel:createChildren()
    ISCollapsableWindow.createChildren(self)

    local theme = PV.UI.Theme
    local c = theme.colors
    local m = theme.metrics
    local PAD = m.pad
    local GAP = m.gap

    local function _trimText(font, txt, maxW)
        if not txt then return "" end
        local tm = getTextManager()
        local w = tm:MeasureStringX(font, txt)
        if w <= maxW then return txt end
        local ell = "â€¦" 
        local ellW = tm:MeasureStringX(font, ell)
        local s = txt
        while #s > 0 and (tm:MeasureStringX(font, s) + ellW) > maxW do
            s = string.sub(s, 1, #s - 1)
        end
        return s .. ell
    end


    local isPublic = (self.targetPlayer == nil)
    local entry    = PV.getVehicleDBEntry(self.sqlid)

    -- Resolve car name (nice display)
    local rawModel = (entry and entry.CarModel) or ""
    local carName  = rawModel
    local idx = string.find(rawModel, "%.")
    if idx then
        local suffix = string.sub(rawModel, idx + 1)
        carName = getTextOrNull("IGUI_VehicleName" .. suffix) or rawModel
    end

    local modeLabel = isPublic
        and getText("IGUI_PV_PublicPerms_Title")
        or  getText("IGUI_PV_PlayerPerms_Title", self.targetPlayer or "")

    -- Current flags: public effective, or per-player
    local flags = {}
    if isPublic then
        flags = PV.getEffectiveFlags and PV.getEffectiveFlags(self.sqlid) or {}
    else
        local al = entry and entry.AllowList
        if al and al[self.targetPlayer] and type(al[self.targetPlayer]) == "table" then
            for k, v in pairs(al[self.targetPlayer]) do flags[k] = v end
        end
    end

    self.flagsWorking = {}
    for _, def in ipairs(FLAG_DEFS) do
        self.flagsWorking[def.key] = flags[def.key] == true
    end

    local contentY = PAD_TOP + PAD
    local contentH = self.height - contentY - PAD

    local minInfoH  = math.floor(130 * m.scale)
    local infoH     = minInfoH
    local flagsH    = contentH - infoH - GAP
    local minFlagsH = math.floor(260 * m.scale)
    if flagsH < minFlagsH then
        flagsH = minFlagsH
        infoH  = math.max(minInfoH, contentH - flagsH - GAP)
    end

    -- ========================================================
    -- INFO CARD (title + mode + buttons)
    -- ========================================================
    self.cardInfo = PV.UI.CardPanel:new(PAD, contentY, self.width - PAD * 2, infoH, getText("UI_PV_Perms_Section_Info"))
    self.cardInfo:initialise(); self.cardInfo:instantiate()
    self:addChild(self.cardInfo)

    local ix, iy, iw, ih = self.cardInfo:getInnerRect()

    local titleFont = UIFont.NewMedium
    local fH = getTextManager():getFontHeight(titleFont)

    local btnH = math.floor(28 * m.scale)
    local btnW = math.floor(130 * m.scale)
    btnW = math.min(btnW, math.floor(iw * 0.38))
    local minBtnW = math.floor(90 * m.scale)
    if btnW < minBtnW then btnW = minBtnW end

    local btnX = ix + iw - btnW
    local btnY = iy

    local labelMaxW = math.max(40, btnX - GAP - ix)
    local carText  = _trimText(titleFont, carName, labelMaxW)
    local modeText = _trimText(UIFont.NewSmall, modeLabel, labelMaxW)

    self.lblCar = ISLabel:new(ix, iy, fH, carText, c.text.r, c.text.g, c.text.b, 1, titleFont, true)
    self.lblCar:initialise(); self.lblCar:instantiate()
    self.cardInfo:addChild(self.lblCar)

    self.lblMode = ISLabel:new(ix, iy + fH + 2, FONT_HGT_SMALL, modeText,
        isPublic and 0.90 or 0.55,
        isPublic and 0.55 or 0.90,
        isPublic and 0.55 or 0.55,
        1, UIFont.NewSmall, true)
    self.lblMode:initialise(); self.lblMode:instantiate()
    self.cardInfo:addChild(self.lblMode)

    -- FIXED: Criando closures locais para os callbacks dos botÃµes
    local panelRef = self
    local function onSaveClick(btn)
        panelRef:onSave(btn)
    end
    local function onCloseClick(btn)
        panelRef:onClose(btn)
    end

    -- Buttons (stacked right) to avoid overlap on narrow windows
    self.btnSave = ISButton:new(btnX, btnY, btnW, btnH, getText("IGUI_PV_Save"), self, onSaveClick)
    self.btnSave.internal = "btnSave"
    self.btnSave:initialise(); self.btnSave:instantiate()
    PV.UI.ApplyButtonStyle(self.btnSave, "success")
    self.cardInfo:addChild(self.btnSave)

    self.btnClose = ISButton:new(btnX, btnY + btnH + GAP, btnW, btnH, getText("IGUI_PV_Close"), self, onCloseClick)
    self.btnClose.internal = "btnClose"
    self.btnClose:initialise(); self.btnClose:instantiate()
    PV.UI.ApplyButtonStyle(self.btnClose, "primary")
    self.cardInfo:addChild(self.btnClose)

    -- ========================================================
    -- FLAGS CARD (list + description)
    -- ========================================================
    local flagsY = contentY + infoH + GAP
    self.cardFlags = PV.UI.CardPanel:new(PAD, flagsY, self.width - PAD * 2, flagsH, getText("UI_PV_Perms_Section_Flags"))
    self.cardFlags:initialise(); self.cardFlags:instantiate()
    self:addChild(self.cardFlags)

    local fx, fy, fw, fh = self.cardFlags:getInnerRect()
    local listW = math.floor(fw * 0.52)
    local minListW = math.floor(220 * m.scale)
    local minDescW = math.floor(200 * m.scale)
    if listW < minListW then listW = minListW end
    if (fw - listW - GAP) < minDescW then listW = fw - minDescW - GAP end
    local descW = fw - listW - GAP

    self.listFlags = ISScrollingListBox:new(fx, fy, listW, fh)
    self.listFlags:initialise(); self.listFlags:instantiate()
    self.listFlags:setFont(UIFont.NewSmall, 4)
    self.listFlags.itemheight = math.max(FONT_HGT_SMALL + 14, math.floor(28 * m.scale))
    PV.UI.ApplyListStyle(self.listFlags)

    -- Populate list
    for _, def in ipairs(FLAG_DEFS) do
        local label = getText(def.label)
        local desc  = getTextOrNull(def.desc) or ""
        local data  = { key = def.key, label = label, desc = desc, value = self.flagsWorking[def.key] == true }
        self.listFlags:addItem(label, data)
    end

    -- FIXED: Criando closure local para o callback da lista
    local listRef = self.listFlags
    local panelRef2 = self
    
    self.listFlags.doDrawItem = function(list, y, item, alt)
        if y + list:getYScroll() + list.itemheight < 0 or
           y + list:getYScroll() >= list.height then
            return y + list.itemheight
        end

        local h = list.itemheight
        local data = item and item.item or nil
        if not data then return y + h end

        local isSel   = (list.selected == item.index)
        local isHover = (list.mouseoverselected == item.index) and not isSel

        local bg = c.listBg or {r=0.08, g=0.08, b=0.10, a=1}
        if isSel and c.listSelected then bg = c.listSelected
        elseif isHover and c.listHover then bg = c.listHover
        elseif alt and c.listAltBg then bg = c.listAltBg end

        list:drawRect(0, y, list:getWidth(), h, bg.a or 1, bg.r, bg.g, bg.b)

        -- Toggle pill (right)
        local pillW = math.floor(56 * m.scale)
        local pillH = math.floor(16 * m.scale)
        local px = list:getWidth() - pillW - 10
        local py = y + math.floor((h - pillH) / 2)

        -- Label (trimmed so it doesn't draw under the pill)
        local label = data.label or item.text or ""
        local maxW = px - 12
        label = _trimText(UIFont.NewSmall, label, maxW)
        local ty = y + math.floor((h - FONT_HGT_SMALL) / 2)
        list:drawText(label, 10, ty, c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall)

        local on = (data.value == true)
        local pbg = on and c.btnSuccess or c.btnDanger
        list:drawRect(px, py, pillW, pillH, 0.9, pbg.r, pbg.g, pbg.b)
        list:drawRectBorder(px, py, pillW, pillH, 1, c.cardBorder.r, c.cardBorder.g, c.cardBorder.b)

        local txt = on and getText("UI_PV_Toggle_On") or getText("UI_PV_Toggle_Off")
        local tw = getTextManager():MeasureStringX(UIFont.NewSmall, txt)
        local txtY = py + math.floor((pillH - FONT_HGT_SMALL) / 2)
        list:drawText(txt, px + (pillW - tw) / 2, txtY, 1, 1, 1, 1, UIFont.NewSmall)

        if c.divider then
            list:drawRect(0, y + h - 1, list:getWidth(), 1, 0.45, c.divider.r, c.divider.g, c.divider.b)
        end

        return y + h
    end

    self.listFlags.onMouseDown = function(list, x, y)
        if #list.items == 0 then return end
        local row = list:rowAt(x, y)
        if row < 1 or row > #list.items then return end
        list.selected = row
        getSoundManager():playUISound("UISelectListItem")

        local data = list.items[row].item
        if data then
            data.value = not (data.value == true)
            panelRef2.flagsWorking[data.key] = data.value == true
            panelRef2:updateFlagDescription()
        end
    end

    self.cardFlags:addChild(self.listFlags)

    -- Description panel
    self.descPanel = ISRichTextPanel:new(fx + listW + GAP, fy, descW, fh)
    self.descPanel:initialise(); self.descPanel:instantiate()
    self.descPanel.background = true
    self.descPanel.backgroundColor = { r=c.listAltBg.r, g=c.listAltBg.g, b=c.listAltBg.b, a=0.55 }
    pcall(function() self.descPanel:setMargins(10, 8, 10, 10) end)
    self.cardFlags:addChild(self.descPanel)

    -- Default selection
    if #self.listFlags.items > 0 then
        self.listFlags.selected = 1
    end
    self:updateFlagDescription()
end


function PV.UI.PermissionPanel:onToggled(index, selected)
    -- handled on Save
end

function PV.UI.PermissionPanel:onSave(btn)
    -- FIXED: ProteÃ§Ã£o mais robusta e fallback seguro
    local newFlags = {}
    
    if self.flagsWorking and type(self.flagsWorking) == "table" then
        for k, v in pairs(self.flagsWorking) do
            newFlags[k] = (v == true)
        end
    else
        -- fallback (legacy)
        if self.checks and type(self.checks) == "table" then
            for key, tick in pairs(self.checks) do
                if tick and tick.isSelected then
                    newFlags[key] = tick:isSelected(1)
                end
            end
        end
    end

    -- FIXED: ProteÃ§Ã£o contra funÃ§Ãµes nÃ£o disponÃ­veis
    if self.targetPlayer == nil then
        -- Public flags
        local delta = newFlags
        
        -- Tentar usar computeFlagsDelta se disponÃ­vel
        if PV.computeFlagsDelta and type(PV.computeFlagsDelta) == "function" then
            local ok, result = pcall(PV.computeFlagsDelta, self.sqlid, newFlags)
            if ok and type(result) == "table" then
                delta = result
            end
        end
        
        local hasDelta = false
        if type(delta) == "table" then
            for _ in pairs(delta) do hasDelta = true; break end
        end
        if hasDelta then
            sendClientCommand(getPlayer(), "ProtectVehicle", "updateFlags", { sqlid = self.sqlid, delta = delta })
            getPlayer():setHaloNote(getText("IGUI_PV_Saved"), 0, 1, 0, 300)
        end
    else
        -- Per-player flags
        sendClientCommand(getPlayer(), "ProtectVehicle", "updatePlayerFlags", { 
            sqlid = self.sqlid, 
            targetPlayer = self.targetPlayer, 
            flags = newFlags 
        })
        getPlayer():setHaloNote(getText("IGUI_PV_Saved"), 0, 1, 0, 300)
    end
    
    self:close()
end

function PV.UI.PermissionPanel:onClose(btn)
    self:close()
end

-- ============================================================
-- Render: draw separators
-- ============================================================
function PV.UI.PermissionPanel:render()
    ISCollapsableWindow.render(self)
end

-- ============================================================
-- close
-- ============================================================
function PV.UI.PermissionPanel:close()
    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
end

function PV.UI.PermissionPanel:prerender()
    ISCollapsableWindow.prerender(self)
end

-- ============================================================
-- Constructor
-- mode: nil = public flags, string = per-player flags for that username
-- ============================================================
function PV.UI.PermissionPanel:new(x, y, width, height, sqlid, targetPlayer)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index     = self
    o.showBackground = true
    local c = (PV.UI.Theme and PV.UI.Theme.colors) or {}
    o.backgroundColor = c.windowBg or {r=0.08, g=0.08, b=0.10, a=0.97}
    o.showBorder     = true
    o.borderColor    = c.windowBorder or {r=0.55, g=0.15, b=0.15, a=1}
    o.title          = (targetPlayer == nil)
                        and getText("IGUI_PV_PublicPerms_WindowTitle")
                        or  getText("IGUI_PV_PlayerPerms_WindowTitle")
    o.width          = width
    o.height         = height
    o.visibleTarget  = o
    o.moveWithMouse  = true
    o.pin            = true
    o.sqlid          = sqlid
    o.targetPlayer   = targetPlayer  -- nil = public, string = per-player
    o.checks         = {}
    o:setResizable(false)
    o:setDrawFrame(true)
    return o
end

-- ============================================================
-- Open helpers
-- ============================================================
local function _panelHeight()
    local tickH = FONT_HGT_SMALL + 8
    -- btnH + PAD + sep + PAD + lblCar + lblMode + PAD + checks + bottom margin
    return (26 + 6) + 1 + 6 + FONT_HGT_SMALL + 2 + FONT_HGT_SMALL + 6
           + #FLAG_DEFS * (tickH + 2) + 14 + PAD_TOP
end

function PV.UI.OpenPermissionPanel(sqlid, targetPlayer)
    local m = (PV.UI and PV.UI.Theme and PV.UI.Theme.metrics) or { scale = 1 }
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()

    local width  = math.floor(520 * m.scale)
    local height = math.max(_panelHeight(), math.floor(520 * m.scale))
    width  = math.min(width,  sw - 60)
    height = math.min(height, sh - 60)

    local x = sw / 2 - width / 2
    local y = sh / 2 - height / 2
    local panel = PV.UI.PermissionPanel:new(x, y, width, height, sqlid, targetPlayer)
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
    return panel
end

-- ============================================================
-- Flag description
-- ============================================================
function PV.UI.PermissionPanel:updateFlagDescription()
    if not self.descPanel or not self.listFlags then return end
    local idx = self.listFlags.selected or 0
    local item = (idx > 0 and self.listFlags.items and self.listFlags.items[idx]) and self.listFlags.items[idx].item or nil
    if not item then
        self.descPanel:setText(getText("UI_PV_Perms_Hint_SelectFlag"))
        self.descPanel:paginate()
        return
    end

    local stateTxt = (item.value == true) and getText("UI_PV_Toggle_On") or getText("UI_PV_Toggle_Off")
    local title = item.label or ""
    local desc  = item.desc  or ""

    local text = "<SIZE:medium><B>" .. title .. "</B></SIZE><LINE>" ..
                 "<RGB:0.75,0.75,0.80>" .. getText("UI_PV_Perms_State", stateTxt) .. "</RGB><LINE><LINE>" ..
                 desc .. "<LINE><LINE><RGB:0.60,0.60,0.65>" .. getText("UI_PV_Perms_Hint_ClickToggle") .. "</RGB>"

    self.descPanel:setText(text)
    self.descPanel:paginate()
end

