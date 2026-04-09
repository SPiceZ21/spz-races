-- server/checkpoints.lua

-- 11.4 & 11.5 Checkpoint & Lap Logic
local function HandleFinish(source, pData)
    if pData.finished or pData.dnf then return end
    
    pData.finished = true
    pData.finish_time = GetGameTimer() - (pData.race_start_time or RaceSession.startTime)
    
    print(string.format("[Race Engine] Player %s (%s) finished! Time: %s ms", pData.name, source, pData.finish_time))
    
    TriggerClientEvent("SPZ:raceFinished", source, pData.finish_time)
    
    -- Update positions one last time
    if UpdateAllPositions then UpdateAllPositions() end
    
    -- Check if everyone is finished or DNF to end the session
    local allDone = true
    for _, p in pairs(RaceSession.players) do
        if not p.finished and not p.dnf then
            allDone = false
            break
        end
    end
    
    if allDone then
        print("[Race Engine] All participants finished. Ending race.")
        exports["spz-races"]:SetRaceState(SPZ.RaceState.ENDED)
    end
end

local function HandleCheckpointAdvance(source, pData)
    local track = RaceSession.track
    local totalCPs = #track.checkpoints

    if pData.current_cp > totalCPs then
        -- Crossed the last CP — lap complete (Circuit)
        if track.type == "circuit" then
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

            -- Check if all laps done
            if pData.current_lap > track.laps then
                HandleFinish(source, pData)
            else
                -- Loop back to first CP
                TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
            end
        else
            -- Sprints shouldn't really reach here if the logic below handles finish on CP=totalCPs
            HandleFinish(source, pData)
        end
    else
        -- Handle SPRINT finish or regular CP advance
        if track.type == "sprint" and pData.current_cp == totalCPs then
            -- Note: In sprint, the last checkpoint is the finish line.
            -- Actually, some sprint layouts might have a final CP that needs to be crossed.
            -- If current_cp == totalCPs, and they just hit it, they should finish.
            HandleFinish(source, pData)
        else
            -- Advance to next checkpoint for rendering
            TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
        end
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
