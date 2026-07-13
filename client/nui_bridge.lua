-- client/nui_bridge.lua
-- Adapter between spz-races events and standalone UI resources (spz-poll, spz-raceUI).

-- ── Poll Events ───────────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:pollOpen", function(data)
    if GetResourceState("spz-poll") ~= "started" then
        print("^1[spz-races] WARNING: spz-poll not started^7")
        return
    end
    exports["spz-poll"]:StartPoll({
        phase    = data.phase,
        timer    = data.duration,
        options  = data.options,
        title    = data.title,
        subtitle = data.subtitle,
    })
end)

RegisterNetEvent("SPZ:pollResult", function(data)
    if GetResourceState("spz-poll") ~= "started" then return end
    exports["spz-poll"]:UpdatePoll(data)
    if data.phase == "vehicle" then
        Citizen.SetTimeout(1200, function()
            exports["spz-poll"]:StopPoll()
        end)
    end
end)

-- ── Warmup panel (spz-raceUI tile HUD) ────────────────────────────────────────
RegisterNetEvent("SPZ:warmupPhase", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowWarmup({
        remaining = data.remaining,
        total     = data.total,
        track     = data.track,
        class     = data.class,
        gridPos   = data.gridPos,
    })
end)

RegisterNetEvent("SPZ:warmupEnd", function()
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:HideWarmup()
end)

-- ── Countdown / Staging Events ────────────────────────────────────────────────
-- Staging is a brief silent settle on the grid after the warmup TP-back.
-- It must NOT render the giant countdown box — doing so showed a 10→1 count
-- right before the real 3-2-1-GO (double countdown). Intentionally a no-op;
-- only SPZ:countdown drives the on-screen 3-2-1-GO.
RegisterNetEvent("SPZ:stagingPhase", function() end)

RegisterNetEvent("SPZ:countdown", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowCountdown({
        number  = data.seconds,
        isGo    = false,
        track   = data.track,
        class   = data.class,
        laps    = data.laps,
        gridPos = data.gridPos,
        total   = data.total,
    })
end)

RegisterNetEvent("SPZ:go", function()
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowCountdown({ isGo = true })
    exports["spz-raceUI"]:SetRaceOverlayVisible(true)
end)

RegisterNetEvent("SPZ:stagingEnd", function() end)

-- ── Race state (native statebag) ──────────────────────────────────────────────
local function _onRaceState(state)
    if state == "IDLE" or state == "CLEANUP" then
        if GetResourceState("spz-raceUI") == "started" then
            exports["spz-raceUI"]:HideAll()
        end
        if GetResourceState("spz-poll") == "started" then
            exports["spz-poll"]:StopPoll()
        end
    elseif state == "WAITING" or state == "COUNTDOWN" or state == "LIVE" then
        if GetResourceState("spz-poll") == "started" then
            exports["spz-poll"]:StopPoll()
        end
        if state ~= "WAITING" and GetResourceState("spz-raceUI") == "started" then
            exports["spz-raceUI"]:HideWarmup()
        end
    end
end

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _onRaceState(value) end
end)

Citizen.CreateThread(function()
    Citizen.Wait(0)
    local s = GlobalState.raceState
    if s then _onRaceState(s) end
end)

-- ── Distance to next checkpoint (10 Hz during LIVE) ─────────────────────────
-- Updates the CPDistancePill in spz-raceUI without triggering a full HUD diff.
local _distState = GlobalState.raceState or "IDLE"
AddStateBagChangeHandler("raceState", "global", function(_, _, v)
    if v then _distState = v end
end)

