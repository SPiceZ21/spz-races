-- server/countdown.lua

-- ── 9. Warmup Phase ──────────────────────────────────────────────────────────
--
-- Entered from WARMUP state.  Players are unfrozen at their grid positions;
-- they may drive around the whole track to scout it or inspect their vehicle.
-- After WarmupTimeSeconds the server re-teleports everyone to their grid slot,
-- freezes them, then transitions to COUNTDOWN for the normal 3-2-1.

function StartWarmupPhase()
    if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

    local warmupTotal = Config.WarmupTimeSeconds or 60
    print(string.format("[Warmup] Free-drive phase started: %d seconds", warmupTotal))

    -- Unfreeze — let players drive
    for src, _ in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:freezeRacer", src, false)
    end

    Citizen.CreateThread(function()
        local remaining = warmupTotal

        while remaining > 0 do
            -- Abort early if state changed externally (e.g. not-enough-players cancel)
            if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

            for src, data in pairs(RaceSession.players) do
                TriggerClientEvent("SPZ:warmupPhase", src, {
                    remaining   = remaining,
                    total       = warmupTotal,
                    track       = RaceSession.track.name,
                    class       = type(RaceSession.carClass) == "table"
                                    and RaceSession.carClass.name
                                    or  tostring(RaceSession.carClass),
                    laps        = RaceSession.track.laps,
                    gridPos     = data.gridIndex or 0,
                })
            end

            Citizen.Wait(1000)
            remaining = remaining - 1
        end

        if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

        -- Warmup was the spawn grace window — anyone whose vehicle still
        -- hasn't confirmed is cut now, before staging.
        if ReconcileUnconfirmed then ReconcileUnconfirmed() end
        if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

        -- Late confirmers weren't in the initial ghosting pass

        -- Signal clients warmup is over so HUD can clear the timer
        BroadcastToRacers("SPZ:warmupEnd")
        print("[Warmup] Phase complete — re-staging players on grid")

        -- Freeze FIRST: freezing only after the TP left a ~2s window where
        -- players could drive off the grid before the countdown started.
        for src, _ in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:freezeRacer", src, true)
        end

        -- Re-teleport each player onto their RACE start slot (still frozen).
        --
        -- Deliberately not the warmup grid slot they spawned on: that is a
        -- staggered grid, and starting a race from it hands row 1 roughly 56
        -- metres over row 8 on a full field — places decided before the lights.
        -- The race placement collapses the field onto a ring at the start point
        -- so every car covers the same distance (Config.RaceStartMode).
        --
        -- Falls back to the warmup slot for a session staged before this
        -- existed, so an in-flight race can never be left with nowhere to go.
        for src, data in pairs(RaceSession.players) do
            local coords  = data.raceCoords  or data.gridCoords
            local heading = data.raceHeading or data.gridHeading or 0.0
            if coords then
                TriggerClientEvent("SPZ:tpToGrid", src, {
                    coords  = coords,
                    heading = heading,
                })
            end
        end

        -- Wait for the client-side TP to settle, then re-assert the freeze
        -- (the teleport can knock the vehicle loose on some clients)
        Citizen.Wait(1500)
        for src, _ in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:freezeRacer", src, true)
        end

        -- Brief pause, then hand off to COUNTDOWN (staging → 3-2-1)
        Citizen.Wait(500)

        SetRaceState(SPZ.RaceState.COUNTDOWN)
    end)
end

exports("StartWarmupPhase", StartWarmupPhase)

-- ── 10. Staging + Countdown Sequence ─────────────────────────────────────
--
-- Flow:
--   COUNTDOWN state entered
--     → Freeze all players on grid
--     → Send checkpoints so map blips appear (spawnCheckpoints already sent by
--       state_machine.lua when entering COUNTDOWN, so clients already have them)
--     → STAGING PHASE: Config.StagingTimeSeconds (default 60) — players sit
--       frozen, can see the full track on the map and inspect their car
--     → 3-2-1 COUNTDOWN: Config.CountdownSeconds (default 3)
--     → GO — unfreeze, unlock vehicles, transition to LIVE

local function _broadcastStagingTick(remaining, total)
    local totalPlayers = 0
    for _ in pairs(RaceSession.players) do totalPlayers = totalPlayers + 1 end

    for source, data in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:stagingPhase", source, {
            remaining   = remaining,
            total       = total,
            track       = RaceSession.track.name,
            class       = type(RaceSession.carClass) == "table" and RaceSession.carClass.name or tostring(RaceSession.carClass),
            laps        = RaceSession.track.laps,
            gridPos     = data.gridIndex or 0,
            totalRacers = totalPlayers,
        })
    end
end

