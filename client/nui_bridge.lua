-- client/nui_bridge.lua

-- This file acts as the adapter between the monolithic spz-races events
-- and the new standalone UI resources (spz-poll, spz-raceUI).

-- ── Poll Events ──────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:pollOpen", function(data)
    if GetResourceState("spz-poll") == "started" then
        -- Convert data to format expected by spz-poll if necessary
        -- spz-poll StartPoll expects: { phase, timer, options }
        exports["spz-poll"]:StartPoll({
            phase = data.phase,
            timer = data.duration, -- map duration to timer
            options = data.options,
            title = data.title,
            subtitle = data.subtitle
        })
    else
        print("^1[spz-races] WARNING: spz-poll is not started!^7")
    end
end)

RegisterNetEvent("SPZ:pollResult", function(data)
    if GetResourceState("spz-poll") == "started" then
        exports["spz-poll"]:UpdatePoll(data)
        
        -- If it's the final phase, close the UI after a short delay so players can see the winner
        if data.phase == "vehicle" then
            Citizen.SetTimeout(1200, function()
                exports["spz-poll"]:StopPoll()
            end)
        end
    end
end)

-- ── Countdown Events ──────────────────────────────────────────────────────
RegisterNetEvent("SPZ:stagingPhase", function(data)
    if GetResourceState("spz-raceUI") == "started" then
        -- stagingPhase is essentially a countdown for the start
        exports["spz-raceUI"]:ShowCountdown({
            number = data.remaining,
            isGo = false,
            track = data.track,
            class = data.class,
            laps = data.laps,
            gridPos = data.gridPos,
            total = data.totalRacers
        })
    end
end)

RegisterNetEvent("SPZ:countdown", function(data)
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:ShowCountdown({
            number = data.seconds,
            isGo = false,
            track = data.track,
            class = data.class,
            laps = data.laps,
            gridPos = data.gridPos,
            total = data.total
        })
    end
end)

RegisterNetEvent("SPZ:go", function()
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:ShowCountdown({ isGo = true })
        -- Also show the live overlay
        exports["spz-raceUI"]:SetRaceOverlayVisible(true)
    end
end)

RegisterNetEvent("SPZ:stagingEnd", function()
    -- Optional cleanup or transition
end)

-- ── State Management ──────────────────────────────────────────────────────
RegisterNetEvent("spz_race:state_updated", function(state)
    print(string.format("[NUI Bridge] DEBUG: State updated to %s", state))
    if state == "IDLE" or state == "CLEANUP" then
        if GetResourceState("spz-raceUI") == "started" then
            exports["spz-raceUI"]:HideAll()
        end
        if GetResourceState("spz-poll") == "started" then
            print("[NUI Bridge] DEBUG: Stopping poll due to IDLE/ENDED")
            exports["spz-poll"]:StopPoll()
        end
    elseif state == "WAITING" or state == "COUNTDOWN" or state == "LIVE" then
        -- Ensure poll is closed when moving out of polling
        if GetResourceState("spz-poll") == "started" then
            print("[NUI Bridge] DEBUG: Stopping poll due to WAITING/COUNTDOWN/LIVE")
            exports["spz-poll"]:StopPoll()
        end
    end
end)

-- ── Telemetry & Race Data ──────────────────────────────────────────────────
RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, currentIdx)
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:UpdateRaceOverlay({ 
            totalCheckpoints = #checkpoints, 
            checkpoint = currentIdx or 1 
        })
    end
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(cpIndex)
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:UpdateRaceOverlay({ checkpoint = cpIndex })
    end
end)

RegisterNetEvent("SPZ:lapComplete", function(lapNum)
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:UpdateRaceOverlay({ lapNum = lapNum + 1, checkpoint = 1 })
    end
end)

local _lastPosBroadcast = 0
RegisterNetEvent("SPZ:positionUpdate", function(payload)
    if GetResourceState("spz-raceUI") == "started" then
        local now = GetGameTimer()
        if now - _lastPosBroadcast < 200 then return end
        _lastPosBroadcast = now
        
        exports["spz-raceUI"]:UpdateRaceOverlay({ 
            positions = payload, 
            mySource = GetPlayerServerId(PlayerId()) 
        })
    end
end)

-- ── Results & Progression ──────────────────────────────────────────────────
local _pendingStats = nil

RegisterNetEvent("SPZ:raceEnd", function(results)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    
    local mySource = GetPlayerServerId(PlayerId())
    local myResult = nil
    
    -- Find my data in finishers
    if results.finishers then
        for _, finisher in ipairs(results.finishers) do
            if finisher.source == mySource then
                myResult = finisher
                break
            end
        end
    end
    
    -- If not in finishers, check DNF
    if not myResult and results.dnf then
        for _, dnf in ipairs(results.dnf) do
            if dnf.source == mySource then
                myResult = dnf
                myResult.position = "DNF"
                break
            end
        end
    end
    
    if not myResult then 
        print("^1[NUI Bridge] ERROR: Could not find my result in race data!^7")
        return 
    end
    
    print("^2[NUI Bridge] DEBUG: Received raceEnd. Track: " .. tostring(results.track) .. "^7")
    
    _pendingStats = {
        trackName = results.track or "UNKNOWN",
        finishTime = myResult.finish_time and string.format("%02d:%05.2f", math.floor(myResult.finish_time/60000), (myResult.finish_time%60000)/1000) or "DNF",
        position = myResult.position or "DNF",
        bestLap = myResult.best_lap and string.format("%02d:%05.2f", math.floor(myResult.best_lap/60000), (myResult.best_lap%60000)/1000) or "N/A",
    }
    
    -- We wait for progressionUpdate to show the UI
end)

RegisterNetEvent("SPZ:progressionUpdate", function(data)
    print("^2[NUI Bridge] DEBUG: Received progressionUpdate. PendingStats: " .. tostring(_pendingStats ~= nil) .. "^7")
    if GetResourceState("spz-raceUI") ~= "started" then return end
    if not _pendingStats then return end
    
    -- Combine stats with gains
    local payload = {
        trackName = _pendingStats.trackName,
        finishTime = _pendingStats.finishTime,
        position = _pendingStats.position,
        bestLap = _pendingStats.bestLap,
        xpGained = data.xpGain or 0,
        xpNewProgress = 0.5, -- TODO: Calculate actual progress fraction
        classPointsGained = data.pointsGain or 0,
        cpNewProgress = 0.5, -- TODO: Calculate actual progress fraction
        iRatingDelta = data.irDelta or 0,
        safetyRatingDelta = data.srDelta or 0
    }
    
    exports["spz-raceUI"]:ShowPostRaceStats(payload)
    _pendingStats = nil -- Clear for next race
end)