-- Projects the active checkpoint into screen space every frame and feeds the
-- raceUI "Next CP" pill so it renders as a 3D billboard anchored on the CP
-- (with a stem line), instead of a fixed HUD pill.
Citizen.CreateThread(function()
    while true do
        if _distState == "LIVE" and GetResourceState("spz-raceUI") == "started" then
            local cp = exports["spz-races"]:GetCurrentCP()
            if cp then
                local pos  = GetEntityCoords(PlayerPedId())
                local dx   = pos.x - cp.coords.x
                local dy   = pos.y - cp.coords.y
                local dist = math.floor(math.sqrt(dx*dx + dy*dy))

                -- Anchor the pill slightly above the checkpoint ground point.
                local onScreen, sx, sy = World3dToScreen2d(
                    cp.coords.x, cp.coords.y, cp.coords.z + 1.0)

                exports["spz-raceUI"]:UpdateCPWaypoint({
                    dist     = dist,
                    onScreen = onScreen and true or false,
                    x        = sx,
                    y        = sy,
                })
                Citizen.Wait(0)
            else
                exports["spz-raceUI"]:UpdateCPWaypoint({ dist = 0, onScreen = false })
                Citizen.Wait(200)
            end
        else
            if (_distState == "IDLE" or _distState == "CLEANUP")
            and GetResourceState("spz-raceUI") == "started" then
                exports["spz-raceUI"]:UpdateCPWaypoint({ dist = 0, onScreen = false })
            end
            Citizen.Wait(500)
        end
    end
end)

-- ── Telemetry ─────────────────────────────────────────────────────────────────
local clientBestLap = nil

RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, currentIdx)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    clientBestLap = LocalPlayer.state.personalBest or 0
    exports["spz-raceUI"]:UpdateRaceOverlay({
        totalCheckpoints = #checkpoints,
        checkpoint       = currentIdx or 1,
        bestLapTime      = clientBestLap,
        allTimeBest      = LocalPlayer.state.allTimeBest or 0
    })
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(cpIndex)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:UpdateRaceOverlay({ checkpoint = cpIndex })
end)

RegisterNetEvent("SPZ:lapComplete", function(lapNum, lapTime)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    if lapTime and (clientBestLap == nil or clientBestLap == 0 or lapTime < clientBestLap) then
        clientBestLap = lapTime
    end
    exports["spz-raceUI"]:UpdateRaceOverlay({
        lapNum      = lapNum + 1,
        checkpoint  = 1,
        bestLapTime = clientBestLap or 0
    })
end)

local _lastPosBroadcast = 0
local _lastPosVersion   = 0

RegisterNetEvent("SPZ:positionUpdate", function(payload, version)
    if version and version == 0 then
        _lastPosVersion = 0
    elseif version and version <= _lastPosVersion then
        return
    else
        _lastPosVersion = version or (_lastPosVersion + 1)
    end

    if GetResourceState("spz-raceUI") ~= "started" then return end
    local now = GetGameTimer()
    if now - _lastPosBroadcast < 200 then return end
    _lastPosBroadcast = now

    exports["spz-raceUI"]:UpdateRaceOverlay({
        positions = payload,
        mySource  = GetPlayerServerId(PlayerId()),
    })
end)

-- ── Results & Progression ─────────────────────────────────────────────────────
local _pendingStats = nil

RegisterNetEvent("SPZ:raceEnd", function(results)
    if GetResourceState("spz-raceUI") ~= "started" then return end

    local mySource = GetPlayerServerId(PlayerId())
    local myResult = nil

    for _, finisher in ipairs(results.finishers or {}) do
        if finisher.source == mySource then myResult = finisher; break end
    end

    if not myResult then
        for _, dnf in ipairs(results.dnf or {}) do
            if dnf.source == mySource then
                myResult          = dnf
                myResult.position = "DNF"
                break
            end
        end
    end

    if not myResult then return end

    _pendingStats = {
        trackName  = results.track or "UNKNOWN",
        finishTime = myResult.finish_time
            and string.format("%02d:%05.2f",
                math.floor(myResult.finish_time / 60000),
                (myResult.finish_time % 60000) / 1000)
            or "DNF",
        position   = myResult.position or "DNF",
        bestLap    = myResult.best_lap
            and string.format("%02d:%05.2f",
                math.floor(myResult.best_lap / 60000),
                (myResult.best_lap % 60000) / 1000)
            or "N/A",
    }
end)