local function _runThreeTwoOne()
    local remaining = Config.CountdownSeconds or 3
    local totalPlayers = 0
    for _ in pairs(RaceSession.players) do totalPlayers = totalPlayers + 1 end

    while remaining > 0 do
        for source, data in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:countdown", source, {
                seconds = remaining,
                -- Length of the whole count, so the HUD can draw a staging
                -- tree with one lamp per second instead of assuming three.
                totalSeconds = Config.CountdownSeconds or 5,
                track   = RaceSession.track.name,
                class   = type(RaceSession.carClass) == "table" and RaceSession.carClass.name or tostring(RaceSession.carClass),
                laps    = RaceSession.track.laps,
                gridPos = data.gridIndex or 0,
                total   = totalPlayers,
            })
        end
        print(string.format("[Countdown] T-minus %d", remaining))
        Citizen.Wait(1000)
        remaining = remaining - 1
    end
end

function StartCountdownSequence()
    if RaceSession.state ~= SPZ.RaceState.COUNTDOWN then return end

    print("[Countdown] Initiating race start sequence.")

    -- Freeze all players at their grid positions
    for source, _ in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:freezeRacer", source, true)
    end

    -- The grid is formed and nobody can move: hand the clients the centre line
    -- so the flag girl can walk out to it and the start camera can frame it.
    --
    -- Sent once, here, rather than on every countdown tick — it is a property
    -- of the grid, not of the clock, and the walk-in has to start well before
    -- the last three seconds to land on time.
    local startCoords  = RaceSession.track.start_coords
    local startHeading = RaceSession.startHeading or RaceSession.track.start_heading or 0.0

    -- How long until the lights go out, from THIS moment. Everything in the
    -- start sequence is timed backwards off this single number rather than
    -- each piece guessing its own duration: the camera push lands on GO, and
    -- the flag girl's walk and swing are fitted into what is left. Change the
    -- two config values and the whole sequence re-times itself.
    local goInMs = ((Config.StagingTimeSeconds or 9) + (Config.CountdownSeconds or 5)) * 1000

    for source, data in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:gridFormed", source, {
            coords    = startCoords,
            heading   = startHeading,
            goInMs    = goInMs,
            staging   = Config.StagingTimeSeconds or 9,
            countdown = Config.CountdownSeconds or 5,
            gridPos   = data.gridIndex or 0,
        })
    end

    Citizen.CreateThread(function()

        -- ── STAGING PHASE ──────────────────────────────────────────────
        -- Players are frozen on grid; they can see the full track, look around,
        -- and prepare. Car customisation menus (if any) may open here.
        local stagingTotal   = Config.StagingTimeSeconds or 60
        local stagingRemain  = stagingTotal

        print(string.format("[Countdown] Staging phase: %d seconds", stagingTotal))

        while stagingRemain > 0 do
            _broadcastStagingTick(stagingRemain, stagingTotal)
            Citizen.Wait(1000)
            stagingRemain = stagingRemain - 1
        end

        -- Signal clients that staging ended (HUD can clear the staging timer)
        BroadcastToRacers("SPZ:stagingEnd")
        print("[Countdown] Staging complete — starting 3-2-1")

        -- ── 3-2-1 COUNTDOWN ────────────────────────────────────────────
        _runThreeTwoOne()

        -- ── GO ─────────────────────────────────────────────────────────
        RaceSession.startTime = GetGameTimer()

        -- Sector clocks start with the race clock, not on the first CP hit.
        ResetSessionSectors()
        for source, pData in pairs(RaceSession.players) do
            InitPlayerSectors(source, pData, RaceSession.track.name, RaceSession.carClassId)
            StartSectorClock(pData, RaceSession.startTime)
        end

        BroadcastToRacers("SPZ:go")
        print("[Countdown] RACE LIVE")

        -- Start timeout watchdog
        StartRaceTimeoutWatchdog()

        -- Unfreeze and unlock vehicles
        for source, _ in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:freezeRacer", source, false)
            if GetResourceState("spz-vehicles") == "started" then
                exports["spz-vehicles"]:UnlockRaceVehicle(source)
            end
        end

        -- Advance state machine
        exports["spz-races"]:SetRaceState(SPZ.RaceState.LIVE)
    end)
end

-- ── Race timeout watchdog ─────────────────────────────────────────────────
function StartRaceTimeoutWatchdog()
    Citizen.CreateThread(function()
        local maxTimeMs = Config.RaceTimeout or 3600000
        local startTime = GetGameTimer()

        while (GetGameTimer() - startTime) < maxTimeMs do
            Citizen.Wait(5000)
            if RaceSession.state ~= SPZ.RaceState.LIVE then return end
        end

        if RaceSession.state == SPZ.RaceState.LIVE then
            print("[Race Engine] Race timeout reached — forcing DNF for remaining players.")
            for source, data in pairs(RaceSession.players) do
                if not data.finished and not data.dnf then
                    ProcessDNF(source, "timeout")
                end
            end
        end
    end)
end

exports("StartCountdownSequence", StartCountdownSequence)
