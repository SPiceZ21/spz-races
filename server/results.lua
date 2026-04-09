-- server/results.lua

-- 15. Race End & Results Logic
function ProcessRaceResults()
    if not RaceSession.track then return end

    local results = {
        raceId    = RaceSession.raceId or "N/A",
        track     = RaceSession.track.name,
        type      = RaceSession.track.type,        -- "circuit" | "sprint"
        carClass  = RaceSession.carClass,
        laps      = RaceSession.track.laps,
        duration  = GetGameTimer() - RaceSession.startTime,
        finishers = {},    -- ordered P1 → PN
        dnf       = {},    -- DNF players
    }

    -- 15.1 Results Object Construction
    for source, pData in pairs(RaceSession.players) do
        if pData.finished then
            table.insert(results.finishers, {
                source        = source,
                name          = pData.name,
                crew_tag      = pData.crew_tag,
                position      = pData.position,
                finish_time   = pData.finish_time,
                lap_times     = pData.lap_times or {},  -- circuit only
                best_lap      = pData.best_lap,         -- circuit only
                personal_best = pData.personal_best or false,
                points_earned = (SPZ.PointsTable and SPZ.PointsTable[pData.position]) or 0,
            })
        else
            table.insert(results.dnf, {
                source     = source,
                name       = pData.name,
                dnf_reason = pData.dnf_reason or "timeout",
            })
        end
    end

    -- Ensure exact ordering by P1 -> PN
    table.sort(results.finishers, function(a, b) 
        return a.position < b.position 
    end)

    print(string.format("[Results] Finalized results for race %s on %s. Winner: %s", 
        results.raceId, results.track, results.finishers[1] and results.finishers[1].name or "None"))

    -- 15.2 Result Broadcasts
    
    -- Client notification (for HUD results screen)
    TriggerClientEvent("SPZ:raceEnd", -1, results)

    -- Server notification (for internal modules: spz-progression, spz-economy, spz-leaderboard)
    TriggerEvent("SPZ:raceEnd", results)
end

-- Export provided for state machine activation in the ENDED state
exports("ProcessRaceResults", ProcessRaceResults)
