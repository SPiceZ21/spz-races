-- server/checkpoints.lua

-- ── 12.1 Finish handler ─────────────────────────────────────────────────────
local function HandleFinish(source, pData)
    if pData.finished or pData.dnf then return end

    pData.finished    = true
    pData.finish_time = GetGameTimer() - (pData.race_start_time or RaceSession.startTime)

    local track    = RaceSession.track
    local carClass = RaceSession.carClassId

    -- A run that won clock back off a rewind is not comparable to a clean one,
    -- so it can be a finishing time but never a personal best or a record.
    local rewound  = (pData.rewind_credit_total or 0) > 0
    local prevBest = LB_GetPersonalBest(source, track.name, carClass)
    pData.personal_best = (not rewound) and ((prevBest == nil) or (pData.finish_time < prevBest))
    if pData.personal_best then
        print(string.format("[Timing] New PB for %s on %s: %d ms", pData.name, track.name, pData.finish_time))
    elseif rewound then
        print(string.format("[Timing] %s finished with %d ms of rewind credit — not eligible for PB/record",
            pData.name, pData.rewind_credit_total))
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
    if track.type ~= "circuit" and not rewound
    and GetResourceState("spz-raceline") == "started" then
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
                rewind_ms     = pData.rewind_credit_total or 0,
                collisions    = pData.incidents or {},
                cleanRace     = (#(pData.incidents or {}) == 0),
                points_earned = (SPZ.PointsTable and SPZ.PointsTable[pData.position or 1]) or 0,
            }
        },
        dnf = {}
    }

    -- Per-finisher notification for modules that want to react the moment a
    -- racer crosses the line (telemetry, feeds, showcase). NOT "SPZ:raceEnd":
    -- that name is the end-of-session contract, and firing it here ran every
    -- SPZ:raceEnd listener once per finisher AND again from results.lua —
    -- double XP/SR/iRating in spz-progression, duplicate race_results rows,
    -- and a Discord post per finisher. All scoring and persistence now
    -- happens exactly once, in ProcessRaceResults.
    TriggerEvent(SPZ.Events.RACER_FINISHED, source, indResult)

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
    ClearRaceState(source)

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
            local lapRewound   = (pData.rewind_credit_lap or 0) > 0

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
            -- player's stored best for the track (server-measured time). A
            -- rewound lap is excluded: those lines become ghost-bots and duel
            -- targets, so a line whose time was partly refunded would seed an
            -- unbeatable ghost.
            if not lapRewound and GetResourceState("spz-raceline") == "started" then
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

-- Proximity check for a claimed crossing. The client decides WHEN it crossed
-- (it owns the frame-accurate gate plane), but the server decides WHETHER it
-- could have: without this, a modified client can spam sequential
-- SPZ:checkpointHit calls and take a track record and the XP without moving. Server-side ped coords lag the owning client by a network
-- tick, so the radius is deliberately generous — it rejects teleport-scripting,
-- not close racing.
local CP_HIT_RADIUS = 75.0

local function CanClaimCheckpoint(src, cp)
    if not cp or not cp.coords then return true end   -- malformed track data: don't punish
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return true end

    local pos = GetEntityCoords(ped)
    local dx, dy, dz = pos.x - cp.coords.x, pos.y - cp.coords.y, pos.z - cp.coords.z
    local radius = math.max(CP_HIT_RADIUS, (cp.radius or 0.0) * 3.0)
    return (dx * dx + dy * dy + dz * dz) <= (radius * radius)
end

-- ── Progress history (for real time gaps) ───────────────────────────────────
-- A gap is only honest in seconds if you can answer "how long ago was the car
-- ahead standing where I am now?". That needs a timestamp per racer per gate,
-- which the engine did not keep — so the live tower fell back to "+2 CP", a
-- unit nobody can read as pace.
--
-- Progress index = gates cleared since GO, so it keeps counting across a lap
-- boundary and is directly comparable between two racers on different laps:
--   idx = (lap - 1) * numCPs + cpIndex
--
-- Stored value is elapsed-since-GO, on the racer's OWN epoch, so it matches the
-- race clock they see (a rewind shifts that epoch, and the gap follows).
function RecordCPProgress(pData, cpIndex, now)
    local track  = RaceSession.track
    local numCPs = (track and track.checkpoints and #track.checkpoints) or 0
    if numCPs < 1 then return end

    local idx     = ((pData.current_lap or 1) - 1) * numCPs + cpIndex
    local elapsed = now - (pData.race_start_time or RaceSession.startTime or now)

    pData.cp_history = pData.cp_history or {}
    pData.cp_history[idx] = elapsed
    pData.progress_idx    = idx
end

-- Elapsed-since-GO at a given progress index, or nil if this racer has not
-- reached it yet.
function CPProgressAt(pData, idx)
    local h = pData and pData.cp_history
    return h and h[idx] or nil
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

    local cp = RaceSession.track and RaceSession.track.checkpoints
               and RaceSession.track.checkpoints[cpIndex]
    if not CanClaimCheckpoint(src, cp) then
        print(string.format("[Security] CP %d claimed by %s from out of range — rejected",
            cpIndex, pData.name))
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

    -- Bank the crossing against a track-wide progress index so live gaps can be
    -- stated in SECONDS instead of "+2 CP". See RecordCPProgress.
    RecordCPProgress(pData, cpIndex, now)

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

    -- Those gates have to be re-crossed, so their banked crossing times are no
    -- longer true. Drop everything at or beyond the rollback point; re-crossing
    -- rewrites them, and the gap tower reads the racer at their real position.
    local track  = RaceSession.track
    local numCPs = (track and track.checkpoints and #track.checkpoints) or 0
    if numCPs > 0 and pData.cp_history then
        local from = ((pData.current_lap or 1) - 1) * numCPs + targetCp
        for idx in pairs(pData.cp_history) do
            if idx >= from then pData.cp_history[idx] = nil end
        end
        pData.progress_idx = math.max(0, from - 1)
    end

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
    local allowed = math.max(0, (cfg.maxCreditPerLapMs or 15000) - used)
    ms = math.min(ms, allowed)
    if ms <= 0 then return end

    local now   = GetGameTimer()
    local start = RaceSession.startTime or now

    pData.rewind_credit_lap = used + ms
    -- Whole-run total, never reset at a lap boundary. A time that won back any
    -- clock is not comparable to one driven clean, so this flag follows the
    -- result through to the leaderboard and blocks records/PBs.
    pData.rewind_credit_total = (pData.rewind_credit_total or 0) + ms
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
