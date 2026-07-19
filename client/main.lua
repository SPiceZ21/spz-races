-- client/main.lua

-- No-collision is global and always on — see spz-core/client/ghost.lua.

-- ── Freeze / unfreeze on grid ─────────────────────────────────────────────────
RegisterNetEvent("SPZ:freezeRacer", function(freeze)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)

    FreezeEntityPosition(ped, freeze)
    SetEntityInvincible(ped, freeze)

    if DoesEntityExist(veh) then
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
    local c   = data.coords
    local h   = data.heading or 0.0

    if DoesEntityExist(veh) then
        -- Unfreeze to move it, reposition, then kill all momentum and re-freeze
        -- so nobody carries warmup speed onto the grid.
        FreezeEntityPosition(veh, false)
        SetEntityCoords(veh, c.x, c.y, c.z, false, false, false, true)
        SetEntityHeading(veh, h)
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
