--[[
    ProtectVehicle - PV_DocumentSystem.lua (client)
    Client-side for the Vehicle Conversion Document system.

    Provides:
      - ISPVConvertToDocAction   timed action (5 s) on vehicle right-click
      - Vehicle context menu: "Convert to Vehicle Title"
      - Inventory item context menu on VehicleConversionDoc: "Spawn Vehicle"
      - Server command handlers: docConvertSuccess, docSpawnSuccess

    B42.14.x
--]]

if isServer() and not isClient() then return end

PV = PV or {}

require "TimedActions/ISBaseTimedAction"
require "TimedActions/WalkToTimedAction"

local DOC_ITEM_TYPE = "ProtectVehicle.VehicleConversionDoc"

local function PV_addDocContextOption(context, text, fn)
    -- Match the B42-compatible addOption pattern already used by PV_Client.lua.
    return context:addOption(text, fn, fn)
end

local function PV_getVehicleOverallConditionPercent(vehicleObj)
    if not vehicleObj then return 0 end

    local total = 0
    local count = 0
    pcall(function()
        local partCount = vehicleObj:getPartCount()
        for i = 0, partCount - 1 do
            local part = vehicleObj:getPartByIndex(i)
            if part and part.getCondition then
                local c = tonumber(part:getCondition())
                if c ~= nil then
                    if c < 0 then c = 0 end
                    if c > 100 then c = 100 end
                    total = total + c
                    count = count + 1
                end
            end
        end
    end)

    if count <= 0 then return 100 end
    return total / count
end

local function PV_docConditionColor(conditionValue)
    local c = tonumber(conditionValue) or 0
    if c <= 0 then return "1,0.2,0.2" end
    if c < 25 then return "1,0.3,0.3" end
    if c < 50 then return "1,0.55,0.25" end
    if c < 75 then return "1,0.8,0.35" end
    return "0.5,1,0.5"
end

local function PV_clampPercent(v)
    local n = tonumber(v) or 0
    if n < 0 then n = 0 end
    if n > 100 then n = 100 end
    return math.floor(n + 0.5)
end

local function PV_compactText(text, maxLen)
    local s = tostring(text or "")
    local m = tonumber(maxLen) or 18
    if #s <= m then return s end
    if m < 4 then return s:sub(1, m) end
    return s:sub(1, m - 3) .. "..."
end

local function PV_formatVehiclePartName(partId)
    local raw = tostring(partId or "?")
    local key = "IGUI_VehiclePart" .. raw
    local translated = nil
    pcall(function()
        if getTextOrNull then translated = getTextOrNull(key) end
    end)
    if translated and translated ~= key then
        return translated
    end

    local name = raw:gsub("_", " ")
    name = name:gsub("(%l)(%u)", "%1 %2")
    name = name:gsub("(%a)(%d)", "%1 %2")
    name = name:gsub("(%d)(%a)", "%1 %2")
    name = name:gsub("%s+", " ")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("(%S)(%S*)", function(a, b)
        local first = tostring(a or "")
        local rest = tostring(b or "")
        if first == "" then return rest end
        return string.upper(first) .. string.lower(rest)
    end)
    return name
end

local function PV_getTitlePartsFromModData(md)
    if type(md) ~= "table" then return nil end
    if type(md.PV_Snapshot) == "table" and type(md.PV_Snapshot.parts) == "table" then
        return md.PV_Snapshot.parts
    end
    if type(md.PV_PartsCondition) == "table" then
        return md.PV_PartsCondition
    end
    return nil
end

local function PV_getTitleAccessState(md)
    if type(md) ~= "table" then
        return false, false
    end
    local access = type(md.PV_Snapshot) == "table" and type(md.PV_Snapshot.access) == "table" and md.PV_Snapshot.access or nil
    local hasKey = access and access.hasKey == true or false
    local hotwired = access and access.hotwired == true or false
    return hasKey, hotwired
end

