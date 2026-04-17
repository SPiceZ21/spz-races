-- server/intermission.lua

-- 17. Intermission logic
-- This handles the cooldown between races and re-inviting players to the next cycle.
function StartIntermission(results)
    local lastResults = {}
    if results and results.finishers then
        for i, racer in ipairs(results.finishers) do
            table.insert(lastResults, {
                name     = racer.name,
                position = racer.position,
                time     = racer.finish_time and string.format("%.2fs", racer.finish_time / 1000) or "DNF",
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
        RaceSession.intermissionActive = false
        exports["spz-races"]:StartPolling()
    end)
end

-- Exported for internal engine use during the cleanup phase
exports("StartIntermission", StartIntermission)
