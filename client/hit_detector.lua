-- client/hit_detector.lua
-- Checkpoint CROSSING detection (see client/cp_cross.lua). Registers only when
-- the player passes THROUGH the gate plane, between the posts — not on entry,
-- not from the sides.

local _raceState = GlobalState.raceState or "IDLE"

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _raceState = value end
end)

local HIT_DEBOUNCE_MS = 500

local _lastIndex = nil    -- which CP we're tracking the crossing side for
local _side      = nil    -- last side of the gate plane the player was on

Citizen.CreateThread(function()
    while true do
        if _raceState == "LIVE" then
            local cp, cpIndex = exports["spz-races"]:GetCurrentCP()

            if cp then
                -- Reset the crossing state whenever the active CP changes.
                if cpIndex ~= _lastIndex then
                    _lastIndex, _side = cpIndex, nil
                end

                local pos = GetEntityCoords(PlayerPedId())
                local crossed, side = SPZ_GateCross(cp, pos, _side)
                _side = side

                if crossed then
                    TriggerServerEvent("SPZ:checkpointHit", cpIndex)
                    Citizen.Wait(HIT_DEBOUNCE_MS)
                else
                    -- Poll fast when close so a fast car can't tunnel the plane.
                    local dx, dy = pos.x - cp.coords.x, pos.y - cp.coords.y
                    local dist   = math.sqrt(dx*dx + dy*dy)
                    Citizen.Wait(dist > 80 and 100 or dist > 30 and 20 or 0)
                end
            else
                Citizen.Wait(100)
            end
        else
            _lastIndex, _side = nil, nil
            Citizen.Wait(500)
        end
    end
end)
