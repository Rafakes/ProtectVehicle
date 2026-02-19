--[[
    PV_TrunkParts.lua
    Trunk/container part name mapping for mod vehicle compatibility.
    Reads SandboxVars.ProtectVehicle.TrunkParts (semicolon-separated).
    B42.14.0 only.
--]]

PV = PV or {}

-- Cache parsed trunk parts list for performance
PV._trunkPartsCache = nil
PV._trunkPartsCacheStr = nil

local function rebuildCache()
    local cfg = (SandboxVars.ProtectVehicle and SandboxVars.ProtectVehicle.TrunkParts)
                or "TrunkDoor;DoorRear;TrailerTrunk;TruckBed;TruckBedOpen"
    if cfg == PV._trunkPartsCacheStr then return end
    PV._trunkPartsCacheStr = cfg
    PV._trunkPartsCache = {}
    for s in string.gmatch(cfg, "([^;]+)") do
        local trimmed = string.lower(s:match("^%s*(.-)%s*$"))
        if #trimmed > 0 then
            PV._trunkPartsCache[trimmed] = true
        end
    end
end

-- Returns true if partId matches a configured trunk/container part name
function PV.isTrunkPart(partId)
    if type(partId) ~= "string" or #partId == 0 then return false end
    rebuildCache()
    return PV._trunkPartsCache[string.lower(partId)] == true
end

-- Returns true if a VehiclePart object is a trunk/container part
function PV.isVehiclePartTrunk(part)
    if not part then return false end
    local id = part:getId()
    if PV.isTrunkPart(id) then return true end
    -- Also check container type as fallback
    local container = part:getItemContainer()
    if container then
        local ctype = container:getType()
        if ctype and PV.isTrunkPart(ctype) then return true end
    end
    return false
end

-- Returns all trunk-type parts for a vehicle
function PV.getVehicleTrunkParts(vehicleObj)
    if not vehicleObj then return {} end
    local result = {}
    local parts = vehicleObj:getPartIterator()
    if parts then
        while parts:hasNext() do
            local part = parts:next()
            if PV.isVehiclePartTrunk(part) then
                table.insert(result, part)
            end
        end
    end
    return result
end
