-- client/incidents.lua
-- Detects hard world impacts during a live race and reports them to the server,
-- which accumulates them into the racer's incident count. spz-progression turns
-- that count into an SR penalty and decides the clean-race bonus.
--
-- Racers are ghosted from each other (see client/main.lua), so a tracked
-- incident is a collision with the world — walls, barriers, props — not another
-- car. Detection watches two signals together to avoid false positives:
--   1. a sudden single-frame speed drop, AND
--   2. a body-health drop.
-- A curb bounce moves speed but not health; coasting to a stop drops speed
-- smoothly over many frames. A real crash spikes both at once.

local IC = nil   -- Config.Incidents, resolved on GO

local liveSince   = 0     -- GetGameTimer() at GO
local lastSpeed   = 0.0   -- km/h last frame
local lastBody    = 1000.0
local lastHitAt   = 0
local reported    = 0
local active      = false

local function reset()
    liveSince = GetGameTimer()
    lastSpeed = 0.0
    lastBody  = 1000.0
    lastHitAt = 0
    reported  = 0
end

RegisterNetEvent("SPZ:go", function()
    IC = Config and Config.Incidents
    if not IC or not IC.enabled then return end
    reset()
    active = true
end)

local function stop()
    active = false
end

RegisterNetEvent("SPZ:raceFinished", stop)
RegisterNetEvent("SPZ:raceEnd", stop)
RegisterNetEvent("SPZ:tpToSafeZone", stop)
RegisterNetEvent("SPZ:playerDNF", function(data)
    -- Only stop for our own DNF
    if data and data.source == GetPlayerServerId(PlayerId()) then stop() end
end)

CreateThread(function()
    while true do
        if active and IC then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local speed = GetEntitySpeed(veh) * 3.6            -- m/s → km/h
                local body  = GetVehicleBodyHealth(veh)
                local now   = GetGameTimer()

                local speedDrop  = lastSpeed - speed
                local bodyDrop   = lastBody - body
                local pastBuffer = (now - liveSince) >= IC.startBufferMs
                local offCooldown = (now - lastHitAt) >= IC.cooldownMs

                if pastBuffer and offCooldown
                   and lastSpeed >= IC.minImpactSpeed
                   and speedDrop >= IC.minSpeedDropKmh
                   and bodyDrop  >= IC.minBodyDamage
                   and reported  <  IC.maxPerRace then
                    lastHitAt = now
                    reported  = reported + 1
                    TriggerServerEvent("SPZ:reportIncident", {
                        speed = math.floor(lastSpeed),
                        drop  = math.floor(speedDrop),
                    })
                end

                lastSpeed = speed
                lastBody  = body
            else
                -- out of the seat: don't let re-entry register a phantom hit
                lastSpeed = 0.0
                lastBody  = 1000.0
            end

            Wait(0)
        else
            Wait(500)
        end
    end
end)
