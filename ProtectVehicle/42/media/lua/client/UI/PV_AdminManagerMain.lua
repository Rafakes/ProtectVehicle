--[[
    ProtectVehicle - PV_AdminManagerMain.lua
    Admin UI for global vehicle management.
    Uses ISCollapsableWindow (B42 pattern from AVCS4213).
    B42.14.x
--]]

if not isClient() and isServer() then return end

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local PAD_TOP = FONT_HGT_SMALL + 1

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
    self.parent:onSelectionChange()
end

-- ============================================================
-- Selection change
-- ============================================================
function PV.UI.AdminManagerMain:onSelectionChange()
    local hasSelection = (#self.listData.items > 0 and self.listData.selected > 0
                          and self.listData.selected <= #self.listData.items)
    self.btnLocate:setEnable(hasSelection)
    self.btnTeleport:setEnable(hasSelection)
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

    local a = 0.9
    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), self.itemheight, 0.3, 0.2, 0.6, 0.9)
    end
    if alt then
        self:drawRect(0, y, self:getWidth(), self.itemheight, 0.15, 0.3, 0.55, 0.55)
    end
    self:drawRectBorder(0, y, self:getWidth(), self.itemheight,
        a, self.borderColor.r, self.borderColor.g, self.borderColor.b)

    local xOff  = 8
    local cols   = self.columns
    local clipY  = math.max(0, y + self:getYScroll())
    local clipY2 = math.min(self.height, y + self:getYScroll() + self.itemheight)

    -- Owner
    local c0s, c0e = cols[1].size, cols[2].size
    self:setStencilRect(c0s, clipY, c0e - c0s, clipY2 - clipY)
    self:drawText(item.item.ownerID or "", c0s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    -- SQLID
    local c1s, c1e = cols[2].size, cols[3].size
    self.javaObject:DrawTextureScaledColor(nil, c1s, y, 1, self.itemheight,
        self.borderColor.r, self.borderColor.g, self.borderColor.b, self.borderColor.a)
    self:setStencilRect(c1s, clipY, c1e - c1s, clipY2 - clipY)
    self:drawText(tostring(item.item.sqlid or ""), c1s + xOff, y + 3, 0.7, 0.85, 1, a, self.font)
    self:clearStencilRect()

    -- Car Name
    local c2s, c2e = cols[3].size, cols[4].size
    self.javaObject:DrawTextureScaledColor(nil, c2s, y, 1, self.itemheight,
        self.borderColor.r, self.borderColor.g, self.borderColor.b, self.borderColor.a)
    self:setStencilRect(c2s, clipY, c2e - c2s, clipY2 - clipY)
    self:drawText(item.item.carName or "", c2s + xOff, y + 3, 1, 1, 1, a, self.font)
    self:clearStencilRect()

    -- Location
    local c3s, c3e = cols[4].size, cols[5].size
    self.javaObject:DrawTextureScaledColor(nil, c3s, y, 1, self.itemheight,
        self.borderColor.r, self.borderColor.g, self.borderColor.b, self.borderColor.a)
    self:setStencilRect(c3s, clipY, c3e - c3s, clipY2 - clipY)
    self:drawText(item.item.location or "", c3s + xOff, y + 3, 0.6, 1, 0.6, a, self.font)
    self:clearStencilRect()

    -- Claimed Date
    local c4s = cols[5].size
    self.javaObject:DrawTextureScaledColor(nil, c4s, y, 1, self.itemheight,
        self.borderColor.r, self.borderColor.g, self.borderColor.b, self.borderColor.a)
    self:drawText(item.item.claimedDate or "", c4s + xOff, y + 3, 0.85, 0.85, 0.85, a, self.font)

    return y + self.itemheight
end

function PV.UI.AdminManagerMain:listDrawText(str, x, y, r, g, b, a, font)
    if self.javaObject ~= nil then
        self.javaObject:DrawText(font or UIFont.NewSmall, tostring(str), x, y, r, g, b, a)
    end
end

-- ============================================================
-- Filter
-- ============================================================
function PV.UI.AdminManagerMain:onFilterChange()
    local filterOwner = string.lower(self.parent.textFilterOwner:getInternalText() or "")
    local filterCar   = string.lower(self.parent.textFilterCar:getInternalText() or "")
    self.parent.listData:clear()
    for _, v in ipairs(self.parent.varData) do
        local matchOwner = (filterOwner == "") or string.find(string.lower(v.ownerID or ""), filterOwner, 1, true)
        local matchCar   = (filterCar   == "") or string.find(string.lower(v.carName or ""), filterCar,   1, true)
        if matchOwner and matchCar then
            self.parent.listData:addItem(v.ownerID, v)
        end
    end
    self.parent:onSelectionChange()
end

-- ============================================================
-- Populate list from DB
-- ============================================================
function PV.UI.AdminManagerMain:initList()
    self.varData = {}
    self.listData:clear()
    if not PV.dbByVehicleSQLID then return end

    local temp = {}
    for sqlid, data in pairs(PV.dbByVehicleSQLID) do
        local rawModel = data.CarModel or ""
        local carName  = rawModel
        local idx = string.find(rawModel, "%.")
        if idx then
            carName = getTextOrNull("IGUI_VehicleName" .. string.sub(rawModel, idx + 1)) or rawModel
        end
        local loc = ""
        if data.LastLocationX and data.LastLocationY then
            loc = tostring(data.LastLocationX) .. ", " .. tostring(data.LastLocationY)
        end
        local claimedDate = data.ClaimDateTime and os.date("%d-%b-%y %H:%M", data.ClaimDateTime) or ""
        table.insert(temp, {
            sqlid       = sqlid,
            ownerID     = data.OwnerPlayerID or "?",
            carName     = carName,
            location    = loc,
            claimedDate = claimedDate,
        })
    end

    table.sort(temp, function(a, b)
        if a.ownerID == b.ownerID then return (a.carName or "") < (b.carName or "") end
        return (a.ownerID or "") < (b.ownerID or "")
    end)

    self.varData = temp
    for _, v in ipairs(temp) do
        self.listData:addItem(v.ownerID, v)
    end
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

    elseif btn.internal == "btnTeleport" then
        local pX, pY, pZ = math.floor(getPlayer():getX()), math.floor(getPlayer():getY()), math.floor(getPlayer():getZ())
        sendClientCommand(getPlayer(), "ProtectVehicle", "adminTeleport",
            { sqlid = entry.sqlid, x = pX, y = pY, z = pZ })

    elseif btn.internal == "btnTpToVehicle" then
        sendClientCommand(getPlayer(), "ProtectVehicle", "adminTpToVehicle", { sqlid = entry.sqlid })

    elseif btn.internal == "btnUnclaim" then
        if self.modDialog ~= nil then
            self.modDialog:close(); self.modDialog:removeFromUIManager(); self.modDialog = nil
        end
        local w, h = 300, 110
        self.modDialog = ISModalDialog:new(
            getCore():getScreenWidth() / 2 - w / 2, getCore():getScreenHeight() / 2 - h / 2,
            w, h, getText("IGUI_PV_Admin_ConfirmUnclaim", entry.ownerID),
            true, self, PV.UI.AdminManagerMain.onConfirmUnclaim,
            getPlayer():getPlayerNum(), nil)
        self.modDialog:initialise()
        self.modDialog:addToUIManager()

    elseif btn.internal == "btnPermissions" then
        if self.subPanel ~= nil then
            self.subPanel:close(); self.subPanel:removeFromUIManager(); self.subPanel = nil
        end
        self.subPanel = PV.UI.PermissionPanel:new(
            getCore():getScreenWidth() / 2 - 160, getCore():getScreenHeight() / 2 - 230, 320, 460)
        self.subPanel.sqlid = entry.sqlid
        self.subPanel:initialise()
        self.subPanel:addToUIManager()
        self.subPanel:setVisible(true)

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
    sendClientCommand(getPlayer(), "ProtectVehicle", "unclaim", { sqlid = entry.sqlid })
    for i, v in ipairs(self.varData) do
        if v.sqlid == entry.sqlid then table.remove(self.varData, i); break end
    end
    self.listData:removeItemByIndex(self.listData.selected)
    self:onSelectionChange()
end

-- ============================================================
-- initialise / createChildren
-- ============================================================
function PV.UI.AdminManagerMain:initialise()
    ISCollapsableWindow.initialise(self)
end

function PV.UI.AdminManagerMain:createChildren()
    ISCollapsableWindow.createChildren(self)

    local listTop    = PAD_TOP + 4
    local btnH       = 26
    local filterH    = getTextManager():getFontHeight(UIFont.NewMedium) + 4
    local bottomArea = filterH + 6 + btnH + 8
    local listH      = self.height - listTop - bottomArea

    -- List
    self.listData = ISScrollingListBox:new(5, listTop, self.width - 10, listH)
    self.listData:initialise()
    self.listData:instantiate()
    self.listData.joypadParent = self
    self.listData.doDrawItem   = self.drawRow
    self.listData.onMouseDown  = self.listOnMouseDown
    self.listData.drawText     = self.listDrawText
    self.listData.drawBorder   = true

    local w = self.width - 10
    self.listData:addColumn(getText("IGUI_PV_Admin_Col_Owner"), 0)
    self.listData:addColumn(getText("IGUI_PV_Admin_Col_ID"),    math.floor(w * 0.22))
    self.listData:addColumn(getText("IGUI_PV_Admin_Col_Car"),   math.floor(w * 0.35))
    self.listData:addColumn(getText("IGUI_PV_Admin_Col_Loc"),   math.floor(w * 0.60))
    self.listData:addColumn(getText("IGUI_PV_Admin_Col_Date"),  math.floor(w * 0.75))
    self.listData:setFont(UIFont.NewSmall, 4)
    self:addChild(self.listData)

    -- Filter row
    local filterY    = listTop + listH + 6
    local filterLblW = 55
    local filterW    = math.floor((self.width - 10 - filterLblW * 2 - 8) / 2)

    local lblOwner = ISLabel:new(5, filterY + 2, filterH, getText("IGUI_PV_Admin_Filter_Owner"), 0.8, 0.8, 0.8, 1, UIFont.NewSmall, true)
    lblOwner:initialise(); lblOwner:instantiate(); self:addChild(lblOwner)

    self.textFilterOwner = ISTextEntryBox:new("", 5 + filterLblW, filterY, filterW, filterH)
    self.textFilterOwner.font = UIFont.NewMedium
    self.textFilterOwner:initialise(); self.textFilterOwner:instantiate()
    self.textFilterOwner.onTextChange = self.onFilterChange
    self.textFilterOwner.target = self
    self.textFilterOwner:setClearButton(true)
    self:addChild(self.textFilterOwner)

    local lblCar = ISLabel:new(5 + filterLblW + filterW + 8, filterY + 2, filterH, getText("IGUI_PV_Admin_Filter_Car"), 0.8, 0.8, 0.8, 1, UIFont.NewSmall, true)
    lblCar:initialise(); lblCar:instantiate(); self:addChild(lblCar)

    self.textFilterCar = ISTextEntryBox:new("", 5 + filterLblW + filterW + 8 + filterLblW, filterY, filterW, filterH)
    self.textFilterCar.font = UIFont.NewMedium
    self.textFilterCar:initialise(); self.textFilterCar:instantiate()
    self.textFilterCar.onTextChange = self.onFilterChange
    self.textFilterCar.target = self
    self.textFilterCar:setClearButton(true)
    self:addChild(self.textFilterCar)

    -- Action buttons (6 buttons)
    local btnY = filterY + filterH + 6
    local btnW = math.floor((self.width - 10 - 5 * 4) / 6)
    local bx   = 5

    local function addBtn(label, internal, bgColor)
        local b = ISButton:new(bx, btnY, btnW, btnH, label, self, self.btnOnClick)
        b.internal = internal
        if bgColor then b.backgroundColor = bgColor end
        b:initialise(); b:instantiate(); b:setEnable(false)
        self:addChild(b)
        bx = bx + btnW + 4
        return b
    end

    self.btnLocate      = addBtn(getText("IGUI_PV_Admin_Locate"),          "btnLocate",      nil)
    self.btnTeleport    = addBtn(getText("IGUI_PV_Admin_Teleport"),         "btnTeleport",    nil)
    self.btnTpToVehicle = addBtn(getText("IGUI_PV_Admin_TeleportToVehicle"),"btnTpToVehicle", {r=0.05, g=0.25, b=0.35, a=1})
    self.btnUnclaim     = addBtn(getText("IGUI_PV_Admin_ForceUnclaim"),     "btnUnclaim",     {r=0.35, g=0.05, b=0.05, a=1})
    self.btnPermissions = addBtn(getText("IGUI_PV_Admin_Permissions"),      "btnPermissions", nil)
    self.btnRebuild     = addBtn(getText("IGUI_PV_Admin_Rebuild"),          "btnRebuild",     {r=0.05, g=0.2,  b=0.35, a=1})
    self.btnRebuild:setEnable(true)

    self:initList()
    self:onSelectionChange()
end

-- ============================================================
-- close / render
-- ============================================================
function PV.UI.AdminManagerMain:close()
    ISCollapsableWindow.close(self)
    if self.subPanel  ~= nil then self.subPanel:close();  self.subPanel:removeFromUIManager();  self.subPanel  = nil end
    if self.modDialog ~= nil then self.modDialog:close(); self.modDialog:removeFromUIManager(); self.modDialog = nil end
    if PV.UI.AdminInstance then PV.UI.AdminInstance = nil end
    self:removeFromUIManager()
end

function PV.UI.AdminManagerMain:prerender() ISCollapsableWindow.prerender(self) end
function PV.UI.AdminManagerMain:render()    ISCollapsableWindow.render(self)    end

-- ============================================================
-- Constructor
-- ============================================================
function PV.UI.AdminManagerMain:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index      = self
    o.showBackground  = true
    o.backgroundColor = {r=0.10, g=0.10, b=0.14, a=0.97}
    o.showBorder      = true
    o.borderColor     = {r=0.35, g=0.45, b=0.65, a=1}
    o.title           = getText("IGUI_PV_Admin_Title")
    o.width           = width
    o.height          = height
    o.visibleTarget   = o
    o.moveWithMouse   = true
    o.pin             = true
    o.varData         = {}
    o.subPanel        = nil
    o.modDialog       = nil
    o:setResizable(false)
    o:setDrawFrame(true)
    return o
end

function PV.UI.OpenAdminManager()
    if PV.UI.AdminInstance ~= nil then PV.UI.AdminInstance:close() end
    local width, height = 900, 520
    local x = getCore():getScreenWidth()  / 2 - width  / 2
    local y = getCore():getScreenHeight() / 2 - height / 2
    PV.UI.AdminInstance = PV.UI.AdminManagerMain:new(x, y, width, height)
    PV.UI.AdminInstance:initialise()
    PV.UI.AdminInstance:addToUIManager()
    PV.UI.AdminInstance:setVisible(true)
end
