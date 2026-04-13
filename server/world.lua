-- server/world.lua

local spawnConfirmed = {}

-- 8. Race World Setup Logic
function SetupRaceWorld()
    if RaceSession.state ~= SPZ.RaceState.WAITING then return end

    -- 8.1 Bucket Creation
    if not RaceSession.raceId then
        RaceSession.raceId = string.format("R%d", math.random(1000, 9999))
    end
    
    -- Ensure spz-core creates a unique routing bucket
    RaceSession.bucketId = exports["spz-core"]:CreateBucket(RaceSession.raceId)
    print(string.format("[World Setup] Isolated bucket %s created for race %s", RaceSession.bucketId, RaceSession.raceId))

    -- 8.2 Grid Positioning
    -- Create ordered list of participants
    local playersInOrder = {}
    for source, _ in pairs(RaceSession.players) do
        table.insert(playersInOrder, source)
    end
    -- In a real scenario, sort by join time or ELO here

    -- Derive spawn heading from track geometry so cars always face the right direction
    -- regardless of whether start_heading is set correctly in the track data.
    local startHeading = RaceSession.track.start_heading or 0
    local firstCP = RaceSession.track.checkpoints and RaceSession.track.checkpoints[1]
    if firstCP then
        local sx = RaceSession.track.start_coords.x
        local sy = RaceSession.track.start_coords.y
        local dx = firstCP.coords.x - sx
        local dy = firstCP.coords.y - sy
        -- GTA V heading: 0 = North (+Y), increases clockwise
        startHeading = math.deg(math.atan2(-dx, dy)) % 360
    end

    local playerCount = #playersInOrder
    local grid = SPZ.Math.GridPositions(
        RaceSession.track.start_coords,
        startHeading,
        playerCount,
        Config.GridRowSpacing or 8.0,
        Config.GridColSpacing or 4.5
    )

    -- 8.3 Player Placement Sequence
    spawnConfirmed = {}
    
    for i, source in ipairs(playersInOrder) do
        local gridPos = grid[i]
        local player = RaceSession.players[source]
        
        -- Transfer to isolated bucket
        exports["spz-core"]:AssignPlayerToBucket(source, RaceSession.bucketId)
        
        -- Request vehicle spawn from dedicated vehicle manager
        local chosenModel = RaceSession.carClass and RaceSession.carClass.model or "sultan"
        
        print(string.format("[World Setup] Spawning vehicle '%s' for player %s at grid %d", chosenModel, source, i))
        local spawnOk, spawnErr = pcall(function()
            exports["spz-vehicles"]:SpawnRaceVehicle(source, chosenModel, gridPos.coords, gridPos.heading)
        end)
        if not spawnOk then
            print(string.format("[World Setup] ERROR: SpawnRaceVehicle failed for %s: %s", source, tostring(spawnErr)))
        end
        
        -- Update identity state
        exports["spz-core"]:SetPlayerState(source, "RACING")
        
        spawnConfirmed[source] = false
    end

    -- Monitor spawn confirmations
    StartSpawnTimeoutMonitor()
end

function StartSpawnTimeoutMonitor()
    Citizen.CreateThread(function()
        local startTime = GetGameTimer()
        local timeoutMs = Config.SpawnTimeout or 8000
        
        while (GetGameTimer() - startTime) < timeoutMs do
            Citizen.Wait(500)
            
            local allReady = true
            for src, confirmed in pairs(spawnConfirmed) do
                if not confirmed then 
                    allReady = false 
                    break 
                end
            end
            
            if allReady then
                print("[World Setup] All players ready. Applying No-Collision.")
                
                -- Apply ghost mode between all participants
                exports["spz-races"]:ApplyRaceNoCollision()

                print("[World Setup] Transitioning to COUNTDOWN.")
                exports["spz-races"]:SetRaceState(SPZ.RaceState.COUNTDOWN)
                return
            end
        end
        
        HandleSpawnTimeout()
    end)
end

function HandleSpawnTimeout()
    print("[World Setup] WARNING: Spawn timeout reached. Reconciling grid.")
    local failedCount = 0
    for src, confirmed in pairs(spawnConfirmed) do
        if not confirmed then
            -- Clean up failed player
            RaceSession.players[src] = nil
            exports["spz-core"]:AssignPlayerToBucket(src, 0) -- Return to default bucket
            exports["spz-core"]:SetPlayerState(src, "IDLE")
            -- Refund logic would trigger here
            failedCount = failedCount + 1
        end
    end
    
    local remaining = 0
    for _ in pairs(RaceSession.players) do remaining = remaining + 1 end
    
    if remaining >= (Config.MinPlayersToStart or 2) then
        exports["spz-races"]:SetRaceState(SPZ.RaceState.COUNTDOWN)
    else
        print("[World Setup] ERROR: Critical player loss during setup. Cancellation required.")
        exports["spz-races"]:ResetToIdle()
    end
end

-- 11. Receive confirmation from spz-vehicles (server-to-server)
AddEventHandler("SPZ:raceVehicleSpawned", function(src, model, entity)
    if spawnConfirmed[src] ~= nil then
        spawnConfirmed[src] = true
        print(string.format("[World Setup] Player %s confirmed ready.", src))
    end
end)

-- Export for state machine trigger
exports("SetupRaceWorld", SetupRaceWorld)
