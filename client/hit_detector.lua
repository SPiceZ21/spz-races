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

-- ── Missed-checkpoint prompt ──────────────────────────────────────────────────
-- SPZ_GateCross reports a MISS when the player crosses the gate plane outside
-- the posts — they went past the checkpoint without going through it. The
-- server will not advance them, so without a prompt the first sign of trouble
-- is the next gate never arming and, eventually, the idle-kick DNF.
--
-- Both offered recoveries are real and already implemented: rewind scrubs the
-- car back along its own path, respawn teleports to the last gate crossed.
-- Keys are read from config so this prompt, the key registration and the HUD
-- key strip can never disagree.
local MISS_COOLDOWN_MS = 8000
local _lastMissAt = 0

local function _promptMissedCheckpoint()
    local now = GetGameTimer()
    if now - _lastMissAt < MISS_COOLDOWN_MS then return end
    _lastMissAt = now

    local rewindKey  = (Config and Config.Rewind and Config.Rewind.enabled ~= false)
                       and (Config.Rewind.key or "B") or nil
    local respawnKey = (Config and Config.RecoverKey) or "F4"

    -- Rewind can be disabled server-side; do not offer a key that does nothing.
    local msg = rewindKey
        and ("Press %s to rewind or press %s to teleport to last checkpoint")
            :format(rewindKey, respawnKey)
        or  ("Press %s to teleport to last checkpoint"):format(respawnKey)

    lib.notify({
        title       = "Checkpoint missed",
        description = msg,
        type        = "error",
        duration    = 6000,
        position    = "center-left",
    })
end

Citizen.CreateThread(function()
    while true do
        -- Rewinding scrubs the car backward through world space — that is not
        -- a real gate crossing, so hit detection sleeps until it ends.
        if _raceState == "LIVE" and not exports["spz-races"]:IsRewinding() then
            local cp, cpIndex = exports["spz-races"]:GetCurrentCP()

            if cp then
                -- Reset the crossing state whenever the active CP changes.
                if cpIndex ~= _lastIndex then
                    _lastIndex, _side = cpIndex, nil
                end

                local pos = GetEntityCoords(PlayerPedId())
                local crossed, side, missed = SPZ_GateCross(cp, pos, _side)
                _side = side

                if crossed then
                    TriggerServerEvent("SPZ:checkpointHit", cpIndex)
                    Citizen.Wait(HIT_DEBOUNCE_MS)
                else
                    if missed then _promptMissedCheckpoint() end
                    -- Poll fast when close so a fast car can't tunnel the plane.
                    -- The 40 m band is set to sit OUTSIDE cp_cross's tracking
                    -- corridor (50 m deep, plus lateral slack): the whole
                    -- corridor has to be sampled at 20 ms or better, because a
                    -- 100 ms poll covers five metres at racing speed and a car
                    -- could enter the corridor and cross the plane inside a
                    -- single sample. Widen one without the other and gates start
                    -- being missed at speed.
                    local dx, dy = pos.x - cp.coords.x, pos.y - cp.coords.y
                    local dist   = math.sqrt(dx*dx + dy*dy)
                    Citizen.Wait(dist > 120 and 100 or dist > 40 and 20 or 0)
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
