-- server/countdown.lua

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
        TriggerClientEvent("SPZ:stagingEnd", -1)
        print("[Countdown] Staging complete — starting 3-2-1")

        -- ── 3-2-1 COUNTDOWN ────────────────────────────────────────────
        _runThreeTwoOne()

        -- ── GO ─────────────────────────────────────────────────────────
        RaceSession.startTime = GetGameTimer()
        TriggerClientEvent("SPZ:go", -1)
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
