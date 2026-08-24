-- client/rewind.lua
-- Forza Horizon-style time rewind. Hold the key to scrub the car backward
-- along its recently recorded path; release to resume driving from that
-- point with the momentum it had back then.
--
-- Why this can't be abused for lap times: the race/TT clock is server-owned
-- and keeps running in real time regardless of where the car physically is,
-- and checkpoints still have to be crossed for real afterwards. Rewinding
-- just costs you the seconds you spend doing it — same trade Forza makes.

local RCfg = Config and Config.Rewind or {}
if RCfg.enabled == false then return end

-- ── Recording buffer ─────────────────────────────────────────────────────────
-- Ring-ish buffer of recent {t, x,y,z, rx,ry,rz, vx,vy,vz}. Oldest-first.
local _buffer        = {}
local _raceState     = GlobalState.raceState or "IDLE"
local _myRaceOver    = false
local _rewinding     = false   -- shared with the playback section below

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _raceState = value end
end)

local function _shouldRecord()
    if _myRaceOver then return false end
    if _raceState == "LIVE" then return true end
    if _G.SPZ_InTimeTrial then return true end
    return false
end

-- The checkpoint the player was heading toward at the moment being recorded —
-- snapshotted per frame so a rewind landing can tell the server which gate to
-- re-arm. Race and TT track this under different exports/index spaces.
local function _currentCpIndex()
    if _G.SPZ_InTimeTrial then
        return exports["spz-races"]:GetTTCpIndex()
    end
    local _, idx = exports["spz-races"]:GetCurrentCP()
    return idx
end

local function _pushFrame(t, pos, rot, vel, cp)
    _buffer[#_buffer + 1] = {
        t = t, x = pos.x, y = pos.y, z = pos.z,
        rx = rot.x, ry = rot.y, rz = rot.z,
        vx = vel.x, vy = vel.y, vz = vel.z,
        cp = cp,
    }
    local cutoff = t - ((RCfg.bufferSeconds or 10) * 1000)
    while _buffer[1] and _buffer[1].t < cutoff do
        table.remove(_buffer, 1)
    end
end

Citizen.CreateThread(function()
    while true do
        if _shouldRecord() and not _rewinding then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                _pushFrame(GetGameTimer(), GetEntityCoords(veh), GetEntityRotation(veh, 2), GetEntityVelocity(veh), _currentCpIndex())
            else
                _buffer = {}
            end
            Citizen.Wait(RCfg.recordIntervalMs or 66)
        else
            if not _rewinding then _buffer = {} end
            Citizen.Wait(300)
        end
    end
end)

-- ── Reset points ──────────────────────────────────────────────────────────────
-- Any teleport that isn't "drive there yourself" invalidates the buffer —
-- rewinding into it would scrub through a jump, not the road.

local function _clearBuffer() _buffer = {} end

RegisterNetEvent("SPZ:spawnCheckpoints", function() _myRaceOver = false; _clearBuffer() end)
RegisterNetEvent("SPZ:tt:Begin",         function() _myRaceOver = false; _clearBuffer() end)
RegisterNetEvent("SPZ:tt:Restarted",     _clearBuffer)
RegisterNetEvent("SPZ:tpToGrid",         _clearBuffer)
RegisterNetEvent("SPZ:tpToSafeZone",     function() _myRaceOver = true;  _clearBuffer() end)

RegisterNetEvent("SPZ:raceFinished", function() _myRaceOver = true end)
RegisterNetEvent("SPZ:playerDNF", function(data)
    if data and data.source == GetPlayerServerId(PlayerId()) then _myRaceOver = true end
end)

-- ── UI bridge ─────────────────────────────────────────────────────────────────

local function _uiUpdate(secondsBack, fraction)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:UpdateRewind({
        active       = true,
        secondsBack  = secondsBack,
        fraction     = fraction,
        bufferSeconds = RCfg.bufferSeconds or 10,
    })
end

local function _uiHide()
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:HideRewind()
end

-- ── Rewind playback ───────────────────────────────────────────────────────────

local _rewindEnt        = nil
local _rewindHead        = 0     -- virtual GetGameTimer() timestamp we're scrubbing at
local _lastApplied        = nil
local _cooldownUntil       = 0

local function _lerp(a, b, f) return a + (b - a) * f end

-- Shortest-path angle interpolation so a heading near 359/1 doesn't spin the
-- long way round.
local function _lerpAngle(a, b, f)
    local diff = ((b - a + 540.0) % 360.0) - 180.0
    return (a + diff * f) % 360.0
end

-- Bracketing frames for a virtual timestamp `head` (buffer is oldest→newest).
local function _findBracket(head)
    for i = #_buffer, 2, -1 do
        if _buffer[i - 1].t <= head then
            return _buffer[i - 1], _buffer[i]
        end
    end
    return _buffer[1], _buffer[1]
end

