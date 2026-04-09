-- server/countdown.lua

-- 10. Countdown System Logic
function StartCountdownSequence()
    if RaceSession.state ~= SPZ.RaceState.COUNTDOWN then return end

    -- 10.1 Server Tick initialization
    print("[Countdown] Initiating race start sequence.")

    -- Synchronously freeze all participants at their assigned grid spots
    for source, _ in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:freezeRacer", source, true)
    end

    -- Run the authoritative timer
    Citizen.CreateThread(function()
        local remaining = Config.CountdownSeconds
        
        while remaining > 0 do
            -- Notify HUD/UI for animation
            TriggerClientEvent("SPZ:countdown", -1, remaining)
            print(string.format("[Countdown] T-minus %s", remaining))
            Citizen.Wait(1000)
            remaining = remaining - 1
        end

        -- 🏁 GO SIGNAL
        RaceSession.startTime = GetGameTimer()
        TriggerClientEvent("SPZ:go", -1)
        print("[Countdown] RACE LIVE")

        -- 12.3 Global Race Timeout Watchdog
        StartRaceTimeoutWatchdog()

        -- Release participants
        for source, _ in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:freezeRacer", source, false)
            
            -- Interface with vehicle resource to enable engine/controls
            if GetResourceState("spz-vehicles") == "started" then
                exports["spz-vehicles"]:UnlockRaceVehicle(source)
            end
        end

        -- Finalize state transition
        exports["spz-races"]:SetRaceState(SPZ.RaceState.LIVE)
    end)
end

-- Authoritative timeout watchdog to prevent infinite sessions
function StartRaceTimeoutWatchdog()
    Citizen.CreateThread(function()
        local maxTimeMs = Config.RaceTimeout or 300000
        local startTime = GetGameTimer()

        while (GetGameTimer() - startTime) < maxTimeMs do
            Citizen.Wait(5000) -- Check every 5 seconds
            if RaceSession.state ~= SPZ.RaceState.LIVE then return end
        end

        if RaceSession.state == SPZ.RaceState.LIVE then
            print("[Race Engine] Global race timeout reached. Kicking lingering racers.")
            for source, data in pairs(RaceSession.players) do
                if not data.finished and not data.dnf then
                    ProcessDNF(source, "timeout")
                end
            end
        end
    end)
end

-- Export provided for state machine activation
exports("StartCountdownSequence", StartCountdownSequence)