RegisterNetEvent("SPZ:progressionUpdate", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    if not _pendingStats then return end

    exports["spz-raceUI"]:ShowPostRaceStats({
        trackName           = _pendingStats.trackName,
        finishTime          = _pendingStats.finishTime,
        position            = _pendingStats.position,
        bestLap             = _pendingStats.bestLap,
        xpGained            = data.xpGain or 0,
        xpNewProgress       = data.xpProgress or 0.0,
        classPointsGained   = data.pointsGain or 0,
        cpNewProgress       = data.cpProgress or 0.0,
        iRatingDelta        = data.irDelta or 0,
        safetyRatingDelta   = data.srDelta or 0,
        level               = data.level or 1,
        levelUp             = data.levelUp or false,
    })
    _pendingStats = nil
end)

-- ── Lobby pill + [E] join ─────────────────────────────────────────────────────
-- Small persistent HUD: "[E] JOIN RACE" while freeroaming, "IN QUEUE" once
-- joined, "NEXT RACE IN Ns" during intermission. Every race requires an
-- explicit join — no auto re-queue loop.

local _lobbyRaceState  = GlobalState.raceState or "IDLE"
local _intermissionEnd = 0   -- GetGameTimer() timestamp when break ends
local _lastLobbySig    = ""

AddStateBagChangeHandler("raceState", "global", function(_, _, v)
    if v then _lobbyRaceState = v end
end)

RegisterNetEvent("SPZ:intermissionStart", function(data)
    local secs = (data and data.seconds) or 60
    _intermissionEnd = GetGameTimer() + secs * 1000
end)

-- Join window: armed by the first joiner, counts down for everyone
local _joinWindowEnd = 0

RegisterNetEvent("SPZ:joinWindow", function(data)
    local secs = (data and data.seconds) or 0
    _joinWindowEnd = secs > 0 and (GetGameTimer() + secs * 1000) or 0
end)

-- Poll opening means the break / join window is over
RegisterNetEvent("SPZ:pollOpen", function()
    _intermissionEnd = 0
    _joinWindowEnd   = 0
end)

local function _lobbyMode()
    if LocalPlayer.state.inRace then return { mode = "hidden" } end

    local qCount = GlobalState.queueCount or 0

    -- seconds until the armed race starts (nil when no window is running)
    local winMs   = _joinWindowEnd - GetGameTimer()
    local winSecs = winMs > 0 and math.ceil(winMs / 1000) or nil

    if LocalPlayer.state.inQueue or LocalPlayer.state.pendingRace then
        return {
            mode       = "queued",
            queuePos   = LocalPlayer.state.queuePosition or 1,
            queueCount = math.max(qCount, 1),
            seconds    = winSecs,
        }
    end

    local remainMs = _intermissionEnd - GetGameTimer()
    if remainMs > 0 then
        return {
            mode    = "intermission",
            seconds = math.ceil(remainMs / 1000),
        }
    end

    return { mode = "join", queueCount = qCount, seconds = winSecs }
end

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)
        if GetResourceState("spz-raceUI") == "started" then
            local lb  = _lobbyMode()
            local sig = ("%s|%s|%s|%s"):format(lb.mode, lb.queueCount or "", lb.queuePos or "", lb.seconds or "")
            if sig ~= _lastLobbySig then
                _lastLobbySig = sig
                exports["spz-raceUI"]:UpdateLobby(lb)
            end
        end
    end
end)

-- [E] to join — active whenever the pill offers joining
Citizen.CreateThread(function()
    while true do
        if not LocalPlayer.state.inRace
        and not LocalPlayer.state.inQueue
        and not LocalPlayer.state.pendingRace
        and not IsPauseMenuActive() then
            if IsControlJustPressed(0, 51) then   -- INPUT_CONTEXT (E)
                TriggerServerEvent("SPZ:joinQueue")
                Citizen.Wait(500)                 -- debounce
            end
            Citizen.Wait(0)
        else
            Citizen.Wait(400)
        end
    end
end)
