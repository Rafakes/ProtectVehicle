--[[
    ProtectVehicle - PV_AdminManagerMain.lua
    Admin UI for global vehicle management.
    Uses ISCollapsableWindow.
    B42.14.x
    
    FIXED:
    - Coordenadas agora aparecem corretamente (loc Ã¢â€ â€™ location)
    - "Claimed On" agora aparece corretamente (date Ã¢â€ â€™ claimedDate)
    - BotÃƒÂ£o "Go To" alterado para "Teleport"
    - BotÃƒÂ£o "Locate" alterado para "Refresh Loc"
    - Unclaim agora atualiza UI corretamente apÃƒÂ³s remoÃƒÂ§ÃƒÂ£o
--]]

if not isClient() and isServer() then return end

require "UI/PV_UIShared"

PV = PV or {}
PV.UI = PV.UI or {}

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local PAD_TOP = FONT_HGT_SMALL + 1

local function PV_getOwner(list)
    return list.pvOwner
        or list.joypadParent
        or (list.parent and list.parent.parent)
        or list.parent
end


PV.UI.AdminManagerMain = ISCollapsableWindow:derive("PV.UI.AdminManagerMain")

-- ============================================================
-- Custom list mouse down
-- ============================================================
function PV.UI.AdminManagerMain:listOnMouseDown(x, y)
    if #self.items == 0 then return end
    local row = self:rowAt(x, y)
    if row > #self.items then row = #self.items end
    if row < 1 then return end
    if row == self.selected then return end
    getSoundManager():playUISound("UISelectListItem")
    self.selected = row
    if self.onmousedown then
        self.onmousedown(self.target, self.items[self.selected].item)
    end

    local owner = PV_getOwner(self)
    if owner and owner.onSelectionChange then
        owner:onSelectionChange()
    end
end

