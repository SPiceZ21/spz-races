-- client/showcase.lua
-- Locks the post-race showcase car so nobody can enter it. Server tags the
-- vehicle entity with `spzShowcase`; server-side door natives are unreliable, so
-- each client re-locks it here when the tag appears (or when re-streamed).

-- The server spawns the car at a ped-height Z, so it starts above the ground.
-- Whoever owns it sets it down once the ground collision has streamed in, then
-- tells the server, which freezes it there for everyone.
local grounding = {}

local function groundShowcase(veh)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    if grounding[netId] then return end
    grounding[netId] = true

    CreateThread(function()
        local deadline = GetGameTimer() + 10000
        while DoesEntityExist(veh) and not HasCollisionLoadedAroundEntity(veh) and GetGameTimer() < deadline do
            local c = GetEntityCoords(veh)
            RequestCollisionAtCoord(c.x, c.y, c.z)
            Wait(100)
        end

        if DoesEntityExist(veh) and NetworkHasControlOfEntity(veh)
            and not Entity(veh).state.spzShowcaseGrounded then
            FreezeEntityPosition(veh, false)
            if SetVehicleOnGroundProperly(veh) then
                Wait(250)
                local c = GetEntityCoords(veh)
                TriggerServerEvent("SPZ:showcaseGrounded", netId, c.x, c.y, c.z)
            end
            -- If it failed, the safety loop below retries.
        end
        grounding[netId] = nil
    end)
end

local function lockShowcase(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    SetVehicleDoorsLocked(veh, 2)                       -- fully locked
    SetVehicleDoorsLockedForAllPlayers(veh, true)       -- no player may enter
    SetVehicleDoorsLockedForPlayer(veh, PlayerId(), true)

    -- Freezing before it is grounded is what pinned it in mid-air.
    if Entity(veh).state.spzShowcaseGrounded then
        FreezeEntityPosition(veh, true)
    elseif NetworkHasControlOfEntity(veh) then
        groundShowcase(veh)
    end
end

-- React to the tag being set on a vehicle entity (and to it being grounded,
-- so everyone freezes it straight away rather than on the next sweep).
local function onShowcaseBag(bagName, _, value)
    if not value then return end
    local netId = tonumber(tostring(bagName):match("entity:(%d+)"))
    if not netId then return end

    CreateThread(function()
        Wait(0)   -- the handler runs before the new value lands on the bag
        local deadline = GetGameTimer() + 15000
        while GetGameTimer() < deadline do
            if NetworkDoesEntityExistWithNetworkId(netId) then
                local veh = NetToVeh(netId)
                if veh and veh ~= 0 and DoesEntityExist(veh) then
                    lockShowcase(veh)
                    return
                end
            end
            Wait(250)
        end
    end)
end
AddStateBagChangeHandler("spzShowcase", nil, onShowcaseBag)
AddStateBagChangeHandler("spzShowcaseGrounded", nil, onShowcaseBag)

-- Safety net: any showcase-tagged vehicle near you stays locked (covers cars that
-- were already tagged before you joined, and re-streams).
CreateThread(function()
    while true do
        Wait(4000)
        local me = GetEntityCoords(PlayerPedId())
        for veh in EnumerateVehicles() do
            if Entity(veh).state.spzShowcase and #(me - GetEntityCoords(veh)) < 60.0 then
                lockShowcase(veh)
            end
        end
    end
end)

function EnumerateVehicles()
    return coroutine.wrap(function()
        local handle, veh = FindFirstVehicle()
        local ok = true
        repeat
            if veh and DoesEntityExist(veh) then coroutine.yield(veh) end
            ok, veh = FindNextVehicle(handle)
        until not ok
        EndFindVehicle(handle)
    end)
end
