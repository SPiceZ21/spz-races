-- server/results.lua

-- 15. Race End & Results Logic
function ProcessRaceResults()
    if not RaceSession.track then return end

    local results = {
        raceId    = RaceSession.raceId or "N/A",
        track     = RaceSession.track.name,
        trackId   = RaceSession.track.id or RaceSession.track.name,
        type      = RaceSession.track.type,        -- "circuit" | "sprint"
        carClass  = RaceSession.carClassId,
        laps      = RaceSession.track.laps,
        duration  = (GetGameTimer() - RaceSession.startTime) / 1000, -- seconds
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
                sector_times  = pData.sector_times or {},
                best_sectors  = pData.best_sectors or {},
                personal_best = pData.personal_best or false,
                -- Real incident data (client-detected world impacts, server-
                -- validated). Clean race = zero incidents. The old code was
                -- `pData.cleanRace or true`, which is ALWAYS true — every racer
                -- got the clean bonus regardless of how they drove.
                collisions    = pData.incidents or {},
                cleanRace     = (#(pData.incidents or {}) == 0),
                points_earned = (SPZ.PointsTable and SPZ.PointsTable[pData.position]) or 0,
            })
        else
            local totalCPs = RaceSession.track and RaceSession.track.checkpoints and #RaceSession.track.checkpoints or 1
            table.insert(results.dnf, {
                source      = source,
                name        = pData.name,
                dnf_reason  = pData.dnf_reason or "timeout",
                -- Progress fraction (0–1) for adaptive SR penalty in spz-progression
                progress    = math.min(1.0, (pData.current_cp or 1) / totalCPs),
            })
        end
    end

    -- Ensure exact ordering by P1 -> PN
    table.sort(results.finishers, function(a, b)
        return a.position < b.position
    end)

    -- Ghost-bots: display-only rows for the results grid. Deliberately kept out
    -- of `finishers` so spz-progression (which scores `finishers`) never sees
    -- them — humans are ranked and rewarded only against humans.
    if GetBotResults then
        results.bots = GetBotResults()
    end

    print(string.format("[Results] Finalized results for race %s on %s. Winner: %s", 
        results.raceId, results.track, results.finishers[1] and results.finishers[1].name or "None"))

    -- 15.2 Result Broadcasts
    
    -- Client notification (for HUD results screen)
    BroadcastToRacers("SPZ:raceEnd", results)

    -- Server notification (for internal modules: spz-progression, spz-economy, leaderboard)
    TriggerEvent("SPZ:raceEnd", results)

    return results
end

-- Export provided for state machine activation in the ENDED state
exports("ProcessRaceResults", ProcessRaceResults)
