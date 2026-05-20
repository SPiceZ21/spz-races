-- server/world.lua

local spawnConfirmed = {}

function SetupRaceWorld()
    if RaceSession.state ~= SPZ.RaceState.WAITING then return end

    if not RaceSession.raceId then
        RaceSession.raceId = string.format("R%d", math.random(1000, 9999))
    end

    RaceSession.bucketId = exports["spz-core"]:CreateBucket(RaceSession.raceId)
    print(string.format("[World Setup] Bucket %d created for race %s",
        RaceSession.bucketId, RaceSession.raceId))

    -- Build ordered player list
    local playersInOrder = {}
    for src in pairs(RaceSession.players) do
        table.insert(playersInOrder, src)
    end

    -- Resolve grid heading
    local startHeading = RaceSession.track.start_heading
    if not startHeading then
        local sx = RaceSession.track.start_coords.x
        local sy = RaceSession.track.start_coords.y
        if RaceSession.track.checkpoints then
            for _, cp in ipairs(RaceSession.track.checkpoints) do
                local dx = cp.coords.x - sx
                local dy = cp.coords.y - sy
                if math.sqrt(dx * dx + dy * dy) > 5.0 then
                    startHeading = math.deg(math.atan2(-dx, dy)) % 360
                    break
                end
            end
        end
        startHeading = startHeading or 0.0
        print(string.format("[World Setup] Computed start heading: %.1f°", startHeading))
    end

    local grid = SPZ.Math.GridPositions(
        RaceSession.track.start_coords,
        startHeading,
        #playersInOrder,
        Config.GridRowSpacing or 8.0,
        Config.GridColSpacing or 4.5
    )

    spawnConfirmed = {}
    local chosenModel = (type(RaceSession.carClass) == "table" and RaceSession.carClass.model) or "sultan"

    for i, src in ipairs(playersInOrder) do
        local gridPos = grid[i]
        local player  = RaceSession.players[src]

        player.gridIndex = i

        exports["spz-core"]:AssignPlayerToBucket(src, RaceSession.bucketId)

        local profile = Player(src).state.profile
        local hasLicense = (profile and profile.license_tier or 0) >= (RaceSession.carClassId or 0)
        local isRental = not hasLicense

        print(string.format("[World Setup] Spawning '%s' for player %d at grid %d (Rental: %s)", chosenModel, src, i, tostring(isRental)))
        local ok, err = pcall(function()
            exports["spz-vehicles"]:SpawnRaceVehicle(src, chosenModel, gridPos.coords, gridPos.heading, isRental)
        end)
        if not ok then
            print(string.format("[World Setup] SpawnRaceVehicle failed for %d: %s", src, tostring(err)))
        end

        Player(src).state:set("inRace",       true,                    true)
        Player(src).state:set("raceId",       RaceSession.raceId,      true)
        Player(src).state:set("raceClass",    RaceSession.carClassId,  true)
        Player(src).state:set("raceTrack",    RaceSession.track.name,  true)
        Player(src).state:set("raceLap",      1,                       true)
        Player(src).state:set("racePosition", 0,                       true)
        Player(src).state:set("raceTime",     0,                       true)
        Player(src).state:set("dnf",          false,                   true)

        spawnConfirmed[src] = false
    end

    StartSpawnTimeoutMonitor()
end

function StartSpawnTimeoutMonitor()
    Citizen.CreateThread(function()
        local startTime = GetGameTimer()
        local timeoutMs = Config.SpawnTimeout or 8000

        while (GetGameTimer() - startTime) < timeoutMs do
            Citizen.Wait(500)

            local allReady = true
            for _, confirmed in pairs(spawnConfirmed) do
                if not confirmed then allReady = false; break end
            end

            if allReady then
                print("[World Setup] All players spawned. Applying no-collision.")
                ApplyRaceNoCollision()
                print("[World Setup] Transitioning to COUNTDOWN.")
                SetRaceState(SPZ.RaceState.COUNTDOWN)
                return
            end
        end

        HandleSpawnTimeout()
    end)
end

function HandleSpawnTimeout()
    print("[World Setup] Spawn timeout — reconciling grid.")

    for src, confirmed in pairs(spawnConfirmed) do
        if not confirmed then
            RaceSession.players[src] = nil
            exports["spz-core"]:AssignPlayerToBucket(src, 0)
            Player(src).state:set("inRace",  false, true)
            Player(src).state:set("inQueue", false, true)
        end
    end

    local remaining = 0
    for _ in pairs(RaceSession.players) do remaining = remaining + 1 end

    if remaining >= (Config.MinPlayersToStart or 2) then
        SetRaceState(SPZ.RaceState.COUNTDOWN)
    else
        print("[World Setup] Critical player loss — cancelling race.")
        ResetToIdle()
    end
end

-- Server-side TriggerEvent is resource-local in FiveM; spz-vehicles uses it so
-- we also expose an export as the reliable cross-resource confirmation path.
exports("ConfirmRaceSpawn", function(src)
    src = tonumber(src)
    if src and spawnConfirmed[src] ~= nil then
        spawnConfirmed[src] = true
        print(string.format("[World Setup] Player %d spawn confirmed (export).", src))
    end
end)

-- Kept for same-resource triggers / backward compat
AddEventHandler("SPZ:raceVehicleSpawned", function(src)
    if spawnConfirmed[src] ~= nil then
        spawnConfirmed[src] = true
        print(string.format("[World Setup] Player %d spawn confirmed (event).", src))
    end
end)

exports("SetupRaceWorld", SetupRaceWorld)
