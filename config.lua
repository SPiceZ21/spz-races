-- config.lua
Config = {}

-- ── Queue ──────────────────────────────────────────────────────────────────
-- No minimum player count: the FIRST player to join arms a join window that
-- counts down for everyone ("race starting in Ns — press E"). Whoever is in
-- the queue when it expires races; latecomers can still join during the polls.
Config.JoinWindowSeconds    = 30      -- countdown armed by the first joiner
Config.MinPlayersToStart    = 1       -- legacy floor — only used as "queue empty" check
Config.PollWaitTime         = 2       -- (legacy, unused by the join-window flow)
Config.MaxPlayersPerRace    = 16      -- hard cap on queue size

-- ── Poll ───────────────────────────────────────────────────────────────────
Config.PollDuration         = 30      -- seconds the poll stays open
Config.PollOptionsPerType   = 2       -- track options per poll (always 2)

-- ── Cycle ──────────────────────────────────────────────────────────────────
-- Rotation order. Repeats.
-- "circuit" = multi-lap, "sprint" = point-to-point
Config.CycleOrder           = { "circuit", "sprint" }  -- alternates each race

-- ── Warmup (60s freeroam + customization window) ────────────────────────────
Config.WarmupTimeSeconds    = 60      -- free-drive after TP before countdown (0 = skip)
                                      -- players practice-drive the track and/or open the
                                      -- tuner menu (/savecustom etc.) to set up their car

-- ── Countdown ──────────────────────────────────────────────────────────────
Config.StagingTimeSeconds   = 3       -- brief SILENT grid settle after warmup TP-back
                                      -- (no on-screen count; keeps players frozen while
                                      --  the TP settles, then the 3-2-1-GO plays)
Config.CountdownSeconds     = 3       -- 3-2-1-GO

-- ── Race ───────────────────────────────────────────────────────────────────
Config.RaceTimeout          = 3600000  -- 60 minutes — DNF anyone not finished (was 5 mins)
Config.PositionBroadcastInterval = 1000   -- ms between live position updates
Config.SpawnTimeout         = 30000   -- ms hard ceiling when NOBODY has spawned yet

-- Warmup doubles as spawn grace: once the FIRST racer is ready, the race moves
-- on after this delay and slow clients keep spawning during the whole warmup
-- (with automatic retries). They're only cut at warmup end.
Config.FirstReadyGraceMs    = 5000    -- ms after first confirm before advancing
Config.SpawnRetryIntervalMs = 8000    -- ms between respawn retries during warmup

-- ── Mid-race reconnect ──────────────────────────────────────────────────────
-- A crash/timeout during a LIVE race no longer means instant DNF: the grid
-- slot is held this long, and rejoining restores lap/checkpoint/time at the
-- last crossed checkpoint. Must be shorter than IdleKickMs.
Config.ReconnectWindowMs    = 60000

-- ── Incidents (clean-race / SR) ─────────────────────────────────────────────
-- Racers are ghosted from each other, so a tracked incident is a hard impact
-- with the world (walls, barriers, props). The client detects these and
-- reports them; spz-progression converts the count into an SR penalty and
-- gates the clean-race bonus. Kept lenient so light kerb-hopping is ignored.
Config.Incidents = {
  enabled           = true,
  minImpactSpeed    = 30,     -- km/h below which an impact is ignored
  minSpeedDropKmh   = 22,     -- sudden speed loss in one frame that counts as a hit
  minBodyDamage     = 45.0,   -- body-health drop that counts as a hit
  cooldownMs        = 1500,   -- ignore repeat hits within this window (one crash = one incident)
  startBufferMs     = 3000,   -- ignore impacts in the first N ms after GO (grid shuffle)
  maxPerRace        = 20,     -- hard cap on reported incidents (anti-spam)
}

-- ── Physics ────────────────────────────────────────────────────────────────
Config.RaceAssists = {
  tcs = true,
  abs = true,
  esc = false,
  lc  = true,
}
-- ── Post-race ──────────────────────────────────────────────────────────────
Config.ResultsDisplayTime   = 12000   -- ms stats screen shown before TP back

-- Armed by the FIRST finisher: everyone still driving gets this long to cross
-- the line, then they're force-DNF'd and results fire. Stops the podium from
-- waiting minutes on cruisers (the 120s idle-kick only catches AFK, not slow).
Config.FinishWindowSeconds  = 180

-- ── Intermission ───────────────────────────────────────────────────────────
-- Runs OVERLAPPED with the results screen: the countdown starts the moment
-- results appear, not after they close.
Config.IntermissionTime     = 30      -- seconds between races

-- ── Grid ───────────────────────────────────────────────────────────────────
-- Passed to SPZ.Math.GridPositions
-- "grid" = staggered F1 grid · "point" = everyone at the start point
Config.SpawnMode            = "point"
Config.PointSpawnRadius     = 0.0     -- 0 = exact same spot (safe: ghosting is
                                      -- armed before vehicles spawn); >0 = ring
Config.GridRowSpacing       = 8.0     -- metres front-to-back (grid mode)
Config.GridColSpacing       = 4.5     -- metres side-to-side (grid mode)

-- ── Safe Zone ──────────────────────────────────────────────────────────────
-- Location players are sent after race cleanup. Set to your paddock / lobby spawn.
Config.SafeZone             = vector3(-1323.8, -1199.1, 4.0)
Config.SafeZoneHeading      = 210.0

-- ── Checkpoints ────────────────────────────────────────────────────────────
-- How long (ms) a racer can go without hitting any checkpoint before they are
-- automatically DNF'd for idling / going off-route.
Config.IdleKickMs           = 120000  -- 2 minutes

-- Range (metres) within which checkpoint gate props are spawned.
-- Beyond this the props are removed again to keep the entity count low.
Config.GateRange            = 130.0

-- GPS route colour index (GTA colour palette, 51 = bright yellow).
Config.GpsRouteColour       = 51

-- ── Debug ──────────────────────────────────────────────────────────────────
Config.Debug                = false
