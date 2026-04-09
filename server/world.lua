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

    local playerCount = #playersInOrder
    local grid = SPZ.Math.GridPositions(
        RaceSession.track.start_coords,
        RaceSession.track.start_heading,
        playerCount
    )

    -- 8.3 Player Placement Sequence
    spawnConfirmed = {}
    
    for i, source in ipairs(playersInOrder) do
        local gridPos = grid[i]
        local player = RaceSession.players[source]
        
        -- Transfer to isolated bucket
        exports["spz-core"]:AssignPlayerToBucket(source, RaceSession.bucketId)
        
        -- Request vehicle spawn from dedicated vehicle manager
        -- Logic to select model based on carClass should be expanded in vehicles resource
        local chosenModel = "zentorno" -- Default race car for now
        
        exports["spz-vehicles"]:SpawnRaceVehicle(source, chosenModel, gridPos.coords, gridPos.heading)
        
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
        local timeoutMs = Config.SpawnTimeout * 1000
        
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

-- Client confirmation listener
RegisterNetEvent("SPZ:raceVehicleSpawned", function()
    local src = source
    if spawnConfirmed[src] ~= nil then
        spawnConfirmed[src] = true
        print(string.format("[World Setup] Player %s confirmed ready.", src))
    end
end)

-- Export for state machine trigger
exports("SetupRaceWorld", SetupRaceWorld)
