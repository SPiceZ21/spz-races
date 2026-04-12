-- server/checkpoints.lua

-- 11.4 & 11.5 Checkpoint & Lap Logic
local function HandleFinish(source, pData)
    if pData.finished or pData.dnf then return end
    
    pData.finished = true
    pData.finish_time = GetGameTimer() - (pData.race_start_time or RaceSession.startTime)
    
    -- 12.2 Personal Best Detection
    local track = RaceSession.track
    local carClass = RaceSession.carClass
    
    -- Only call leaderboard if resource is actually running
    if GetResourceState("spz-leaderboard") == "started" then
        local prevBest = exports["spz-leaderboard"]:GetPersonalBest(source, track.name, carClass)
        pData.personal_best = (prevBest == nil) or (pData.finish_time < prevBest)
        
        if pData.personal_best then
            print(string.format("[Timing] New PB for %s on %s: %s ms", pData.name, track.name, pData.finish_time))
            exports["spz-leaderboard"]:WriteResult(source, track.name, carClass, pData.finish_time)
        end
    else
        pData.personal_best = false
    end
    
    print(string.format("[Race Engine] Player %s (%s) finished! Time: %s ms (PB: %s)", pData.name, source, pData.finish_time, pData.personal_best))
    
    TriggerClientEvent("SPZ:raceFinished", source, pData.finish_time, pData.personal_best)
    
    -- Update positions one last time
    if UpdateAllPositions then UpdateAllPositions() end
    
    -- Check if everyone is finished or DNF to end the session
    CheckAllFinished()
end

local function HandleCheckpointAdvance(source, pData)
    local track = RaceSession.track
    local totalCPs = #track.checkpoints

    -- pData.current_cp has already been incremented to the NEXT expected CP.
    -- When it exceeds totalCPs the player has passed the final checkpoint of a lap/sprint.
    if pData.current_cp > totalCPs then
        if track.type == "circuit" then
            -- Lap complete
            local timeNow = GetGameTimer()
            local lapStartTime = pData.lap_start_time or RaceSession.startTime
            local lapTime = timeNow - lapStartTime

            pData.current_cp = 1
            pData.current_lap = pData.current_lap + 1
            pData.lap_start_time = timeNow

            table.insert(pData.lap_times, lapTime)
            if not pData.best_lap or lapTime < pData.best_lap then
                pData.best_lap = lapTime
            end

            print(string.format("[Race Engine] %s completed lap %s in %s ms", pData.name, pData.current_lap - 1, lapTime))
            TriggerClientEvent("SPZ:lapComplete", source, pData.current_lap - 1, lapTime)

            if pData.current_lap > track.laps then
                HandleFinish(source, pData)
            else
                TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
            end
        else
            -- Sprint: all checkpoints cleared = finish
            HandleFinish(source, pData)
        end
    else
        -- Normal advance — send next checkpoint index to client
        TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
    end

    -- Recalculate positions for HUD updates
    if UpdateAllPositions then UpdateAllPositions() end
end

-- 11.4 Hit Validation
RegisterNetEvent("SPZ:checkpointHit", function(cpIndex)
    local src = source
    local pData = RaceSession.players[src]
    
    if not pData then return end
    if pData.finished or pData.dnf then return end
    if RaceSession.state ~= SPZ.RaceState.LIVE then return end

    -- Enforcement: Must be the correct next checkpoint (prevents skipping)
    if cpIndex ~= pData.current_cp then
        print(string.format("[Security] CP skip attempt by %s: expected %d, got %d", pData.name, pData.current_cp, cpIndex))
        return
    end

    -- Server-side progress update
    pData.current_cp = pData.current_cp + 1
    HandleCheckpointAdvance(src, pData)
end)

-- Export for external monitoring if needed
exports("HandleCheckpointAdvance", HandleCheckpointAdvance)
