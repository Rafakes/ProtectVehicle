--[[
    ProtectVehicle - PV_UserManagerMain.lua
    Player UI to list and manage their own claimed vehicles.
    Features:
      - Vehicle list + 3D preview
      - Info panel (name, location, date, expiry)
      - AllowList: add/remove players by username
      - Per-player permission flags (via PermissionPanel)
      - Public permission flags (via PermissionPanel, red button)
      - Quick-allow presets available by right-clicking the player character in the world (PV_Client.lua)
    Uses ISCollapsableWindow.
    B42.14.x
    
    CHANGELOG (2026-02-21):
      - FIXED: Increased Allowed Players vertical size for better visibility
      - FIXED: Moved vehicle stats (Vehicle, Location, Claimed On, Expires In) below vehicle list
      - ADDED: "Expires In" field to show vehicle claim expiration
      - FIXED: Action buttons now properly fit within borders (reduced padding)
--]]

if not isClient() and isServer() then return end

require "UI/PV_UIShared"

PV = PV or {}
PV.UI = PV.UI or {}

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local PAD_TOP = FONT_HGT_SMALL + 1
local UI_SCALE = (PV.getUIFontScale and PV.getUIFontScale()) or 1
local USER_WINDOW_LAYOUT_VERSION = 4

local function PV_getUserWindowDefaults(screenW, screenH)
    local compact = (screenW <= 1600 or screenH <= 900)

    local width
    local height
    if compact then
        width = math.min(math.floor(screenW * 0.70), math.floor(1040 * UI_SCALE))
        height = math.min(math.floor(screenH * 0.66), math.floor(620 * UI_SCALE))
    else
        width = math.min(math.floor(screenW * 0.66), math.floor(1160 * UI_SCALE))
        height = math.min(math.floor(screenH * 0.64), math.floor(660 * UI_SCALE))
    end

    width = math.max(math.floor(520 * UI_SCALE), width)
    height = math.max(math.floor(440 * UI_SCALE), height)

    return {
        compact = compact,
        width = width,
        height = height,
        x = math.floor((screenW - width) / 2),
        y = math.max(20, math.floor((screenH - height) / 2)),
    }
end

local function PV_getOwner(list)
    -- list is an ISScrollingListBox, usually parented inside CardPanel.
    -- Prefer explicit owner reference to avoid nil callbacks.
    return list.pvOwner
        or list.joypadParent
        or (list.parent and list.parent.parent)
        or list.parent
end


-- ============================================================
-- Class definition
-- ============================================================
PV.UI.UserManagerMain = ISCollapsableWindow:derive("PV.UI.UserManagerMain")

-- ============================================================
-- Vehicle list: mouse down
-- ============================================================
function PV.UI.UserManagerMain:listOnMouseDown(x, y)
    if #self.items == 0 then return end
    local row = self:rowAt(x, y)
    if row > #self.items then row = #self.items end
    if row < 1 then return end
    if row == self.selected then return end
    getSoundManager():playUISound("UISelectListItem")
    self.selected = row

    local owner = PV_getOwner(self)
    if owner and owner.onSelectionChange then
        owner:onSelectionChange()
    end
end

-- ============================================================
-- AllowList: mouse down (left = select, right = context menu)
-- ============================================================
function PV.UI.UserManagerMain:allowListOnMouseDown(x, y)
    if #self.items == 0 then return end
    local row = self:rowAt(x, y)
    if row > #self.items then row = #self.items end
    if row < 1 then return end
    getSoundManager():playUISound("UISelectListItem")
    self.selected = row

    local owner = PV_getOwner(self)
    if owner and owner.onAllowListSelectionChange then
        owner:onAllowListSelectionChange()
    end
end

function PV.UI.UserManagerMain:allowListOnRightMouseDown(x, y)
    -- Right-click inside the list: just select the row (no UI context menu).
    -- Quick-allow presets are available by right-clicking the player character in the world.
    if #self.items == 0 then return end
    local row = self:rowAt(x, y)
    if row > #self.items then row = #self.items end
    if row < 1 then return end
    self.selected = row
    self.parent:onAllowListSelectionChange()
end

-- ============================================================
-- Vehicle 3D Preview
-- ============================================================
local PV_USER_VEHICLE_PREVIEW_ZOOM = 4.6
local PV_USER_VEHICLE_PREVIEW_PAN_Y = 24

local function PV_applyUserVehiclePreviewCamera(scene)
    if not scene or not scene.javaObject then return end

    if scene.setView then
        pcall(function() scene:setView("Right") end)
    else
        pcall(function() scene.javaObject:fromLua1("setView", "Right") end)
    end
    pcall(function() scene.javaObject:fromLua1("setZoom", PV_USER_VEHICLE_PREVIEW_ZOOM) end)

    -- Apply once per scene. dragView is cumulative, so repeating it would
    -- keep shifting the vehicle whenever the preview is rebuilt or refreshed.
    if not scene._pvUserPreviewPanApplied then
        pcall(function() scene.javaObject:fromLua2("dragView", 0, PV_USER_VEHICLE_PREVIEW_PAN_Y) end)
        scene._pvUserPreviewPanApplied = true
    end
end

function PV.UI.UserManagerMain:setVehiclePreview(sqlid)
    if not self.vehiclePreview or not self.vehiclePreview.javaObject then return end
    local vEntry = sqlid and PV.getVehicleDBEntry(sqlid)
    if not vEntry then
        self.vehiclePreview.javaObject:fromLua2("setVehicleScript", "pvPreviewVeh", "")
        return
    end
    local model = vEntry.CarModel or ""
    self.vehiclePreview.javaObject:fromLua2("setVehicleScript", "pvPreviewVeh", model)
end

function PV.UI.UserManagerMain:setVehiclePreviewModel(model)
    if not self.vehiclePreview or not self.vehiclePreview.javaObject then return end
    local script = tostring(model or "")
    self.vehiclePreview.javaObject:fromLua2("setVehicleScript", "pvPreviewVeh", script)
end

