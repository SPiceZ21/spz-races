-- server/intermission.lua

-- 17. Intermission logic
-- This handles the cooldown between races and re-inviting players to the next cycle.
function StartIntermission(results)
    local lastResults = {}
    if results and results.standings then
        for i, racer in ipairs(results.standings) do
            table.insert(lastResults, {
                name = racer.name,
                time = racer.finishTime and string.format("%.2fs", racer.finishTime / 1000) or "DNF",
            })
            if i >= 3 then break end
        end
    end

    local playersInQueue = exports["spz-races"]:GetQueueCount()

    print(string.format("[Race Engine] Starting %ds intermission. Next race type: %s", 
        Config.IntermissionTime or 60, RaceSession.raceType or "unknown"))

    -- 17.1 Broadcast start event to all clients for HUD countdowns
    TriggerClientEvent("SPZ:intermissionStart", -1, {
        seconds        = Config.IntermissionTime or 60,
        nextType       = RaceSession.raceType or "circuit",
        lastResults    = lastResults,
        playersInQueue = playersInQueue
    })

    -- 17.2 Wait for intermission duration before re-showing the choice screen
    local delayMs = (Config.IntermissionTime or 60) * 1000
    
    Citizen.SetTimeout(delayMs, function()
        print("[Race Engine] Intermission over. Transitioning to Poll.")
        
        -- Instead of choice screens, we directly start the poll for the next race.
        -- This keeps the lobby flow moving automatically.
        exports["spz-races"]:StartPolling()
    end)
end

-- Exported for internal engine use during the cleanup phase
exports("StartIntermission", StartIntermission)
