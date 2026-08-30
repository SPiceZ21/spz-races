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
        FreezeEntityPosition(veh, false)
        SetEntityCoords(veh, c.x, c.y, c.z, false, false, false, true)
        SetEntityHeading(veh, h)
        SetVehicleOnGroundProperly(veh)
        SetEntityVelocity(veh, 0.0, 0.0, 0.0)
        SetEntityRotation(veh, 0.0, 0.0, h, 2, true)
        SetVehicleForwardSpeed(veh, 0.0)
        SetVehicleHandbrake(veh, true)
        FreezeEntityPosition(veh, true)
    else
        SetEntityCoords(ped, c.x, c.y, c.z, false, false, false, true)
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

    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    SetEntityCoords(ped, coords.x, coords.y, coords.z + 1.0, false, false, false, true)

    -- Let the world stream in around the grid before the vehicle is created.
    local deadline = GetGameTimer() + 3000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        Citizen.Wait(50)
    end
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

    if DoesEntityExist(veh) then
        SetEntityCoords(veh, sz.x, sz.y, sz.z, false, false, false, true)
        SetEntityHeading(veh, sh)
    else
        SetEntityCoords(ped, sz.x, sz.y, sz.z, false, false, false, true)
        SetEntityHeading(ped, sh)
    end

    -- Any teleport-out means the race is over for us — clear all race UI.
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:HideWarmup()
        exports["spz-raceUI"]:SetRaceOverlayVisible(false)
    end
end)
