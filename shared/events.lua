-- shared/events.lua
-- Race event-name registry.
--
-- This file was empty while every event name in the engine lived as a raw
-- string literal, repeated across eight resources. A typo in any one of them is
-- silent: the handler simply never fires, and the feature looks "sometimes
-- broken" rather than wrong.
--
-- SPZ.Events comes from '@spz-core/shared/events.lua' (loaded ahead of this
-- file in fxmanifest.lua). The race names are merged into the same table rather
-- than replacing it, so the core names stay valid here and load order between
-- the two files cannot lose entries.
--
-- Consumers in OTHER resources get these by adding
--   '@spz-core/shared/events.lua'
-- to their shared_scripts; each FiveM resource has its own Lua state, so the
-- table is not visible across resources without that import.

SPZ = SPZ or {}
SPZ.Events = SPZ.Events or {}

local RaceEvents = {
    -- ── Server-local, cross-resource ──────────────────────────────────────────
    -- Fired exactly once per race, from ProcessRaceResults. This is the
    -- end-of-session contract: scoring, persistence and payouts hang off it, so
    -- nothing else may emit it. See RACER_FINISHED for the per-racer signal.
    RACE_END        = "SPZ:raceEnd",

    -- One racer crossed the line. Fires once per finisher, carries a
    -- single-finisher results payload. For reactive things (feeds, telemetry,
    -- showcase) — never for scoring, because the field is still incomplete.
    RACER_FINISHED  = "SPZ:racerFinished",

    -- Live running order, humans + ghost-bots. Throttled separately from the
    -- racer HUD feed (Config.StandingsBroadcastInterval).
    STANDINGS       = "SPZ:standings",

    -- All three sectors purple within one lap.
    PERFECT_LAP     = "SPZ:perfectLap",

    -- Race lifecycle state transitions (mirrors GlobalState.raceState).
    RACE_STATE      = "SPZ:raceStateChanged",

    -- ── Server → client ───────────────────────────────────────────────────────
    GO              = "SPZ:go",
    COUNTDOWN       = "SPZ:countdown",
    WARMUP_PHASE    = "SPZ:warmupPhase",
    WARMUP_END      = "SPZ:warmupEnd",
    STAGING_PHASE   = "SPZ:stagingPhase",
    STAGING_END     = "SPZ:stagingEnd",
    NEXT_CHECKPOINT = "SPZ:nextCheckpoint",
    SPAWN_CPS       = "SPZ:spawnCheckpoints",
    LAP_COMPLETE    = "SPZ:lapComplete",
    SECTOR_COMPLETE = "SPZ:sectorComplete",
    POSITION_UPDATE = "SPZ:positionUpdate",
    RACE_FINISHED   = "SPZ:raceFinished",
    PLAYER_DNF      = "SPZ:playerDNF",
    FREEZE_RACER    = "SPZ:freezeRacer",
    TP_TO_GRID      = "SPZ:tpToGrid",
    TP_TO_GRID_PT   = "SPZ:tpToGridPoint",
    TP_TO_SAFE_ZONE = "SPZ:tpToSafeZone",
    INTERMISSION    = "SPZ:intermissionStart",
    JOIN_WINDOW     = "SPZ:joinWindow",
    QUEUE_UPDATED   = "SPZ:queueUpdated",
    POLL_OPEN       = "SPZ:pollOpen",
    POLL_CLOSED     = "SPZ:pollClosed",
    POLL_RESULT     = "SPZ:pollResult",

    -- ── Client → server ───────────────────────────────────────────────────────
    CHECKPOINT_HIT  = "SPZ:checkpointHit",
    REPORT_INCIDENT = "SPZ:reportIncident",
    REWIND_CP       = "SPZ:rewindCheckpoint",
    REWIND_TIME     = "SPZ:rewindTime",
    REQUEST_RESYNC  = "SPZ:requestResync",
    JOIN_QUEUE      = "SPZ:joinQueue",
    LEAVE_QUEUE     = "SPZ:leaveQueue",
    POLL_VOTE       = "SPZ:pollVote",
}

for key, name in pairs(RaceEvents) do
    -- A collision here means two registries disagree on the same key, which is
    -- exactly the drift this file exists to stop.
    if SPZ.Events[key] and SPZ.Events[key] ~= name then
        print(("^1[spz-races] Event registry conflict on %s: '%s' vs '%s'^0")
            :format(key, SPZ.Events[key], name))
    end
    SPZ.Events[key] = name
end
