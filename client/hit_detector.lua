-- client/hit_detector.lua
-- Gate-width checkpoint detection.
-- Each checkpoint in tracks.lua carries a center coords, a radius, and optional
-- left/right lane-marker vectors.  When left+right exist we derive the gate
-- half-width at runtime (more accurate than the static radius for oddly-shaped
-- gates); otherwise we fall back to the stored radius.

local _raceState = "IDLE"
AddEventHandler("spz_race:state_updated", function(s) _raceState = s end)

-- Vertical tolerance: how many metres above/below the CP centre still counts as a hit.
local CP_Z_THRESHOLD = 8.0

-- How long (ms) to ignore further hits after one is registered (anti-double-trigger).
local HIT_DEBOUNCE_MS = 500

-- ── Gate width helper ───────────────────────────────────────────────────────
-- Returns the squared detection radius for a given checkpoint.
-- Prefer the distance from center → left marker so the gate always matches the
-- physical props placed on those exact coords.
local function _gateRadius2(cp)
    if cp.left then
        local dx = cp.coords.x - cp.left.x
        local dy = cp.coords.y - cp.left.y
        local dz = cp.coords.z - cp.left.z
        local r  = math.sqrt(dx*dx + dy*dy + dz*dz)
        return r * r
    end
    -- Fallback: use the stored radius field (pre-computed from left/right during track conversion)
    local r = cp.radius or 5.0
    return r * r
end

-- ── Detection thread ────────────────────────────────────────────────────────
Citizen.CreateThread(function()
    while true do
        if _raceState == "LIVE" then
            local cp, cpIndex = exports["spz-races"]:GetCurrentCP()

            if cp then
                local playerPos = GetEntityCoords(PlayerPedId())
                local dx = playerPos.x - cp.coords.x
                local dy = playerPos.y - cp.coords.y
                local dist2 = dx * dx + dy * dy

                local gate2 = _gateRadius2(cp)

                if dist2 < gate2 and math.abs(playerPos.z - cp.coords.z) < CP_Z_THRESHOLD then
                    TriggerServerEvent("SPZ:checkpointHit", cpIndex)
                    Citizen.Wait(HIT_DEBOUNCE_MS)
                else
                    -- Adaptive polling: close = frame-tight, far = sleep more
                    local dist  = math.sqrt(dist2)
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
