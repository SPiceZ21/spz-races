-- client/hit_detector.lua
-- Gate-width checkpoint detection.

local _raceState = GlobalState.raceState or "IDLE"

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _raceState = value end
end)

local CP_Z_THRESHOLD = 8.0
local HIT_DEBOUNCE_MS = 500

local function _gateRadius2(cp)
    if cp.left then
        local dx = cp.coords.x - cp.left.x
        local dy = cp.coords.y - cp.left.y
        local dz = cp.coords.z - cp.left.z
        local r  = math.sqrt(dx*dx + dy*dy + dz*dz)
        return r * r
    end
    local r = cp.radius or 5.0
    return r * r
end

Citizen.CreateThread(function()
    while true do
        if _raceState == "LIVE" then
            local cp, cpIndex = exports["spz-races"]:GetCurrentCP()

            if cp then
                local playerPos = GetEntityCoords(PlayerPedId())
                local dx    = playerPos.x - cp.coords.x
                local dy    = playerPos.y - cp.coords.y
                local dist2 = dx * dx + dy * dy
                local gate2 = _gateRadius2(cp)

                if dist2 < gate2 and math.abs(playerPos.z - cp.coords.z) < CP_Z_THRESHOLD then
                    TriggerServerEvent("SPZ:checkpointHit", cpIndex)
                    Citizen.Wait(HIT_DEBOUNCE_MS)
                else
                    local dist   = math.sqrt(dist2)
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
