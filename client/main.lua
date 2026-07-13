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

-- ── Race ghosting (persistent no-collision) ───────────────────────────────────
-- The server's pairwise one-shot breaks whenever an entity re-streams into
-- scope. Re-assert no-collision against every other player each frame while
-- the race is active — cheap for a race lobby, bulletproof.
local GHOST_STATES = { WARMUP = true, COUNTDOWN = true, LIVE = true }

Citizen.CreateThread(function()
    while true do
        if LocalPlayer.state.inRace and GHOST_STATES[_clientRaceState] then
            local myPed = PlayerPedId()
            local myVeh = GetVehiclePedIsIn(myPed, false)

            for _, plr in ipairs(GetActivePlayers()) do
                if plr ~= PlayerId() then
                    local tPed = GetPlayerPed(plr)
                    if tPed ~= 0 and DoesEntityExist(tPed) then
                        local tVeh = GetVehiclePedIsIn(tPed, false)

                        SetEntityNoCollisionEntity(myPed, tPed, false)
                        SetEntityNoCollisionEntity(tPed, myPed, false)

                        if myVeh ~= 0 then
                            SetEntityNoCollisionEntity(myVeh, tPed, false)
                            if tVeh ~= 0 then
                                SetEntityNoCollisionEntity(myVeh, tVeh, false)
                                SetEntityNoCollisionEntity(tVeh, myVeh, false)
                            end
                        end
                        if tVeh ~= 0 then
                            SetEntityNoCollisionEntity(tVeh, myPed, false)
                            SetEntityNoCollisionEntity(myPed, tVeh, false)
                        end
                    end
                end
            end
            Citizen.Wait(0)   -- must re-assert every frame
        else
            Citizen.Wait(500)
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
