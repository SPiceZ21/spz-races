-- client/hit_detector.lua

-- 11.3 Hit Detection (Client)
-- High-precision thread running during LIVE state for millisecond-perfect crossing detection.

-- Cache race state locally to avoid a per-frame export call across the resource bridge.
local _raceState = "IDLE"
AddEventHandler("spz_race:state_updated", function(newState)
    _raceState = newState
end)

local CP_HEIGHT_THRESHOLD = 8.0  -- metres above/below CP centre still counts as a hit

Citizen.CreateThread(function()
    while true do
        if _raceState == "LIVE" then
            local cp, cpIndex = exports["spz-races"]:GetCurrentCP()

            if cp then
                local playerPed = PlayerPedId()
                local playerPos = GetEntityCoords(playerPed)
                local cpPos     = vector3(cp.coords.x, cp.coords.y, cp.coords.z)
                local radius    = cp.radius or 5.0

                -- Horizontal squared-distance (avoids sqrt in the hot path)
                local dx   = playerPos.x - cpPos.x
                local dy   = playerPos.y - cpPos.y
                local dist2 = dx * dx + dy * dy

                -- Cylindrical hit: horizontal radius AND vertical tolerance
                if dist2 < (radius * radius) and math.abs(playerPos.z - cpPos.z) < CP_HEIGHT_THRESHOLD then
                    TriggerServerEvent("SPZ:checkpointHit", cpIndex)
                    -- Brief wait prevents multi-trigger before server advances the index
                    Citizen.Wait(500)
                else
                    -- Adaptive polling: poll faster when close, slower when far away
                    local dist = math.sqrt(dist2)
                    local waitMs = dist > 80 and 100 or dist > 30 and 50 or 0
                    Citizen.Wait(waitMs)
                end
            else
                Citizen.Wait(100)
            end
        else
            Citizen.Wait(500)
        end
    end
end)