local function PV_computeOverallFromParts(parts)
    if type(parts) ~= "table" then return nil end
    local total = 0
    local count = 0
    for _, pd in ipairs(parts) do
        local cond = pd and tonumber(pd.condition) or nil
        if cond ~= nil then
            if cond < 0 then cond = 0 end
            if cond > 100 then cond = 100 end
            total = total + cond
            count = count + 1
        end
    end
    if count <= 0 then return nil end
    return total / count
end

local function PV_titleHasRV(md)
    if type(md) ~= "table" then return false end
    if md.PV_HasRV == true then return true end
    if type(md.PV_RV) == "table" and md.PV_RV.hasRV == true then return true end
    if type(md.PV_Snapshot) == "table"
    and type(md.PV_Snapshot.rv) == "table"
    and md.PV_Snapshot.rv.hasRV == true
    then
        return true
    end
    return false
end

local function PV_collectPartLines(parts, opts)
    opts = opts or {}
    local threshold = tonumber(opts.threshold) or 20
    local criticalOnly = opts.criticalOnly == true
    local compactNames = opts.compactNames == true

    local entries = {}
    local criticalCount = 0
    for _, pd in ipairs(parts or {}) do
        local partName = PV_formatVehiclePartName(pd and pd.id or "?")
        if compactNames then
            partName = PV_compactText(partName, 16)
        end

        local cond = pd and tonumber(pd.condition) or nil
        if cond ~= nil then
            local rounded = PV_clampPercent(cond)
            local isCritical = rounded < threshold
            if isCritical then criticalCount = criticalCount + 1 end
            if not criticalOnly or isCritical then
                local lineText = getText("IGUI_PV_Doc_PartConditionLine", partName, tostring(rounded))
                lineText = tostring(lineText):gsub("%%%%", "%%")
                entries[#entries + 1] = {
                    text = lineText,
                    color = PV_docConditionColor(rounded),
                    rawName = partName,
                    rawCond = rounded,
                    isCritical = isCritical,
                }
            end
        elseif not criticalOnly then
            entries[#entries + 1] = {
                text = getText("IGUI_PV_Doc_PartConditionUnknown", partName),
                color = "0.7,0.7,0.7",
                rawName = partName,
                rawCond = nil,
                isCritical = false,
            }
        end
    end

    return entries, criticalCount
end