function PV.UI.UserManagerMain:vehiclePreviewOnRightMouseDown(x, y)
    local views = {"Right","Top","Front","Left","Back"}
    local cur = self.parent.vehiclePreview:getView()
    for i, v in ipairs(views) do
        if v == cur then
            self.parent.vehiclePreview:setView(views[(i % #views) + 1])
            return
        end
    end
end

-- ============================================================
-- Helper: Calculate expiry text (similar to AdminManager logic)
-- ============================================================
local function calcExpiryUser(ownerID)
    local timeoutHours = tonumber(SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.ClaimTimeoutHours or 0) or 0
    if timeoutHours <= 0 then
        return getText("IGUI_PV_Admin_Col_Expiry_Never")
    end
    local pData = PV.dbByPlayerID and PV.dbByPlayerID[ownerID]
    local logoff = pData and pData.LastKnownLogoffTime or nil
    if not logoff then
        return getText("IGUI_PV_Admin_Col_Expiry_Never")
    end
    local now = os.time()
    local expireAt = logoff + timeoutHours * 3600
    local remaining = expireAt - now
    if remaining <= 0 then
        return getText("IGUI_PV_Admin_Col_Expiry_Expired")
    end
    local expireDate = os.date("%d-%b-%y %H:%M", expireAt)
    local isOnline = (getPlayerByUsername and getPlayerByUsername(ownerID) ~= nil) or false
    if isOnline then
        return getText("IGUI_PV_Admin_Col_Expiry_Online", expireDate)
    end
    return expireDate
end

-- ============================================================
-- Vehicle selection change
-- ============================================================
function PV.UI.UserManagerMain:onSelectionChange()
    if not self.btnUnclaim then return end
    local hasItem = (#self.listVehicles.items > 0
                     and self.listVehicles.selected > 0
                     and self.listVehicles.selected <= #self.listVehicles.items)
    if self.subPanel ~= nil then
        self.subPanel:close(); self.subPanel:removeFromUIManager(); self.subPanel = nil
    end

    local rawKey = hasItem and self.listVehicles.items[self.listVehicles.selected].item or nil
    local isDoc  = type(rawKey) == "string" and string.sub(rawKey, 1, 4) == "doc:"

    if isDoc then
        -- Document-state vehicle: disable claim management, show basic info
        self.btnUnclaim:setEnable(false)
        self.btnPublicPerms:setEnable(false)
        local docId   = string.sub(rawKey, 5)
        local docs    = PV.dbDocuments or {}
        local docEntry = docs[docId]
        local function _docValidityText(entry)
            if type(entry) ~= "table" then return "-" end
            local ex = tonumber(entry.expiresAt) or 0
            if ex <= 0 then return getText("IGUI_PV_Doc_ValidityNever") end
            if os.time() >= ex then return getText("IGUI_PV_Doc_ExpiredShort") end
            return getText("IGUI_PV_Doc_ValidityUntil", os.date("%d-%b-%y %H:%M", ex))
        end
        local function _docStatusText(entry)
            local st = tostring(entry and entry.status or "held")
            if st == "listed" then return getText("IGUI_PV_Doc_Status_Listed") end
            if st == "transferred" then return getText("IGUI_PV_Doc_Status_Transferred") end
            if st == "redeemed" then return getText("IGUI_PV_Doc_Status_Redeemed") end
            return getText("IGUI_PV_Doc_Status_Held")
        end
        -- Show document info in the info panel using available labels
        if self.lblCarNameVal then
            self.lblCarNameVal:setName((docEntry and docEntry.vehicleName) or docId)
        end
        if self.lblLocationVal then
            self.lblLocationVal:setName(_docStatusText(docEntry))
        end
        if self.lblClaimedVal then
            local ts = docEntry and docEntry.convertedAt
            self.lblClaimedVal:setName(ts and os.date("%d-%b-%y %H:%M", ts) or "—")
        end
        if self.lblExpiresVal then
            self.lblExpiresVal:setName(_docValidityText(docEntry))
        end
        -- Keep 3D preview for titles when scriptName is available in doc entry.
        local docModel = (docEntry and (docEntry.scriptName or docEntry.CarModel)) or ""
        self:setVehiclePreviewModel(docModel)
        if self.listAllowList then self.listAllowList:clear() end
        self:refreshGroupAccess(nil)
        self:onAllowListSelectionChange()
    else
        -- Normal claimed vehicle
        local sqlid = rawKey
        self.btnUnclaim:setEnable(hasItem and not isDoc)
        self.btnPublicPerms:setEnable(hasItem and not isDoc)
        self:updateInfoPanel(sqlid)
        self:setVehiclePreview(sqlid)
        self:refreshAllowList(sqlid)
        self:refreshGroupAccess(sqlid)
        self:onAllowListSelectionChange()
    end
end

-- ============================================================
-- AllowList selection change
-- ============================================================
function PV.UI.UserManagerMain:onAllowListSelectionChange()
    if not self.btnPlayerPerms then return end
    local hasPlayer = (self.listAllowList ~= nil
                       and #self.listAllowList.items > 0
                       and self.listAllowList.selected > 0
                       and self.listAllowList.selected <= #self.listAllowList.items)
    self.btnPlayerPerms:setEnable(hasPlayer)
    self.btnRemovePlayer:setEnable(hasPlayer)
end



-- ============================================================
-- Allowed Players tabs (By Name / Safehouse / Faction)
-- ============================================================
function PV.UI.UserManagerMain:onAllowTabClick(btn)
    if not btn or not btn.internal then return end
    self:setAllowTab(btn.internal)
end

function PV.UI.UserManagerMain:setAllowTab(tab)
    if tab ~= "players" and tab ~= "safehouse" and tab ~= "faction" then
        tab = "players"
    end
    self.allowTab = tab

    if self.allowPanelPlayers then self.allowPanelPlayers:setVisible(tab == "players") end
    if self.allowPanelSafehouse then self.allowPanelSafehouse:setVisible(tab == "safehouse") end
    if self.allowPanelFaction then self.allowPanelFaction:setVisible(tab == "faction") end

    if self.btnAllowTabPlayers then PV.UI.ApplyButtonStyle(self.btnAllowTabPlayers, (tab == "players") and "primary" or nil) end
    if self.btnAllowTabSafehouse then PV.UI.ApplyButtonStyle(self.btnAllowTabSafehouse, (tab == "safehouse") and "primary" or nil) end
    if self.btnAllowTabFaction then PV.UI.ApplyButtonStyle(self.btnAllowTabFaction, (tab == "faction") and "primary" or nil) end

-- When not in "By Name" tab, disable player-specific action buttons
if tab ~= "players" then
    if self.btnPlayerPerms then self.btnPlayerPerms:setEnable(false) end
    if self.btnRemovePlayer then self.btnRemovePlayer:setEnable(false) end
else
    self:onAllowListSelectionChange()
end
end

-- ============================================================
-- Group access toggles (per-vehicle): Safehouse / Faction
-- ============================================================
function PV.UI.UserManagerMain:refreshGroupAccess(sqlid)
    local entry = (sqlid and PV.getVehicleDBEntry(sqlid)) or nil
    local hasItem = entry ~= nil
    local safehouseAllowed = not (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowSafehouse == false)
    local factionAllowed = not (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowFaction == false)

    local function apply(btn, lbl, enabled, available)
        if btn then
            btn:setEnable(hasItem and available)
            if enabled then
                btn:setTitle(getText("UI_PV_Toggle_On"))
                PV.UI.ApplyButtonStyle(btn, "success")
            else
                btn:setTitle(getText("UI_PV_Toggle_Off"))
                PV.UI.ApplyButtonStyle(btn, "danger")
            end
        end
        if lbl then
            lbl:setName(getText("UI_PV_Perms_State", enabled and getText("UI_PV_Toggle_On") or getText("UI_PV_Toggle_Off")))
        end
    end

    apply(self.btnToggleSafehouse,    self.lblSafehouseState,    safehouseAllowed and entry and entry.AllowSafehouse == true,   safehouseAllowed)
    apply(self.btnToggleFaction,      self.lblFactionState,      factionAllowed and entry and entry.AllowFaction == true,       factionAllowed)
    apply(self.btnToggleSafehouseRV,  self.lblSafehouseRVState,  safehouseAllowed and entry and entry.AllowSafehouseRV == true, safehouseAllowed)
    apply(self.btnToggleFactionRV,    self.lblFactionRVState,    factionAllowed and entry and entry.AllowFactionRV == true,     factionAllowed)
end

function PV.UI.UserManagerMain:onToggleSafehouseClick(btn)
    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowSafehouse == false then return end
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return end
    local newVal = not (entry.AllowSafehouse == true)
    sendClientCommand(getPlayer(), "ProtectVehicle", "setGroupAccess", { sqlid = sqlid, allowSafehouse = newVal })
end

function PV.UI.UserManagerMain:onToggleFactionClick(btn)
    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowFaction == false then return end
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return end
    local newVal = not (entry.AllowFaction == true)
    sendClientCommand(getPlayer(), "ProtectVehicle", "setGroupAccess", { sqlid = sqlid, allowFaction = newVal })
end

function PV.UI.UserManagerMain:onToggleSafehouseRVClick(btn)
    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowSafehouse == false then return end
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return end
    local newVal = not (entry.AllowSafehouseRV == true)
    sendClientCommand(getPlayer(), "ProtectVehicle", "setGroupAccess", { sqlid = sqlid, allowSafehouseRV = newVal })
end

function PV.UI.UserManagerMain:onToggleFactionRVClick(btn)
    if SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.AllowFaction == false then return end
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return end
    local newVal = not (entry.AllowFactionRV == true)
    sendClientCommand(getPlayer(), "ProtectVehicle", "setGroupAccess", { sqlid = sqlid, allowFactionRV = newVal })
end

-- ============================================================
-- Info panel (now below vehicle list with 4 rows)
-- ============================================================
function PV.UI.UserManagerMain:updateInfoPanel(sqlid)
    if not self.lblCarNameVal then return end
    local data = sqlid and PV.getVehicleDBEntry(sqlid)
    if not data then
        self.lblCarNameVal:setName("â€”")
        self.lblLocationVal:setName("â€”")
        self.lblClaimedVal:setName("â€”")
        self.lblExpiresVal:setName("â€”")
        return
    end
    local rawModel = data.CarModel or ""
    local carName  = PV.getVehicleDisplayNameFromModel(rawModel)
    local loc = (data.LastLocationX and data.LastLocationY)
                and (tostring(data.LastLocationX) .. ", " .. tostring(data.LastLocationY))
                or "?"
    local claimedDate = data.ClaimDateTime and os.date("%d-%b-%y %H:%M", data.ClaimDateTime) or "?"
    local expiryText = calcExpiryUser(data.OwnerPlayerID or "")
    
    self.lblCarNameVal:setName(carName)
    self.lblLocationVal:setName(loc)
    self.lblClaimedVal:setName(claimedDate)
    self.lblExpiresVal:setName(expiryText)
end

-- ============================================================
-- AllowList refresh
-- ============================================================
function PV.UI.UserManagerMain:refreshAllowList(sqlid)
    if not self.listAllowList then return end
    self.listAllowList:clear()
    local rentry = sqlid and PV.getVehicleDBEntry(sqlid)
    if not rentry then return end
    local al = rentry.AllowList
    if not al then return end
    for username, _ in pairs(al) do
        self.listAllowList:addItem(username, username)
    end
end

-- ============================================================
-- Populate vehicle list (claimed vehicles + document-state vehicles)
-- ============================================================
function PV.UI.UserManagerMain:refreshList()
    self.listVehicles:clear()
    local username = getPlayer():getUsername()
    local function _hasDocItemWithId(container, targetDocId)
        if not container or not targetDocId then return false end
        local items = container.getItems and container:getItems() or nil
        if not items then return false end
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it then
                local md = it.getModData and it:getModData() or nil
                if md and tostring(md.PV_DocId or "") == tostring(targetDocId) then
                    return true
                end
                local nested = (it.getItemContainer and it:getItemContainer())
                    or (it.getInventory and it:getInventory())
                if nested and _hasDocItemWithId(nested, targetDocId) then
                    return true
                end
            end
        end
        return false
    end

    -- Claimed vehicles
    local pData = PV.dbByPlayerID and PV.dbByPlayerID[username]
    if pData then
        for sqlid, _ in pairs(pData) do
            if sqlid ~= "LastKnownLogonTime" and sqlid ~= "LastKnownLogoffTime" then
                local vData = PV.getVehicleDBEntry(sqlid)
                if vData then
                    local rawModel = vData.CarModel or ""
                    local carName  = PV.getVehicleDisplayNameFromModel(rawModel)
                    self.listVehicles:addItem(carName, sqlid)
                end
            end
        end
    end

    -- Document-state vehicles (held by this player, status "held")
    local docs = PV.dbDocuments
    local byPlayer = PV.dbDocumentsByPlayer
    local playerInv = getPlayer() and getPlayer():getInventory() or nil
    if docs and byPlayer and byPlayer[username] then
        for docId in pairs(byPlayer[username]) do
            local docEntry = docs[docId]
            if docEntry
                and docEntry.status == "held"
                and docEntry.ownerName == username
                and _hasDocItemWithId(playerInv, docId) then
                local label = (docEntry.vehicleName or docId) ..
                    " " .. getText("IGUI_PV_DocTag")
                -- Store docId with a "doc:" prefix so onSelectionChange can distinguish
                self.listVehicles:addItem(label, "doc:" .. docId)
            end
        end
    end

    self:updateClaimStatus()
    self:onSelectionChange()
end

-- ============================================================
-- Claim status footer: vehicle count / limit + role, per sandbox config.
-- ============================================================
function PV.UI.UserManagerMain:updateClaimStatus()
    if not self.lblClaimCount then return end
    local player = getPlayer()
    if not player then return end

    local roleName = PV.getPlayerRoleName(player)
    if not roleName or roleName == "" then roleName = "User" end

    if PV.isStaffPlayer(player) then
        self.lblClaimCount:setName(getText("UI_PV_User_ClaimCountLine", tostring(PV.getClaimCount(player)), "∞"))
    else
        self.lblClaimCount:setName(getText("UI_PV_User_ClaimCountLine", tostring(PV.getClaimCount(player)), tostring(PV.getClaimLimit(player))))
    end
    if self.lblClaimRole then
        self.lblClaimRole:setName(getText("UI_PV_User_RoleLine", roleName))
    end
end

-- ============================================================
-- Button: Unclaim
-- ============================================================
function PV.UI.UserManagerMain:onUnclaimClick(btn)
    if self.listVehicles.selected < 1 then return end
    if self.modDialog ~= nil then
        self.modDialog:close(); self.modDialog:removeFromUIManager(); self.modDialog = nil
    end
    local w, h = 280, 110
    self.modDialog = ISModalDialog:new(
        getCore():getScreenWidth()  / 2 - w / 2,
        getCore():getScreenHeight() / 2 - h / 2,
        w, h, getText("IGUI_PV_ConfirmUnclaim"),
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
    
    -- FIXED: Enviar comando unclaim
    sendClientCommand(getPlayer(), "ProtectVehicle", "unclaim", { sqlid = sqlid })
    
    -- FIXED: Aguardar um frame para garantir que o servidor processa antes de atualizar UI
    -- O servidor vai enviar o comando "removeVehicle" que vai limpar o DB e atualizar a UI
    -- Mas precisamos limpar a seleÃ§Ã£o local imediatamente para evitar clicks duplicados
    self.listVehicles.selected = 0
    self:onSelectionChange()
end

-- ============================================================
-- Button: Public Permissions (red)
-- ============================================================
function PV.UI.UserManagerMain:onPublicPermsClick(btn)
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    if not sqlid then return end
    if self.subPanel ~= nil then
        self.subPanel:close(); self.subPanel:removeFromUIManager(); self.subPanel = nil
    end
    self.subPanel = PV.UI.OpenPermissionPanel(sqlid, nil)
end

-- ============================================================
-- Button: Player Permissions (enabled when player selected)
-- ============================================================
function PV.UI.UserManagerMain:onPlayerPermsClick(btn)
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    if not sqlid then return end
    if not self.listAllowList or self.listAllowList.selected < 1 then return end
    local targetPlayer = self.listAllowList.items[self.listAllowList.selected].item
    if not targetPlayer then return end
    if self.subPanel ~= nil then
        self.subPanel:close(); self.subPanel:removeFromUIManager(); self.subPanel = nil
    end
    self.subPanel = PV.UI.OpenPermissionPanel(sqlid, targetPlayer)
end

-- ============================================================
-- Button: Add player to AllowList
-- ============================================================
function PV.UI.UserManagerMain:onAddPlayerClick(btn)
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    if not sqlid then return end
    local name = self.inputPlayerName:getInternalText()
    if not name or name == "" then return end
    name = name:match("^%s*(.-)%s*$")
    if name == "" then return end
    sendClientCommand(getPlayer(), "ProtectVehicle", "addToAllowList",
        { sqlid = sqlid, targetPlayer = name })
    self.inputPlayerName:setText("")
end

-- ============================================================
-- Button: Remove player from AllowList
-- ============================================================
function PV.UI.UserManagerMain:onRemovePlayerClick(btn)
    if self.listVehicles.selected < 1 then return end
    local sqlid = self.listVehicles.items[self.listVehicles.selected].item
    if not sqlid then return end
    if self.listAllowList.selected < 1 then return end
    local targetPlayer = self.listAllowList.items[self.listAllowList.selected].item
    if not targetPlayer then return end
    sendClientCommand(getPlayer(), "ProtectVehicle", "removeFromAllowList",
        { sqlid = sqlid, targetPlayer = targetPlayer })
end

-- ============================================================
-- initialise / createChildren
-- ============================================================
function PV.UI.UserManagerMain:initialise()
    ISCollapsableWindow.initialise(self)
end

function PV.UI.UserManagerMain:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:buildLayout()
end

function PV.UI.UserManagerMain:buildLayout()
    local theme = PV.UI.Theme
    local c = theme.colors
    local m = theme.metrics

    local PAD  = m.pad
    local GAP  = m.gap
    local btnH = math.floor(28 * m.scale)
    local rowH = getTextManager():getFontHeight(UIFont.NewSmall) + 6

    self.watermarkTexture = getTexture("media/textures/PV_ServerHand_Watermark.png")

    -- Clamp to minimum without calling setWidth/setHeight (avoids breaking resize grip)
    local effectiveW = math.max(self.width,  math.floor(520 * m.scale))
    local effectiveH = math.max(self.height, math.floor(440 * m.scale))

    local contentY = PAD_TOP + PAD
    local contentH = effectiveH - contentY - PAD

    -- HEIGHTS: AllowList height now matches Preview height
    local actionH = math.floor(64  * m.scale)
    local avail   = contentH - actionH - (GAP * 2)
    local topH    = math.floor(avail / 2)
    if topH < math.floor(190 * m.scale) then topH = math.floor(190 * m.scale) end

    -- Keep mid section equal to preview height (requested)
    local midH = topH

    -- Clamp if the window is too small
    local total = (topH * 2) + actionH + (GAP * 2)
    if total > contentH then
        topH = math.floor((contentH - actionH - (GAP * 2)) / 2)
        midH = topH
    end

    local leftW  = math.floor(250 * m.scale)
    local rightW = effectiveW - (PAD * 2) - GAP - leftW
    local leftX  = PAD
    local rightX = leftX + leftW + GAP

    -- ========================================================
    -- TOP LEFT: Vehicles (list + claim status footer)
    -- ========================================================
    self.cardVehicles = PV.UI.CardPanel:new(leftX, contentY, leftW, topH, getText("UI_PV_Section_Vehicles"))
    self.cardVehicles:initialise(); self.cardVehicles:instantiate()
    self:addChild(self.cardVehicles)

    local vx, vy, vw, vh = self.cardVehicles:getInnerRect()

    -- Reserve footer space for claim count / role, plus an upgrade hint for non-supporters.
    local statusGap = math.floor(4 * m.scale)
    local claimPlayer = getPlayer()
    local showUpgradeHint = claimPlayer ~= nil
        and not PV.isStaffPlayer(claimPlayer)
        and not PV.isSupporterPlayer(claimPlayer)
    local footerH = (rowH * 2) + statusGap + (showUpgradeHint and (rowH + statusGap) or 0)

    local listH = vh - footerH - statusGap
    if listH < rowH then listH = rowH; footerH = vh - listH - statusGap end

    self.listVehicles = ISScrollingListBox:new(vx, vy, vw, listH)
    self.listVehicles.onMouseDown = self.listOnMouseDown
    self.listVehicles:initialise(); self.listVehicles:instantiate()
    self.listVehicles:setFont(UIFont.NewSmall, 4)
    self.listVehicles.itemheight = rowH
    self.listVehicles.doDrawItem = function(list, y, item, alt)
        return PV.UI.DrawSimpleListItem(list, y, item, alt)
    end
    PV.UI.ApplyListStyle(self.listVehicles)
    self.listVehicles.pvOwner = self
    self.cardVehicles:addChild(self.listVehicles)

    -- Claim status footer: how many vehicles claimed vs. the role's limit.
    local statusY = vy + listH + statusGap
    self.lblClaimCount = ISLabel:new(vx, statusY, rowH, "", c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall, true)
    self.lblClaimCount:initialise(); self.lblClaimCount:instantiate()
    self.cardVehicles:addChild(self.lblClaimCount)

    self.lblClaimRole = ISLabel:new(vx, statusY + rowH, rowH, "", c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
    self.lblClaimRole:initialise(); self.lblClaimRole:instantiate()
    self.cardVehicles:addChild(self.lblClaimRole)

    if showUpgradeHint then
        self.lblClaimHint = ISLabel:new(vx, statusY + rowH * 2 + statusGap, rowH, getText("UI_PV_User_ClaimUpgradeHint"), c.accent.r, c.accent.g, c.accent.b, 1, UIFont.NewSmall, true)
        self.lblClaimHint:initialise(); self.lblClaimHint:instantiate()
        self.cardVehicles:addChild(self.lblClaimHint)
    else
        self.lblClaimHint = nil
    end

    self:updateClaimStatus()

    -- ========================================================
    -- TOP RIGHT: Preview
    -- ========================================================
    self.cardPreview = PV.UI.CardPanel:new(rightX, contentY, rightW, topH, getText("UI_PV_Section_Preview"))
    self.cardPreview:initialise(); self.cardPreview:instantiate()
    self:addChild(self.cardPreview)

    local px, py, pw, ph = self.cardPreview:getInnerRect()

    self.vehiclePreview = ISUI3DScene:new(px, py, pw, ph)
    self.vehiclePreview.onRightMouseDown = self.vehiclePreviewOnRightMouseDown
    self.vehiclePreview:initialise(); self.vehiclePreview:instantiate()
    self.vehiclePreview.javaObject:fromLua1("setDrawGrid", false)
    self.vehiclePreview.javaObject:fromLua1("createVehicle", "pvPreviewVeh")
    self.vehiclePreview.javaObject:fromLua2("setVehicleScript", "pvPreviewVeh", "")
    PV_applyUserVehiclePreviewCamera(self.vehiclePreview)
    self.cardPreview:addChild(self.vehiclePreview)

    -- ========================================================
    -- MIDDLE: Stats (left) + Allowed Players (right) SIDE-BY-SIDE
    -- Stats moved down to where AllowList used to be.
    -- AllowList height now matches Preview height.
    -- ========================================================
    local midY = contentY + topH + GAP

    -- ---- STATS CARD ----
    self.cardStats = PV.UI.CardPanel:new(leftX, midY, leftW, midH, getText("UI_PV_Section_Stats"))
    self.cardStats:initialise(); self.cardStats:instantiate()
    self:addChild(self.cardStats)

    local sx, sy, sw, sh = self.cardStats:getInnerRect()

    self.infoPanel = ISPanel:new(sx, sy, sw, sh)
    self.infoPanel.backgroundColor = { r=0, g=0, b=0, a=0 }
    self.infoPanel.borderColor = { r=0, g=0, b=0, a=0 }
    self.infoPanel:initialise(); self.infoPanel:instantiate()
    self.infoPanel.prerender = function(panel)
        local bg = c.listAltBg
        panel:drawRect(0, 0, panel.width, panel.height, 0.55, bg.r, bg.g, bg.b)
        panel:drawRectBorder(0, 0, panel.width, panel.height, 1, c.cardBorder.r, c.cardBorder.g, c.cardBorder.b)
    end
    self.cardStats:addChild(self.infoPanel)

    local labelX = PAD
    local valueX = math.floor(95 * m.scale)
    local infoTop = PAD

    local function addInfoRow(y, labelKey, r, g, b)
        local lbl = ISLabel:new(labelX, y, rowH, getText(labelKey), c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
        lbl:initialise(); lbl:instantiate(); self.infoPanel:addChild(lbl)
        local val = ISLabel:new(valueX, y, rowH, "â€”", r or c.text.r, g or c.text.g, b or c.text.b, 1, UIFont.NewSmall, true)
        val:initialise(); val:instantiate(); self.infoPanel:addChild(val)
        return val
    end

    self.lblCarNameVal  = addInfoRow(infoTop,              "UI_PV_User_CarName",   c.text.r,    c.text.g,    c.text.b)
    self.lblLocationVal = addInfoRow(infoTop + rowH,       "UI_PV_User_Location",  0.55, 0.90, 0.55)
    self.lblClaimedVal  = addInfoRow(infoTop + rowH * 2,   "UI_PV_User_Claimed",   0.80, 0.80, 0.88)
    self.lblExpiresVal  = addInfoRow(infoTop + rowH * 3,   "UI_PV_User_ExpiresIn", 0.95, 0.70, 0.30)

    -- ---- ALLOW LIST CARD ----
    self.cardAllow = PV.UI.CardPanel:new(rightX, midY, rightW, midH, getText("UI_PV_Section_AllowList"))
    self.cardAllow:initialise(); self.cardAllow:instantiate()
    self:addChild(self.cardAllow)

    
local ax, ay, aw, ah = self.cardAllow:getInnerRect()

-- Tabs inside "Allowed Players" (By Name / Safehouse / Faction)
self.allowTab = "players"
local tabH = math.floor(24 * m.scale)
if tabH < 20 then tabH = 20 end
local tabGap = math.floor(4 * m.scale)
local tabUsable = aw - (tabGap * 2)
local tabW = math.floor(tabUsable / 3)
local tabExtra = tabUsable - (tabW * 3)

local tx = ax
local ty = ay
local function addTab(titleKey, internal, wOverride)
    local w = wOverride or tabW
    local b = ISButton:new(tx, ty, w, tabH, getText(titleKey), self, self.onAllowTabClick)
    b.internal = internal
    b:initialise(); b:instantiate()
    PV.UI.ApplyButtonStyle(b, (internal == "players") and "primary" or nil)
    self.cardAllow:addChild(b)
    tx = tx + w + tabGap
    return b
end

self.btnAllowTabPlayers   = addTab("UI_PV_AllowTab_ByName",    "players",   tabW)
self.btnAllowTabSafehouse = addTab("UI_PV_AllowTab_Safehouse", "safehouse", tabW)
self.btnAllowTabFaction   = addTab("UI_PV_AllowTab_Faction",   "faction",   tabW + tabExtra)

local panelY = ay + tabH + GAP
local panelH = ah - tabH - GAP

-- ========================================================
-- TAB: By Name (existing list + add player)
-- ========================================================
self.allowPanelPlayers = ISPanel:new(ax, panelY, aw, panelH)
self.allowPanelPlayers.backgroundColor = { r=0, g=0, b=0, a=0 }
self.allowPanelPlayers.borderColor = { r=0, g=0, b=0, a=0 }
self.allowPanelPlayers:initialise(); self.allowPanelPlayers:instantiate()
self.cardAllow:addChild(self.allowPanelPlayers)

local listH2 = panelH - btnH - GAP
self.listAllowList = ISScrollingListBox:new(0, 0, aw, listH2)
self.listAllowList.onMouseDown      = self.allowListOnMouseDown
self.listAllowList.onRightMouseDown = self.allowListOnRightMouseDown
self.listAllowList:initialise(); self.listAllowList:instantiate()
self.listAllowList:setFont(UIFont.NewSmall, 4)
self.listAllowList.itemheight = rowH
self.listAllowList.doDrawItem = function(list, y, item, alt)
    return PV.UI.DrawSimpleListItem(list, y, item, alt)
end
PV.UI.ApplyListStyle(self.listAllowList)
self.listAllowList.pvOwner = self
self.allowPanelPlayers:addChild(self.listAllowList)

local addRowY = listH2 + GAP
local addBtnW = math.floor(96 * m.scale)
local inputW  = aw - addBtnW - GAP

self.inputPlayerName = ISTextEntryBox:new("", 0, addRowY, inputW, btnH)
self.inputPlayerName.font = UIFont.NewSmall
self.inputPlayerName:initialise(); self.inputPlayerName:instantiate()
self.inputPlayerName:setMaxTextLength(32)
self.allowPanelPlayers:addChild(self.inputPlayerName)

self.btnAddPlayer = ISButton:new(inputW + GAP, addRowY, addBtnW, btnH, getText("IGUI_PV_AllowList_Add"), self, self.onAddPlayerClick)
self.btnAddPlayer.internal = "btnAdd"
self.btnAddPlayer:initialise(); self.btnAddPlayer:instantiate()
PV.UI.ApplyButtonStyle(self.btnAddPlayer, "success")
self.allowPanelPlayers:addChild(self.btnAddPlayer)

-- ========================================================
-- TAB: Safehouse (all powers)
-- ========================================================
self.allowPanelSafehouse = ISPanel:new(ax, panelY, aw, panelH)
self.allowPanelSafehouse.backgroundColor = { r=0, g=0, b=0, a=0 }
self.allowPanelSafehouse.borderColor = { r=0, g=0, b=0, a=0 }
self.allowPanelSafehouse:initialise(); self.allowPanelSafehouse:instantiate()
self.allowPanelSafehouse.prerender = function(panel)
    local bg = c.listAltBg
    panel:drawRect(0, 0, panel.width, panel.height, 0.55, bg.r, bg.g, bg.b)
    panel:drawRectBorder(0, 0, panel.width, panel.height, 1, c.cardBorder.r, c.cardBorder.g, c.cardBorder.b)
end
self.cardAllow:addChild(self.allowPanelSafehouse)

local padIn = PAD
local toggleW = math.floor(92 * m.scale)

self.lblAllowSafehouse = ISLabel:new(padIn, padIn, rowH, getText("UI_PV_AllowOpt_Safehouse"), c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall, true)
self.lblAllowSafehouse:initialise(); self.lblAllowSafehouse:instantiate()
self.allowPanelSafehouse:addChild(self.lblAllowSafehouse)

self.btnToggleSafehouse = ISButton:new(aw - toggleW - padIn, padIn, toggleW, btnH, getText("UI_PV_Toggle_Off"), self, self.onToggleSafehouseClick)
self.btnToggleSafehouse.internal = "btnToggleSafehouse"
self.btnToggleSafehouse:initialise(); self.btnToggleSafehouse:instantiate()
PV.UI.ApplyButtonStyle(self.btnToggleSafehouse, "danger")
self.allowPanelSafehouse:addChild(self.btnToggleSafehouse)

self.lblSafehouseState = ISLabel:new(padIn, padIn + rowH + GAP, rowH, getText("UI_PV_Perms_State", getText("UI_PV_Toggle_Off")), c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
self.lblSafehouseState:initialise(); self.lblSafehouseState:instantiate()
self.allowPanelSafehouse:addChild(self.lblSafehouseState)

-- RV Interior access for Safehouse members
local rvRowY = padIn + rowH + GAP + rowH + GAP
self.lblAllowSafehouseRV = ISLabel:new(padIn, rvRowY, rowH, getText("UI_PV_AllowOpt_SafehouseRV"), c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall, true)
self.lblAllowSafehouseRV:initialise(); self.lblAllowSafehouseRV:instantiate()
self.allowPanelSafehouse:addChild(self.lblAllowSafehouseRV)

self.btnToggleSafehouseRV = ISButton:new(aw - toggleW - padIn, rvRowY, toggleW, btnH, getText("UI_PV_Toggle_Off"), self, self.onToggleSafehouseRVClick)
self.btnToggleSafehouseRV.internal = "btnToggleSafehouseRV"
self.btnToggleSafehouseRV:initialise(); self.btnToggleSafehouseRV:instantiate()
PV.UI.ApplyButtonStyle(self.btnToggleSafehouseRV, "danger")
self.allowPanelSafehouse:addChild(self.btnToggleSafehouseRV)

self.lblSafehouseRVState = ISLabel:new(padIn, rvRowY + rowH + GAP, rowH, getText("UI_PV_Perms_State", getText("UI_PV_Toggle_Off")), c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
self.lblSafehouseRVState:initialise(); self.lblSafehouseRVState:instantiate()
self.allowPanelSafehouse:addChild(self.lblSafehouseRVState)

-- ========================================================
-- TAB: Faction (all powers)
-- ========================================================
self.allowPanelFaction = ISPanel:new(ax, panelY, aw, panelH)
self.allowPanelFaction.backgroundColor = { r=0, g=0, b=0, a=0 }
self.allowPanelFaction.borderColor = { r=0, g=0, b=0, a=0 }
self.allowPanelFaction:initialise(); self.allowPanelFaction:instantiate()
self.allowPanelFaction.prerender = self.allowPanelSafehouse.prerender
self.cardAllow:addChild(self.allowPanelFaction)

self.lblAllowFaction = ISLabel:new(padIn, padIn, rowH, getText("UI_PV_AllowOpt_Faction"), c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall, true)
self.lblAllowFaction:initialise(); self.lblAllowFaction:instantiate()
self.allowPanelFaction:addChild(self.lblAllowFaction)

self.btnToggleFaction = ISButton:new(aw - toggleW - padIn, padIn, toggleW, btnH, getText("UI_PV_Toggle_Off"), self, self.onToggleFactionClick)
self.btnToggleFaction.internal = "btnToggleFaction"
self.btnToggleFaction:initialise(); self.btnToggleFaction:instantiate()
PV.UI.ApplyButtonStyle(self.btnToggleFaction, "danger")
self.allowPanelFaction:addChild(self.btnToggleFaction)

self.lblFactionState = ISLabel:new(padIn, padIn + rowH + GAP, rowH, getText("UI_PV_Perms_State", getText("UI_PV_Toggle_Off")), c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
self.lblFactionState:initialise(); self.lblFactionState:instantiate()
self.allowPanelFaction:addChild(self.lblFactionState)

-- RV Interior access for Faction members
local rvRowYF = padIn + rowH + GAP + rowH + GAP
self.lblAllowFactionRV = ISLabel:new(padIn, rvRowYF, rowH, getText("UI_PV_AllowOpt_FactionRV"), c.text.r, c.text.g, c.text.b, 1, UIFont.NewSmall, true)
self.lblAllowFactionRV:initialise(); self.lblAllowFactionRV:instantiate()
self.allowPanelFaction:addChild(self.lblAllowFactionRV)

self.btnToggleFactionRV = ISButton:new(aw - toggleW - padIn, rvRowYF, toggleW, btnH, getText("UI_PV_Toggle_Off"), self, self.onToggleFactionRVClick)
self.btnToggleFactionRV.internal = "btnToggleFactionRV"
self.btnToggleFactionRV:initialise(); self.btnToggleFactionRV:instantiate()
PV.UI.ApplyButtonStyle(self.btnToggleFactionRV, "danger")
self.allowPanelFaction:addChild(self.btnToggleFactionRV)

self.lblFactionRVState = ISLabel:new(padIn, rvRowYF + rowH + GAP, rowH, getText("UI_PV_Perms_State", getText("UI_PV_Toggle_Off")), c.textMuted.r, c.textMuted.g, c.textMuted.b, 1, UIFont.NewSmall, true)
self.lblFactionRVState:initialise(); self.lblFactionRVState:instantiate()
self.allowPanelFaction:addChild(self.lblFactionRVState)

-- Apply default tab
self:setAllowTab("players")

-- ========================================================
    -- BOTTOM: Action buttons (fixed to stay inside the box)
    -- ========================================================
    local actY = midY + midH + GAP
    self.cardActions = PV.UI.CardPanel:new(PAD, actY, effectiveW - PAD * 2, actionH, getText("UI_PV_Section_Actions"))
    self.cardActions:initialise(); self.cardActions:instantiate()
    self:addChild(self.cardActions)

    local bx, by, bw, bh = self.cardActions:getInnerRect()
    local padBtn = math.floor(4 * m.scale)
    local nBtns  = 4

    -- Slightly smaller buttons + safe margin so they never bleed outside the card border
    local actBtnH = math.floor(26 * m.scale)
    if actBtnH < 22 then actBtnH = 22 end
    local safe = 2

    local usable = bw - (nBtns - 1) * padBtn - safe
    local baseW  = math.floor(usable / nBtns)
    local extra  = usable - (baseW * nBtns)

    local x = bx + math.floor(safe / 2)
    local yBtn = by + math.floor((bh - actBtnH) / 2)
    local btnIndex = 1
    local function addBtn(label, internal, variant, handler)
        local wBtn = baseW
        if btnIndex == nBtns then wBtn = baseW + extra end -- last button eats rounding
        local btn = ISButton:new(x, yBtn, wBtn, actBtnH, label, self, handler)
        btn.internal = internal
        btn:initialise(); btn:instantiate()
        PV.UI.ApplyButtonStyle(btn, variant)
        btn:setEnable(false)
        self.cardActions:addChild(btn)
        x = x + wBtn + padBtn
        btnIndex = btnIndex + 1
        return btn
    end

    self.btnUnclaim      = addBtn(getText("UI_PV_User_Unclaim"),       "btnUnclaim",      "danger",  self.onUnclaimClick)
    self.btnRemovePlayer = addBtn(getText("IGUI_PV_AllowList_Remove"), "btnRemovePlayer", "danger",  self.onRemovePlayerClick)
    self.btnPlayerPerms  = addBtn(getText("UI_PV_User_Manage"),        "btnPlayerPerms",  "primary", self.onPlayerPermsClick)
    self.btnPublicPerms  = addBtn(getText("IGUI_PV_PublicPerms"),      "btnPublicPerms",  "primary", self.onPublicPermsClick)

self:refreshList()
end

function PV.UI.UserManagerMain:render()
    ISCollapsableWindow.render(self)
end

-- ============================================================
-- close
-- ============================================================
function PV.UI.UserManagerMain:close()
    -- Save current size/position before closing
    local player = getPlayer and getPlayer()
    if player then
        local md = player:getModData()
        md.PV_WindowSizes = md.PV_WindowSizes or {}
        md.PV_WindowSizes.user = {
            w = self.width,
            h = self.height,
            x = self.x,
            y = self.y,
            layoutVersion = USER_WINDOW_LAYOUT_VERSION,
            screenW = getCore():getScreenWidth(),
            screenH = getCore():getScreenHeight(),
        }
    end
    ISCollapsableWindow.close(self)
    if self.subPanel  ~= nil then self.subPanel:close();  self.subPanel:removeFromUIManager();  self.subPanel  = nil end
    if self.modDialog ~= nil then self.modDialog:close(); self.modDialog:removeFromUIManager(); self.modDialog = nil end
    if PV.UI.UserInstance then PV.UI.UserInstance = nil end
    self:removeFromUIManager()
end

function PV.UI.UserManagerMain:prerender()
    -- B42: onResize() not reliably called by Java grip — detect here with debounce.
    local w, h = self.width, self.height
    if self._pvPrevW == nil then
        self._pvPrevW, self._pvPrevH = w, h
    elseif w ~= self._pvPrevW or h ~= self._pvPrevH then
        self._pvPrevW, self._pvPrevH = w, h
        self._pvResizeCooldown = 2
    elseif self._pvResizeCooldown and self._pvResizeCooldown > 0 then
        self._pvResizeCooldown = self._pvResizeCooldown - 1
        if self._pvResizeCooldown == 0 then
            if self.cardVehicles then self:removeChild(self.cardVehicles); self.cardVehicles = nil end
            if self.cardPreview  then self:removeChild(self.cardPreview);  self.cardPreview  = nil end
            if self.cardStats    then self:removeChild(self.cardStats);    self.cardStats    = nil end
            if self.cardAllow    then self:removeChild(self.cardAllow);    self.cardAllow    = nil end
            if self.cardActions  then self:removeChild(self.cardActions);  self.cardActions  = nil end
            self:buildLayout()
            local player = getPlayer and getPlayer()
            if player then
                local md = player:getModData()
                md.PV_WindowSizes = md.PV_WindowSizes or {}
                md.PV_WindowSizes.user = {
                    w = w,
                    h = h,
                    x = self.x,
                    y = self.y,
                    layoutVersion = USER_WINDOW_LAYOUT_VERSION,
                    screenW = getCore():getScreenWidth(),
                    screenH = getCore():getScreenHeight(),
                }
            end
        end
    end

    ISCollapsableWindow.prerender(self)

    if not self.watermarkTexture then return end

    local pad = (PV.UI.Theme and PV.UI.Theme.metrics and PV.UI.Theme.metrics.pad) or 10
    local contentX = pad
    local contentY = PAD_TOP + pad
    local contentW = self.width - (pad * 2)
    local contentH = self.height - contentY - pad

    PV.UI.DrawCenteredWatermark(
        self,
        self.watermarkTexture,
        contentX,
        contentY,
        contentW,
        contentH,
        0.09,
        0.82,
        { r = 1, g = 1, b = 1 }
    )
end

-- ============================================================
-- Constructor
-- ============================================================
function PV.UI.UserManagerMain:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index      = self
    o.showBackground  = true
    local c = (PV.UI.Theme and PV.UI.Theme.colors) or {}
    o.backgroundColor = c.windowBg or {r=0.08, g=0.08, b=0.10, a=0.97}
    o.showBorder      = true
    o.borderColor     = c.windowBorder or {r=0.55, g=0.15, b=0.15, a=1}
    o.title           = getText("UI_PV_User_Title")
    o.width           = width
    o.height          = height
    o.visibleTarget   = o
    o.moveWithMouse   = true
    o.pin             = true
    o.subPanel        = nil
    o.modDialog       = nil
    o:setResizable(true)
    o:setDrawFrame(true)
    local s = (PV.UI.Theme and PV.UI.Theme.metrics and PV.UI.Theme.metrics.scale) or 1
    o.minimumWidth  = math.floor(520 * s)
    o.minimumHeight = math.floor(440 * s)
    return o
end

-- ============================================================
-- Open singleton
-- ============================================================
function PV.UI.OpenUserManager()
    if PV.UI.UserInstance ~= nil then PV.UI.UserInstance:close() end
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local s    = (PV.UI.Theme and PV.UI.Theme.metrics and PV.UI.Theme.metrics.scale) or 1
    local minW = math.floor(520 * s)
    local minH = math.floor(440 * s)
    local defaults = PV_getUserWindowDefaults(screenW, screenH)
    local width = defaults.width
    local height = defaults.height
    local x = defaults.x
    local y = defaults.y

    -- Restore last saved size/position if available
    local player = getPlayer and getPlayer()
    if player then
        local md = player:getModData()
        md.PV_WindowSizes = md.PV_WindowSizes or {}
        local saved = md.PV_WindowSizes.user
        if saved then
            local sameLayout = saved.layoutVersion == USER_WINDOW_LAYOUT_VERSION
            local screenShrank = (saved.screenW and saved.screenW > screenW)
                or (saved.screenH and saved.screenH > screenH)
            local oversizedForCompact = defaults.compact and (
                (saved.w and saved.w > math.floor(defaults.width * 1.08)) or
                (saved.h and saved.h > math.floor(defaults.height * 1.08))
            )

            if sameLayout and not screenShrank and not oversizedForCompact then
                width  = math.max(minW, math.min(saved.w or width,  screenW - 20))
                height = math.max(minH, math.min(saved.h or height, screenH - 20))
                x = saved.x and math.max(0, math.min(saved.x, screenW - width))  or x
                y = saved.y and math.max(0, math.min(saved.y, screenH - height)) or y
            else
                md.PV_WindowSizes.user = {
                    w = width,
                    h = height,
                    x = x,
                    y = y,
                    layoutVersion = USER_WINDOW_LAYOUT_VERSION,
                    screenW = screenW,
                    screenH = screenH,
                }
            end
        end
    end
    PV.UI.UserInstance = PV.UI.UserManagerMain:new(x, y, width, height)
    PV.UI.UserInstance:initialise()
    PV.UI.UserInstance:addToUIManager()
    PV.UI.UserInstance:setVisible(true)
end
