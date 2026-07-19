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

        player.gridIndex   = i
        player.gridCoords  = gridPos.coords
        player.gridHeading = gridPos.heading

        exports["spz-core"]:AssignPlayerToBucket(src, RaceSession.bucketId)

        -- Ghost BEFORE any vehicle exists: with one-point spawning every car
        -- overlaps, so collision must already be off on the very first frame
        -- each remote vehicle streams in.

        local profile = Player(src).state.profile
        local hasLicense = (profile and profile.license_tier or 0) >= (RaceSession.carClassId or 0)
        local isRental = not hasLicense

        -- Bring the player to their grid slot BEFORE the vehicle spawns.
        -- Remote clients far from the track never get the grid vehicle into
        -- network scope, can't resolve its netId → upgrade timeout → abort.
        local ped = GetPlayerPed(src)
        if ped and ped > 0 then
            SetEntityCoords(ped, gridPos.coords.x, gridPos.coords.y, gridPos.coords.z + 1.0)
        end

        print(string.format("[World Setup] Spawning '%s' for player %d at grid %d (Rental: %s)", chosenModel, src, i, tostring(isRental)))
        local ok, err = pcall(function()
            exports["spz-vehicles"]:SpawnRaceVehicle(src, chosenModel, gridPos.coords, gridPos.heading, isRental)
        end)
        if not ok then
            print(string.format("[World Setup] SpawnRaceVehicle failed for %d: %s", src, tostring(err)))
        end

        local pb = 0
        local tb = 0
        pcall(function()
            pb = LB_GetPersonalBest(src, RaceSession.track.name, RaceSession.carClassId) or 0
            local records = LB_GetTrackRecords(RaceSession.track.name, RaceSession.carClassId, 1)
            tb = records and records[1] and records[1].lap_time_ms or 0
        end)

        Player(src).state:set("inRace",       true,                    true)
        Player(src).state:set("raceId",       RaceSession.raceId,      true)
        Player(src).state:set("raceClass",    RaceSession.carClassId,  true)
        Player(src).state:set("raceTrack",    RaceSession.track.name,  true)
        Player(src).state:set("raceLap",      1,                       true)
        Player(src).state:set("raceLaps",     RaceSession.track.laps or 1, true)
        Player(src).state:set("personalBest", pb,                      true)
        Player(src).state:set("allTimeBest",  tb,                      true)
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
        local hardMs    = Config.SpawnTimeout or 30000
        local graceMs   = Config.FirstReadyGraceMs or 5000
        local firstAt   = nil

        -- Phase 1: advance as soon as everyone is ready, OR shortly after the
        -- FIRST racer is ready. Stragglers keep spawning through the warmup.
        while (GetGameTimer() - startTime) < hardMs do
            Citizen.Wait(500)

            local anyReady, allReady = false, true
            for _, confirmed in pairs(spawnConfirmed) do
                if confirmed then anyReady = true else allReady = false end
            end

            if allReady then break end
            if anyReady then
                firstAt = firstAt or GetGameTimer()
                if (GetGameTimer() - firstAt) >= graceMs then break end
            end
        end

        local anyReady = false
        for _, confirmed in pairs(spawnConfirmed) do
            if confirmed then anyReady = true break end
        end

        if not anyReady then
            print("[World Setup] Nobody spawned — cancelling race.")
            ReconcileUnconfirmed()   -- clears everyone, resets to idle
            return
        end

        local warmup    = (Config.WarmupTimeSeconds or 0) > 0
        local nextState = warmup and SPZ.RaceState.WARMUP or SPZ.RaceState.COUNTDOWN
        print(string.format("[World Setup] Transitioning to %s.", nextState))
        SetRaceState(nextState)

        if warmup then
            StartWarmupSpawnGrace()   -- keep retrying stragglers during warmup
        else
            ReconcileUnconfirmed()    -- no warmup → cut stragglers now
        end
    end)
end

-- Remove anyone whose vehicle never confirmed. Called at warmup end (or
-- immediately when there is no warmup phase).
function ReconcileUnconfirmed()
    local cut = 0
    for src, confirmed in pairs(spawnConfirmed) do
        if not confirmed and RaceSession.players[src] then
            RaceSession.players[src] = nil
            exports["spz-core"]:AssignPlayerToBucket(src, 0)
            Player(src).state:set("inRace",  false, true)
            Player(src).state:set("inQueue", false, true)
            if GetPlayerName(src) then
                SPZ.Notify(src, "Your vehicle failed to spawn in time — you'll auto-join the next race.", "error", 6000)
            end
            cut = cut + 1
        end
    end
    if cut > 0 then
        print(("[World Setup] Reconciled grid — %d unspawned player(s) removed."):format(cut))
    end

    local remaining = 0
    for _ in pairs(RaceSession.players) do remaining = remaining + 1 end
    if remaining < 1 then
        print("[World Setup] Critical player loss — cancelling race.")
        ResetToIdle()
    end
end

-- Warmup = spawn grace window for slow networks / low-end PCs. Every few
-- seconds, retry the full spawn chain for anyone still unconfirmed (their
-- previous vehicle may have been deleted by the upgrade timeout).
function StartWarmupSpawnGrace()
    Citizen.CreateThread(function()
        while RaceSession.state == SPZ.RaceState.WARMUP do
            Citizen.Wait(Config.SpawnRetryIntervalMs or 8000)
            if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

            local chosenModel = (type(RaceSession.carClass) == "table" and RaceSession.carClass.model) or "sultan"

            for src, confirmed in pairs(spawnConfirmed) do
                local pData = RaceSession.players[src]
                if not confirmed and pData and GetPlayerName(src) then
                    local active = exports["spz-vehicles"]:GetPlayerVehicle(src)
                    if not active then
                        print(("[World Setup] Warmup grace: retrying spawn for %d"):format(src))
                        local ped = GetPlayerPed(src)
                        if ped and ped > 0 and pData.gridCoords then
                            SetEntityCoords(ped, pData.gridCoords.x, pData.gridCoords.y, pData.gridCoords.z + 1.0)
                        end
                        pcall(function()
                            exports["spz-vehicles"]:SpawnRaceVehicle(
                                src, chosenModel, pData.gridCoords, pData.gridHeading, true)
                        end)
                    end
                end
            end
        end
    end)
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