local function PV_appendTitlePartsTooltip(baseDescription, md, opts)
    opts = opts or {}
    local parts = PV_getTitlePartsFromModData(md)
    if type(parts) ~= "table" or #parts == 0 then
        return baseDescription, 0
    end

    local desc = baseDescription
    local overall = tonumber(md.PV_OverallCondition)
    if overall == nil then
        overall = PV_computeOverallFromParts(parts)
    end
    if overall ~= nil then
        local rounded = math.floor(overall + 0.5)
        if rounded < 0 then rounded = 0 end
        if rounded > 100 then rounded = 100 end
        desc = desc
            .. " <LINE> <RGB:" .. PV_docConditionColor(rounded) .. "> "
            .. getText("IGUI_PV_Doc_OverallCondition", tostring(rounded))
    end

    local partLines, criticalCount = PV_collectPartLines(parts, opts)
    if opts.criticalOnly == true then
        desc = desc .. " <LINE> " .. getText("IGUI_PV_Doc_CriticalPartsCondition")
    else
        desc = desc .. " <LINE> " .. getText("IGUI_PV_Doc_PartsCondition")
    end

    if #partLines == 0 and opts.criticalOnly == true then
        desc = desc .. " <LINE> <RGB:0.5,1,0.5> " .. getText("IGUI_PV_Doc_NoCriticalParts")
        return desc, criticalCount
    end

    local totalLines = #partLines
    local maxParts = tonumber(opts.maxParts)
    if maxParts and maxParts > 0 and totalLines > maxParts then
        local trimmed = {}
        for i = 1, maxParts do
            trimmed[#trimmed + 1] = partLines[i]
        end
        partLines = trimmed
    end

    if opts.twoColumns == true and #partLines > 1 then
        local half = math.ceil(#partLines / 2)
        for i = 1, half do
            local left = partLines[i]
            local right = partLines[i + half]
            desc = desc .. " <LINE> <RGB:" .. left.color .. "> " .. left.text
            if right then
                desc = desc .. " <RGB:0.85,0.85,0.85>    --    <RGB:" .. right.color .. "> " .. right.text
            end
        end
    else
        for _, line in ipairs(partLines) do
            desc = desc .. " <LINE> <RGB:" .. line.color .. "> " .. line.text
        end
    end

    local hidden = totalLines - #partLines
    if hidden > 0 then
        desc = desc
            .. " <LINE> <RGB:0.85,0.85,0.85> "
            .. "(+" .. tostring(hidden) .. " pecas...)"
    end

    return desc, criticalCount
end

local function PV_buildHoverSummaryText(md, vehicleName)
    if type(md) ~= "table" then return nil end

    -- A redeemed title keeps no usable snapshot; show its state instead of stale data.
    if md.PV_Redeemed == true then
        local used = {}
        if vehicleName and vehicleName ~= "" then used[#used + 1] = tostring(vehicleName) end
        used[#used + 1] = getText("IGUI_PV_Doc_Status_Redeemed")
        return table.concat(used, "\n")
    end
    local overall = tonumber(md.PV_OverallCondition)
    local parts = PV_getTitlePartsFromModData(md)
    if overall == nil then
        overall = PV_computeOverallFromParts(parts)
    end
    overall = PV_clampPercent(overall or 0)

    local hasKey, hotwired = PV_getTitleAccessState(md)
    local rvText = PV_titleHasRV(md) and getText("IGUI_PV_Doc_RVStatus_Yes") or getText("IGUI_PV_Doc_RVStatus_No")
    local keyText = hasKey and getText("IGUI_PV_Doc_RVStatus_Yes") or getText("IGUI_PV_Doc_RVStatus_No")
    local hotwireText = hotwired and getText("IGUI_PV_Doc_RVStatus_Yes") or getText("IGUI_PV_Doc_RVStatus_No")

    local expText = getText("IGUI_PV_Doc_ValidityNever")
    local expiresAt = tonumber(md.PV_ExpiresAt)
    if expiresAt and expiresAt > 0 then
        expText = os.date("%d/%m %H:%M", expiresAt)
        if os.time() >= expiresAt then
            expText = getText("IGUI_PV_Doc_ExpiredShort")
        else
            expText = getText("IGUI_PV_Doc_ValidityUntil", expText)
        end
    end

    local criticalLines = nil
    local criticalCount = 0
    if type(parts) == "table" and #parts > 0 then
        criticalLines, criticalCount = PV_collectPartLines(parts, { criticalOnly = true, threshold = 20, compactNames = true })
    end

    local criticalText = tostring(criticalCount)
    if criticalLines and #criticalLines > 0 then
        local a = criticalLines[1]
        local b = criticalLines[2]
        local short = a.rawName .. " " .. tostring(a.rawCond) .. "%"
        if b then
            short = short .. ", " .. b.rawName .. " " .. tostring(b.rawCond) .. "%"
        end
        criticalText = criticalText .. " (" .. short .. ")"
    end

    local lines = {}
    if vehicleName and vehicleName ~= "" then
        lines[#lines + 1] = tostring(vehicleName)
    end
    lines[#lines + 1] = getText("IGUI_PV_Doc_OverallCondition", tostring(overall))
    lines[#lines + 1] = getText("IGUI_PV_Doc_RVStatus", rvText)
    lines[#lines + 1] = getText("IGUI_PV_Doc_KeyStatus", keyText)
    lines[#lines + 1] = getText("IGUI_PV_Doc_HotwireStatus", hotwireText)
    lines[#lines + 1] = getText("IGUI_PV_Doc_ValidityStatus", expText)
    lines[#lines + 1] = getText("IGUI_PV_Doc_CriticalCount", criticalText)
    -- Inventory-item tooltip expects real newlines; "<LINE>" is rendered literally there.
    return table.concat(lines, "\n")
end

-- Text handed to InventoryItem:setTooltip() is run through Translator.getText(),
-- which calls String.format() on it. A bare "%" (as in "85%") is not a valid
-- conversion and throws UnknownFormatConversionException on every render frame,
-- so escape it to "%%" and let the formatter print a single literal "%".
local function PV_escapeTooltipPercent(text)
    if type(text) ~= "string" then return text end
    return (text:gsub("%%", "%%%%"))
end

local function PV_applyDocHoverSummary(item)
    if not item or not item.getType or item:getType() ~= "VehicleConversionDoc" then return end
    local md = item:getModData()
    if not md or not md.PV_DocId then return end
    local txt = PV_buildHoverSummaryText(md, md.PV_VehicleName)
    if txt and item.setTooltip then
        local safeText = PV_escapeTooltipPercent(txt)
        pcall(function() item:setTooltip(safeText) end)
    end
end

local function PV_collectVehicleDocItemsClient(container, out)
    if not container then return out end
    out = out or {}
    local items = nil
    pcall(function() items = container:getItems() end)
    if not items then return out end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item.getType and item:getType() == "VehicleConversionDoc" then
            out[#out + 1] = item
        end
        local nested = nil
        pcall(function()
            if item and item.getItemContainer then nested = item:getItemContainer() end
        end)
        if nested then
            PV_collectVehicleDocItemsClient(nested, out)
        end
    end
    return out
end

local function PV_refreshLocalDocHoverSummaries()
    local pl = getPlayer()
    if not pl or not pl.getInventory then return end
    local inv = pl:getInventory()
    if not inv then return end
    local docs = PV_collectVehicleDocItemsClient(inv, {})
    for _, it in ipairs(docs) do
        PV_applyDocHoverSummary(it)
    end
end

-- ============================================================
-- Timed Action: Convert vehicle → document (5 seconds)
-- ============================================================
ISPVConvertToDocAction = ISBaseTimedAction:derive("ISPVConvertToDocAction")

function ISPVConvertToDocAction:isValid()
    if not self.vehicle or self.vehicle:isRemovedFromWorld() then return false end
    return self.character:DistTo(self.vehicle:getX(), self.vehicle:getY()) <= 3.5
end

function ISPVConvertToDocAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function ISPVConvertToDocAction:update()
    self.character:faceThisObject(self.vehicle)
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISPVConvertToDocAction:start()
    self:setActionAnim("VehicleWorkOnMid")
end

function ISPVConvertToDocAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISPVConvertToDocAction:perform()
    sendClientCommand(self.character, "ProtectVehicle", "vehicleConvertToDoc",
        { vehicleId = self.vehicle:getId() })
    ISBaseTimedAction.perform(self)
end

function ISPVConvertToDocAction:new(character, vehicle)
    local o = ISBaseTimedAction.new(self, character)
    setmetatable(o, self)
    self.__index = self
    o.stopOnWalk = true
    o.stopOnRun  = true
    o.character  = character
    o.vehicle    = vehicle
    o.maxTime    = character:isTimedActionInstant() and 1 or 300
    return o
end

-- ============================================================
-- Timed Action: Spawn vehicle from document
-- ============================================================
ISPVSpawnFromDocAction = ISBaseTimedAction:derive("ISPVSpawnFromDocAction")

function ISPVSpawnFromDocAction:isValid()
    return self.character ~= nil
end

function ISPVSpawnFromDocAction:waitToStart()
    return false
end

function ISPVSpawnFromDocAction:update()
    self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISPVSpawnFromDocAction:start()
    self:setActionAnim("VehicleWorkOnMid")
end

function ISPVSpawnFromDocAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISPVSpawnFromDocAction:perform()
    sendClientCommand(self.character, "ProtectVehicle", "vehicleSpawnFromDoc", {
        docId = self.docId,
        x     = self.x,
        y     = self.y,
        z     = self.z,
    })
    ISBaseTimedAction.perform(self)
end

function ISPVSpawnFromDocAction:new(character, docId, x, y, z)
    local o = ISBaseTimedAction.new(self, character)
    setmetatable(o, self)
    self.__index = self
    o.stopOnWalk = true
    o.stopOnRun  = true
    o.character  = character
    o.docId      = docId
    o.x          = x
    o.y          = y
    o.z          = z
    o.maxTime    = character:isTimedActionInstant() and 1 or 120
    return o
end

-- ============================================================
-- Helper: choose a spawn position near the player
-- (one tile in front in cardinal direction, same Z)
-- ============================================================
local function PV_getSpawnPositionNearPlayer(playerObj)
    local px = math.floor(playerObj:getX())
    local py = math.floor(playerObj:getY())
    local pz = math.floor(playerObj:getZ() or 0)
    -- Try tiles in front, left, right, behind
    local offsets = { {3, 0}, {0, 3}, {-3, 0}, {0, -3}, {5, 0}, {0, 5} }
    for _, off in ipairs(offsets) do
        local tx, ty = px + off[1], py + off[2]
        local sq = getCell() and getCell():getGridSquare(tx, ty, pz) or nil
        if sq and not sq:isSolid() then
            return tx, ty, pz
        end
    end
    -- Fallback: player's exact tile
    return px, py, pz
end

-- ============================================================
-- Server → Client command handlers (registered in PV_Client.lua flow)
-- ============================================================
local PV_DocSystem_OnServerCommand_orig = nil
local PV_pendingVehicleRVSync = {}

local function PV_applyVehicleRVSync(vehicleRuntimeId, rv)
    if type(rv) ~= "table" or rv.hasRV ~= true then return true end

    local vehicleId = tonumber(vehicleRuntimeId) or vehicleRuntimeId
    if not vehicleId then return true end

    local vehicle = getVehicleById(vehicleId)
    if not vehicle then return false end

    local md = vehicle:getModData()
    if type(md) ~= "table" then return false end

    if rv.uniqueId ~= nil then md.projectRV_uniqueId = tostring(rv.uniqueId) end
    if rv.type ~= nil then md.projectRV_type = tostring(rv.type) end
    if type(rv.room) == "table" and rv.room.x and rv.room.y then
        md.room = {
            x = rv.room.x,
            y = rv.room.y,
            z = rv.room.z or 0,
        }
    end

    return true
end

local function PV_processPendingVehicleRVSync()
    for id, data in pairs(PV_pendingVehicleRVSync) do
        if PV_applyVehicleRVSync(id, data.rv) then
            PV_pendingVehicleRVSync[id] = nil
        else
            data.tries = (data.tries or 0) + 1
            if data.tries > 120 then
                PV_pendingVehicleRVSync[id] = nil
            end
        end
    end
end

local function PV_DocSystem_OnServerCommand(module, command, args)
    if module ~= "ProtectVehicle" then return end

    if command == "docConvertSuccess" then
        local removeRuntimeId = args and args.removeRuntimeId
        if removeRuntimeId and getPlayer() then
            pcall(function()
                sendClientCommand(getPlayer(), "vehicle", "remove", { vehicle = removeRuntimeId })
            end)
        end

        if args and args.docId and args.docEntry then
            PV.dbDocuments = PV.dbDocuments or {}
            PV.dbDocuments[args.docId] = args.docEntry

            local ownerName = args.docEntry.ownerName
            if ownerName then
                PV.dbDocumentsByPlayer = PV.dbDocumentsByPlayer or {}
                PV.dbDocumentsByPlayer[ownerName] = PV.dbDocumentsByPlayer[ownerName] or {}
                PV.dbDocumentsByPlayer[ownerName][args.docId] = true
            end
        else
            ModData.request("PVDocuments")
            ModData.request("PVDocumentsByPlayer")
        end

        -- Refresh user manager if open (new document entry may appear)
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end
        PV_refreshLocalDocHoverSummaries()

    elseif command == "docSpawnSuccess" then
        local docId = args and args.docId
        if docId then
            local ownerName = nil
            if PV.dbDocuments and PV.dbDocuments[docId] then
                ownerName = PV.dbDocuments[docId].ownerName
                PV.dbDocuments[docId] = nil
            end
            if PV.dbDocumentsByPlayer then
                if ownerName and PV.dbDocumentsByPlayer[ownerName] then
                    PV.dbDocumentsByPlayer[ownerName][docId] = nil
                else
                    for _, docs in pairs(PV.dbDocumentsByPlayer) do
                        if type(docs) == "table" then docs[docId] = nil end
                    end
                end
            end
        end

        -- Vehicle was spawned; refresh user manager
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end
        PV_refreshLocalDocHoverSummaries()
    elseif command == "syncVehicleRVData" then
        local vehicleId = args and args.vehicleRuntimeId
        local rv = args and args.rv
        if vehicleId and not PV_applyVehicleRVSync(vehicleId, rv) then
            PV_pendingVehicleRVSync[tonumber(vehicleId) or vehicleId] = { rv = rv, tries = 0 }
        end
    elseif command == "docError" then
        -- Ensure the player gets feedback even if haloNote is missed.
        local key = args and args.msgKey
        if key and getPlayer() then
            getPlayer():setHaloNote(getText(key), 255, 255, 255, 300)
        end
    end
end

-- ============================================================
-- VEHICLE CONTEXT MENU: "Convert to Vehicle Title"
-- Injected into ISVehicleMenu.FillMenuOutsideVehicle after
-- PV_Client.lua already overrides it. We chain safely.
-- ============================================================
local function PV_addConvertToDocOption(playerObj, context, vehicle)
    if not vehicle or vehicle:isRemovedFromWorld() then return end
    if not playerObj or not context then return end

    -- Only show for claimed vehicles the local player owns
    local sqlid = PV.getVehicleID(vehicle)
    if not sqlid then return end
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then return end
    if entry.OwnerPlayerID ~= playerObj:getUsername() then return end

    local function doConvert()
        local ok, err = pcall(function()
            if playerObj:DistTo(vehicle:getX(), vehicle:getY()) > 1.5 then
                ISTimedActionQueue.add(ISWalkToTimedAction:new(playerObj, vehicle))
            end
            ISTimedActionQueue.add(ISPVConvertToDocAction:new(playerObj, vehicle))
        end)
        if not ok then
            playerObj:setHaloNote(getText("IGUI_PV_Error_ActionFailed"), 255, 255, 255, 240)
            print("[PV] Convert-to-doc enqueue failed: " .. tostring(err))
        end
    end

    -- Build tooltip with checks so player knows why it might not be available
    local toolTip = ISToolTip:new()
    toolTip:initialise()
    toolTip:setVisible(false)
    toolTip.description = getText("IGUI_PV_ContextMenu_ConvertToDoc")

    local notAvailable = false
    local sv = SandboxVars.ProtectVehicle

    -- Require blank doc check (visual hint only — server enforces)
    if sv and sv.RequireConversionDocument then
        local hasDoc = playerObj:getInventory():containsTypeRecurse(DOC_ITEM_TYPE)
        if not hasDoc then
            toolTip.description = toolTip.description
                .. " <LINE> <RGB:1,0.3,0.3> "
                .. getText("IGUI_PV_ConvertToDoc_NeedDoc")
            notAvailable = true
        end
    end

    -- Max documents check (visual hint only)
    if sv then
        local maxDocs = tonumber(sv.MaxVehicleDocuments) or 0
        if maxDocs > 0 then
            local count = PV.countPlayerDocuments and PV.countPlayerDocuments(playerObj:getUsername()) or 0
            if count >= maxDocs then
                toolTip.description = toolTip.description
                    .. " <LINE> <RGB:1,0.3,0.3> "
                    .. getText("IGUI_PV_ConvertToDoc_MaxDocs")
                notAvailable = true
            end
        end
    end

    -- Minimum overall condition check (visual hint only â€” server enforces)
    if sv then
        local minCondition = tonumber(sv.MinVehicleConditionForConversion) or 0
        if minCondition > 0 then
            if minCondition < 0 then minCondition = 0 end
            if minCondition > 100 then minCondition = 100 end

            local overall = PV_getVehicleOverallConditionPercent(vehicle)
            if overall < minCondition then
                local minText = tostring(math.floor(minCondition))
                local curText = tostring(math.floor(overall + 0.5))
                toolTip.description = toolTip.description
                    .. " <LINE> <RGB:1,0.3,0.3> "
                    .. getText("IGUI_PV_ConvertToDoc_MinCondition")
                    .. " <LINE> <RGB:1,0.3,0.3> "
                    .. getText("IGUI_PV_ConvertToDoc_MinConditionHint", minText, curText)
                notAvailable = true
            end
        end
    end

    local option = PV_addDocContextOption(context, getText("IGUI_PV_ContextMenu_ConvertToDoc"), doConvert)
    option.toolTip = toolTip
    if notAvailable then option.notAvailable = true end
end

-- Chain on top of PV_Client.lua's ISVehicleMenu override (which was already set).
-- Wait until OnTick fires to ensure PV_Client.lua has already patched the function.
local _pvDocConvertHooked = false
local function PV_HookConvertToDoc()
    if _pvDocConvertHooked then return end
    _pvDocConvertHooked = true

    local _prevFill = ISVehicleMenu.FillMenuOutsideVehicle
    function ISVehicleMenu.FillMenuOutsideVehicle(player, context, vehicle, test)
        _prevFill(player, context, vehicle, test)
        PV_addConvertToDocOption(getSpecificPlayer(player), context, vehicle)
    end

    Events.OnTick.Remove(PV_HookConvertToDoc)
end

Events.OnTick.Add(PV_HookConvertToDoc)

-- ============================================================
-- INVENTORY CONTEXT MENU: "Spawn Vehicle" on VehicleConversionDoc
-- ============================================================
local function PV_isItemInPlayerMainInventory(playerObj, item)
    if not playerObj or not item then return false end
    local mainInventory = playerObj:getInventory()
    if not mainInventory then return false end

    local container = nil
    pcall(function()
        if item.getContainer then
            container = item:getContainer()
        end
    end)

    return container == mainInventory
end

local function PV_onFillInventoryContextMenu(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    -- Check if the right-clicked item is our doc and is filled
    local docItem = nil
    for _, stack in ipairs(items) do
        local item = stack
        -- In B42, items may be wrapped in an InventoryItem table or stack object
        if type(stack) == "table" and stack.items then
            item = stack.items[1]
        end
        if item and item.getType and item:getType() == "VehicleConversionDoc" then
            -- Make sure it comes from our module and is filled
            local md = item:getModData()
            if md and md.PV_DocId and not md.PV_Redeemed then
                docItem = item
                break
            end
        end
    end

    if not docItem then return end

    local md = docItem:getModData()
    local docId      = md.PV_DocId
    local vehicleName = md.PV_VehicleName or "?"
    local expiresAt  = tonumber(md.PV_ExpiresAt)
    local isExpired  = (expiresAt and expiresAt > 0 and os.time() >= expiresAt) and true or false
    local isMainInventoryDoc = PV_isItemInPlayerMainInventory(player, docItem)

    -- Build tooltip
    local toolTip = ISToolTip:new()
    toolTip:initialise()
    toolTip:setVisible(false)
    toolTip.maxLineWidth = 360
    toolTip.description = getText("IGUI_PV_Doc_VehicleName", vehicleName)
    if md.PV_ConvertedAt then
        local dateStr = os.date("%d-%b-%y %H:%M", md.PV_ConvertedAt)
        toolTip.description = toolTip.description
            .. " <LINE> "
            .. getText("IGUI_PV_Doc_ConvertedAt", dateStr)
    end
    local validityText = getText("IGUI_PV_Doc_ValidityNever")
    if expiresAt and expiresAt > 0 then
        if isExpired then
            validityText = getText("IGUI_PV_Doc_ExpiredShort")
        else
            validityText = getText("IGUI_PV_Doc_ValidityUntil", os.date("%d-%b-%y %H:%M", expiresAt))
        end
    end
    toolTip.description = toolTip.description
        .. " <LINE> "
        .. getText("IGUI_PV_Doc_ValidityStatus", validityText)

    toolTip.description = toolTip.description
        .. " <LINE> "
        .. getText(
            "IGUI_PV_Doc_RVStatus",
            PV_titleHasRV(md) and getText("IGUI_PV_Doc_RVStatus_Yes") or getText("IGUI_PV_Doc_RVStatus_No"))

    toolTip.description = PV_appendTitlePartsTooltip(toolTip.description, md, {
        criticalOnly = false,
        threshold = 20,
        twoColumns = false,
        compactNames = true,
        maxParts = 8,
    })
    PV_applyDocHoverSummary(docItem)

    if isExpired then
        toolTip.description = toolTip.description
            .. " <LINE> <RGB:1,0.3,0.3> "
            .. getText("IGUI_PV_SpawnFromDoc_Expired")
    end
    if not isMainInventoryDoc then
        toolTip.description = toolTip.description
            .. " <LINE> <RGB:1,0.3,0.3> "
            .. getText("IGUI_PV_SpawnFromDoc_MainInventoryOnly")
    end

    local function doSpawn()
        local x, y, z = PV_getSpawnPositionNearPlayer(player)
        ISTimedActionQueue.add(ISPVSpawnFromDocAction:new(player, docId, x, y, z))
    end

    local option = PV_addDocContextOption(context, getText("IGUI_PV_ContextMenu_SpawnFromDoc"), doSpawn)
    option.toolTip = toolTip
    if isExpired or not isMainInventoryDoc then
        option.notAvailable = true
    end
end

Events.OnFillInventoryObjectContextMenu.Add(PV_onFillInventoryContextMenu)

-- ============================================================
-- Hook our server command responses into the main handler
-- ============================================================
local function PV_DocSystem_AfterGameStart()
    Events.OnServerCommand.Add(PV_DocSystem_OnServerCommand)
    Events.OnTick.Remove(PV_DocSystem_AfterGameStart)
end

Events.OnTick.Add(PV_DocSystem_AfterGameStart)
Events.OnTick.Add(PV_processPendingVehicleRVSync)

-- ============================================================
-- ModData sync: request document DB on game start
-- ============================================================
local function PV_DocSystem_RequestModData()
    Events.OnTick.Remove(PV_DocSystem_RequestModData)
    pcall(function()
        ModData.request("PVDocuments")
        ModData.request("PVDocumentsByPlayer")
        PV_refreshLocalDocHoverSummaries()
    end)
end

Events.OnTick.Add(PV_DocSystem_RequestModData)

-- Receive document DB updates
local function PV_DocSystem_OnReceiveGlobalModData(key, modData)
    if key == "PVDocuments" then
        PV.dbDocuments = modData
        if PV.UI.UserInstance and PV.UI.UserInstance:isVisible() then
            PV.UI.UserInstance:refreshList()
        end
    elseif key == "PVDocumentsByPlayer" then
        PV.dbDocumentsByPlayer = modData
    end
end

Events.OnReceiveGlobalModData.Add(PV_DocSystem_OnReceiveGlobalModData)
Events.EveryOneMinute.Add(PV_refreshLocalDocHoverSummaries)
