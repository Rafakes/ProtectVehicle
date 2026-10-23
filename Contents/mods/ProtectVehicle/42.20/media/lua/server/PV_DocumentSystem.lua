--[[
    ProtectVehicle - PV_DocumentSystem.lua (server)
    Handles conversion of claimed vehicles to VehicleConversionDoc items
    and spawning vehicles back from those documents.

    Commands (client → server):
      vehicleConvertToDoc  { vehicleId }
      vehicleSpawnFromDoc  { docId, x, y, z }

    Commands (server → client):
      docConvertSuccess    { docId, vehicleName }
      docSpawnSuccess      { docId }
      docError             { msgKey }

    B42.14.x
--]]

if not isServer() then return end

PV = PV or {}

-- ============================================================
-- HELPERS
-- ============================================================

local DOC_ITEM_TYPE = "ProtectVehicle.VehicleConversionDoc"
local DOC_ITEM_SHORT_TYPE = "VehicleConversionDoc"
local PV_VEHICLE_MODDATA_KEYS = {
    tuning2 = true,
    PzkVanillaPlusCarPack = true,
    damnlib_migrated = true,
    towHeight = true,
    hookOffset = true,
    hookOffsetY = true,
}
local PV_VEHICLE_MODDATA_PREFIXES = {
    "defaultPartSet_",
}
local PV_VEHICLE_MODDATA_CLEAR_KEYS = {
    "tuning2",
    "PzkVanillaPlusCarPack",
    "damnlib_migrated",
    "towHeight",
    "hookOffset",
    "hookOffsetY",
}
local PV_VEHICLE_MODDATA_CLEAR_PREFIXES = {
    "defaultPartSet_",
}
local PV_PART_MODDATA_CLEAR_KEYS = {
    tuning2 = true,
    t2disableOpenWindow = true,
    atatuning = true,
    tsarslib = true,
    ataProtection = true,
    saveCond = true,
    ["damn:savedCondition"] = true,
    PzkVanillaPlusCarPack = true,
    fuel = true,
    isLit = true,
    burnTime = true,
}
local PV_PART_MODDATA_CLEAR_PREFIXES = {
    "damn:",
}
local PV_spawnVehicleOnSquare
local PV_restoreSnapshot

local function PV_sendDocError(player, msgKey)
    sendServerCommand(player, "ProtectVehicle", "haloNote",
        { text = msgKey, r = 1, g = 0.25, b = 0.25 })
    -- Optional explicit channel for UI/diagnostics.
    sendServerCommand(player, "ProtectVehicle", "docError", { msgKey = msgKey })
end

local function PV_dbg(msg)
    if PV and PV.Log and PV.Log.writeGlobal then
        PV.Log.writeGlobal(msg, "DEBUG")
    else
        print(tostring(msg))
    end
end

local function PV_docTrace(msg, forceConsole)
    local line = "[PV-DOC] " .. tostring(msg)
    if PV and PV.Log and PV.Log.writeGlobal then
        PV.Log.writeGlobal(line, "DEBUG", forceConsole == true)
    else
        print(line)
    end
end

PV_docTrace("module loaded", true)

local function PV_copySnapshotValue(value, depth, seen)
    local valueType = type(value)
    if valueType == "string" or valueType == "number" or valueType == "boolean" then
        return value
    end
    if valueType ~= "table" then return nil end

    depth = tonumber(depth) or 0
    if depth > 8 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true

    local out = {}
    for k, v in pairs(value) do
        local keyType = type(k)
        if keyType == "string" or keyType == "number" or keyType == "boolean" then
            local copied = PV_copySnapshotValue(v, depth + 1, seen)
            if copied ~= nil then
                out[k] = copied
            end
        end
    end

    seen[value] = nil
    return out
end

local function PV_tableIsEmpty(tbl)
    if type(tbl) ~= "table" then return true end
    for _, _ in pairs(tbl) do
        return false
    end
    return true
end

local function PV_callGetter(obj, methodName)
    if not obj or not methodName or not obj[methodName] then
        return false, nil
    end
    return pcall(function()
        return obj[methodName](obj)
    end)
end

