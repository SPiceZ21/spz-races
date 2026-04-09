-- server/positions.lua

function UpdateAllPositions()
    local players = {}
    for source, data in pairs(RaceSession.players) do
        table.insert(players, data)
    end
    
    table.sort(players, function(a, b)
        -- 1. Finished players come first, ordered by finish_time
        if a.finished and not b.finished then return true end
        if b.finished and not a.finished then return false end
        if a.finished and b.finished then return a.finish_time < b.finish_time end
        
        -- 2. DNF players come last
        if a.dnf and not b.dnf then return false end
        if b.dnf and not a.dnf then return true end
        
        -- 3. Lap logic (Circuit only)
        if RaceSession.raceType == SPZ.RaceType.CIRCUIT then
            if a.current_lap ~= b.current_lap then return a.current_lap > b.current_lap end
        end

        -- 4. Checkpoint logic
        if a.current_cp ~= b.current_cp then return a.current_cp > b.current_cp end
        
        -- 5. Fallback stable sort
        return a.source < b.source
    end)
    
    for i, data in ipairs(players) do
        data.position = i
    end

    -- Push updates to HUD (NUI Bridge)
    TriggerClientEvent("spz_race:update_positions", -1, RaceSession.players)
end

-- Export for timing engine
exports("UpdatePositions", UpdateAllPositions)
