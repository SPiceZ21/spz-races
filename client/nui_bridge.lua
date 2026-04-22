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
    if state == "IDLE" or state == "ENDED" or state == "CLEANUP" then
        if GetResourceState("spz-raceUI") == "started" then
            exports["spz-raceUI"]:HideAll()
        end
        if GetResourceState("spz-poll") == "started" then
            exports["spz-poll"]:StopPoll()
        end
    end
end)