local function PV_keyHasPrefix(key, prefixes)
    if type(key) ~= "string" or type(prefixes) ~= "table" then return false end
    for _, prefix in ipairs(prefixes) do
        if type(prefix) == "string" and string.sub(key, 1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local function PV_captureModData(obj, keySet, keyPrefixes, denyKeys)
    if not obj then return nil end

    local md = nil
    pcall(function()
        if obj.getModData then md = obj:getModData() end
    end)
    if type(md) ~= "table" then return nil end

    local out = {}
    local includeAll = keySet == nil and keyPrefixes == nil
    for key, value in pairs(md) do
        local denied = type(denyKeys) == "table" and denyKeys[key] == true
        local allowed = includeAll
            or (type(keySet) == "table" and keySet[key] == true)
            or PV_keyHasPrefix(key, keyPrefixes)
        if allowed and not denied then
            local copied = PV_copySnapshotValue(value, 0, {})
            if copied ~= nil then
                out[key] = copied
            end
        end
    end

    if PV_tableIsEmpty(out) then return nil end
    return out
end

local function PV_captureWhitelistedModData(obj, keySet, keyPrefixes)
    return PV_captureModData(obj, keySet, keyPrefixes, nil)
end

local function PV_applyCapturedModData(obj, data, clearKeys, clearPrefixes)
    if not obj then return end

    local md = nil
    pcall(function()
        if obj.getModData then md = obj:getModData() end
    end)
    if type(md) ~= "table" then return end

    if type(clearKeys) == "table" then
        for key, _ in pairs(clearKeys) do
            if type(key) == "number" then
                md[_] = nil
            else
                md[key] = nil
            end
        end
    end

    if type(clearPrefixes) == "table" then
        local keysToClear = {}
        for key, _ in pairs(md) do
            if PV_keyHasPrefix(key, clearPrefixes) then
                keysToClear[#keysToClear + 1] = key
            end
        end
        for _, key in ipairs(keysToClear) do
            md[key] = nil
        end
    end

    if type(data) ~= "table" then return end
    for key, value in pairs(data) do
        local keyType = type(key)
        if keyType == "string" or keyType == "number" or keyType == "boolean" then
            local copied = PV_copySnapshotValue(value, 0, {})
            if copied ~= nil then
                md[key] = copied
            end
        end
    end
end

local function PV_isVehicleDocItem(item)
    if not item then return false end
    local fullType = nil
    local shortType = nil
    pcall(function() if item.getFullType then fullType = item:getFullType() end end)
    pcall(function() if item.getType then shortType = item:getType() end end)
    return fullType == DOC_ITEM_TYPE
        or shortType == DOC_ITEM_SHORT_TYPE
        or shortType == DOC_ITEM_TYPE
end

local function PV_collectVehicleDocItems(container, out)
    if not container then return end
    out = out or {}

    local items = nil
    pcall(function() items = container:getItems() end)
    if not items then return out end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if PV_isVehicleDocItem(item) then
            out[#out + 1] = item
        end

        local nested = nil
        pcall(function()
            if item and item.getItemContainer then nested = item:getItemContainer() end
        end)
        if nested then
            PV_collectVehicleDocItems(nested, out)
        end
    end

    return out
end

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

local function PV_syncInventoryItem(item, playerObj)
    if not item then return end
    pcall(function()
        if item.syncItemFields then
            item:syncItemFields()
        elseif syncItemFields then
            syncItemFields(item)
        end
    end)
    pcall(function()
        if item.syncItemModData and playerObj then
            item:syncItemModData(playerObj)
        elseif syncItemModData and playerObj then
            syncItemModData(playerObj, item)
        end
    end)
    pcall(function()
        if sendItemStats then sendItemStats(item) end
    end)
end

local function PV_getSquareAt(x, y, z)
    local square = nil
    pcall(function()
        local cell = getCell and getCell() or nil
        if cell then
            square = cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
        end
    end)
    return square
end

local function PV_removeVehicleFromWorld(vehicleObj, vehicleId)
    if not vehicleObj then return false end

    local attempts = {
        "permanentlyRemove",
        "removeFromWorld",
        "removeFromSquare",
    }

    for _, methodName in ipairs(attempts) do
        local method = vehicleObj[methodName]
        if method then
            local ok, err = pcall(function() method(vehicleObj) end)
            if ok then
                PV_docTrace("remove method OK | method=" .. methodName .. " | runtimeId=" .. tostring(vehicleId))
                return true
            end
            PV_docTrace("remove method ERROR | method=" .. methodName .. " | runtimeId=" .. tostring(vehicleId) .. " | err=" .. tostring(err), true)
        else
            PV_docTrace("remove method unavailable | method=" .. methodName .. " | runtimeId=" .. tostring(vehicleId))
        end
    end

    PV_docTrace("remove FAILED | runtimeId=" .. tostring(vehicleId), true)
    return false
end

local function PV_restoreClaimAfterFailedConversion(playerObj, sqlid, entry, scriptName, snapshot, x, y, z)
    if not sqlid or type(entry) ~= "table" then return false end

    PV.dbByVehicleSQLID[sqlid] = entry
    local owner = entry.OwnerPlayerID or (playerObj and playerObj:getUsername()) or nil
    if owner then
        PV.dbByPlayerID[owner] = PV.dbByPlayerID[owner] or {
            LastKnownLogonTime = getTimestamp(),
            LastKnownLogoffTime = getTimestamp(),
        }
        PV.dbByPlayerID[owner][sqlid] = true
    end
    ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
    ModData.add("PVByPlayerID", PV.dbByPlayerID)

    local square = PV_getSquareAt(x, y, z)
    local restoredVehicle = square and PV_spawnVehicleOnSquare(scriptName, x, y, z, square, playerObj) or nil
    if restoredVehicle then
        PV_restoreSnapshot(restoredVehicle, snapshot, playerObj)
        pcall(function()
            local md = restoredVehicle:getModData()
            if md then md.SQLID = sqlid end
        end)
        sendServerCommand("ProtectVehicle", "registerVehicleSQLID", {
            vehicleRuntimeId = restoredVehicle:getId(),
            sqlid = sqlid,
        })
        PV.Log.writeGlobal("[PV] conversion rollback restored vehicle | sqlid=" .. tostring(sqlid), "WARN")
        return true
    end

    PV.Log.writeGlobal("[PV] conversion rollback restored DB only; vehicle respawn failed | sqlid=" .. tostring(sqlid), "ERROR")
    return false
end

-- Find all players online as a map username→IsoPlayer.
local function PV_getOnlinePlayerMap()
    local map = {}
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return map end
    if players.size and players.get then
        for i = 0, players:size() - 1 do
            local pl = players:get(i)
            if pl and pl.getUsername then map[pl:getUsername()] = pl end
        end
    end
    return map
end

-- Find a VehicleConversionDoc item in a player's inventory by docId.
-- Returns the item or nil.
local function PV_findDocItemInInventory(playerObj, docId)
    if not playerObj or not docId then return nil end
    local inv = playerObj:getInventory()
    if not inv then return nil end
    local found = nil
    pcall(function()
        local items = PV_collectVehicleDocItems(inv)
        for _, item in ipairs(items) do
            local md = item:getModData()
            if md and md.PV_DocId == docId then
                found = item
                return
            end
        end
    end)
    return found
end

-- Find a blank (unfilled) VehicleConversionDoc in player's inventory.
-- Blank = no PV_DocId in ModData.
local function PV_findBlankDocInInventory(playerObj)
    if not playerObj then return nil end
    local inv = playerObj:getInventory()
    if not inv then return nil end
    local found = nil
    pcall(function()
        local items = PV_collectVehicleDocItems(inv)
        for _, item in ipairs(items) do
            local md = item:getModData()
            if not md or not md.PV_DocId then
                found = item
                return
            end
        end
    end)
    return found
end

-- Check if any seat in the vehicle is occupied.
local function PV_vehicleHasPassengers(vehicleObj)
    local hasAny = false
    pcall(function()
        local count = vehicleObj.getPassengerCount and vehicleObj:getPassengerCount() or 0
        if count > 0 then hasAny = true; return end
        -- Fallback: iterate seats
        local seats = vehicleObj.getSeatCount and vehicleObj:getSeatCount() or 0
        for i = 0, seats - 1 do
            local seat = vehicleObj:getSeat(i)
            if seat and seat.getCharacter and seat:getCharacter() then
                hasAny = true; return
            end
        end
    end)
    return hasAny
end

-- Check if the vehicle has cargo in any part container.
local function PV_vehicleHasCargo(vehicleObj)
    local hasCargo = false
    pcall(function()
        local partCount = vehicleObj:getPartCount()
        for i = 0, partCount - 1 do
            local part = vehicleObj:getPartByIndex(i)
            if part then
                local container = part.getItemContainer and part:getItemContainer() or nil
                if container then
                    local items = container:getItems()
                    if items and items:size() > 0 then
                        hasCargo = true; return
                    end
                end
            end
        end
    end)
    return hasCargo
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

-- Check if a vehicle is involved in a tow (towing or being towed).
local function PV_vehicleIsTowing(vehicleObj)
    local isTowing = false
    pcall(function()
        local towing  = vehicleObj.getVehicleTowing and vehicleObj:getVehicleTowing() or nil
        local towedBy = vehicleObj.getVehicleTowedBy and vehicleObj:getVehicleTowedBy() or nil
        isTowing = (towing ~= nil) or (towedBy ~= nil)
    end)
    return isTowing
end

local function PV_vehicleIsHotwired(vehicleObj)
    local hotwired = false
    pcall(function()
        if vehicleObj and vehicleObj.isHotwired then
            hotwired = (vehicleObj:isHotwired() == true)
        end
    end)
    return hotwired
end

-- True when there is a usable key context for this vehicle:
-- key in player's inventory, key in ignition, key on door, current key object, etc.
local function PV_vehicleHasAnyKey(playerObj, vehicleObj)
    if not vehicleObj then return false end

    local hasKey = false
    local keyId = nil
    pcall(function()
        if vehicleObj.getKeyId then keyId = vehicleObj:getKeyId() end
    end)

    if playerObj and keyId and tonumber(keyId) and tonumber(keyId) >= 0 then
        pcall(function()
            local inv = playerObj:getInventory()
            if inv and inv.haveThisKeyId and inv:haveThisKeyId(tonumber(keyId)) then
                hasKey = true
            end
        end)
    end
    if hasKey then return true end

    pcall(function()
        if vehicleObj.isKeysInIgnition and vehicleObj:isKeysInIgnition() then
            hasKey = true
        end
    end)
    if hasKey then return true end

    pcall(function()
        if vehicleObj.isKeyIsOnDoor and vehicleObj:isKeyIsOnDoor() then
            hasKey = true
        end
    end)
    if hasKey then return true end

    pcall(function()
        if vehicleObj.getCurrentKey and vehicleObj:getCurrentKey() ~= nil then
            hasKey = true
        end
    end)
    if hasKey then return true end

    pcall(function()
        if vehicleObj.haveKey and vehicleObj:haveKey() then
            hasKey = true
        end
    end)

    return hasKey
end

local function PV_itemIsKey(item)
    if not item then return false end
    local isKey = false
    pcall(function()
        if item.getCategory and item:getCategory() == "Key" then
            isKey = true
        end
    end)
    if not isKey and instanceof then
        pcall(function()
            isKey = (instanceof(item, "Key") == true)
        end)
    end
    return isKey
end

local function PV_collectKeyItemsByKeyId(container, keyId, out)
    if not container then return out end
    out = out or {}

    local items = nil
    pcall(function() items = container:getItems() end)
    if not items then return out end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local itemKeyId = nil
        pcall(function()
            if item and item.getKeyId then itemKeyId = tonumber(item:getKeyId()) end
        end)

        if PV_itemIsKey(item) and itemKeyId and keyId and itemKeyId == keyId then
            out[#out + 1] = { container = container, item = item }
        end

        local nested = nil
        pcall(function()
            if item and item.getItemContainer then nested = item:getItemContainer() end
        end)
        if nested then
            PV_collectKeyItemsByKeyId(nested, keyId, out)
        end
    end

    return out
end

local function PV_consumeVehicleKeyItemsFromInventory(playerObj, vehicleObj, keyIdHint)
    if not playerObj then return 0 end

    local keyId = tonumber(keyIdHint)
    if not keyId and vehicleObj then
        pcall(function()
            if vehicleObj.getKeyId then keyId = tonumber(vehicleObj:getKeyId()) end
        end)
    end
    if not keyId or keyId < 0 then return 0 end

    local inv = playerObj:getInventory()
    if not inv then return 0 end

    local matches = PV_collectKeyItemsByKeyId(inv, keyId, {})
    local removed = 0
    for _, entry in ipairs(matches) do
        pcall(function()
            local container = entry.container
            local item = entry.item
            if container and item then
                container:Remove(item)
                if sendRemoveItemFromContainer then
                    sendRemoveItemFromContainer(container, item)
                end
                removed = removed + 1
            end
        end)
    end

    if removed > 0 then
        PV_docTrace(
            "convert consumed_keys | user='" .. tostring(playerObj:getUsername()) ..
            "' | keyId=" .. tostring(keyId) ..
            " | removed=" .. tostring(removed))
    end

    return removed
end

local _pvRvVehicleTypesCache = nil

local function PV_getRVVehicleTypes()
    if _pvRvVehicleTypesCache ~= nil then
        return _pvRvVehicleTypesCache
    end

    local ok, rv = pcall(require, "RVVehicleTypes")
    if ok and rv and type(rv.VehicleTypes) == "table" then
        _pvRvVehicleTypesCache = rv.VehicleTypes
    else
        _pvRvVehicleTypesCache = false
    end
    return _pvRvVehicleTypesCache
end

local function PV_findRVTypeByScript(scriptName)
    if type(scriptName) ~= "string" or scriptName == "" then return nil end
    local vehicleTypes = PV_getRVVehicleTypes()
    if not vehicleTypes or vehicleTypes == false then return nil end

    for typeKey, def in pairs(vehicleTypes) do
        local scripts = def and def.scripts
        if type(scripts) == "table" then
            for _, candidate in ipairs(scripts) do
                if candidate == scriptName then
                    return tostring(typeKey)
                end
            end
        end
    end
    return nil
end

local function PV_captureRVState(vehicleObj)
    local rv = { hasRV = false }
    if not vehicleObj then return rv end

    local scriptName = nil
    pcall(function()
        local script = vehicleObj:getScript()
        scriptName = script and script:getFullName() or nil
    end)

    local vmd = nil
    pcall(function() vmd = vehicleObj:getModData() end)
    vmd = (type(vmd) == "table") and vmd or {}

    local uniqueId = vmd.projectRV_uniqueId and tostring(vmd.projectRV_uniqueId) or nil
    local rvType = vmd.projectRV_type and tostring(vmd.projectRV_type) or nil
    if not rvType then
        rvType = PV_findRVTypeByScript(scriptName)
    end

    local room = nil
    if type(vmd.room) == "table" and vmd.room.x and vmd.room.y then
        room = {
            x = tonumber(vmd.room.x) or vmd.room.x,
            y = tonumber(vmd.room.y) or vmd.room.y,
            z = tonumber(vmd.room.z) or 0,
        }
    end

    rv.uniqueId = uniqueId
    rv.type = rvType
    rv.room = room
    rv.hasRV = (uniqueId ~= nil) or (rvType ~= nil) or (room ~= nil)

    return rv
end

local function PV_restoreVehicleRVState(vehicleObj, snap)
    if not vehicleObj or type(snap) ~= "table" or type(snap.rv) ~= "table" then return end
    local rv = snap.rv
    if rv.hasRV ~= true then return end

    local vmd = nil
    pcall(function() vmd = vehicleObj:getModData() end)
    if type(vmd) ~= "table" then return end

    local uniqueId = rv.uniqueId and tostring(rv.uniqueId) or nil
    local rvType = rv.type and tostring(rv.type) or nil

    if uniqueId then vmd.projectRV_uniqueId = uniqueId end
    if rvType then vmd.projectRV_type = rvType end
    if type(rv.room) == "table" and rv.room.x and rv.room.y then
        vmd.room = {
            x = rv.room.x,
            y = rv.room.y,
            z = rv.room.z or 0,
        }
    end

    if uniqueId and rvType then
        local ok, projectRVData = pcall(function()
            return ModData.getOrCreate("modPROJECTRVInterior")
        end)
        if ok and type(projectRVData) == "table" then
            local assignedKey = (rvType == "normal") and "AssignedRooms" or ("AssignedRooms" .. rvType)
            projectRVData[assignedKey] = projectRVData[assignedKey] or {}
            if type(rv.room) == "table" and rv.room.x and rv.room.y then
                projectRVData[assignedKey][uniqueId] = {
                    x = rv.room.x,
                    y = rv.room.y,
                    z = rv.room.z or 0,
                }
            end

            projectRVData.Vehicles = projectRVData.Vehicles or {}
            projectRVData.Vehicles[uniqueId] = {
                x = vehicleObj:getX(),
                y = vehicleObj:getY(),
                z = vehicleObj:getZ(),
            }

            ModData.add("modPROJECTRVInterior", projectRVData)
        end
    end
end

local function PV_capturePartItemState(item)
    if not item then return nil end

    local data = {}
    if item.getFullType then
        pcall(function() data.fullType = tostring(item:getFullType()) end)
    end
    if item.getCondition then
        pcall(function() data.condition = item:getCondition() end)
    end
    if item.getCurrentUsesFloat then
        pcall(function() data.currentUsesFloat = item:getCurrentUsesFloat() end)
    end
    if item.getCurrentUses then
        pcall(function() data.currentUses = item:getCurrentUses() end)
    end
    if item.getMaxUses then
        pcall(function() data.maxUses = item:getMaxUses() end)
    end
    if item.getUseDelta then
        pcall(function() data.useDelta = item:getUseDelta() end)
    end
    if item.getUsedDelta then
        pcall(function() data.usedDelta = item:getUsedDelta() end)
    end
    data.modData = PV_captureModData(item, nil, nil, nil)

    if not data.fullType or data.fullType == "" then return nil end
    return data
end

-- Capture a complete vehicle snapshot as a Lua table.
local function PV_captureSnapshot(vehicleObj, playerObj)
    local snap = { parts = {}, access = {} }

    -- B42 color API
    local ok, value = PV_callGetter(vehicleObj, "getColorHue")
    if ok then snap.colorHue = value end
    ok, value = PV_callGetter(vehicleObj, "getColorSaturation")
    if ok then snap.colorSat = value end
    ok, value = PV_callGetter(vehicleObj, "getColorValue")
    if ok then snap.colorVal = value end
    -- Legacy fallback fields
    ok, value = PV_callGetter(vehicleObj, "getHue")
    if ok then snap.hue = value end
    ok, value = PV_callGetter(vehicleObj, "getSaturation")
    if ok then snap.sat = value end
    ok, value = PV_callGetter(vehicleObj, "getValue")
    if ok then snap.val = value end
    ok, value = PV_callGetter(vehicleObj, "getSkinIndex")
    if ok then snap.skinIndex = value end
    ok, value = PV_callGetter(vehicleObj, "getRust")
    if ok then snap.rust = value end
    snap.modData = PV_captureWhitelistedModData(vehicleObj, PV_VEHICLE_MODDATA_KEYS, PV_VEHICLE_MODDATA_PREFIXES)
    snap.engine = {}
    ok, value = PV_callGetter(vehicleObj, "getEngineQuality")
    if ok then snap.engine.quality = value end
    ok, value = PV_callGetter(vehicleObj, "getEngineLoudness")
    if ok then snap.engine.loudness = value end
    ok, value = PV_callGetter(vehicleObj, "getEnginePower")
    if ok then snap.engine.power = value end
    if PV_tableIsEmpty(snap.engine) then snap.engine = nil end
    pcall(function()
        if vehicleObj.getKeyId then snap.access.keyId = vehicleObj:getKeyId() end
    end)
    snap.access.hasKey = PV_vehicleHasAnyKey(playerObj, vehicleObj)
    snap.access.hotwired = PV_vehicleIsHotwired(vehicleObj)
    snap.rv = PV_captureRVState(vehicleObj)

    pcall(function()
        local count = vehicleObj:getPartCount()
        for i = 0, count - 1 do
            local part = vehicleObj:getPartByIndex(i)
            if part then
                local pd = {}
                if part.getId then
                    pd.id = part:getId()
                end
                if pd.id then
                    if part.getCondition then
                        pcall(function() pd.condition = part:getCondition() end)
                    end
                    if part.getHealth then
                        pcall(function() pd.health = part:getHealth() end)
                    end
                    if part.getContainerContentAmount then
                        pcall(function() pd.contentAmount = part:getContainerContentAmount() end)
                    end
                    if part.getContainerCapacity then
                        pcall(function() pd.contentCapacity = part:getContainerCapacity() end)
                    end
                    if part.getItemType then
                        pcall(function() pd.requiredItemType = tostring(part:getItemType() or "") end)
                    end
                    pd.modData = PV_captureModData(part, nil, nil, nil)
                    if part.getTable then
                        pcall(function() pd.hasInstallTable = part:getTable("install") ~= nil end)
                    end
                    if part.getInventoryItem then
                        pcall(function()
                            local item = part:getInventoryItem()
                            pd.hasInventoryItem = item ~= nil
                            pd.item = PV_capturePartItemState(item)
                            if type(pd.item) == "table" and pd.item.fullType then
                                pd.installedItemType = pd.item.fullType
                            end
                        end)
                    end
                    if pd.hasInstallTable ~= nil then
                        pd.missing = pd.hasInstallTable == true and pd.hasInventoryItem == false
                    end
                end
                -- Capture door/window open state if available
                if pd.id then pcall(function()
                    local isWindowPart = false
                    if part.isWindow then
                        isWindowPart = (part:isWindow() == true)
                    end
                    if isWindowPart then
                        pd.isOpen = (part.isOpen and part:isOpen()) or false
                        pd.isDamaged = (part.getDamagedRate and part:getDamagedRate()) or 0
                    end
                end) end
                if pd.id then
                    table.insert(snap.parts, pd)
                end
            end
        end
    end)

    return snap
end

local function PV_clearVehicleContainers(vehicleObj)
    if not vehicleObj then return end
    pcall(function()
        local partCount = vehicleObj:getPartCount()
        for i = 0, partCount - 1 do
            local part = vehicleObj:getPartByIndex(i)
            if part then
                local container = part.getItemContainer and part:getItemContainer() or nil
                if container and container.clear then
                    container:clear()
                end
            end
        end
    end)
end

local function PV_restoreVehicleAccessState(vehicleObj, snap, playerObj)
    if not vehicleObj or not snap or type(snap.access) ~= "table" then return end
    local access = snap.access

    local hotwired = access.hotwired == true
    pcall(function()
        if vehicleObj.setHotwired then vehicleObj:setHotwired(hotwired) end
    end)

    -- Normalize spawned key state first so we can rebuild it deterministically.
    pcall(function()
        if vehicleObj.setKeysInIgnition then vehicleObj:setKeysInIgnition(false) end
    end)
    pcall(function()
        if vehicleObj.setKeyIsOnDoor then vehicleObj:setKeyIsOnDoor(false) end
    end)
    pcall(function()
        if vehicleObj.setCurrentKey then vehicleObj:setCurrentKey(nil) end
    end)

    if access.hasKey == true then
        local keyId = tonumber(access.keyId)
        if keyId and keyId >= 0 then
            pcall(function()
                if vehicleObj.setKeyId then vehicleObj:setKeyId(keyId) end
            end)
        end

        local alreadyHasKey = false
        if playerObj and keyId and keyId >= 0 then
            pcall(function()
                local inv = playerObj:getInventory()
                if inv and inv.haveThisKeyId and inv:haveThisKeyId(keyId) then
                    alreadyHasKey = true
                end
            end)
        end

        local keyItem = nil
        if not alreadyHasKey then
            pcall(function()
                if vehicleObj.createVehicleKey then keyItem = vehicleObj:createVehicleKey() end
            end)
        end

        if keyItem and playerObj then
            pcall(function()
                local inv = playerObj:getInventory()
                if inv then
                    inv:AddItem(keyItem)
                    if sendAddItemToContainer then sendAddItemToContainer(inv, keyItem) end
                end
            end)
        end
    end
end

local function PV_forceVehicleUnlocked(vehicleObj)
    if not vehicleObj then return end

    pcall(function()
        local partCount = vehicleObj:getPartCount()
        for i = 0, partCount - 1 do
            local part = vehicleObj:getPartByIndex(i)
            if part and part.getDoor then
                local door = part:getDoor()
                if door then
                    if door.setLocked then
                        pcall(function() door:setLocked(false) end)
                    end
                    if vehicleObj.transmitPartDoor then
                        pcall(function() vehicleObj:transmitPartDoor(part) end)
                    end
                end
            end
        end
    end)
end

local function PV_snapshotPartIsMissingItem(pdata)
    if type(pdata) ~= "table" or pdata.item ~= nil then return false end
    if pdata.missing ~= nil then return pdata.missing == true end
    if pdata.hasInventoryItem == true then return false end
    if tostring(pdata.installedItemType or pdata.itemType or "") ~= "" then return false end
    if pdata.hasInstallTable ~= nil then return pdata.hasInstallTable == true end

    -- Older titles did not store the vanilla install table flag.
    -- Only treat old records as missing when there is no positive condition.
    local requiredItemType = tostring(pdata.requiredItemType or "")
    local condition = tonumber(pdata.condition)
    return requiredItemType ~= "" and (condition == nil or condition <= 0)
end

local function PV_clearPartInventoryItem(part, vehicleObj)
    if not part or not part.setInventoryItem then return end

    local existing = nil
    pcall(function()
        if part.getInventoryItem then existing = part:getInventoryItem() end
    end)
    if not existing then return end

    pcall(function() part:setInventoryItem(nil) end)
    if vehicleObj and vehicleObj.transmitPartItem then
        pcall(function() vehicleObj:transmitPartItem(part) end)
    end
end

local function PV_restorePartItemState(part, pdata, vehicleObj)
    if not part or type(pdata) ~= "table" then return end

    if type(pdata.item) ~= "table" then
        if PV_snapshotPartIsMissingItem(pdata) then
            PV_clearPartInventoryItem(part, vehicleObj)
        end
        return
    end

    local itemData = pdata.item
    local fullType = tostring(itemData.fullType or itemData.itemType or "")
    if fullType == "" then return end

    local item = nil
    pcall(function()
        if part.getInventoryItem then item = part:getInventoryItem() end
    end)

    local currentType = nil
    if item and item.getFullType then
        pcall(function() currentType = tostring(item:getFullType()) end)
    end

    if (not item or currentType ~= fullType) then
        local created = nil
        if InventoryItemFactory and InventoryItemFactory.CreateItem then
            pcall(function() created = InventoryItemFactory.CreateItem(fullType) end)
        end
        -- fallback: B42 vehicle part items use instanceItem() instead of InventoryItemFactory
        if not created then
            pcall(function() if instanceItem then created = instanceItem(fullType) end end)
        end
        if created then
            item = created
            pcall(function()
                if part.setInventoryItem then part:setInventoryItem(item) end
            end)
            pcall(function()
                if vehicleObj and vehicleObj.transmitPartItem then vehicleObj:transmitPartItem(part) end
            end)
        end
    end

    if not item then return end

    if itemData.condition ~= nil and item.setCondition then
        pcall(function() item:setCondition(itemData.condition) end)
    end
    PV_applyCapturedModData(item, itemData.modData, nil)
    if itemData.useDelta ~= nil and item.setUseDelta then
        pcall(function() item:setUseDelta(itemData.useDelta) end)
    end
    if itemData.currentUses ~= nil and item.setCurrentUses then
        pcall(function() item:setCurrentUses(itemData.currentUses) end)
    end

    local usedDelta = itemData.usedDelta
    if usedDelta == nil then usedDelta = itemData.currentUsesFloat end
    if usedDelta ~= nil and item.setUsedDelta then
        pcall(function()
            local v = tonumber(usedDelta)
            if v then
                if v < 0 then v = 0 end
                if v > 1 then v = 1 end
                item:setUsedDelta(v)
            end
        end)
        pcall(function()
            if vehicleObj and vehicleObj.transmitPartUsedDelta then vehicleObj:transmitPartUsedDelta(part) end
        end)
    end

    pcall(function()
        if vehicleObj and vehicleObj.transmitPartItem then vehicleObj:transmitPartItem(part) end
    end)
end

local function PV_syncRestoredPartModData(vehicleObj, part, data)
    if not vehicleObj or not part or type(data) ~= "table" or PV_tableIsEmpty(data) then return end
    if vehicleObj.transmitPartModData then
        pcall(function() vehicleObj:transmitPartModData(part) end)
    end
end

local function PV_runRestoredPartInstallComplete(vehicleObj, part)
    if not vehicleObj or not part then return end

    local item = nil
    pcall(function()
        if part.getInventoryItem then item = part:getInventoryItem() end
    end)
    if not item then return end

    local installTable = nil
    pcall(function()
        if part.getTable then installTable = part:getTable("install") end
    end)
    if type(installTable) == "table" and installTable.complete and VehicleUtils and VehicleUtils.callLua then
        pcall(function()
            VehicleUtils.callLua(installTable.complete, vehicleObj, part)
        end)
    end

    pcall(function()
        if part.doInventoryItemStats then
            part:doInventoryItemStats(part:getInventoryItem(), part:getMechanicSkillInstaller())
        end
    end)
    pcall(function()
        local wheelIndex = part.getWheelIndex and part:getWheelIndex() or nil
        if wheelIndex and wheelIndex > -1 and vehicleObj.setTireRemoved then
            vehicleObj:setTireRemoved(wheelIndex, false)
        end
    end)
end

local function PV_callModelRefresh(fn, vehicleObj, part, item)
    if type(fn) ~= "function" then return end
    if item then
        pcall(fn, vehicleObj, part, item)
    else
        pcall(fn, vehicleObj, part)
    end
end

local function PV_refreshDAMNPartModels(vehicleObj)
    if not vehicleObj then return end

    local scriptFullName = nil
    pcall(function()
        local script = vehicleObj.getScript and vehicleObj:getScript() or nil
        if script and script.getFullName then scriptFullName = tostring(script:getFullName() or "") end
    end)
    if not scriptFullName or scriptFullName == "" then return end

    local registry = nil
    if type(KI5) == "table" and type(KI5.loadedParts) == "table" then
        registry = KI5.loadedParts[scriptFullName]
    end
    if type(registry) ~= "table" and type(DAMN) == "table"
    and type(DAMN.Parts) == "table" and type(DAMN.Parts.loadedByVehicleScript) == "table" then
        registry = DAMN.Parts.loadedByVehicleScript[scriptFullName]
    end
    if type(registry) ~= "table" or type(registry.rootNS) ~= "table" or type(registry.parts) ~= "table" then return end

    for partNS, enabled in pairs(registry.parts) do
        if enabled and type(registry.rootNS[partNS]) == "function" then
            pcall(registry.rootNS[partNS], vehicleObj, nil)
        end
    end
end

local function PV_refreshGenericPartModels(vehicleObj, part)
    if not vehicleObj or not part then return end

    local item = nil
    pcall(function()
        if part.getInventoryItem then item = part:getInventoryItem() end
    end)

    if ATATuning and type(ATATuning.ModelByItemName) == "function" then
        PV_callModelRefresh(ATATuning.ModelByItemName, vehicleObj, part, item)
    end
    if ATATuning2Utils and type(ATATuning2Utils.ModelByItemName) == "function" then
        PV_callModelRefresh(ATATuning2Utils.ModelByItemName, vehicleObj, part, item)
    end
    if ATATuning2Utils and type(ATATuning2Utils.ModelByModData) == "function" then
        -- ModelByModData calls setAllModelsVisible(false) unconditionally and then removes
        -- the inventory item when tuning2 exists but model=nil. Only call it for parts
        -- where tuning2.model is explicitly set (non-nil), so base window/glass parts
        -- that carry tuning2 as a marker (model=nil) are not affected.
        local _md2 = nil
        pcall(function() if part.getModData then _md2 = part:getModData() end end)
        if type(_md2) == "table" and type(_md2.tuning2) == "table" and _md2.tuning2.model ~= nil then
            PV_callModelRefresh(ATATuning2Utils.ModelByModData, vehicleObj, part, item)
        end
    end
    if SVUC and type(SVUC.ModelByItemName) == "function" then
        PV_callModelRefresh(SVUC.ModelByItemName, vehicleObj, part, item)
    end
    if SVUC and type(SVUC.ModelByModData) == "function" then
        PV_callModelRefresh(SVUC.ModelByModData, vehicleObj, part, item)
    end
end

local PV_ATA_ENGINE_PART_IDS = {
    ATA2AirScoop = true,
    ATA2Airscoop = true,
    ATA2Snorkel = true,
}

local PV_ATA_ENGINE_PART_ALIASES = {
    ATA2AirScoop = "ATA2Airscoop",
    ATA2Airscoop = "ATA2AirScoop",
}

local function PV_getNumber(value)
    local n = tonumber(value)
    if n == nil then return nil end
    return n
end

local function PV_getVehicleNumber(vehicleObj, getterName)
    local value = nil
    pcall(function()
        if vehicleObj and getterName and vehicleObj[getterName] then
            value = vehicleObj[getterName](vehicleObj)
        end
    end)
    return PV_getNumber(value)
end

local function PV_getPartId(part)
    local partId = nil
    pcall(function()
        if part and part.getId then partId = tostring(part:getId() or "") end
    end)
    return partId
end

local function PV_getVehicleScriptName(vehicleObj)
    local vehicleName = nil
    pcall(function()
        local script = vehicleObj and vehicleObj.getScript and vehicleObj:getScript() or nil
        if script and script.getName then vehicleName = tostring(script:getName() or "") end
    end)
    return vehicleName
end

local function PV_getATATuningModelInfo(vehicleObj, partId, modelName)
    if type(ATA2TuningTable) ~= "table" or not partId or not modelName then return nil end

    local vehicleName = PV_getVehicleScriptName(vehicleObj)
    if not vehicleName or vehicleName == "" then return nil end

    local vehicleInfo = ATA2TuningTable[vehicleName]
    if type(vehicleInfo) ~= "table" or type(vehicleInfo.parts) ~= "table" then return nil end

    local partInfo = vehicleInfo.parts[partId]
    if type(partInfo) ~= "table" then
        local alias = PV_ATA_ENGINE_PART_ALIASES[partId]
        if alias then partInfo = vehicleInfo.parts[alias] end
    end
    if type(partInfo) ~= "table" then return nil end

    local modelInfo = partInfo[tostring(modelName)]
    if type(modelInfo) ~= "table" then return nil end
    return modelInfo
end

local function PV_getPartTuning2(part)
    local md = nil
    pcall(function()
        if part and part.getModData then md = part:getModData() end
    end)
    if type(md) ~= "table" or type(md.tuning2) ~= "table" then return nil end
    return md.tuning2
end

local function PV_isATATuningEngineUpgrade(vehicleObj, part, tuning)
    if type(tuning) ~= "table" or not tuning.model then return false end

    local partId = PV_getPartId(part)
    local modelInfo = PV_getATATuningModelInfo(vehicleObj, partId, tuning.model)
    if type(modelInfo) == "table" and modelInfo.engineUpgrade then return true end
    if PV_ATA_ENGINE_PART_IDS[partId] then return true end
    if tuning.hasAirScoop == true then return true end
    if PV_getNumber(tuning.oldPower) or PV_getNumber(tuning.powerIncrease) or PV_getNumber(tuning.enginePower) then return true end
    return false
end

local function PV_captureGeneratedTuning2EngineData(vehicleObj, part)
    local tuning = PV_getPartTuning2(part)
    if not PV_isATATuningEngineUpgrade(vehicleObj, part, tuning) then return nil end

    local out = {
        oldPower = PV_getNumber(tuning.oldPower),
        powerIncrease = PV_getNumber(tuning.powerIncrease),
        oldLoudness = PV_getNumber(tuning.oldLoudness),
        enginePower = PV_getNumber(tuning.enginePower),
        hasAirScoop = tuning.hasAirScoop == true,
    }
    if not out.oldPower and not out.powerIncrease and not out.oldLoudness and not out.enginePower and not out.hasAirScoop then
        return nil
    end
    return out
end

local function PV_setTuningNumber(tuning, key, value)
    if value == nil then return false end
    if type(tuning[key]) ~= "number" or tuning[key] ~= value then
        tuning[key] = value
        return true
    end
    return false
end

local function PV_normalizeTuning2EngineUpgrade(vehicleObj, part, generated)
    local tuning = PV_getPartTuning2(part)
    if not PV_isATATuningEngineUpgrade(vehicleObj, part, tuning) then return false end

    local partId = PV_getPartId(part)
    local modelInfo = PV_getATATuningModelInfo(vehicleObj, partId, tuning.model)
    local powerIncrease = PV_getNumber(tuning.powerIncrease)
        or (type(generated) == "table" and PV_getNumber(generated.powerIncrease) or nil)
        or (type(modelInfo) == "table" and PV_getNumber(modelInfo.powerIncrease) or nil)
        or 100

    local enginePower = PV_getNumber(tuning.enginePower)
        or (type(generated) == "table" and PV_getNumber(generated.enginePower) or nil)
    local oldPower = PV_getNumber(tuning.oldPower)
        or (type(generated) == "table" and PV_getNumber(generated.oldPower) or nil)

    if not oldPower and enginePower and powerIncrease then
        oldPower = enginePower - powerIncrease
    end
    if not oldPower then
        local currentPower = PV_getVehicleNumber(vehicleObj, "getEnginePower")
        if currentPower and powerIncrease then
            oldPower = currentPower - powerIncrease
        else
            oldPower = 0
        end
    end
    if not enginePower and oldPower and powerIncrease then
        enginePower = oldPower + powerIncrease
    end

    local oldLoudness = PV_getNumber(tuning.oldLoudness)
        or (type(generated) == "table" and PV_getNumber(generated.oldLoudness) or nil)
    if not oldLoudness then
        local currentLoudness = PV_getVehicleNumber(vehicleObj, "getEngineLoudness")
        if currentLoudness and currentLoudness > 0 then
            oldLoudness = currentLoudness / 2.75
        else
            oldLoudness = 0
        end
    end

    local changed = false
    changed = PV_setTuningNumber(tuning, "powerIncrease", powerIncrease) or changed
    changed = PV_setTuningNumber(tuning, "oldPower", oldPower) or changed
    changed = PV_setTuningNumber(tuning, "oldLoudness", oldLoudness) or changed
    changed = PV_setTuningNumber(tuning, "enginePower", enginePower) or changed
    if tuning.hasAirScoop ~= true then
        tuning.hasAirScoop = true
        changed = true
    end

    if changed and vehicleObj and vehicleObj.transmitPartModData then
        pcall(function() vehicleObj:transmitPartModData(part) end)
    end
    return changed
end

local function PV_refreshTuningModels(vehicleObj)
    if not vehicleObj then return end

    pcall(function()
        local partCount = vehicleObj:getPartCount()
        for i = 0, partCount - 1 do
            local part = vehicleObj:getPartByIndex(i)
            if part then
                local md = nil
                pcall(function()
                    if part.getModData then md = part:getModData() end
                end)
                local tuning = type(md) == "table" and type(md.tuning2) == "table" and md.tuning2 or nil
                    if tuning and tuning.model then
                        local item = nil
                        pcall(function()
                            if part.getInventoryItem then item = part:getInventoryItem() end
                        end)
                        if ATATuning and type(ATATuning.ModelByItemName) == "function" then
                            pcall(ATATuning.ModelByItemName, vehicleObj, part, item)
                        end
                        if ATATuning2Utils and type(ATATuning2Utils.ModelByModData) == "function" then
                            pcall(ATATuning2Utils.ModelByModData, vehicleObj, part, item)
                        end
                        PV_refreshGenericPartModels(vehicleObj, part)
                    PV_normalizeTuning2EngineUpgrade(vehicleObj, part, nil)
                    local partId = nil
                    pcall(function()
                        if part.getId then partId = tostring(part:getId() or "") end
                    end)
                    if type(SetModelAnchor) == "function" and string.find(partId or "", "Anchor") then
                        pcall(SetModelAnchor, part)
                    end
                    if vehicleObj.transmitPartModData then
                        pcall(function() vehicleObj:transmitPartModData(part) end)
                    end
                    if vehicleObj.transmitPartItem then
                        pcall(function() vehicleObj:transmitPartItem(part) end)
                    end
                elseif type(md) == "table" and not PV_tableIsEmpty(md) then
                    PV_refreshGenericPartModels(vehicleObj, part)
                    if vehicleObj.transmitPartModData then
                        pcall(function() vehicleObj:transmitPartModData(part) end)
                    end
                else
                    PV_refreshGenericPartModels(vehicleObj, part)
                end
            end
        end
    end)

    PV_refreshDAMNPartModels(vehicleObj)
    pcall(function()
        if type(SetHoodScooped) ~= "function" then return end
        local hood = vehicleObj:getPartById("EngineDoor")
        if not hood then return end
        local scoop = vehicleObj:getPartById("ATA2AirScoop")
        SetHoodScooped(hood, scoop and scoop:getInventoryItem() ~= nil)
    end)
    pcall(function() if vehicleObj.doDamageOverlay then vehicleObj:doDamageOverlay() end end)
end

local function PV_postRestoreDAMNSaveCond(vehicleObj)
    local damnOk = type(DAMN) == "table" and type(DAMN.Armor) == "table"
    if not damnOk then return end
    local count = vehicleObj:getPartCount()
    for i = 0, count - 1 do
        local part = vehicleObj:getPartByIndex(i)
        if part then
            local md = part:getModData()
            local cond = part:getCondition()
            md["saveCond"] = cond
            md["damn:savedCondition"] = cond
            vehicleObj:transmitPartModData(part)
        end
    end
end

local function PV_postRestoreSVU3Init(vehicleObj)
    local svu3Ok = type(ATATuning2) == "table" and type(ATATuning2.Init) == "table" and type(ATATuning2.Init.Tuning) == "function"
    if not svu3Ok then return end
    local count = vehicleObj:getPartCount()

    for i = 0, count - 1 do
        local part = vehicleObj:getPartByIndex(i)
        if part then
            local md = part:getModData()
            local hasT2 = type(md) == "table" and type(md.tuning2) == "table"
            local t2model = hasT2 and md.tuning2.model or nil
            -- Only call Init.Tuning when tuning2.model is explicitly set.
            -- ModelByModData (called inside Init.Tuning) runs setAllModelsVisible(false)
            -- and then removes the inventory item when model=nil — which wrongly strips
            -- TrunkDoor, TruckBed, window glass, etc. that are tuning2-tagged but have
            -- no active model. Parts with model=nil are just SVU3 markers, not active tuning.
            if hasT2 and t2model ~= nil then
                pcall(ATATuning2.Init.Tuning, vehicleObj, part)
                vehicleObj:transmitPartModData(part)
            end
        end
    end
end

-- Restore a vehicle snapshot previously captured by PV_captureSnapshot.
PV_restoreSnapshot = function(vehicleObj, snap, playerObj)
    if not snap then return end

    pcall(function()
        if snap.colorHue ~= nil and snap.colorSat ~= nil and snap.colorVal ~= nil and vehicleObj.setColorHSV then
            vehicleObj:setColorHSV(snap.colorHue, snap.colorSat, snap.colorVal)
        else
            if snap.hue ~= nil and vehicleObj.setHue then vehicleObj:setHue(snap.hue) end
            if snap.sat ~= nil and vehicleObj.setSaturation then vehicleObj:setSaturation(snap.sat) end
            if snap.val ~= nil and vehicleObj.setValue then vehicleObj:setValue(snap.val) end
        end
        if snap.skinIndex ~= nil then vehicleObj:setSkinIndex(snap.skinIndex) end
        if snap.rust      ~= nil then vehicleObj:setRust(snap.rust) end
    end)
    PV_applyCapturedModData(vehicleObj, snap.modData, PV_VEHICLE_MODDATA_CLEAR_KEYS, PV_VEHICLE_MODDATA_CLEAR_PREFIXES)

    if snap.parts then
        for _, pd in ipairs(snap.parts) do
            pcall(function()
                local part = vehicleObj:getPartById(pd.id)
                if not part then return end
                if pd.condition ~= nil and part.setCondition then part:setCondition(pd.condition) end
                if pd.health    ~= nil and part.setHealth then part:setHealth(pd.health) end
                PV_applyCapturedModData(part, pd.modData, PV_PART_MODDATA_CLEAR_KEYS)
                PV_restorePartItemState(part, pd, vehicleObj)
                PV_runRestoredPartInstallComplete(vehicleObj, part)
                local generatedTuning2 = PV_captureGeneratedTuning2EngineData(vehicleObj, part)
                PV_restorePartItemState(part, pd, vehicleObj)
                PV_applyCapturedModData(part, pd.modData, PV_PART_MODDATA_CLEAR_KEYS, PV_PART_MODDATA_CLEAR_PREFIXES)
                local normalizedTuning2 = PV_normalizeTuning2EngineUpgrade(vehicleObj, part, generatedTuning2)
                PV_syncRestoredPartModData(vehicleObj, part, pd.modData)
                PV_refreshGenericPartModels(vehicleObj, part)
                if normalizedTuning2 and (type(pd.modData) ~= "table" or PV_tableIsEmpty(pd.modData)) then
                    PV_syncRestoredPartModData(vehicleObj, part, { tuning2 = true })
                end
                if pd.condition ~= nil and part.setCondition then part:setCondition(pd.condition) end
                if pd.health    ~= nil and part.setHealth then part:setHealth(pd.health) end
                if pd.contentAmount ~= nil and part.setContainerContentAmount then
                    pcall(function() part:setContainerContentAmount(pd.contentAmount) end)
                    pcall(function()
                        if vehicleObj.transmitPartUsedDelta then vehicleObj:transmitPartUsedDelta(part) end
                    end)
                end
                if pd.isOpen    ~= nil then
                    if pd.isOpen then
                        if part.open then pcall(function() part:open() end) end
                    else
                        if part.close then pcall(function() part:close() end) end
                    end
                end
                if pd.isDamaged ~= nil and part.setDamagedRate then
                    pcall(function() part:setDamagedRate(pd.isDamaged) end)
                end
            end)
        end
    end

    PV_postRestoreSVU3Init(vehicleObj)
    PV_postRestoreDAMNSaveCond(vehicleObj)
    PV_refreshTuningModels(vehicleObj)
    pcall(function()
        if snap.engine and vehicleObj.setEngineFeature
        and snap.engine.quality ~= nil and snap.engine.loudness ~= nil and snap.engine.power ~= nil then
            vehicleObj:setEngineFeature(snap.engine.quality, snap.engine.loudness, snap.engine.power)
        end
    end)
    pcall(function() if vehicleObj.transmitEngine then vehicleObj:transmitEngine() end end)
    pcall(function() if vehicleObj.updatePartStats then vehicleObj:updatePartStats() end end)
    pcall(function() if vehicleObj.updateBulletStats then vehicleObj:updateBulletStats() end end)

    PV_restoreVehicleAccessState(vehicleObj, snap, playerObj)
    PV_restoreVehicleRVState(vehicleObj, snap)

    if vehicleObj.transmitColorHSV then pcall(function() vehicleObj:transmitColorHSV() end) end
end

-- Spawn vehicle in B42 server environment.
-- Prefer addVehicleDebug(script, direction, skinIndex, square), with safe fallbacks.
local function PV_squareBlocksVehicleSpawn(square)
    if not square then return true end

    local blocked = false
    pcall(function()
        if square.isOutside and square:isOutside() == false then blocked = true end
    end)
    if blocked then return true end

    pcall(function()
        if square.isSolid and square:isSolid() then blocked = true end
    end)
    if blocked then return true end

    pcall(function()
        if square.isSolidTrans and square:isSolidTrans() then blocked = true end
    end)
    if blocked then return true end

    pcall(function()
        if square.isFree and square:isFree(false) == false then blocked = true end
    end)
    if blocked then return true end

    pcall(function()
        local moving = square.getMovingObjects and square:getMovingObjects() or nil
        if moving and moving.size and moving:size() > 0 then blocked = true end
    end)

    return blocked
end

local function PV_spawnAreaHasVehicle(x, y, z, radius)
    local found = false
    pcall(function()
        local cell = getCell and getCell() or nil
        local vehicles = cell and cell.getVehicles and cell:getVehicles() or nil
        if not vehicles then return end
        local r = radius or 4
        local r2 = r * r
        PV.iterVehicles(vehicles, function(v)
            if found or not v or v:isRemovedFromWorld() then return end
            local vz = v.getZ and v:getZ() or z
            if math.abs((vz or 0) - (z or 0)) > 0.75 then return end
            local dx = (v:getX() or 0) - x
            local dy = (v:getY() or 0) - y
            if (dx * dx) + (dy * dy) <= r2 then found = true end
        end)
    end)
    return found
end

local function PV_isVehicleSpawnAreaClear(x, y, z)
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    z = math.floor(tonumber(z) or 0)

    for dx = -1, 1 do
        for dy = -2, 2 do
            local sq = PV_getSquareAt(x + dx, y + dy, z)
            if PV_squareBlocksVehicleSpawn(sq) then
                PV_docTrace("spawn denied | reason=blocked_square | pos=" ..
                    tostring(x + dx) .. "," .. tostring(y + dy) .. "," .. tostring(z))
                return false
            end
        end
    end

    if PV_spawnAreaHasVehicle(x, y, z, 4) then
        PV_docTrace("spawn denied | reason=near_vehicle | pos=" ..
            tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
        return false
    end

    return true
end

PV_spawnVehicleOnSquare = function(scriptName, x, y, z, square, player)
    local newVehicle = nil

    local direction = nil
    pcall(function()
        if player and player.getDir then
            direction = player:getDir()
        end
    end)
    if not direction and IsoDirections and IsoDirections.N then
        direction = IsoDirections.N
    end

    if type(addVehicleDebug) == "function" then
        local ok, err = pcall(function()
            newVehicle = addVehicleDebug(scriptName, direction, nil, square)
        end)
        if ok and newVehicle then
            PV_docTrace("spawn method OK | method=addVehicleDebug | script=" .. tostring(scriptName) .. " | pos=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
            return newVehicle
        end
        PV_docTrace("spawn method fail | method=addVehicleDebug | script=" .. tostring(scriptName) .. " | err=" .. tostring(err))
    end

    if type(addVehicle) == "function" then
        local ok, err = pcall(function()
            newVehicle = addVehicle(scriptName, x, y, z)
        end)
        if ok and newVehicle then
            PV_docTrace("spawn method OK | method=addVehicle | script=" .. tostring(scriptName) .. " | pos=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
            return newVehicle
        end
        PV_docTrace("spawn method fail | method=addVehicle | script=" .. tostring(scriptName) .. " | err=" .. tostring(err))
    end

    if type(spawnVehicle) == "function" then
        local ok, err = pcall(function()
            newVehicle = spawnVehicle(scriptName, x, y, z)
        end)
        if ok and newVehicle then
            PV_docTrace("spawn method OK | method=spawnVehicle | script=" .. tostring(scriptName) .. " | pos=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
            return newVehicle
        end
        PV_docTrace("spawn method fail | method=spawnVehicle | script=" .. tostring(scriptName) .. " | err=" .. tostring(err))
    end

    PV_docTrace("spawn failed | no working spawn method | script=" .. tostring(scriptName) .. " | pos=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z), true)
    return nil
end

local function PV_createDocItem(playerObj, docId, snapshot, scriptName, vehicleName, convertedAt, sqlid, expiresAt, overallCondition)
    local item = nil
    pcall(function() item = instanceItem(DOC_ITEM_TYPE) end)
    if not item then
        pcall(function() item = InventoryItemFactory.CreateItem(DOC_ITEM_TYPE) end)
    end
    if not item then
        PV.Log.writeGlobal("[PV] PV_createDocItem: failed to create " .. DOC_ITEM_TYPE, "ERROR")
        return nil
    end

    local md = item:getModData()
    md.PV_DocId       = docId
    md.PV_OwnerKey    = playerObj:getSteamID() or playerObj:getUsername()
    md.PV_OwnerName   = playerObj:getUsername()
    md.PV_ScriptName  = scriptName
    md.PV_VehicleName = vehicleName
    md.PV_Snapshot    = snapshot
    md.PV_PartsCondition = snapshot and snapshot.parts or nil
    md.PV_OverallCondition = overallCondition
    md.PV_RV = snapshot and snapshot.rv or nil
    md.PV_HasRV = (snapshot and snapshot.rv and snapshot.rv.hasRV == true) or false
    md.PV_RVType = snapshot and snapshot.rv and snapshot.rv.type or nil
    md.PV_RVUniqueId = snapshot and snapshot.rv and snapshot.rv.uniqueId or nil
    md.PV_ConvertedAt = convertedAt
    md.PV_ExpiresAt   = expiresAt
    md.PV_SQLID       = sqlid

    pcall(function()
        if item.setName then item:setName(vehicleName) end
        if item.setCustomName then item:setCustomName(true) end
    end)

    return item
end

local function PV_giveDocItem(playerObj, item)
    if not playerObj or not item then return false end
    local inv = playerObj:getInventory()
    if not inv then return false end

    local added = false
    local ok, err = pcall(function()
        inv:AddItem(item)
        if sendAddItemToContainer then sendAddItemToContainer(inv, item) end
        PV_syncInventoryItem(item, playerObj)
        added = true
    end)
    if not ok then
        PV.Log.writeGlobal("[PV] PV_createAndGiveDocItem error: " .. tostring(err), "ERROR")
    end
    if not added then
        -- Fallback: drop near player
        pcall(function()
            local sq = playerObj:getCurrentSquare()
            if sq then
                sq:AddWorldInventoryItem(item, 0, 0, 0)
                if transmitCompleteItemToClients then transmitCompleteItemToClients(item) end
                added = true
            end
        end)
    end
    return added
end

-- Create and fill a VehicleConversionDoc item, then give it to the player.
-- Returns true on success.
local function PV_createAndGiveDocItem(playerObj, docId, snapshot, scriptName, vehicleName, convertedAt, sqlid, expiresAt, overallCondition)
    local item = PV_createDocItem(playerObj, docId, snapshot, scriptName, vehicleName, convertedAt, sqlid, expiresAt, overallCondition)
    if not item then return false end
    return PV_giveDocItem(playerObj, item)
end

-- ============================================================
-- COMMAND: vehicleConvertToDoc
-- Args: { vehicleId }
-- ============================================================
local function PV_handleConvertToDoc(player, args)
    local username = player:getUsername()
    PV_docTrace("convert request | user='" .. tostring(username) ..
        "' | dbReady=" .. tostring(type(PV.dbByVehicleSQLID) == "table") ..
        " | vehicleId=" .. tostring(args and args.vehicleId), true)

    -- 1. Locate the vehicle
    local vehicleId = args.vehicleId and (tonumber(args.vehicleId) or args.vehicleId) or nil
    local vehicleObj = vehicleId and getVehicleById(vehicleId) or nil
    if not vehicleObj or vehicleObj:isRemovedFromWorld() then
        PV_docTrace("convert denied | reason=vehicle_not_found | vehicleId=" .. tostring(vehicleId), true)
        PV_sendDocError(player, "IGUI_PV_Error_VehicleNotFound")
        return
    end

    -- 2. Player must be the registered owner
    local sqlid = PV.getVehicleID(vehicleObj)
    if not sqlid then
        PV_docTrace("convert denied | reason=sqlid_missing | vehicleId=" .. tostring(vehicleId), true)
        PV_sendDocError(player, "IGUI_PV_Error_VehicleNotClaimed")
        return
    end
    local entry = PV.getVehicleDBEntry(sqlid)
    if not entry then
        PV_docTrace("convert denied | reason=db_entry_missing | sqlid=" .. tostring(sqlid), true)
        PV_sendDocError(player, "IGUI_PV_Error_VehicleNotClaimed")
        return
    end
    if entry.OwnerPlayerID ~= username and not PV.isStaffPlayer(player) then
        PV_docTrace("convert denied | reason=not_owner | sqlid=" .. tostring(sqlid) .. " | owner='" .. tostring(entry.OwnerPlayerID) .. "' | user='" .. tostring(username) .. "'", true)
        PV_sendDocError(player, "IGUI_PV_Error_NotOwner")
        return
    end

    -- 3. Vehicle safety checks
    local engineOn = false
    pcall(function() engineOn = vehicleObj:isEngineRunning() end)
    if engineOn then
        PV_docTrace("convert denied | reason=engine_on | sqlid=" .. tostring(sqlid))
        PV_sendDocError(player, "IGUI_PV_ConvertToDoc_EngineOn")
        return
    end

    if PV_vehicleHasPassengers(vehicleObj) then
        PV_docTrace("convert denied | reason=has_passengers | sqlid=" .. tostring(sqlid))
        PV_sendDocError(player, "IGUI_PV_ConvertToDoc_HasPassengers")
        return
    end

    if PV_vehicleIsTowing(vehicleObj) then
        PV_docTrace("convert denied | reason=has_tow | sqlid=" .. tostring(sqlid))
        PV_sendDocError(player, "IGUI_PV_ConvertToDoc_HasTow")
        return
    end

    if PV_vehicleHasCargo(vehicleObj) then
        PV_docTrace("convert denied | reason=has_cargo | sqlid=" .. tostring(sqlid))
        PV_sendDocError(player, "IGUI_PV_ConvertToDoc_HasCargo")
        return
    end

    local sv = SandboxVars.ProtectVehicle

    -- 4. Sandbox: minimum overall vehicle condition for conversion?
    local overallCondition = PV_getVehicleOverallConditionPercent(vehicleObj)
    local minCondition = sv and tonumber(sv.MinVehicleConditionForConversion) or 0
    if minCondition > 0 then
        if minCondition < 0 then minCondition = 0 end
        if minCondition > 100 then minCondition = 100 end

        if overallCondition < minCondition then
            PV_docTrace(
                "convert denied | reason=min_condition | sqlid=" .. tostring(sqlid) ..
                " | overall=" .. tostring(math.floor(overallCondition + 0.5)) ..
                " | min=" .. tostring(minCondition))
            PV_sendDocError(player, "IGUI_PV_ConvertToDoc_MinCondition")
            return
        end
    end

    -- 5. Sandbox: require key ownership or hotwire state for conversion?
    if sv and sv.RequireKeyForConversion then
        local hasKey = PV_vehicleHasAnyKey(player, vehicleObj)
        local isHotwired = PV_vehicleIsHotwired(vehicleObj)
        local allowHotwired = (sv.AllowHotwiredForConversion ~= false)
        local canConvert = hasKey or (allowHotwired and isHotwired)
        if not canConvert then
            PV_docTrace(
                "convert denied | reason=missing_key_or_hotwired | sqlid=" .. tostring(sqlid) ..
                " | hasKey=" .. tostring(hasKey) ..
                " | hotwired=" .. tostring(isHotwired) ..
                " | allowHotwired=" .. tostring(allowHotwired))
            if allowHotwired then
                PV_sendDocError(player, "IGUI_PV_ConvertToDoc_NeedKeyOrHotwire")
            else
                PV_sendDocError(player, "IGUI_PV_ConvertToDoc_NeedKey")
            end
            return
        end
    end

    -- 6. Sandbox: require blank title in inventory?
    local blankDoc = nil
    if sv and sv.RequireConversionDocument then
        blankDoc = PV_findBlankDocInInventory(player)
        if not blankDoc then
            PV_docTrace("convert denied | reason=missing_blank_doc | user='" .. tostring(username) .. "'")
            PV_sendDocError(player, "IGUI_PV_ConvertToDoc_NeedDoc")
            return
        end
    end

    -- 7. Sandbox: max titles per player?
    local maxDocs = sv and tonumber(sv.MaxVehicleDocuments) or 0
    if maxDocs > 0 then
        local currentCount = PV.countPlayerDocuments(username)
        if currentCount >= maxDocs then
            PV_docTrace("convert denied | reason=max_docs | user='" .. tostring(username) .. "' | count=" .. tostring(currentCount) .. " | limit=" .. tostring(maxDocs))
            PV_sendDocError(player, "IGUI_PV_ConvertToDoc_MaxDocs")
            return
        end
    end

    -- 8. Capture snapshot before any destructive actions
    local snapshot    = PV_captureSnapshot(vehicleObj, player)
    local scriptName  = vehicleObj:getScript():getFullName()
    local vehicleName = PV.getVehicleDisplayNameFromModel(scriptName) or scriptName
    local convertedAt = os.time()
    local validityHours = sv and tonumber(sv.DocumentValidityHours) or 0
    local expiresAt = nil
    if validityHours and validityHours > 0 then
        expiresAt = convertedAt + (math.floor(validityHours) * 3600)
    end
    PV_docTrace("convert snapshot_ok | sqlid=" .. tostring(sqlid) .. " | vehicle='" .. tostring(vehicleName) .. "'")

    local originalX = vehicleObj:getX()
    local originalY = vehicleObj:getY()
    local originalZ = vehicleObj:getZ()
    local docId = PV.nextDocId()
    local ownerKey = player:getSteamID() or username
    local storedSnapshot = PV_copySnapshotValue(snapshot, 0, {}) or snapshot
    local pendingDocItem = PV_createDocItem(player, docId, storedSnapshot, scriptName, vehicleName, convertedAt, sqlid, expiresAt, overallCondition)
    if not pendingDocItem then
        PV_docTrace("convert denied | reason=doc_item_create_failed | user='" .. tostring(username) .. "' | sqlid=" .. tostring(sqlid), true)
        PV_sendDocError(player, "IGUI_PV_Error_ActionFailed")
        return
    end

    -- 9. Permanently remove vehicle from world before changing ownership/document state.
    local removedOk = PV_removeVehicleFromWorld(vehicleObj, vehicleId)
    if not removedOk then
        PV_docTrace("convert denied | reason=remove_failed | sqlid=" .. tostring(sqlid) .. " | runtimeId=" .. tostring(vehicleId), true)
        PV_sendDocError(player, "IGUI_PV_Error_ActionFailed")
        return
    end

    -- 11. Remove claim (without giving back a VehicleDocument for claiming).
    --    We call the underlying DB cleanup directly to avoid the ReturnDocumentOnUnclaim
    --    side-effect in ServerUnclaimVehicle.
    PV.clearPlayerVehicleIndex(entry.OwnerPlayerID, sqlid)
    PV.clearVehicleDBEntry(sqlid)
    ModData.add("PVByVehicleSQLID", PV.dbByVehicleSQLID)
    ModData.add("PVByPlayerID", PV.dbByPlayerID)
    sendServerCommand("ProtectVehicle", "removeVehicle", { sqlid = sqlid, owner = username })

    -- 12. Register title in DB
    local docEntry = {
        docId       = docId,
        ownerKey    = ownerKey,
        ownerName   = username,
        originalSQLID = sqlid,
        scriptName  = scriptName,
        vehicleName = vehicleName,
        snapshot    = storedSnapshot,
        overallCondition = overallCondition,
        hasRV       = (snapshot and snapshot.rv and snapshot.rv.hasRV == true) or false,
        rvType      = snapshot and snapshot.rv and snapshot.rv.type or nil,
        rvUniqueId  = snapshot and snapshot.rv and snapshot.rv.uniqueId or nil,
        convertedAt = convertedAt,
        expiresAt   = expiresAt,
        status      = "held",
    }
    PV.registerDocument(docEntry)

    -- 13. Create item and give to player
    local success = PV_giveDocItem(player, pendingDocItem)

    if success then
        -- Consume blank title only after the filled title was actually delivered.
        if blankDoc then
            pcall(function()
                player:getInventory():Remove(blankDoc)
                if sendRemoveItemFromContainer then sendRemoveItemFromContainer(player:getInventory(), blankDoc) end
            end)
        end

        -- Consume matching vehicle key(s) from player's inventory so keys are not kept after document conversion.
        -- Key restored on spawn is handled by PV_restoreVehicleAccessState.
        PV_consumeVehicleKeyItemsFromInventory(
            player,
            vehicleObj,
            snapshot and snapshot.access and snapshot.access.keyId or nil)

        PV_docTrace("convert success | user='" .. tostring(username) .. "' | sqlid=" .. tostring(sqlid) .. " | docId=" .. tostring(docId), true)
        PV.Log.writeGlobal(
            "vehicleConvertToDoc | user='" .. username ..
            "' | docId=" .. docId ..
            " | vehicle='" .. vehicleName ..
            "' | sqlid=" .. tostring(sqlid),
            "INFO")
        sendServerCommand(player, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_ConvertToDoc_Success", r = 0.5, g = 1.0, b = 0.5 })
        sendServerCommand(player, "ProtectVehicle", "docConvertSuccess",
            { docId = docId, vehicleName = vehicleName, docEntry = docEntry, removeRuntimeId = vehicleId })
    else
        PV_docTrace("convert failed | reason=doc_item_give_failed | user='" .. tostring(username) .. "' | sqlid=" .. tostring(sqlid) .. " | docId=" .. tostring(docId), true)
        PV.unregisterDocument(docId)
        PV_restoreClaimAfterFailedConversion(player, sqlid, entry, scriptName, snapshot, originalX, originalY, originalZ)
        PV.Log.writeGlobal(
            "vehicleConvertToDoc FAILED to give item | user='" .. username ..
            "' | docId=" .. docId .. " | scriptName=" .. scriptName,
            "ERROR")
        PV_sendDocError(player, "IGUI_PV_Error_ActionFailed")
    end
end

-- ============================================================
-- COMMAND: vehicleSpawnFromDoc
-- Args: { docId, x, y, z }
-- ============================================================
local function PV_handleSpawnFromDoc(player, args)
    local username = player:getUsername()
    local docId = args.docId
    if not docId then return end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z)
    if not x or not y then
        PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_InvalidSquare")
        return
    end
    z = z or 0

    -- 1. Verify document exists in DB and status is "held" (or "transferred")
    local docEntry = PV.getDocumentEntry(docId)
    if not docEntry then
        PV_sendDocError(player, "IGUI_PV_Error_VehicleNotFound")
        return
    end
    local isAdminExpiredOverride = PV.getAccessLevelName and PV.getAccessLevelName(player) == "admin"
    if docEntry.status == "expired" and not isAdminExpiredOverride then
        PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_Expired")
        return
    end
    if docEntry.status ~= "held"
        and docEntry.status ~= "transferred"
        and not (docEntry.status == "expired" and isAdminExpiredOverride) then
        PV_sendDocError(player, "IGUI_PV_Error_VehicleNotFound")
        return
    end

    -- 2. Player must hold the item with matching docId
    local docItem = PV_findDocItemInInventory(player, docId)
    if not docItem then
        PV_sendDocError(player, "IGUI_PV_Error_VehicleNotFound")
        return
    end
    if not PV_isItemInPlayerMainInventory(player, docItem) then
        PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_MainInventoryOnly")
        return
    end

    -- 3. Ownership check:
    --    "held"       → PV_OwnerKey must match
    --    "transferred" → SS_TransferredTo must match
    local md = docItem:getModData()
    local myKey = player:getSteamID() or username
    if docEntry.status == "held" then
        local expectedOwnerKey = docEntry.ownerKey or md.PV_OwnerKey
        if expectedOwnerKey ~= myKey then
            PV_sendDocError(player, "IGUI_PV_Error_NotOwner")
            return
        end
    elseif docEntry.status == "transferred" then
        if md.SS_TransferredTo ~= myKey then
            PV_sendDocError(player, "IGUI_PV_Error_NotOwner")
            return
        end
    end

    -- 4. Expiration check (0 = never expires)
    local expiresAt = tonumber(docEntry.expiresAt) or tonumber(md.PV_ExpiresAt)
    if expiresAt and expiresAt > 0 and os.time() >= expiresAt then
        md.PV_Expired = true
        md.PV_ExpiresAt = expiresAt
        PV_syncInventoryItem(docItem, player)
        if not isAdminExpiredOverride then
            PV.setDocumentStatus(docId, "expired")
            PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_Expired")
            return
        end
    end

    -- 5. Distance check
    local sv = SandboxVars.ProtectVehicle
    local maxDist = sv and tonumber(sv.SpawnMaxDistance) or 12
    local dx = player:getX() - x
    local dy = player:getY() - y
    if ((dx * dx) + (dy * dy)) > (maxDist * maxDist) then
        PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_TooFar")
        return
    end

    -- 5. Validate spawn square
    local square = nil
    pcall(function()
        square = getCell():getGridSquare(x, y, z)
    end)
    if not square then
        PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_InvalidSquare")
        return
    end
    if not PV_isVehicleSpawnAreaClear(x, y, z) then
        PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_InvalidSquare")
        return
    end

    -- 6. Spawn the vehicle
    local scriptName = docEntry.scriptName or md.PV_ScriptName
    local snapshot   = docEntry.snapshot or md.PV_Snapshot
    local vehicleName = docEntry.vehicleName or md.PV_VehicleName or scriptName
    if not scriptName or not snapshot then
        PV.Log.writeGlobal(
            "vehicleSpawnFromDoc denied: missing server snapshot/script | user='" .. username ..
            "' | docId=" .. tostring(docId),
            "ERROR")
        PV_sendDocError(player, "IGUI_PV_Error_VehicleNotFound")
        return
    end

    local newVehicle = PV_spawnVehicleOnSquare(scriptName, x, y, z, square, player)
    if not newVehicle then
        PV.Log.writeGlobal(
            "vehicleSpawnFromDoc FAILED to spawn vehicle | user='" .. username ..
            "' | docId=" .. docId .. " | script=" .. tostring(scriptName),
            "ERROR")
        PV_sendDocError(player, "IGUI_PV_SpawnFromDoc_InvalidSquare")
        return
    end

    -- 7. Remove generated random loot from spawned containers.
    PV_clearVehicleContainers(newVehicle)

    -- 8. Restore snapshot (appearance + mechanical state + key/hotwire status)
    PV_restoreSnapshot(newVehicle, snapshot, player)
    -- Vehicles spawned from title/document always return unlocked.
    PV_forceVehicleUnlocked(newVehicle)

    -- 8. Vehicle returns unclaimed; clear any generated SQLID before persistence/restart.
    pcall(function()
        local md = newVehicle:getModData()
        if md then md.SQLID = nil end
    end)

    if snapshot and snapshot.rv and snapshot.rv.hasRV == true then
        sendServerCommand("ProtectVehicle", "syncVehicleRVData", {
            vehicleRuntimeId = newVehicle:getId(),
            rv = snapshot.rv,
        })
    end

    -- 9. Handle document item
    if sv and sv.ConsumeDocumentOnSpawn then
        -- Remove item from inventory
        pcall(function()
            player:getInventory():Remove(docItem)
            if sendRemoveItemFromContainer then sendRemoveItemFromContainer(player:getInventory(), docItem) end
        end)
    else
        -- Clear snapshot from item so it cannot be re-used
        md.PV_Snapshot  = nil
        md.PV_Redeemed  = true
        PV_syncInventoryItem(docItem, player)
    end

    -- 10. Remove document from DB
    PV.unregisterDocument(docId)

    -- 11. Log and notify
    PV.Log.writeGlobal(
        "vehicleSpawnFromDoc | user='" .. username ..
        "' | docId=" .. docId ..
        " | vehicle='" .. vehicleName ..
        "' | pos=" .. x .. "," .. y .. "," .. z,
        "INFO")
    sendServerCommand(player, "ProtectVehicle", "haloNote",
        { text = "IGUI_PV_SpawnFromDoc_Success", r = 0.5, g = 1.0, b = 0.5 })
    sendServerCommand(player, "ProtectVehicle", "docSpawnSuccess", { docId = docId })
end

-- ============================================================
-- HOOK INTO MAIN COMMAND ROUTER
-- ============================================================
local PV_DocSystem_OnClientCommand = function(module, command, player, args)
    if module ~= "ProtectVehicle" then return end
    if not player then return end
    local isDocCommand = command == "vehicleConvertToDoc" or command == "vehicleSpawnFromDoc"
    if not isDocCommand then return end

    if command == "vehicleConvertToDoc" then
        PV_docTrace("listener receive | command=vehicleConvertToDoc | user='" .. tostring(player:getUsername()) .. "' | vehicleId=" .. tostring(args and args.vehicleId))
    elseif command == "vehicleSpawnFromDoc" then
        PV_docTrace("listener receive | command=vehicleSpawnFromDoc | user='" .. tostring(player:getUsername()) .. "' | docId=" .. tostring(args and args.docId))
    end
    args = args or {}

    if not PV.RateLimit.isAllowed(player, command) then
        PV_docTrace("listener denied | reason=rate_limited | command=" .. tostring(command) .. " | user='" .. tostring(player:getUsername()) .. "'", true)
        sendServerCommand(player, "ProtectVehicle", "haloNote",
            { text = "IGUI_PV_Error_RateLimited", r = 1, g = 0.75, b = 0.2 })
        return
    end

    if command == "vehicleConvertToDoc" then
        local ok, err = pcall(PV_handleConvertToDoc, player, args)
        if not ok then
            PV_dbg("[PV] vehicleConvertToDoc SERVER ERROR: " .. tostring(err))
            PV_sendDocError(player, "IGUI_PV_Error_ActionFailed")
        end
    elseif command == "vehicleSpawnFromDoc" then
        local ok, err = pcall(PV_handleSpawnFromDoc, player, args)
        if not ok then
            PV_dbg("[PV] vehicleSpawnFromDoc SERVER ERROR: " .. tostring(err))
            PV_sendDocError(player, "IGUI_PV_Error_ActionFailed")
        end
    end
end

Events.OnClientCommand.Add(PV_DocSystem_OnClientCommand)
