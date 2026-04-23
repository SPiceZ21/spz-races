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
    if state == "IDLE" or state == "ENDED" or state == "CLEANUP" then
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
