--[[
    ProtectVehicle - PV_UserManagerMain.lua
    Player UI to list and manage their own claimed vehicles.
    Uses ISCollapsableWindow (B42 pattern from AVCS4213).
    B42.14.x
--]]

if not isClient() and isServer() then return end

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local PAD_TOP = FONT_HGT_SMALL + 1

-- ============================================================
-- Class definition
-- ============================================================
PV.UI.UserManagerMain = ISCollapsableWindow:derive("PV.UI.UserManagerMain")

-- ============================================================
-- Custom list: intercept mouse click to call selection handler
-- ============================================================
function PV.UI.UserManagerMain:listOnMouseDown(x, y)
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
-- Selection change → update info panel + enable buttons
-- ============================================================
function PV.UI.UserManagerMain:onSelectionChange()
    local hasItem = (#self.listVehicles.items > 0
                     and self.listVehicles.selected > 0
                     and self.listVehicles.selected <= #self.listVehicles.items)

    self.btnUnclaim:setEnable(hasItem)
    self.btnManage:setEnable(hasItem)

    if self.subPanel ~= nil then
        self.subPanel:close()
        self.subPanel:removeFromUIManager()
        self.subPanel = nil
    end

    if hasItem then
        local sqlid = self.listVehicles.items[self.listVehicles.selected].item
        self:updateInfoPanel(sqlid)
    else
        self:updateInfoPanel(nil)
    end
end

-- ============================================================
-- Info panel content (car details below the list)
-- ============================================================
function PV.UI.UserManagerMain:updateInfoPanel(sqlid)
    if sqlid == nil or not PV.dbByVehicleSQLID or not PV.dbByVehicleSQLID[sqlid] then
        self.lblCarNameVal:setName("—")
        self.lblLocationVal:setName("—")
        self.lblClaimedVal:setName("—")
        return
    end

    local data = PV.dbByVehicleSQLID[sqlid]
    -- Resolve display name
    local rawModel = data.CarModel or ""
    local carName  = rawModel
    local idx = string.find(rawModel, "%.")
    if idx then
        local suffix = string.sub(rawModel, idx + 1)
        carName = getTextOrNull("IGUI_VehicleName" .. suffix) or rawModel
    end

    local loc = "?"
    if data.LastLocationX and data.LastLocationY then
        loc = tostring(data.LastLocationX) .. ", " .. tostring(data.LastLocationY)
    end

    local claimedDate = data.ClaimDateTime and
        os.date("%d-%b-%y %H:%M", data.ClaimDateTime) or "?"

    self.lblCarNameVal:setName(carName)
    self.lblLocationVal:setName(loc)
    self.lblClaimedVal:setName(claimedDate)
end

-- ============================================================
-- Populate the list with the player's vehicles
-- ============================================================
function PV.UI.UserManagerMain:refreshList()
    self.listVehicles:clear()
    local username = getPlayer():getUsername()
    local pData = PV.dbByPlayerID and PV.dbByPlayerID[username]
    if not pData then
        self:onSelectionChange()
        return
    end

    for sqlid, _ in pairs(pData) do
        if sqlid ~= "LastKnownLogonTime" and sqlid ~= "LastKnownLogoffTime" then
            local vData = PV.dbByVehicleSQLID and PV.dbByVehicleSQLID[sqlid]
            if vData then
                local rawModel = vData.CarModel or ""
                local carName  = rawModel
                local idx = string.find(rawModel, "%.")
                if idx then
                    local suffix = string.sub(rawModel, idx + 1)
                    carName = getTextOrNull("IGUI_VehicleName" .. suffix) or rawModel
                end
                self.listVehicles:addItem(carName, sqlid)
            end
        end
    end

    self:onSelectionChange()
end

-- ============================================================
-- Button: Unclaim (with confirmation)
-- ============================================================
function PV.UI.UserManagerMain:onUnclaimClick(btn)
    if self.listVehicles.selected < 1 then return end
    if self.modDialog ~= nil then
        self.modDialog:close()
        self.modDialog:removeFromUIManager()
        self.modDialog = nil
    end
    local w, h = 280, 110
    self.modDialog = ISModalDialog:new(
        getCore():getScreenWidth()  / 2 - w / 2,
        getCore():getScreenHeight() / 2 - h / 2,
        w, h,
        getText("UI_PV_ConfirmUnclaim"),
        true, self, PV.UI.UserManagerMain.onConfirmUnclaim,
        getPlayer():getPlayerNum(), nil)
    self.modDialog:initialise()
    self.modDialog:addToUIManager()
end

function PV.UI.UserManagerMain:onConfirmUnclaim(btn)
    if btn.internal == "NO" then return end
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    if not sqlid then return end
    sendClientCommand(getPlayer(), "ProtectVehicle", "unclaim", { sqlid = sqlid })
    self.listVehicles:removeItemByIndex(self.listVehicles.selected)
    self:onSelectionChange()
end

-- ============================================================
-- Button: Manage Permissions
-- ============================================================
function PV.UI.UserManagerMain:onManageClick(btn)
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    if not sqlid then return end

    if self.subPanel ~= nil then
        self.subPanel:close()
        self.subPanel:removeFromUIManager()
        self.subPanel = nil
    end
    self.subPanel = PV.UI.PermissionPanel:new(
        getCore():getScreenWidth()  / 2 - 160,
        getCore():getScreenHeight() / 2 - 230,
        320, 460)
    self.subPanel.sqlid = sqlid
    self.subPanel:initialise()
    self.subPanel:addToUIManager()
    self.subPanel:setVisible(true)
end

-- ============================================================
-- initialise / createChildren
-- ============================================================
function PV.UI.UserManagerMain:initialise()
    ISCollapsableWindow.initialise(self)
end

function PV.UI.UserManagerMain:createChildren()
    ISCollapsableWindow.createChildren(self)

    local listTop   = PAD_TOP + 4
    local btnH      = 26
    local infoH     = (FONT_HGT_SMALL + 4) * 3 + 10  -- 3 info rows
    local bottomH   = infoH + btnH + 16
    local listH     = self.height - listTop - bottomH

    -- ---- VEHICLE LIST ----
    self.listVehicles = ISScrollingListBox:new(5, listTop, self.width - 10, listH)
    self.listVehicles.onMouseDown = self.listOnMouseDown
    self.listVehicles:initialise()
    self.listVehicles:instantiate()
    self.listVehicles.drawBorder = true
    self.listVehicles:setFont(UIFont.NewSmall, 4)
    self:addChild(self.listVehicles)

    -- ---- INFO PANEL (below list) ----
    local infoY  = listTop + listH + 6
    local lblW   = 110
    local valX   = 5 + lblW + 4
    local valW   = self.width - valX - 10
    local rowH   = FONT_HGT_SMALL + 4

    -- Car Name row
    local lblCarName = ISLabel:new(5, infoY, rowH,
        getText("UI_PV_User_CarName"), 0.7, 0.7, 0.7, 1, UIFont.NewSmall, true)
    lblCarName:initialise()
    lblCarName:instantiate()
    self:addChild(lblCarName)
    self.lblCarNameVal = ISLabel:new(valX, infoY, rowH, "—", 0.9, 0.9, 0.9, 1, UIFont.NewSmall, true)
    self.lblCarNameVal:initialise()
    self.lblCarNameVal:instantiate()
    self:addChild(self.lblCarNameVal)

    -- Location row
    local lblLoc = ISLabel:new(5, infoY + rowH + 4, rowH,
        getText("UI_PV_User_Location"), 0.7, 0.7, 0.7, 1, UIFont.NewSmall, true)
    lblLoc:initialise()
    lblLoc:instantiate()
    self:addChild(lblLoc)
    self.lblLocationVal = ISLabel:new(valX, infoY + rowH + 4, rowH, "—", 0.6, 1, 0.6, 1, UIFont.NewSmall, true)
    self.lblLocationVal:initialise()
    self.lblLocationVal:instantiate()
    self:addChild(self.lblLocationVal)

    -- Claimed Date row
    local lblClaimed = ISLabel:new(5, infoY + (rowH + 4) * 2, rowH,
        getText("UI_PV_User_Claimed"), 0.7, 0.7, 0.7, 1, UIFont.NewSmall, true)
    lblClaimed:initialise()
    lblClaimed:instantiate()
    self:addChild(lblClaimed)
    self.lblClaimedVal = ISLabel:new(valX, infoY + (rowH + 4) * 2, rowH, "—", 0.85, 0.85, 0.85, 1, UIFont.NewSmall, true)
    self.lblClaimedVal:initialise()
    self.lblClaimedVal:instantiate()
    self:addChild(self.lblClaimedVal)

    -- ---- BUTTONS ----
    local btnY = infoY + infoH + 6
    local btnW = math.floor((self.width - 10 - 8) / 2)

    self.btnUnclaim = ISButton:new(5, btnY, btnW, btnH,
        getText("UI_PV_User_Unclaim"), self, self.onUnclaimClick)
    self.btnUnclaim.internal = "btnUnclaim"
    self.btnUnclaim.backgroundColor = {r=0.35, g=0.05, b=0.05, a=1}
    self.btnUnclaim:initialise()
    self.btnUnclaim:instantiate()
    self.btnUnclaim:setEnable(false)
    self:addChild(self.btnUnclaim)

    self.btnManage = ISButton:new(5 + btnW + 8, btnY, btnW, btnH,
        getText("UI_PV_User_Manage"), self, self.onManageClick)
    self.btnManage.internal = "btnManage"
    self.btnManage:initialise()
    self.btnManage:instantiate()
    self.btnManage:setEnable(false)
    self:addChild(self.btnManage)

    -- populate
    self:refreshList()
end

-- ============================================================
-- close
-- ============================================================
function PV.UI.UserManagerMain:close()
    ISCollapsableWindow.close(self)
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
    if PV.UI.UserInstance then PV.UI.UserInstance = nil end
    self:removeFromUIManager()
end

function PV.UI.UserManagerMain:prerender()
    ISCollapsableWindow.prerender(self)
end

function PV.UI.UserManagerMain:render()
    ISCollapsableWindow.render(self)
end

-- ============================================================
-- Constructor
-- ============================================================
function PV.UI.UserManagerMain:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.showBackground  = true
    o.backgroundColor = {r=0.10, g=0.10, b=0.14, a=0.97}
    o.showBorder      = true
    o.borderColor     = {r=0.35, g=0.45, b=0.65, a=1}
    o.title           = getText("UI_PV_User_Title")
    o.width           = width
    o.height          = height
    o.visibleTarget   = o
    o.moveWithMouse   = true
    o.pin             = true
    o.subPanel        = nil
    o.modDialog       = nil
    o:setResizable(false)
    o:setDrawFrame(true)
    return o
end

-- ============================================================
-- Open singleton
-- ============================================================
function PV.UI.OpenUserManager()
    if PV.UI.UserInstance ~= nil then
        PV.UI.UserInstance:close()
    end
    local width  = 420
    local height = 400
    local x = getCore():getScreenWidth()  / 2 - width  / 2
    local y = getCore():getScreenHeight() / 2 - height / 2
    PV.UI.UserInstance = PV.UI.UserManagerMain:new(x, y, width, height)
    PV.UI.UserInstance:initialise()
    PV.UI.UserInstance:addToUIManager()
    PV.UI.UserInstance:setVisible(true)
end
