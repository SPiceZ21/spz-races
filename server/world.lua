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

    -- Resolve spawn heading: prefer the explicitly-authored track heading.
    -- Circuit tracks have checkpoint[1] = start_coords, so computing from that
    -- gives atan2(0,0)=0 (due north) regardless of the actual track direction.
    -- Only fall back to geometry when start_heading is missing, and skip any
    -- checkpoint that sits on (or within 5 m of) the start position.
    local startHeading = RaceSession.track.start_heading

    if not startHeading then
        -- Geometry fallback: find the first checkpoint meaningfully ahead
        local sx = RaceSession.track.start_coords.x
        local sy = RaceSession.track.start_coords.y
        if RaceSession.track.checkpoints then
            for _, cp in ipairs(RaceSession.track.checkpoints) do
                local dx = cp.coords.x - sx
                local dy = cp.coords.y - sy
                -- Skip checkpoints that are basically at the start line
                if math.sqrt(dx * dx + dy * dy) > 5.0 then
                    startHeading = math.deg(math.atan2(-dx, dy)) % 360
                    break
                end
            end
        end
        startHeading = startHeading or 0.0
        print(string.format("[World Setup] No start_heading in track data — computed %.1f° from geometry", startHeading))
    else
        print(string.format("[World Setup] Using track start_heading: %.1f°", startHeading))
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
        
        -- Force competitive racing assists
        if GetResourceState("spz-physics") == "started" then
            exports["spz-physics"]:SetAssists(source, Config.RaceAssists)
        end

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
    print(string.format("[World Setup] DEBUG: Received SPZ:raceVehicleSpawned for player %s", src))
    if spawnConfirmed[src] ~= nil then
        spawnConfirmed[src] = true
        print(string.format("[World Setup] Player %s confirmed ready.", src))
    else
        print(string.format("[World Setup] WARNING: Received confirmation for unknown player %s", src))
    end
end)

-- Export for state machine trigger
exports("SetupRaceWorld", SetupRaceWorld)
