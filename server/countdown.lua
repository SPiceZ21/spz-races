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

        -- Re-teleport each player back to their grid slot (still frozen)
        for src, data in pairs(RaceSession.players) do
            if data.gridCoords then
                TriggerClientEvent("SPZ:tpToGrid", src, {
                    coords  = data.gridCoords,
                    heading = data.gridHeading or 0.0,
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

        -- Backfill the grid with ghost-bots (uses the GO clock just set).
        if SpawnRaceBots then SpawnRaceBots() end

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
