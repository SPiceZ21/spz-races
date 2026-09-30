-- server/copchase.lua
-- Server-side spawning for the NPC cop chase (client/copchase.lua).
--
-- The cops used to be LOCAL entities, seen only by the racer they chased. They
-- are now created HERE as networked entities in the racer's race bucket, so
-- every racer sees and collides with the same cruisers.
--
-- The server only creates and deletes. It cannot drive them: FiveM runs AI on
-- whichever client owns an entity, and a fresh entity goes to the nearest
-- client -- the racer who asked for it, since it is spawned right behind them.
-- That client runs the existing pursuit AI on it exactly as before.

local CC = Config.CopChase or {}
local MAX_PER_RACER = CC.MaxServerUnits or 14   -- cars + chopper + roadblock

local Owned = {}   -- [src] = { [netId] = entity }

local function track(src, ent)
    Owned[src] = Owned[src] or {}
    Owned[src][NetworkGetNetworkIdFromEntity(ent)] = ent
end

local function count(src)
    local n = 0
    for _ in pairs(Owned[src] or {}) do n = n + 1 end
    return n
end

local function deleteAll(src)
    for _, ent in pairs(Owned[src] or {}) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end
    Owned[src] = nil
end

local function waitExists(ent)
    local dl = GetGameTimer() + 3000
    while ent ~= 0 and not DoesEntityExist(ent) and GetGameTimer() < dl do Wait(0) end
    return ent ~= 0 and DoesEntityExist(ent)
end

--- Spawn one pursuit vehicle with its driver.
--- d = { veh = hash, ped = hash, x, y, z, h, heli = bool }
--- Returns vehNet, pedNet (or nil, reason).
lib.callback.register("spz-races:copSpawn", function(src, d)
    if GlobalState.raceCopChase ~= true then return nil, "cop chase is off" end
    if not Player(src).state.inRace then return nil, "not in a race" end
    if type(d) ~= "table" or not d.veh or not d.ped then return nil, "bad request" end
    -- Two entities per unit (car + driver).
    if count(src) + 2 > MAX_PER_RACER * 2 then return nil, "unit cap" end

    local bucket = GetPlayerRoutingBucket(src)
    local veh = CreateVehicleServerSetter(d.veh, d.heli and "heli" or "automobile",
        d.x + 0.0, d.y + 0.0, d.z + 0.0, (d.h or 0.0) + 0.0)
    if not waitExists(veh) then return nil, "vehicle failed" end
    SetEntityRoutingBucket(veh, bucket)

    local ped = CreatePedInsideVehicle(veh, 26, d.ped, -1, true, false)
    if not waitExists(ped) then
        DeleteEntity(veh)
        return nil, "driver failed"
    end
    SetEntityRoutingBucket(ped, bucket)

    track(src, veh)
    track(src, ped)
    return NetworkGetNetworkIdFromEntity(veh), NetworkGetNetworkIdFromEntity(ped)
end)

--- Delete units this racer asked for (only their own).
RegisterNetEvent("spz-races:copDelete", function(netIds)
    local src = source
    local mine = Owned[src]
    if not mine or type(netIds) ~= "table" then return end
    for _, id in ipairs(netIds) do
        local ent = mine[id]
        if ent then
            if DoesEntityExist(ent) then DeleteEntity(ent) end
            mine[id] = nil
        end
    end
end)

--- Racer's pursuit is over (escaped / race ended on their side).
RegisterNetEvent("spz-races:copClear", function()
    deleteAll(source)
end)

AddEventHandler("playerDropped", function()
    deleteAll(source)
end)

-- Race over for everyone: sweep every pack.
AddStateBagChangeHandler("raceState", "global", function(_, _, v)
    if v == "IDLE" or v == "CLEANUP" then
        for src in pairs(Owned) do deleteAll(src) end
    end
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for src in pairs(Owned) do deleteAll(src) end
end)