-- ============================================================
-- Selection change
-- ============================================================
function PV.UI.AdminManagerMain:onSelectionChange()
    -- Guard: buttons may not exist yet if createChildren hasn't completed
    if not self.btnLocate or not self.btnTpToVehicle or not self.btnUnclaim
    or not self.btnPermissions or not self.btnRebuild then return end

    local hasSelection = (#self.listData.items > 0 and self.listData.selected > 0
                          and self.listData.selected <= #self.listData.items)
    self.btnLocate:setEnable(hasSelection)
    self.btnTpToVehicle:setEnable(hasSelection)
    self.btnUnclaim:setEnable(hasSelection)
    self.btnPermissions:setEnable(hasSelection)
    self.btnRebuild:setEnable(true)

    if self.subPanel ~= nil then
        self.subPanel:close()
        self.subPanel:removeFromUIManager()
        self.subPanel = nil
    end
    if self.modDialog ~= nil then
        self.modDialog:close()
        self.modDialog:removeFromUIManager()
        self.modDialog = nil
    end
end

-- ============================================================
-- Custom row renderer
-- ============================================================
function PV.UI.AdminManagerMain:drawRow(y, item, alt)
    if y + self:getYScroll() + self.itemheight < 0 or
       y + self:getYScroll() >= self.height then
        return y + self.itemheight
    end

    local c = (PV.UI.Theme and PV.UI.Theme.colors) or {}
    local h = self.itemheight
    local w = self:getWidth()

    local isSel = (self.selected == item.index)
    local isHover = (self.mouseoverselected == item.index) and not isSel

    local bg = c.listBg or {r=0.08, g=0.08, b=0.10, a=1}
    if isSel and c.listSelected then bg = c.listSelected
    elseif isHover and c.listHover then bg = c.listHover
    elseif alt and c.listAltBg then bg = c.listAltBg end

    self:drawRect(0, y, w, h, bg.a or 1, bg.r, bg.g, bg.b)
    -- subtle row divider
    if c.divider then
        self:drawRect(0, y + h - 1, w, 1, 0.45, c.divider.r, c.divider.g, c.divider.b)
    end

    local a = 1
    local xOff  = 8
    local cols  = self.pvColumns or {}
    local function colX(i)
        local col = cols[i]
        if type(col) == "table" and col.size then
            return col.size
        end
        return w
    end
    local function colRange(i)
        local s = colX(i)
        local e = colX(i+1)
        if e < s then e = s end
        return s, e
    end
    local clipY  = math.max(0, y + self:getYScroll())
    local clipY2 = math.min(self.height, y + self:getYScroll() + h)

    -- Owner
    local c0s, c0e = colRange(1)
    self.javaObject:setStencilRect(c0s, clipY, c0e - c0s, clipY2 - clipY)
    self:drawText(item.item.ownerID or "", c0s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    -- SQLID
    local c1s, c1e = colRange(2)
    self.javaObject:setStencilRect(c1s, clipY, c1e - c1s, clipY2 - clipY)
    self:drawText(tostring(item.item.sqlid or ""), c1s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    -- Car model
    local c2s, c2e = colRange(3)
    self.javaObject:setStencilRect(c2s, clipY, c2e - c2s, clipY2 - clipY)
    self:drawText(item.item.carName or "", c2s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    -- Location (FIXED: location em vez de loc)
    local c3s, c3e = colRange(4)
    self.javaObject:setStencilRect(c3s, clipY, c3e - c3s, clipY2 - clipY)
    self:drawText(item.item.location or "", c3s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    -- Claim date (FIXED: claimedDate em vez de date)
    local c4s, c4e = colRange(5)
    self.javaObject:setStencilRect(c4s, clipY, c4e - c4s, clipY2 - clipY)
    self:drawText(item.item.claimedDate or "", c4s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    -- Expiry
    local c5s, c5e = colRange(6)
    self.javaObject:setStencilRect(c5s, clipY, c5e - c5s, clipY2 - clipY)
    self:drawText(item.item.expiry or "", c5s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    return y + h
end

function PV.UI.AdminManagerMain:listDrawText(str, x, y, r, g, b, a, font)
    if self.javaObject ~= nil then
        self.javaObject:DrawText(font or UIFont.NewSmall, tostring(str), x, y, r, g, b, a)
    end
end

local function PV_makeAdminColumns(totalWidth)
    local leftInset = 14
    local rightInset = 12
    local usable = math.max(0, totalWidth - leftInset - rightInset)

    local ownerX  = leftInset
    local idX     = leftInset + math.floor(usable * 0.20)
    local carX    = leftInset + math.floor(usable * 0.34)
    local locX    = leftInset + math.floor(usable * 0.56)
    local dateX   = leftInset + math.floor(usable * 0.71)
    local expiryX = leftInset + math.floor(usable * 0.85)
    local endX    = totalWidth - rightInset

    return {
        {name="owner",  size=ownerX},
        {name="id",     size=idX},
        {name="car",    size=carX},
        {name="loc",    size=locX},
        {name="date",   size=dateX},
        {name="expiry", size=expiryX},
        {name="end",    size=endX},
    }
end

-- ============================================================
-- Filter
-- FIX: Em B42 o ISTextEntryBox.onTextChange ÃƒÂ© chamado como
--   onTextChange(widgetSelf)  Ã¢â‚¬â€ nÃƒÂ£o passa o 'owner/target'.
--   Por isso usamos closures que capturam 'panel' (AdminManagerMain).
-- ============================================================
local function PV_getTextEntryValue(entry)
    if not entry then return "" end
    local ok, value = pcall(function() return entry:getInternalText() end)
    if ok and value ~= nil then return tostring(value) end
    ok, value = pcall(function() return entry:getText() end)
    if ok and value ~= nil then return tostring(value) end
    return ""
end

local function PV_buildFilterCallback(panel)
    return function(_widget)
        if panel and panel.applyFilters then panel:applyFilters() end
    end
end

function PV.UI.AdminManagerMain:storeFilterState()
    if self.textFilterOwner then self._filterOwnerText = PV_getTextEntryValue(self.textFilterOwner) end
    if self.textFilterCar then self._filterCarText = PV_getTextEntryValue(self.textFilterCar) end
end

function PV.UI.AdminManagerMain:applyFilters()
    if not self.listData then return end

    self:storeFilterState()
    local filterOwner = string.lower(self._filterOwnerText or "")
    local filterCar = string.lower(self._filterCarText or "")

    local selectedSqlid = nil
    if self.listData.selected and self.listData.selected > 0 and self.listData.items[self.listData.selected] then
        local selectedItem = self.listData.items[self.listData.selected].item
        selectedSqlid = selectedItem and selectedItem.sqlid or nil
    end

    self.listData:clear()
    local selectedIndex = 0
    for _, v in ipairs(self.varData or {}) do
        local matchOwner = (filterOwner == "") or string.find(string.lower(v.ownerID or ""), filterOwner, 1, true)
        local matchCar = (filterCar == "") or string.find(string.lower(v.carName or ""), filterCar, 1, true)
        if matchOwner and matchCar then
            self.listData:addItem(v.ownerID, v)
            if selectedSqlid ~= nil and tostring(v.sqlid or "") == tostring(selectedSqlid) then
                selectedIndex = #self.listData.items
            end
        end
    end

    self.listData.selected = selectedIndex
    self:onSelectionChange()
end

-- ============================================================
-- Populate list from DB
-- ============================================================
function PV.UI.AdminManagerMain:initList()
    self.varData = {}
    if not PV.dbByVehicleSQLID then
        self:applyFilters()
        return
    end

    local timeoutHours = (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.ClaimTimeoutHours) or 0
    local now          = getTimestamp and getTimestamp() or os.time()

    local function calcExpiry(ownerID)
        if timeoutHours <= 0 then
            return getText("IGUI_PV_Admin_Col_Expiry_Never"), false
        end
        local pData   = PV.dbByPlayerID and PV.dbByPlayerID[ownerID]
        local logoff  = pData and pData.LastKnownLogoffTime or nil
        if not logoff then
            return getText("IGUI_PV_Admin_Col_Expiry_Never"), false
        end
        local expireAt  = logoff + timeoutHours * 3600
        local remaining = expireAt - now
        if remaining <= 0 then
            return getText("IGUI_PV_Admin_Col_Expiry_Expired"), false
        end
        local expireDate = os.date("%d-%b-%y %H:%M", expireAt)
        local isOnline = (getPlayerByUsername and getPlayerByUsername(ownerID) ~= nil) or false
        if isOnline then
            return getText("IGUI_PV_Admin_Col_Expiry_Online", expireDate), true
        end
        return expireDate, false
    end

    local temp = {}
    for sqlid, data in pairs(PV.dbByVehicleSQLID) do
        local rawModel = data.CarModel or ""
    local carName  = PV.getVehicleDisplayNameFromModel(rawModel)
        local loc = ""
        if data.LastLocationX and data.LastLocationY then
            loc = tostring(data.LastLocationX) .. ", " .. tostring(data.LastLocationY)
        end
        local claimedDate = data.ClaimDateTime and os.date("%d-%b-%y %H:%M", data.ClaimDateTime) or ""
        local expiry, expiryOnline = calcExpiry(data.OwnerPlayerID or "")
        table.insert(temp, {
            sqlid         = sqlid,
            ownerID       = data.OwnerPlayerID or "?",
            carName       = carName,
            location      = loc,  -- FIXED: Usando 'location' ao invÃƒÂ©s de 'loc'
            claimedDate   = claimedDate,  -- FIXED: Usando 'claimedDate' ao invÃƒÂ©s de 'date'
            expiry        = expiry,
            expiryOnline  = expiryOnline,
        })
    end

    table.sort(temp, function(a, b)
        if a.ownerID == b.ownerID then return (a.carName or "") < (b.carName or "") end
        return (a.ownerID or "") < (b.ownerID or "")
    end)

    self.varData = temp
    self:applyFilters()
end

-- ============================================================
-- Button handler
-- ============================================================
function PV.UI.AdminManagerMain:btnOnClick(btn)
    if self.listData.selected < 1 or self.listData.selected > #self.listData.items then return end
    local entry = self.listData.items[self.listData.selected].item
    if not entry then return end

    if btn.internal == "btnLocate" then
        sendClientCommand(getPlayer(), "ProtectVehicle", "adminLocate", { sqlid = entry.sqlid })

    elseif btn.internal == "btnTpToVehicle" then
        sendClientCommand(getPlayer(), "ProtectVehicle", "adminTpToVehicle", { sqlid = entry.sqlid })

    elseif btn.internal == "btnUnclaim" then
        if self.modDialog ~= nil then
            self.modDialog:close(); self.modDialog:removeFromUIManager(); self.modDialog = nil
        end
        local w, h = 300, 110
        self.modDialog = ISModalDialog:new(
            getCore():getScreenWidth() / 2 - w / 2, getCore():getScreenHeight() / 2 - h / 2,
            w, h, getText("UI_PV_Admin_ConfirmUnclaim", entry.ownerID),
            true, self, PV.UI.AdminManagerMain.onConfirmUnclaim,
            getPlayer():getPlayerNum(), nil)
        self.modDialog:initialise()
        self.modDialog:addToUIManager()

    elseif btn.internal == "btnPermissions" then
        if self.subPanel ~= nil then
            self.subPanel:close(); self.subPanel:removeFromUIManager(); self.subPanel = nil
        end
        self.subPanel = PV.UI.OpenPermissionPanel(entry.sqlid, nil)

    elseif btn.internal == "btnRebuild" then
        sendClientCommand(getPlayer(), "ProtectVehicle", "adminRebuildDB", {})
        getPlayer():setHaloNote(getText("IGUI_PV_Admin_RebuildSent"), 0.5, 1, 0.5, 300)
    end
end

function PV.UI.AdminManagerMain:onConfirmUnclaim(btn)
    if btn.internal == "NO" then return end
    if self.listData.selected < 1 then return end
    local entry = self.listData.items[self.listData.selected].item
    if not entry then return end
    
    -- FIXED: Enviar comando unclaim
    sendClientCommand(getPlayer(), "ProtectVehicle", "unclaim", { sqlid = entry.sqlid })
    
    -- FIXED: Aguardar um frame para garantir que o servidor processa antes de atualizar UI
    -- O servidor vai enviar o comando "removeVehicle" que vai limpar o DB e atualizar a UI
    -- Mas precisamos limpar a seleÃƒÂ§ÃƒÂ£o local imediatamente para evitar clicks duplicados
    self.listData.selected = 0
    self:onSelectionChange()
end

-- ============================================================
-- initialise / createChildren
-- ============================================================
function PV.UI.AdminManagerMain:initialise()
    ISCollapsableWindow.initialise(self)
end

function PV.UI.AdminManagerMain:blockForeignOwnerSearch()
    -- BetterSafehouse injects an owner-search row into any admin-like window
    -- with a teleport button. Mark this window as already handled and remove
    -- any injected widgets if another mod raced ahead of us.
    self._BS_ownerSearchInstalled = true
    self._BS_ownerSearchInstalling = nil

    local injected = {
        "_BS_ownerSearchLabel",
        "_BS_ownerSearchEntry",
        "_BS_ownerSearchClearBtn",
    }

    for _, key in ipairs(injected) do
        local child = rawget(self, key)
        if child then
            pcall(function()
                if child.removeFromUIManager then child:removeFromUIManager() end
            end)
            pcall(function()
                if child.parent and child.parent.removeChild then
                    child.parent:removeChild(child)
                elseif self.removeChild then
                    self:removeChild(child)
                end
            end)
            self[key] = nil
        end
    end

    if self.listData and self._BS_ownerSearchOrigY then
        local origY = self._BS_ownerSearchOrigY
        local origH = self._BS_ownerSearchOrigH
        if origY then pcall(function() self.listData:setY(origY) end) end
        if origH then pcall(function() self.listData:setHeight(origH) end) end
    end

    self._BS_ownerSearchOrigY = nil
    self._BS_ownerSearchOrigH = nil
    self._BS_ownerSearchListBox = nil
    self._BS_ownerSearchAllItems = nil
    self._BS_ownerSearchBaselineCount = nil
    self._BS_ownerSearchIsFiltering = nil
end

function PV.UI.AdminManagerMain:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:blockForeignOwnerSearch()
    self:buildLayout()
end

function PV.UI.AdminManagerMain:buildLayout()
    self:storeFilterState()

    local tm    = getTextManager()
    local theme = PV.UI.Theme
    local c     = theme.colors
    local m     = theme.metrics

    local PAD = m.pad
    local GAP = m.gap

    -- Clamp to minimum without calling setWidth/setHeight (avoids breaking resize grip)
    local effectiveW = math.max(self.width,  math.floor(600 * m.scale))
    local effectiveH = math.max(self.height, math.floor(400 * m.scale))

    local contentY = PAD_TOP + PAD
    local contentH = effectiveH - contentY - PAD

    -- Layout sizing (adaptive so buttons never get clipped)
    local btnFont   = UIFont.NewSmall
    local filterFont= UIFont.NewMedium
    local filterH   = tm:getFontHeight(filterFont) + 4
    local labelH    = tm:getFontHeight(UIFont.NewSmall)
    local gapY      = math.floor(8 * m.scale)
    local btnH      = tm:getFontHeight(btnFont) + math.floor(12 * m.scale)

    -- CardPanel inner height = controlsH - (headerH + pad*2)
    local minControlsH = (labelH + 4 + filterH + gapY + btnH) + m.headerH + (m.pad * 2) + 2
    local controlsH = math.max(math.floor(132 * m.scale), minControlsH)

    local minListH  = math.floor(220 * m.scale) -- list scrolls; allow smaller on low-res/UI scale
    local listCardH = contentH - controlsH - GAP

    if listCardH < minListH then
        -- Keep controls readable; shrink the list instead.
        controlsH = math.max(minControlsH, contentH - minListH - GAP)
        listCardH = contentH - controlsH - GAP
    end

    -- Final clamp (never exceed available contentH)
    local overflow = (listCardH + controlsH + GAP) - contentH
    if overflow > 0 then
        listCardH = math.max(math.floor(100 * m.scale), listCardH - overflow)
    end

    -- ========================================================
    -- LIST CARD
    -- ========================================================
    self.cardList = PV.UI.CardPanel:new(PAD, contentY, effectiveW - PAD * 2, listCardH, getText("UI_PV_Admin_Section_List"))
    self.cardList:initialise(); self.cardList:instantiate()
    self:addChild(self.cardList)

    local colHeaderH = FONT_HGT_SMALL + 6
    local lx, ly, lw, lh = self.cardList:getInnerRect()

    -- Place list lower so the column header row (drawn ABOVE the list) remains inside the card.
    local listY = ly + colHeaderH + 2
    local listH = lh - colHeaderH - 2

    self.listData = ISScrollingListBox:new(lx, listY, lw, listH)
    self.listData:initialise(); self.listData:instantiate()
    self.listData.joypadParent = self
    self.listData.doDrawItem   = self.drawRow
    self.listData.onMouseDown  = self.listOnMouseDown
    self.listData.drawText     = self.listDrawText
    self.listData.drawBorder   = false
    self.listData:setFont(UIFont.NewSmall, 4)
    self.listData.itemheight   = tm:getFontHeight(UIFont.NewSmall) + 4

    local w = lw
    -- Define column positions manually to avoid B42.16 built-in header/search row
    self.listData.drawColumns = false
    self.listData.pvColumns = PV_makeAdminColumns(w)

    self.listHeader = ISPanel:new(lx, ly, lw, colHeaderH)
    self.listHeader:initialise()
    self.listHeader:instantiate()
    self.listHeader.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.listHeader.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.listHeader.prerender = function(panel)
        ISPanel.prerender(panel)
        local hdrColor = c.textMuted
        local cols = self.listData and self.listData.pvColumns or {}
        local titles = {
            getText("IGUI_PV_Admin_Col_Owner"),
            getText("IGUI_PV_Admin_Col_ID"),
            getText("IGUI_PV_Admin_Col_Car"),
            getText("IGUI_PV_Admin_Col_Loc"),
            getText("IGUI_PV_Admin_Col_Date"),
            getText("IGUI_PV_Admin_Col_Expiry"),
        }

        for i = 1, #titles do
            local col = cols[i]
            if col and col.size then
                panel:drawText(titles[i], col.size, 2, hdrColor.r, hdrColor.g, hdrColor.b, 1, UIFont.NewSmall)
            end
        end

        panel:drawRect(0, panel.height - 1, panel.width, 1, 0.45, c.divider.r, c.divider.g, c.divider.b)
    end
    self.cardList:addChild(self.listHeader)

    PV.UI.ApplyListStyle(self.listData)
    self.listData.pvOwner = self
    self.cardList:addChild(self.listData)

    -- ========================================================
    -- CONTROLS CARD (filters + buttons)
    -- ========================================================
    local controlsY = contentY + listCardH + GAP
    self.cardControls = PV.UI.CardPanel:new(PAD, controlsY, effectiveW - PAD * 2, controlsH, getText("UI_PV_Admin_Section_Controls"))
    self.cardControls:initialise(); self.cardControls:instantiate()
    self:addChild(self.cardControls)

    local cx, cy, cw, ch = self.cardControls:getInnerRect()
    -- Uses filterH/btnH/btnFont from layout sizing above

    -- Filter row
    local groupGap  = math.floor(18 * m.scale)
    local labelToBoxGap = 4
    local groupsW   = math.max(0, cw - groupGap)
    local group1W   = math.floor(groupsW / 2)
    local group2W   = groupsW - group1W
    local ownerText = getText("IGUI_PV_Admin_Filter_Owner")
    local carText   = getText("IGUI_PV_Admin_Filter_Car")
    local boxY = cy + labelH + labelToBoxGap
    local box1W     = math.max(80, group1W)
    local box2W     = math.max(80, group2W)
    local ownerFilterText = self._filterOwnerText or ""
    local carFilterText = self._filterCarText or ""

    local lblOwner = ISLabel:new(cx, cy, labelH, ownerText, c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
    lblOwner:initialise(); lblOwner:instantiate(); self.cardControls:addChild(lblOwner)

    self.textFilterOwner = ISTextEntryBox:new(ownerFilterText, cx, boxY, box1W, filterH)
    self.textFilterOwner.font = UIFont.NewMedium
    self.textFilterOwner:initialise(); self.textFilterOwner:instantiate()
    self.textFilterOwner.onTextChange = PV_buildFilterCallback(self)
    self.textFilterOwner:setClearButton(true)
    self.cardControls:addChild(self.textFilterOwner)

    local lbl2X = cx + group1W + groupGap
    local lblCar = ISLabel:new(lbl2X, cy, labelH, carText, c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
    lblCar:initialise(); lblCar:instantiate(); self.cardControls:addChild(lblCar)

    self.textFilterCar = ISTextEntryBox:new(carFilterText, lbl2X, boxY, box2W, filterH)
    self.textFilterCar.font = UIFont.NewMedium
    self.textFilterCar:initialise(); self.textFilterCar:instantiate()
    self.textFilterCar.onTextChange = PV_buildFilterCallback(self)
    self.textFilterCar:setClearButton(true)
    self.cardControls:addChild(self.textFilterCar)

    -- Buttons row
    local btnY = boxY + filterH + gapY
    local PAD_BTN = math.floor(8 * m.scale)
    local nBtns = 5
    local usable = cw - (nBtns - 1) * PAD_BTN
    local baseW  = math.floor(usable / nBtns)
    local extra  = usable - (baseW * nBtns)

    local bx = cx
    local btnIndex = 1
    local function nextW()
        local w = baseW
        if btnIndex == nBtns then w = baseW + extra end
        btnIndex = btnIndex + 1
        return w
    end

    local function addBtn(label, internal, variant)
        local w = nextW()
        local b = ISButton:new(bx, btnY, w, btnH, label, self, self.btnOnClick)
        b.internal = internal
        b.font = btnFont
        b:initialise(); b:instantiate()
        PV.UI.ApplyButtonStyle(b, variant)
        b:setEnable(false)
        self.cardControls:addChild(b)
        bx = bx + w + PAD_BTN
        return b
    end

    -- FIXED: Textos alterados conforme solicitado
    self.btnLocate      = addBtn("Refresh Loc",  "btnLocate",      "primary")  -- Alterado de "Locate"
    self.btnTpToVehicle = addBtn("Teleport", "btnTpToVehicle", "primary")  -- Alterado de "Go To"
    self.btnUnclaim     = addBtn(getText("IGUI_PV_Admin_ForceUnclaim"),      "btnUnclaim",     "danger")
    self.btnPermissions = addBtn(getText("IGUI_PV_Admin_Permissions"),       "btnPermissions", "primary")
    self.btnRebuild     = addBtn(getText("IGUI_PV_Admin_Rebuild"),           "btnRebuild",     "success")
    self.btnRebuild:setEnable(true)

    self:initList()
    self:onSelectionChange()
    self:blockForeignOwnerSearch()
end

function PV.UI.AdminManagerMain:close()
    -- Save current size/position before closing
    local player = getPlayer and getPlayer()
    if player then
        local md = player:getModData()
        md.PV_WindowSizes = md.PV_WindowSizes or {}
        md.PV_WindowSizes.admin = { w = self.width, h = self.height, x = self.x, y = self.y }
    end
    ISCollapsableWindow.close(self)
    if self.subPanel  ~= nil then self.subPanel:close();  self.subPanel:removeFromUIManager();  self.subPanel  = nil end
    if self.modDialog ~= nil then self.modDialog:close(); self.modDialog:removeFromUIManager(); self.modDialog = nil end
    if PV.UI.AdminInstance then PV.UI.AdminInstance = nil end
    self:removeFromUIManager()
end

function PV.UI.AdminManagerMain:prerender()
    self:blockForeignOwnerSearch()

    -- B42: onResize() is not reliably called by the Java grip.
    -- Detect size changes here and rebuild layout after 2 stable frames (debounce).
    local w, h = self.width, self.height
    if self._pvPrevW == nil then
        -- First frame: just record, do not rebuild
        self._pvPrevW, self._pvPrevH = w, h
    elseif w ~= self._pvPrevW or h ~= self._pvPrevH then
        self._pvPrevW, self._pvPrevH = w, h
        self._pvResizeCooldown = 2
    elseif self._pvResizeCooldown and self._pvResizeCooldown > 0 then
        self._pvResizeCooldown = self._pvResizeCooldown - 1
        if self._pvResizeCooldown == 0 then
            self:storeFilterState()
            if self.cardList     then self:removeChild(self.cardList);     self.cardList     = nil end
            if self.cardControls then self:removeChild(self.cardControls); self.cardControls = nil end
            self:buildLayout()
            local player = getPlayer and getPlayer()
            if player then
                local md = player:getModData()
                md.PV_WindowSizes = md.PV_WindowSizes or {}
                md.PV_WindowSizes.admin = { w = w, h = h, x = self.x, y = self.y }
            end
        end
    end

    ISCollapsableWindow.prerender(self)
end
function PV.UI.AdminManagerMain:render()    ISCollapsableWindow.render(self)    end

-- ============================================================
-- Constructor
-- ============================================================
function PV.UI.AdminManagerMain:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index      = self
    o.showBackground  = true
    local c = (PV.UI.Theme and PV.UI.Theme.colors) or {}
    o.backgroundColor = c.windowBg or {r=0.08, g=0.08, b=0.10, a=0.97}
    o.showBorder      = true
    o.borderColor     = c.windowBorder or {r=0.55, g=0.15, b=0.15, a=1}
    o.title           = getText("IGUI_PV_Admin_Title")
    o.width           = width
    o.height          = height
    o.visibleTarget   = o
    o.moveWithMouse   = true
    o.pin             = true
    o.varData         = {}
    o.subPanel        = nil
    o.modDialog       = nil
    o._BS_ownerSearchInstalled = true
    o:setResizable(true)
    o:setDrawFrame(true)
    local s = (PV.UI.Theme and PV.UI.Theme.metrics and PV.UI.Theme.metrics.scale) or 1
    o.minimumWidth  = math.floor(600 * s)
    o.minimumHeight = math.floor(400 * s)
    return o
end

function PV.UI.OpenAdminManager()
    if PV.UI.AdminInstance ~= nil then PV.UI.AdminInstance:close() end
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()

    local s = (PV.UI.Theme and PV.UI.Theme.metrics and PV.UI.Theme.metrics.scale) or 1
    local minW = math.floor(600 * s)
    local minH = math.floor(400 * s)

    local width  = math.min(1100, screenW - 40)
    local height = math.min(700, screenH - 60)
    if height < 500 then height = math.max(480, screenH - 40) end
    local x = screenW / 2 - width  / 2
    local y = math.max(20, screenH / 2 - height / 2)

    -- Restore last saved size/position if available
    local player = getPlayer and getPlayer()
    if player then
        local saved = player:getModData().PV_WindowSizes and player:getModData().PV_WindowSizes.admin
        if saved then
            width  = math.max(minW, math.min(saved.w or width,  screenW - 20))
            height = math.max(minH, math.min(saved.h or height, screenH - 20))
            x = saved.x and math.max(0, math.min(saved.x, screenW - width))  or x
            y = saved.y and math.max(0, math.min(saved.y, screenH - height)) or y
        end
    end
    PV.UI.AdminInstance = PV.UI.AdminManagerMain:new(x, y, width, height)
    PV.UI.AdminInstance:initialise()
    PV.UI.AdminInstance:addToUIManager()
    PV.UI.AdminInstance:setVisible(true)
end
