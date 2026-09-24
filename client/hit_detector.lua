-- client/hit_detector.lua
-- Checkpoint CROSSING detection (see client/cp_cross.lua). Registers only when
-- the player passes THROUGH the gate plane, between the posts — not on entry,
-- not from the sides.

local _raceState = GlobalState.raceState or "IDLE"

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _raceState = value end
end)

-- ── Optimistic gate arming ────────────────────────────────────────────────────
-- The next gate used to arm only when the server's SPZ:nextCheckpoint came back,
-- and only after a flat 500 ms debounce on top of the round trip. At racing
-- speed that is 35+ m of blind driving: on a tight section the next gate was
-- crossed before it was armed, never registered, every later gate stayed dead,
-- and two minutes on the idle watchdog DNF'd a racer who was driving flat out.
--
-- Now the moment a crossing is reported the NEXT gate is armed locally. Hits are
-- reliable and ordered, so the server receives n then n+1 and accepts both. The
-- chain is dropped the moment the server's index disagrees (rejection, rewind,
-- rollback) or it goes unconfirmed for PENDING_MAX_MS, and tracking falls back
-- to the server's gate — never worse than before.
local PENDING_MAX_MS = 2500

-- ── Position trail ───────────────────────────────────────────────────────────
-- The last couple of seconds of positions, so a gate can be scored from the
-- path actually driven (SPZ_GateSegmentCross) when side-tracking missed it:
-- armed after the car was already through, or jumped over in a frame hitch.
-- Segments faster than TRAIL_MAX_MPS are teleports (F4 recover, respawn) and
-- never count; the trail is dropped while rewinding.
local TRAIL_MS      = 2000
local TRAIL_MAX_MPS = 150.0   -- ~540 km/h
local _trail = {}             -- { x, y, z, t }, oldest first

local function _trailPush(pos, now)
    local last = _trail[#_trail]
    if last and now - last.t < 15 then return end
    _trail[#_trail + 1] = { x = pos.x, y = pos.y, z = pos.z, t = now }
    while _trail[1] and now - _trail[1].t > TRAIL_MS do table.remove(_trail, 1) end
end

local function _realSegment(a, b)
    local dt = (b.t - a.t) / 1000
    if dt <= 0 then return false end
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) / dt <= TRAIL_MAX_MPS
end

--- Did the path since `sinceIdx` in the trail go through `cp`?
local function _trailCrossed(cp, sinceIdx)
    for i = math.max(2, sinceIdx or 2), #_trail do
        local a, b = _trail[i - 1], _trail[i]
        if _realSegment(a, b) and SPZ_GateSegmentCross(cp, a, b) then return true end
    end
    return false
end

local _pending   = {}     -- gate indices reported, oldest first, not yet confirmed
local _pendingAt = 0      -- when the oldest unconfirmed one was sent

local function _nextIdx(idx, total, trackType)
    if idx < total then return idx + 1 end
    if trackType == "circuit" then return 1 end
    return nil            -- sprint: that was the finish
end

--- Which gate to watch, given the server's current one and what we've sent.
local function _trackedIdx(serverIdx, total, trackType)
    -- Drop every pending hit the server has confirmed (it moved to the gate
    -- after it). Anything else means the server went somewhere we didn't
    -- predict: trust it and start over from its gate.
    while _pending[1] do
        if serverIdx == _pending[1] then break end                       -- not confirmed yet
        if serverIdx == _nextIdx(_pending[1], total, trackType) then
            table.remove(_pending, 1)
            _pendingAt = GetGameTimer()
        else
            _pending = {}
        end
    end
    if _pending[1] and GetGameTimer() - _pendingAt > PENDING_MAX_MS then
        _pending = {}                                                    -- rejected / lost
    end

    local last = _pending[#_pending]
    if last then return _nextIdx(last, total, trackType) end
    return serverIdx
end

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

    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:PlaySound("cpmiss")
    end

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
            local cps, serverIdx, trackType = exports["spz-races"]:GetCheckpointDebug()
            local cpIndex = (cps and #cps > 0 and serverIdx)
                and _trackedIdx(serverIdx, #cps, trackType) or nil
            local cp = cpIndex and cps[cpIndex] or nil

            if cp then
                local pos = GetEntityCoords(PlayerPedId())
                local now = GetGameTimer()
                local before = #_trail
                _trailPush(pos, now)

                local crossed, side, missed
                if cpIndex ~= _lastIndex then
                    -- Newly armed gate: did we already drive through it in the
                    -- last couple of seconds, before it was armed?
                    _lastIndex, _side = cpIndex, nil
                    crossed = _trailCrossed(cp, 2)
                end

                if not crossed then
                    crossed, side, missed = SPZ_GateCross(cp, pos, _side)
                    _side = side
                    -- Hitch: the latest step jumped clean through the gate.
                    if not crossed and #_trail > before and #_trail >= 2 then
                        crossed = _trailCrossed(cp, #_trail)
                    end
                end

                if crossed then
                    TriggerServerEvent("SPZ:checkpointHit", cpIndex)
                    if not _pending[1] then _pendingAt = GetGameTimer() end
                    _pending[#_pending + 1] = cpIndex
                    -- No debounce: the watched gate has already moved on, so this
                    -- crossing can't be reported twice.
                    Citizen.Wait(0)
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
            _pending = {}
            _trail = {}          -- a rewind scrubs back through gates: never count that
            Citizen.Wait(500)
        end
    end
end)
