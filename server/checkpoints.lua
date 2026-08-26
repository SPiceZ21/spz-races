-- server/checkpoints.lua

-- ── 12.1 Finish handler ─────────────────────────────────────────────────────
local function HandleFinish(source, pData)
    if pData.finished or pData.dnf then return end

    pData.finished    = true
    pData.finish_time = GetGameTimer() - (pData.race_start_time or RaceSession.startTime)

    local track    = RaceSession.track
    local carClass = RaceSession.carClassId

    local prevBest      = LB_GetPersonalBest(source, track.name, carClass)
    pData.personal_best = (prevBest == nil) or (pData.finish_time < prevBest)
    if pData.personal_best then
        print(string.format("[Timing] New PB for %s on %s: %d ms", pData.name, track.name, pData.finish_time))
    end

    print(string.format("[Race] %s (%d) finished in %d ms (PB: %s)",
        pData.name, source, pData.finish_time, tostring(pData.personal_best)))

    if UpdateAllPositions then UpdateAllPositions() end

    -- Trigger client-side finish audio sound and state flag
    TriggerClientEvent("SPZ:raceFinished", source, pData.finish_time, pData.personal_best)

    -- First finisher arms the finish window for everyone still driving
    if not RaceSession.finishWindowArmed then
        RaceSession.finishWindowArmed = true
        StartFinishWindow()
    end

    -- Sprints have no laps — the whole run is the "lap" for raceline storage.
    -- (Circuit laps were already handed over at each lap boundary.)
    if track.type ~= "circuit" and GetResourceState("spz-raceline") == "started" then
        TriggerEvent("spz-raceline:lapCompleted", source, track.name, pData.finish_time)
    end

    -- ── Immediate Progression & Safe Zone Teleport for Finisher ────────────
    local indResult = {
        raceId    = RaceSession.raceId or "N/A",
        track     = track.name,
        trackId   = track.id or track.name,
        type      = track.type,
        carClass  = carClass,
        laps      = track.laps,
        duration  = pData.finish_time / 1000,
        finishers = {
            {
                source        = source,
                name          = pData.name,
                crew_tag      = pData.crew_tag,
                position      = pData.position or 1,
                finish_time   = pData.finish_time,
                lap_times     = pData.lap_times or {},
                best_lap      = pData.best_lap,
                sector_times  = pData.sector_times or {},
                best_sectors  = pData.best_sectors or {},
                personal_best = pData.personal_best or false,
                collisions    = pData.incidents or {},
                cleanRace     = (#(pData.incidents or {}) == 0),
                points_earned = (SPZ.PointsTable and SPZ.PointsTable[pData.position or 1]) or 0,
            }
        },
        dnf = {}
    }

    -- Process progression rewards & send SPZ:progressionUpdate to finisher
    if GetResourceState("spz-progression") == "started" then
        TriggerEvent("SPZ:raceEnd", indResult)
    end

    -- Send raceEnd event directly to this finisher so UI shows stats modal
    TriggerClientEvent("SPZ:raceEnd", source, indResult)

    -- Despawn race vehicle
    if GetResourceState("spz-vehicles") == "started" then
        pcall(function() exports["spz-vehicles"]:DespawnVehicle(source) end)
    end

    -- Return player to Freeroam Bucket 0
    if GetResourceState("spz-core") == "started" then
        exports["spz-core"]:AssignPlayerToBucket(source, 0)
    else
        SetPlayerRoutingBucket(source, 0)
    end

    -- Clear race statebags for this player
    Player(source).state:set("inRace",       false, true)
    Player(source).state:set("inQueue",      false, true)
    Player(source).state:set("queueClass",   nil,   true)
    Player(source).state:set("raceId",       nil,   true)
    Player(source).state:set("raceClass",    nil,   true)
    Player(source).state:set("raceTrack",    nil,   true)
    Player(source).state:set("racePosition", nil,   true)
    Player(source).state:set("raceLap",      nil,   true)
    Player(source).state:set("raceLaps",     nil,   true)
    Player(source).state:set("personalBest", nil,   true)
    Player(source).state:set("allTimeBest",  nil,   true)
    Player(source).state:set("raceTime",     nil,   true)

    -- Teleport finished player immediately to Safe Zone
    if pData and not pData.teleportedToSafeZone then
        pData.teleportedToSafeZone = true
        TriggerClientEvent("SPZ:tpToSafeZone", source)
    end

    CheckAllFinished()
end

-- ── 12.2 Checkpoint advance handler ────────────────────────────────────────
local function HandleCheckpointAdvance(source, pData)
    local track    = RaceSession.track
    local totalCPs = #track.checkpoints

    if pData.current_cp > totalCPs then
        if track.type == "circuit" then
            -- Lap completed
            local now          = GetGameTimer()
            local lapStartTime = pData.lap_start_time or RaceSession.startTime
            local lapTime      = now - lapStartTime

            pData.current_cp      = 1
            pData.current_lap     = pData.current_lap + 1
            pData.lap_start_time  = now
            pData.rewind_credit_lap = 0   -- per-lap credit budget resets with the lap
            StartSectorClock(pData, now)

            table.insert(pData.lap_times, lapTime)
            if not pData.best_lap or lapTime < pData.best_lap then
                pData.best_lap = lapTime
            end

            print(string.format("[Race] %s lap %d done in %d ms", pData.name, pData.current_lap - 1, lapTime))
            TriggerClientEvent("SPZ:lapComplete", source, pData.current_lap - 1, lapTime)

            -- spz-raceline stores the driven line iff this lap beats the
            -- player's stored best for the track (server-measured time).
            if GetResourceState("spz-raceline") == "started" then
                TriggerEvent("spz-raceline:lapCompleted", source, track.name, lapTime)
            end

            if pData.current_lap > track.laps then
                -- All laps done — wait for the start/finish cross
                pData.awaitingFinish = true
                TriggerClientEvent("SPZ:nextCheckpoint", source, 1)
            else
                TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
            end
        else
            -- Sprint: reaching end of CPs = instant finish
            HandleFinish(source, pData)
        end
    else
        TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
    end

    if UpdateAllPositions then UpdateAllPositions() end
end

-- ── 11.4 Hit validation ─────────────────────────────────────────────────────
RegisterNetEvent("SPZ:checkpointHit", function(cpIndex)
    local src   = source
    local pData = RaceSession.players[src]

    if not pData                                      then return end
    if pData.finished or pData.dnf                    then return end
    if RaceSession.state ~= SPZ.RaceState.LIVE        then return end
    if cpIndex ~= pData.current_cp                    then
        print(string.format("[Security] CP skip by %s: expected %d, got %d",
            pData.name, pData.current_cp, cpIndex))
        return
    end

    -- Circuit finish: player cleared all laps and crosses CP1 to stop the clock
    if pData.awaitingFinish and cpIndex == 1 then
        HandleFinish(src, pData)
        return
    end

    -- Record the time this CP was hit (used by the idle-kick watchdog below)
    local now = GetGameTimer()
    pData.last_cp_time = now

    -- Must run before current_cp advances: sectors close on the CP just hit.
    RecordSectorHit(src, pData, cpIndex, now)

    pData.current_cp = pData.current_cp + 1
    HandleCheckpointAdvance(src, pData)
end)

-- ── Rewind checkpoint rollback ───────────────────────────────────────────────
-- Fired by client/rewind.lua when a scrub lands before the last checkpoint the
-- player crossed. Backward-only and server-clamped: it can only ever push
-- current_cp EARLIER (more gates to re-cross), never skip one, so a spoofed
-- or stale target is a harmless no-op at worst.
RegisterNetEvent("SPZ:rewindCheckpoint", function(targetCp)
    local src   = source
    local pData = RaceSession.players[src]
    if not pData                               then return end
    if pData.finished or pData.dnf             then return end
    if RaceSession.state ~= SPZ.RaceState.LIVE then return end

    targetCp = tonumber(targetCp)
    if not targetCp or targetCp < 1 or targetCp >= pData.current_cp then return end

    pData.current_cp     = targetCp
    pData.awaitingFinish = false
    TriggerClientEvent("SPZ:nextCheckpoint", src, targetCp)
end)

-- ── Rewind clock credit ──────────────────────────────────────────────────────
-- The client scrubbed `ms` of driving away, so the same `ms` comes off this
-- racer's clocks: the car and its time land on the same moment. Implemented by
-- shifting the epochs forward rather than carrying a separate offset, so every
-- derived number (race time, lap time, sector time, the idle watchdog) follows
-- automatically. Clamped hard — this reaches the leaderboard:
--   • one claim can never exceed the history buffer (× the credit factor)
--   • the running total per lap is capped at maxCreditPerLapMs
--   • no epoch can move past now, so elapsed times stay >= 0
-- Ceiling for a SINGLE scrub: the whole history buffer, plus the real time it
-- takes to play that buffer back at the scrub speed (the clock is put back on
-- the car's moment, so both halves count), plus a second of slack.
local function _maxRewindCredit(cfg, factor)
    local bufMs = (cfg.bufferSeconds or 10) * 1000
    local mult  = math.max(0.1, cfg.playbackSpeedMult or 2.5)
    return math.floor((bufMs * (1.0 + 1.0 / mult) + 1000) * factor)
end

RegisterNetEvent("SPZ:rewindTime", function(ms)
    local src   = source
    local pData = RaceSession.players[src]
    if not pData                               then return end
    if pData.finished or pData.dnf             then return end
    if RaceSession.state ~= SPZ.RaceState.LIVE then return end

    local cfg    = Config.Rewind or {}
    local factor = math.max(0.0, math.min(1.0, cfg.timeCreditFactor or 1.0))
    if factor <= 0.0 then return end

    ms = math.floor(tonumber(ms) or 0)
    if ms <= 0 or ms > _maxRewindCredit(cfg, factor) then return end

    local used    = pData.rewind_credit_lap or 0
    local allowed = math.max(0, (cfg.maxCreditPerLapMs or 60000) - used)
    ms = math.min(ms, allowed)
    if ms <= 0 then return end

    local now   = GetGameTimer()
    local start = RaceSession.startTime or now

    pData.rewind_credit_lap = used + ms
    pData.race_start_time = math.min((pData.race_start_time or start) + ms, now)
    pData.lap_start_time  = math.min((pData.lap_start_time  or start) + ms, now)
    if pData.sector_start then
        pData.sector_start = math.min(pData.sector_start + ms, now)
    end
end)

-- ── Idle-kick watchdog ──────────────────────────────────────────────────────
-- If a racer has not crossed a single checkpoint within Config.IdleKickMs during
-- a live race they are assumed to have given up / gone AFK and are DNF'd.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(10000)  -- check every 10 s (low overhead)

        if RaceSession and RaceSession.state == SPZ.RaceState.LIVE then
            local cutoff = GetGameTimer() - (Config.IdleKickMs or 120000)

            for src, pData in pairs(RaceSession.players) do
                -- .disconnected racers are managed by the reconnect window,
                -- not the idle kick (their CP clock is legitimately stalled)
                if not pData.finished and not pData.dnf and not pData.disconnected then
                    local lastHit = pData.last_cp_time or RaceSession.startTime or 0
                    if lastHit < cutoff then
                        print(string.format("[Idle-Kick] %s (%d) timed out — no CP in %d s",
                            pData.name, src, (Config.IdleKickMs or 120000) / 1000))
                        MarkDNF(src, "idle")
                    end
                end
            end
        end
    end
end)

exports("HandleCheckpointAdvance", HandleCheckpointAdvance)