local function _finishRewind()
    if not _rewinding then return end
    _rewinding = false

    local ent = _rewindEnt
    if ent and DoesEntityExist(ent) then
        local landing = _lastApplied
        if landing then
            SetEntityVelocity(ent, landing.vx, landing.vy, landing.vz)
        end
        -- No getter native exists for the prior invincible state, and nothing
        -- else in this resource sets it true during a LIVE race — false is
        -- always the correct value to hand back.
        SetEntityInvincible(ent, false)
        SetVehicleTyresCanBurst(ent, true)
    end

    -- Drop every recorded frame newer than the landing point — that "future"
    -- never happened — and resume recording forward from here.
    if _lastApplied then
        local landAt = _lastApplied.t
        local trimmed = {}
        for _, fr in ipairs(_buffer) do
            if fr.t <= landAt then trimmed[#trimmed + 1] = fr end
        end
        _buffer = trimmed
    end

    -- Checkpoint progress is server-authoritative and never moves with the
    -- scrub itself — if the landing point predates the last checkpoint the
    -- player actually crossed, tell the server so both sides agree on what
    -- still needs to be re-crossed. This can only push the target EARLIER
    -- (more of the route to redrive), never skip a gate, so it's safe even if
    -- the snapshot is a frame or two stale.
    if _lastApplied and _lastApplied.cp then
        local nowCp = _currentCpIndex()
        if nowCp and _lastApplied.cp < nowCp then
            if _G.SPZ_InTimeTrial then
                TriggerServerEvent("SPZ:tt:rewindCheckpoint", _lastApplied.cp)
            else
                TriggerServerEvent("SPZ:rewindCheckpoint", _lastApplied.cp)
            end
        end
    end

    _rewindEnt   = nil
    _lastApplied = nil
    _cooldownUntil = GetGameTimer() + (RCfg.resumeCooldownMs or 350)

    PlaySoundFrontend(-1, "SELECT", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
    _uiHide()
end

-- Accel/brake (71/72) are deliberately NOT blocked: the velocity is force-zeroed
-- every frame below regardless of throttle input, so blocking them bought
-- nothing — and holding a disabled control for the whole scrub desyncs GTA's
-- input edge-detection, which is what left the accelerator "stuck" after
-- release until a full let-off + re-press. Steering/handbrake/exit have no
-- such held-edge behaviour, so those stay blocked.
local REWIND_CONTROLS = { 59, 63, 64, 76, 75 } -- steer LR, steer L/R digital, handbrake, exit vehicle

local function _rewindLoop()
    local lastTick   = GetGameTimer()
    local playbackMult = RCfg.playbackSpeedMult or 2.5

    while _rewinding do
        local now = GetGameTimer()
        local dt  = now - lastTick
        lastTick  = now

        _rewindHead = _rewindHead - (dt * playbackMult)

        local oldest = _buffer[1]
        local newest = _buffer[#_buffer]
        if not oldest or not newest then
            _finishRewind()
            return
        end

        -- Ran out of buffer: clamp to the oldest frame, apply it exactly below,
        -- then end the rewind on this same tick (rather than stopping one tick
        -- short and leaving the car's position and its handed-back velocity
        -- slightly out of sync).
        local exhausted = _rewindHead <= oldest.t
        if exhausted then _rewindHead = oldest.t end

        local ent = _rewindEnt
        if not DoesEntityExist(ent) then
            _finishRewind()
            return
        end

        for _, c in ipairs(REWIND_CONTROLS) do DisableControlAction(0, c, true) end

        local f1, f2 = _findBracket(_rewindHead)
        local span   = math.max(f2.t - f1.t, 1)
        local frac   = math.max(0.0, math.min(1.0, (_rewindHead - f1.t) / span))

        local x  = _lerp(f1.x, f2.x, frac)
        local y  = _lerp(f1.y, f2.y, frac)
        local z  = _lerp(f1.z, f2.z, frac)
        local rx = _lerp(f1.rx, f2.rx, frac)
        local ry = _lerp(f1.ry, f2.ry, frac)
        local rz = _lerpAngle(f1.rz, f2.rz, frac)
        local vx = _lerp(f1.vx, f2.vx, frac)
        local vy = _lerp(f1.vy, f2.vy, frac)
        local vz = _lerp(f1.vz, f2.vz, frac)

        SetEntityCoords(ent, x, y, z, false, false, false, false)
        SetEntityRotation(ent, rx, ry, rz, 2, true)

        -- Wheels only spin off the entity's actual velocity — zeroing it (as
        -- this used to, to stop the chassis fighting the teleport) left them
        -- dead-static for the whole scrub. Position is already re-pinned
        -- every tick above regardless of velocity, so feeding it the real
        -- interpolated speed is free. Negated because time is running
        -- backward: the car is visibly sliding the opposite way it originally
        -- drove this stretch, so the wheels should spin opposite too. Scaled
        -- by playbackMult so the spin rate matches the sped-up scrub instead
        -- of reading as the car's original, slower-than-this-looks pace.
        SetEntityVelocity(ent, -vx * playbackMult, -vy * playbackMult, -vz * playbackMult)

        _lastApplied = { t = _rewindHead, vx = vx, vy = vy, vz = vz, cp = f1.cp }

        if exhausted then
            _finishRewind()
            return
        end

        local bufSpan     = math.max(newest.t - oldest.t, 1)
        local secondsBack = (newest.t - _rewindHead) / 1000.0
        _uiUpdate(secondsBack, math.min((newest.t - _rewindHead) / bufSpan, 1.0))

        Citizen.Wait(0)
    end
end

local function _startRewind()
    if _rewinding then return end
    if GetGameTimer() < _cooldownUntil then return end
    if not _shouldRecord() then return end
    if #_buffer < 3 then return end

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end

    _rewinding            = true
    _rewindEnt            = veh
    _rewindHead           = GetGameTimer()
    _lastApplied          = nil

    SetEntityInvincible(veh, true)
    SetVehicleTyresCanBurst(veh, false)
    PlaySoundFrontend(-1, "BACK", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)

    Citizen.CreateThread(_rewindLoop)
end

RegisterCommand("+spz_rewind", _startRewind, false)
RegisterCommand("-spz_rewind", _finishRewind, false)
RegisterKeyMapping("+spz_rewind", "Race: Rewind Time", "keyboard", RCfg.key or "R")

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and _rewinding then _finishRewind() end
end)

-- ── Export ────────────────────────────────────────────────────────────────────
-- Lets checkpoint / incident detection suppress false hits while the car is
-- being scrubbed backward through world space.
exports("IsRewinding", function() return _rewinding end)
