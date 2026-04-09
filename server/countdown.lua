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

-- Export provided for state machine activation
exports("StartCountdownSequence", StartCountdownSequence)
