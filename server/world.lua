-- server/world.lua

local spawnConfirmed = {}

function SetupRaceWorld()
    if RaceSession.state ~= SPZ.RaceState.WAITING then return end

    if not RaceSession.raceId then
        RaceSession.raceId = string.format("R%d", math.random(1000, 9999))
    end

    -- Enable ambient population in the race bucket only if players voted for
    -- traffic (light/heavy). "none" keeps the classic clean race world.
    local wantTraffic = RaceSession.trafficLevel and RaceSession.trafficLevel ~= "none"
    RaceSession.bucketId = exports["spz-core"]:CreateBucket(RaceSession.raceId, wantTraffic or false)

    -- CreateBucket applies STRICT entity lockdown (isolation), which also blocks
    -- the client-spawned AMBIENT traffic. So when traffic was voted, relax the
    -- lockdown so ambient vehicles/peds can actually populate the race world.
    if wantTraffic then
        SetRoutingBucketEntityLockdownMode(RaceSession.bucketId, "relaxed")
    end

    print(string.format("[World Setup] Bucket %d created for race %s (traffic: %s)",
        RaceSession.bucketId, RaceSession.raceId, tostring(RaceSession.trafficLevel or "none")))

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

    -- Kept on the session because the countdown needs the same centre line the
    -- grid was built around: the flag girl walks to it and the start camera
    -- frames it. Recomputing the heading there would risk the two drifting
    -- apart on a track that has no explicit start_heading.
    RaceSession.startHeading = startHeading

    -- Two placements, because the two phases want opposite things.
    --
    -- WARMUP spreads the field over a staggered grid: nothing is being won yet
    -- and separated slots are the safe way to put a full field on one road.
    --
    -- The RACE START collapses that to a ring on the start point, so no one is
    -- handed places by their slot before the lights go out. Both are computed
    -- here, up front, so every downstream consumer has coords even if the spawn
    -- thread aborts partway.
    local warmupGrid = SPZ.Math.GridPositions(
        RaceSession.track.start_coords,
        startHeading,
        #playersInOrder,
        Config.GridRowSpacing or 8.0,
        Config.GridColSpacing or 4.5,
        Config.WarmupSpawnMode or "grid"
    )

    local raceGrid = SPZ.Math.GridPositions(
        RaceSession.track.start_coords,
        startHeading,
        #playersInOrder,
        Config.GridRowSpacing or 8.0,
        Config.GridColSpacing or 4.5,
        Config.RaceStartMode or "split"
    )

    -- Warmup slots are what the cars are CREATED on, so this is the one the
    -- spawn loop below reads.
    local grid = warmupGrid

    -- Seed the whole grid up front. Populating this inside the spawn loop meant
    -- the timeout monitor's "allReady" test ran against a table holding only the
    -- players processed so far — one confirmed racer out of sixteen read as the
    -- entire grid being ready.
    spawnConfirmed = {}
    for i, src in ipairs(playersInOrder) do
        spawnConfirmed[src] = false

        -- Grid slots are assigned here, not inside the spawn thread, so every
        -- racer has coords even if that thread aborts partway: the warmup retry
        -- pass and the post-warmup TP-back both read gridCoords.
        local pData = RaceSession.players[src]
        if pData and warmupGrid[i] then
            pData.gridIndex   = i
            pData.gridCoords  = warmupGrid[i].coords
            pData.gridHeading = warmupGrid[i].heading

            -- Where this player is re-staged for the actual start. Falls back
            -- to the warmup slot so a mode that returned nothing can never
            -- leave a racer with no start position at all.
            local rp = raceGrid[i] or warmupGrid[i]
            pData.raceCoords  = rp.coords
            pData.raceHeading = rp.heading
        end
    end

    local chosenModel = (type(RaceSession.carClass) == "table" and RaceSession.carClass.model) or "sultan"
    local spawnRaceId = RaceSession.raceId
    local staggerMs   = Config.SpawnStaggerMs or 800

    Citizen.CreateThread(function()
        for i, src in ipairs(playersInOrder) do
            if i > 1 then
                -- Stagger exists so vehicle creations don't land on the same
                -- network tick, not to pace the race clock. At 5s a 16-player
                -- grid took 75s to spawn — long past the point the timeout
                -- monitor had already moved the session to WARMUP, so this loop
                -- kept spawning cars while StartWarmupSpawnGrace retried the
                -- same sources, and on a full grid it could still be running at
                -- COUNTDOWN.
                Citizen.Wait(staggerMs)
            end

            -- The session this loop was started for must still be the live one.
            if RaceSession.raceId ~= spawnRaceId then
                print("[World Setup] Grid spawn aborted — session changed mid-spawn.")
                return
            end
            if RaceSession.state ~= SPZ.RaceState.WAITING
            and RaceSession.state ~= SPZ.RaceState.WARMUP then
                print(string.format("[World Setup] Grid spawn aborted at %s — too late to add cars.",
                    tostring(RaceSession.state)))
                return
            end

            if RaceSession.players[src] and grid[i] then
                local gridPos = grid[i]

                exports["spz-core"]:AssignPlayerToBucket(src, RaceSession.bucketId)

                -- Ghosting is armed before any vehicle exists so collision is
                -- already off on the frame each remote car streams in.
                --
                -- It is NOT what keeps the grid safe, and it never was. Cars are
                -- spawned on separated slots (Config.SpawnMode) because the
                -- engine's interpenetration resolver ejects overlapping
                -- entities on creation, and no collision exclusion touches that
                -- path. Ghosting handles racing contact; geometry handles the
                -- grid. Putting the whole spawn on the flag is what threw cars
                -- across the map.

                local profile = Player(src).state.profile
                local hasLicense = (profile and profile.license_tier or 0) >= (RaceSession.carClassId or 0)
                local isRental = not hasLicense

                -- Bring the player to their grid slot BEFORE the vehicle spawns.
                -- Remote clients far from the track never get the grid vehicle into
                -- network scope, can't resolve its netId → upgrade timeout → abort.
                -- The owning client does this (see client/main.lua) — a
                -- server-side SetEntityCoords on a player ped is advisory only.
                TriggerClientEvent("SPZ:tpToGridPoint", src, gridPos.coords)
                Citizen.Wait(Config.GridTpSettleMs or 400)

                print(string.format("[World Setup] Staggered spawn #%d: '%s' for player %d at grid %d (Rental: %s)", i, chosenModel, src, i, tostring(isRental)))
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
            end
        end
    end)

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
            ClearRaceState(src)
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
                        if pData.gridCoords then
                            TriggerClientEvent("SPZ:tpToGridPoint", src, pData.gridCoords)
                            Citizen.Wait(Config.GridTpSettleMs or 400)
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
