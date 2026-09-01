-- client/main.lua

-- No-collision is global and always on — see spz-core/client/ghost.lua.

-- ── Freeze / unfreeze on grid ─────────────────────────────────────────────────
RegisterNetEvent("SPZ:freezeRacer", function(freeze)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)

    if (not DoesEntityExist(veh) or veh == 0) and freeze then
        local lastVeh = GetVehiclePedIsIn(ped, true)
        if DoesEntityExist(lastVeh) then
            local seatPed = GetPedInVehicleSeat(lastVeh, -1)
            if seatPed == 0 or seatPed == ped then
                veh = lastVeh
            end
        end
    end

    FreezeEntityPosition(ped, freeze)
    SetEntityInvincible(ped, freeze)

    if DoesEntityExist(veh) and veh ~= 0 then
        FreezeEntityPosition(veh, freeze)
        SetEntityInvincible(veh, freeze)
        SetVehicleTyresCanBurst(veh, not freeze)
        if freeze then
            -- Kill any carried momentum while held on the grid
            SetEntityVelocity(veh, 0.0, 0.0, 0.0)
            SetVehicleForwardSpeed(veh, 0.0)
        else
            -- Release the staging handbrake at GO
            SetVehicleHandbrake(veh, false)
        end
    end
end)

-- ── Warmup ──────────────────────────────────────────────────────────────────
-- HUD lives in spz-raceUI (warmup tile panel); nui_bridge.lua forwards the
-- SPZ:warmupPhase / SPZ:warmupEnd events there.

-- Re-teleport to grid after warmup ends
RegisterNetEvent("SPZ:tpToGrid", function(data)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)

    -- If player is a free ped (stepped out during warmup), warp back into vehicle
    if not DoesEntityExist(veh) or veh == 0 then
        local lastVeh = GetVehiclePedIsIn(ped, true)
        if DoesEntityExist(lastVeh) then
            local driverSeat = GetPedInVehicleSeat(lastVeh, -1)
            if driverSeat == 0 or driverSeat == ped then
                TaskWarpPedIntoVehicle(ped, lastVeh, -1)
                veh = lastVeh
            end
        end
    end

    local c = data.coords
    local h = data.heading or 0.0

    -- Pre-request world collision at grid start point so vehicle doesn't clip/fall
    RequestCollisionAtCoord(c.x, c.y, c.z)

    if DoesEntityExist(veh) and veh ~= 0 then
        -- Unfreeze to move it, reposition, then kill all momentum and re-freeze
        -- so nobody carries warmup speed onto the grid.
        --
        -- clearArea is FALSE, and that is the whole difference between a
        -- single-point start working and the grid firing cars across the map.
        -- The final argument to SetEntityCoords asks the engine to CLEAR the
        -- destination — it shoves whatever is already standing there out of the
        -- way. With every car re-staged onto the same coordinate, each arrival
        -- was booting the cars that arrived before it, one after another, and no
        -- collision flag touches that path because it is not a collision: it is
        -- the engine doing exactly what it was asked.
        --
        -- With it off, cars simply land stacked, stay frozen until the lights,
        -- and drive through each other on GO because they are ghosted.
        FreezeEntityPosition(veh, false)
        SetEntityCoords(veh, c.x, c.y, c.z, false, false, false, false)
        SetEntityHeading(veh, h)
        SetVehicleOnGroundProperly(veh)
        SetEntityVelocity(veh, 0.0, 0.0, 0.0)
        SetEntityRotation(veh, 0.0, 0.0, h, 2, true)
        SetVehicleForwardSpeed(veh, 0.0)
        SetVehicleHandbrake(veh, true)
        FreezeEntityPosition(veh, true)
    else
        SetEntityCoords(ped, c.x, c.y, c.z, false, false, false, false)
        SetEntityHeading(ped, h)
        FreezeEntityPosition(ped, true)
    end
end)

