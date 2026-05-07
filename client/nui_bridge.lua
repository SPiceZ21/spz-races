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

-- ── Countdown / Staging Events ────────────────────────────────────────────────
RegisterNetEvent("SPZ:stagingPhase", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowCountdown({
        number  = data.remaining,
        isGo    = false,
        track   = data.track,
        class   = data.class,
        laps    = data.laps,
        gridPos = data.gridPos,
        total   = data.totalRacers,
    })
end)

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

-- ── Telemetry ─────────────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, currentIdx)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:UpdateRaceOverlay({
        totalCheckpoints = #checkpoints,
        checkpoint       = currentIdx or 1,
    })
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(cpIndex)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:UpdateRaceOverlay({ checkpoint = cpIndex })
end)

RegisterNetEvent("SPZ:lapComplete", function(lapNum)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:UpdateRaceOverlay({ lapNum = lapNum + 1, checkpoint = 1 })
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
    })
    _pendingStats = nil
end)
