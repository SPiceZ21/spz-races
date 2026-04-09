-- server/intermission.lua

-- 17. Intermission logic
-- This handles the cooldown between races and re-inviting players to the next cycle.
function StartIntermission()
    print(string.format("[Race Engine] Starting %ds intermission. Next race type: %s", 
        Config.IntermissionTime or 60, RaceSession.raceType or "unknown"))

    -- 17.1 Broadcast start event to all clients for HUD countdowns
    TriggerClientEvent("SPZ:intermissionStart", -1, {
        seconds  = Config.IntermissionTime or 60,
        nextType = RaceSession.raceType or "circuit",
    })

    -- 17.2 Wait for intermission duration before re-showing the choice screen
    local delayMs = (Config.IntermissionTime or 60) * 1000
    
    -- Using standard Citizen.SetTimeout for reliable local timing
    Citizen.SetTimeout(delayMs, function()
        print("[Race Engine] Intermission over. Prompting choice screens.")
        
        -- Retrieve all connected sessions to re-invite everyone (not just previous racers)
        -- This ensures fresh players who just joined as the race ended are also invited.
        local sessions = exports["spz-core"]:GetAllSessions()
        if sessions then
            for source, _ in pairs(sessions) do
                TriggerClientEvent("SPZ:showChoiceScreen", source)
            end
        else
            -- Fallback: trigger for everyone currently connected
            TriggerClientEvent("SPZ:showChoiceScreen", -1)
        end
    end)
end

-- Exported for internal engine use during the cleanup phase
exports("StartIntermission", StartIntermission)