-- ── Pre-spawn grid placement ──────────────────────────────────────────────────
-- Moves the ped to its grid slot BEFORE the race vehicle is created, so the
-- spawning client is in network scope of the new vehicle and can resolve its
-- netId. Deliberately does NOT freeze or touch a vehicle — SPZ:tpToGrid is the
-- staging teleport; this one only gets the player to the right part of the map.
--
-- The server used to call SetEntityCoords on the player ped directly. Entity
-- position for a player-owned ped is authoritative on the OWNING client; the
-- server-side call is advisory and is silently dropped whenever the client is
-- mid-stream, which is exactly the case this teleport exists to fix.
RegisterNetEvent("SPZ:tpToGridPoint", function(coords)
    if not coords then return end
    local ped = PlayerPedId()

    -- clearArea off here too: the warmup slots are separated, but the flag also
    -- shoves anything else standing near the point, and a player arriving on
    -- their own slot has no business pushing the neighbour who got there first.
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    SetEntityCoords(ped, coords.x, coords.y, coords.z + 1.0, false, false, false, false)

    -- PIN the ped on its slot until its car exists.
    --
    -- The server creates the grid vehicle at these exact coordinates a moment
    -- after this runs, and the engine's interpenetration resolver ejects
    -- whatever is already standing there. Ghosting does not stop that: it
    -- suppresses contact response between two entities, while this is the
    -- placement resolver, which runs on creation regardless of any collision
    -- exclusion. An unfrozen ped standing on its own grid slot is launched by
    -- its own car appearing around it.
    --
    -- Freezing removes the ped from that resolution entirely. It is released
    -- the moment the ped is in a vehicle (the spawn warped them in, so the
    -- danger is over), and unconditionally on timeout so a failed spawn can
    -- never leave someone welded to the tarmac.
    FreezeEntityPosition(ped, true)

    local deadline = GetGameTimer() + 3000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        Citizen.Wait(50)
    end

    -- Released as soon as the car EXISTS, not once we are sitting in it. The
    -- ejection risk ends the moment creation has resolved, and holding the
    -- freeze until the warp would gamble the whole race on
    -- TaskWarpPedIntoVehicle working on a frozen ped — if it did not, the
    -- player would sit welded to the grid until the timeout while the race
    -- started without them.
    Citizen.CreateThread(function()
        local hardStop = GetGameTimer() + 8000
        while GetGameTimer() < hardStop do
            local p = PlayerPedId()
            if GetVehiclePedIsIn(p, false) ~= 0 then break end

            local pos = GetEntityCoords(p)
            local veh = GetClosestVehicle(pos.x, pos.y, pos.z, 5.0, 0, 71)
            if veh ~= 0 and DoesEntityExist(veh) then break end

            Citizen.Wait(100)
        end
        FreezeEntityPosition(PlayerPedId(), false)
    end)
end)

-- ── Staging ───────────────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:stagingPhase", function(data)
    if Config and Config.Debug then
        print(string.format("[Race] Staging: %ds remaining (track: %s)",
            data.remaining, tostring(data.track)))
    end
end)

RegisterNetEvent("SPZ:stagingEnd", function()
    if Config and Config.Debug then print("[Race] Staging complete — countdown incoming") end
end)

RegisterNetEvent("SPZ:countdown", function(data)
    if Config and Config.Debug then print("[Race] Countdown: " .. data.seconds) end
end)

RegisterNetEvent("SPZ:go", function()
    if Config and Config.Debug then print("[Race] GO!") end
end)

-- ── Resync loop ───────────────────────────────────────────────────────────────
local _clientRaceState = GlobalState.raceState or "IDLE"

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if not value then return end
    _clientRaceState = value
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(12000)
        if _clientRaceState == "LIVE" then
            TriggerServerEvent("SPZ:requestResync")
        end
    end
end)

-- ── Safe-zone teleport ────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:tpToSafeZone", function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local sz  = (Config and Config.SafeZone)        or vector3(0.0, 0.0, 0.0)
    local sh  = (Config and Config.SafeZoneHeading) or 0.0

    -- clearArea off: the safe zone is a SINGLE point that every racer is sent
    -- to at the same moment when a race ends, so this is the same convergence
    -- as the start line. With it on, each arriving car asks the engine to clear
    -- the destination and boots whoever landed first — the whole field
    -- scattering across the paddock a second after the results appear.
    if DoesEntityExist(veh) then
        SetEntityCoords(veh, sz.x, sz.y, sz.z, false, false, false, false)
        SetEntityHeading(veh, sh)
    else
        SetEntityCoords(ped, sz.x, sz.y, sz.z, false, false, false, false)
        SetEntityHeading(ped, sh)
    end

    -- Any teleport-out means the race is over for us — clear all race UI.
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:HideWarmup()
        exports["spz-raceUI"]:SetRaceOverlayVisible(false)
    end
end)
