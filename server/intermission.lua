-- server/intermission.lua

-- 16.2 Intermission Handler
-- This phase represents the cooldown period between race sessions.
function StartIntermission()
    print("[Race Engine] Intermission started. Queue is now accepting participants for the next cycle.")
    
    -- Potential logic for broadcasting global notifications
    -- TriggerClientEvent("spz_race:notify_global", -1, "A new race will be starting soon! Join the queue now.")
end

-- Exported for internal engine use
exports("StartIntermission", StartIntermission)
