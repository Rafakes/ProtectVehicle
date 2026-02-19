--[[
    ProtectVehicle - PV_PermissionPanel.lua
    UI for managing public vehicle permission flags.
    Uses ISCollapsableWindow (B42 pattern from AVCS4213).
    B42.14.x
--]]

if not isClient() and isServer() then return end

local FONT_HGT_SMALL  = getTextManager():getFontHeight(UIFont.NewSmall)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.NewMedium)
local PAD_TOP = FONT_HGT_SMALL + 1

-- ============================================================
-- Flag definitions (key → translation key → description key)
-- ============================================================
local FLAG_DEFS = {
    { key = "AllowDrive",           label = "UI_PV_Flag_Drive",        desc = "UI_PV_FlagDesc_Drive"        },
    { key = "AllowPassenger",       label = "UI_PV_Flag_Passenger",    desc = "UI_PV_FlagDesc_Passenger"    },
    { key = "AllowOpeningDoors",    label = "UI_PV_Flag_Doors",        desc = "UI_PV_FlagDesc_Doors"        },
    { key = "AllowOpeningTrunk",    label = "UI_PV_Flag_Trunk",        desc = "UI_PV_FlagDesc_Trunk"        },
    { key = "AllowContainersAccess",label = "UI_PV_Flag_Containers",   desc = "UI_PV_FlagDesc_Containers"   },
    { key = "AllowSiphonFuel",      label = "UI_PV_Flag_Siphon",       desc = "UI_PV_FlagDesc_Siphon"       },
    { key = "AllowInflateTires",    label = "UI_PV_Flag_Inflate",      desc = "UI_PV_FlagDesc_Inflate"      },
    { key = "AllowDeflateTires",    label = "UI_PV_Flag_Deflate",      desc = "UI_PV_FlagDesc_Deflate"      },
    { key = "AllowUninstallParts",  label = "UI_PV_Flag_Uninstall",    desc = "UI_PV_FlagDesc_Uninstall"    },
    { key = "AllowTakeEngineParts", label = "UI_PV_Flag_Engine",       desc = "UI_PV_FlagDesc_Engine"       },
    { key = "AllowTow",             label = "UI_PV_Flag_Tow",          desc = "UI_PV_FlagDesc_Tow"          },
    { key = "AllowScrapVehicle",    label = "UI_PV_Flag_Scrap",        desc = "UI_PV_FlagDesc_Scrap"        },
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

    local entry = PV.dbByVehicleSQLID and PV.dbByVehicleSQLID[self.sqlid]
    local flags = PV.getEffectiveFlags and PV.getEffectiveFlags(self.sqlid) or {}

    -- Car name label at the top
    local rawModel = (entry and entry.CarModel) or ""
    local carName  = rawModel
    local idx = string.find(rawModel, "%.")
    if idx then
        local suffix = string.sub(rawModel, idx + 1)
        carName = getTextOrNull("IGUI_VehicleName" .. suffix) or rawModel
    end

    local lblTitle = ISLabel:new(5, PAD_TOP + 4, FONT_HGT_MEDIUM,
        carName, 0.7, 0.9, 1, 1, UIFont.NewMedium, true)
    lblTitle:initialise()
    lblTitle:instantiate()
    self:addChild(lblTitle)

    -- Separator line (drawn via render)
    local checkStartY = PAD_TOP + 4 + FONT_HGT_MEDIUM + 8

    -- TickBoxes for each flag
    self.checks = {}
    local tickH = FONT_HGT_SMALL + 8
    local y     = checkStartY

    for _, def in ipairs(FLAG_DEFS) do
        local tick = ISTickBox:new(10, y, self.width - 20, tickH, "", self, self.onToggled)
        tick:addOption(getText(def.label))
        if flags[def.key] then tick:setSelected(1, true) end
        tick.flagKey = def.key
        -- tooltip if description key exists
        local descTxt = getTextOrNull(def.desc)
        if descTxt then
            tick:setTooltip(descTxt)
        end
        tick:initialise()
        tick:instantiate()
        self:addChild(tick)
        self.checks[def.key] = tick
        y = y + tickH + 2
    end

    -- Buttons at bottom
    local btnH = 26
    local btnW = math.floor((self.width - 20 - 8) / 2)
    local btnY = self.height - btnH - 10

    self.btnSave = ISButton:new(10, btnY, btnW, btnH,
        getText("UI_PV_Save"), self, self.onSave)
    self.btnSave.internal = "btnSave"
    self.btnSave.backgroundColor = {r=0.05, g=0.25, b=0.05, a=1}
    self.btnSave:initialise()
    self.btnSave:instantiate()
    self:addChild(self.btnSave)

    self.btnClose = ISButton:new(10 + btnW + 8, btnY, btnW, btnH,
        getText("UI_PV_Close"), self, self.close)
    self.btnClose.internal = "btnClose"
    self.btnClose:initialise()
    self.btnClose:instantiate()
    self:addChild(self.btnClose)
end

-- ============================================================
-- Handlers
-- ============================================================
function PV.UI.PermissionPanel:onToggled(index, selected)
    -- state handled on Save to minimize network calls
end

function PV.UI.PermissionPanel:onSave(btn)
    local newFlags = {}
    for key, tick in pairs(self.checks) do
        newFlags[key] = tick:isSelected(1)
    end
    local delta = PV.computeFlagsDelta and PV.computeFlagsDelta(self.sqlid, newFlags) or newFlags
    if next(delta) ~= nil then
        sendClientCommand(getPlayer(), "ProtectVehicle", "updateFlags",
            { sqlid = self.sqlid, delta = delta })
        getPlayer():setHaloNote(getText("UI_PV_Saved"), 0, 1, 0, 300)
    end
    self:close()
end

-- ============================================================
-- Render: draw a separator under the car name
-- ============================================================
function PV.UI.PermissionPanel:render()
    ISCollapsableWindow.render(self)
    local sepY = PAD_TOP + 4 + FONT_HGT_MEDIUM + 4
    self:drawRect(5, sepY, self.width - 10, 1, 0.8, 0.35, 0.45, 0.65)
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
-- ============================================================
function PV.UI.PermissionPanel:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.showBackground  = true
    o.backgroundColor = {r=0.10, g=0.10, b=0.14, a=0.97}
    o.showBorder      = true
    o.borderColor     = {r=0.35, g=0.45, b=0.65, a=1}
    o.title           = getText("UI_PV_Permissions_Title")
    o.width           = width
    o.height          = height
    o.visibleTarget   = o
    o.moveWithMouse   = true
    o.pin             = true
    o.sqlid           = nil
    o.checks          = {}
    o:setResizable(false)
    o:setDrawFrame(true)
    return o
end

-- ============================================================
-- Open helper (used by PV_Client.lua and both manager panels)
-- ============================================================
function PV.UI.OpenPermissionPanel(sqlid)
    local width  = 320
    local height = #FLAG_DEFS * (FONT_HGT_SMALL + 10) + PAD_TOP + FONT_HGT_MEDIUM + 8 + 26 + 30
    local x = getCore():getScreenWidth()  / 2 - width  / 2
    local y = getCore():getScreenHeight() / 2 - height / 2
    local panel = PV.UI.PermissionPanel:new(x, y, width, height)
    panel.sqlid = sqlid
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
end
