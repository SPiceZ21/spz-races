-- server/timing.lua

function OnCheckPointHit(playerSource, checkpointIndex)
    local player = RaceSession.players[playerSource]
    if not player or player.finished or player.dnf then return end
    
    -- Check if it's the expected checkpoint
    if checkpointIndex ~= player.current_cp then return end

    local track = RaceSession.track
    if not track then return end

    local totalCheckpoints = #track.checkpoints
    
    if RaceSession.raceType == SPZ.RaceType.CIRCUIT then
        -- CIRCUIT LOGIC
        -- CP[1] -> CP[2] -> ... -> CP[N] -> CP[1] (lap 2)
        if checkpointIndex == totalCheckpoints then
            -- Last CP hit, next is 1
            player.current_cp = 1
        else
            player.current_cp = checkpointIndex + 1
        end

        -- Finish trigger: current_lap > track.laps after crossing CP[1]
        -- Crossing CP[1] starts a new lap
        if checkpointIndex == 1 then
            local timeNow = GetGameTimer()
            local lapTime = timeNow - (player.lastLapStartTime or RaceSession.startTime)
            table.insert(player.lap_times, lapTime)
            player.lastLapStartTime = timeNow
            
            if not player.best_lap or lapTime < player.best_lap then
                player.best_lap = lapTime
            end

            player.current_lap = player.current_lap + 1
            
            -- If we just completed the last lap
            if player.current_lap > track.laps then
                FinishPlayer(playerSource)
            end
        end

    elseif RaceSession.raceType == SPZ.RaceType.SPRINT then
        -- SPRINT LOGIC
        -- Finish trigger: current_cp > #track.checkpoints
        player.current_cp = player.current_cp + 1
        
        if player.current_cp > totalCheckpoints then
            FinishPlayer(playerSource)
        end
    end

    -- Update position logic (interfacing with positions.lua)
    UpdateAllPositions()
end

function FinishPlayer(playerSource)
    local player = RaceSession.players[playerSource]
    player.finished = true
    player.finish_time = GetGameTimer() - RaceSession.startTime
    
    print(string.format("[Race Engine] Player %s finished in %s ms", player.name, player.finish_time))
    
    -- Check if all finished
    -- End race logic
end

RegisterNetEvent("spz_race:checkpoint_hit", function(checkpointIndex)
    local src = source
    OnCheckPointHit(src, checkpointIndex)
end)
