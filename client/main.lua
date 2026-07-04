-- client/main.lua

-- ── No-collision ──────────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:applyNoCollision", function(targetServerId)
    local myPed    = PlayerPedId()
    local targetId = GetPlayerFromServerId(targetServerId)
    if targetId == -1 then return end

    local targetPed = GetPlayerPed(targetId)
    if not DoesEntityExist(targetPed) then return end

    SetEntityNoCollisionEntity(myPed, targetPed, false)
    SetEntityNoCollisionEntity(targetPed, myPed, false)

    local myVeh     = GetVehiclePedIsIn(myPed, false)
    local targetVeh = GetVehiclePedIsIn(targetPed, false)
    if DoesEntityExist(myVeh) and DoesEntityExist(targetVeh) then
        SetEntityNoCollisionEntity(myVeh, targetVeh, false)
        SetEntityNoCollisionEntity(targetVeh, myVeh, false)
    end
end)

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
    end
end)

-- ── Warmup (60s freeroam + customization window) ───────────────────────────────
-- Draws an on-screen HUD so players know this is the practice/setup window and
-- NOT freeroam — the race starts when the timer hits zero.
local Warmup = { active = false, remaining = 0, total = 0, track = "", class = "", gridPos = 0 }

local function _drawWarmupText(text, x, y, scale, r, g, b, a, center)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    SetTextCentre(center or false)
    SetTextDropShadow()
    SetTextEntry("STRING")
    AddTextComponentString(text)
    DrawText(x, y)
end

RegisterNetEvent("SPZ:warmupPhase", function(data)
    Warmup.active    = true
    Warmup.remaining = data.remaining or 0
    Warmup.total     = data.total or 0
    Warmup.track     = data.track or ""
    Warmup.class     = data.class or ""
    Warmup.gridPos   = data.gridPos or 0
end)

RegisterNetEvent("SPZ:warmupEnd", function()
    Warmup.active = false
end)

-- Clear the HUD if the race state moves on unexpectedly
AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value and value ~= "WARMUP" then Warmup.active = false end
end)

Citizen.CreateThread(function()
    while true do
        if Warmup.active then
            -- Title
            _drawWarmupText("~y~WARM-UP", 0.5, 0.045, 0.9, 255, 220, 0, 255, true)
            -- Timer
            _drawWarmupText(("Race starts in ~y~%ds"):format(Warmup.remaining), 0.5, 0.095, 0.55, 255, 255, 255, 255, true)
            -- Hint
            _drawWarmupText("~g~Practice the track~s~   •   ~b~/savecustom~s~ to tune your car", 0.5, 0.130, 0.42, 220, 220, 220, 220, true)
            -- Context (track / class / grid)
            _drawWarmupText(("%s   |   %s   |   Grid #%d"):format(
                tostring(Warmup.track), tostring(Warmup.class), Warmup.gridPos or 0),
                0.5, 0.160, 0.38, 160, 160, 160, 200, true)
            Citizen.Wait(0)
        else
            Citizen.Wait(300)
        end
    end
end)

-- Re-teleport to grid after warmup ends
RegisterNetEvent("SPZ:tpToGrid", function(data)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local c   = data.coords
    local h   = data.heading or 0.0

    if DoesEntityExist(veh) then
        SetEntityCoords(veh, c.x, c.y, c.z, false, false, false, true)
        SetEntityHeading(veh, h)
    else
        SetEntityCoords(ped, c.x, c.y, c.z, false, false, false, true)
        SetEntityHeading(ped, h)
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
end)
