-- client/showcase.lua
-- Locks the post-race showcase car so nobody can enter it. Server tags the
-- vehicle entity with `spzShowcase`; server-side door natives are unreliable, so
-- each client re-locks it here when the tag appears (or when re-streamed).

local function lockShowcase(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    SetVehicleDoorsLocked(veh, 2)                       -- fully locked
    SetVehicleDoorsLockedForAllPlayers(veh, true)       -- no player may enter
    SetVehicleDoorsLockedForPlayer(veh, PlayerId(), true)
    FreezeEntityPosition(veh, true)
end

-- React to the tag being set on a vehicle entity.
AddStateBagChangeHandler("spzShowcase", nil, function(bagName, _, value)
    if not value then return end
    local netId = tonumber(tostring(bagName):match("entity:(%d+)"))
    if not netId then return end

    CreateThread(function()
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
end)

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
