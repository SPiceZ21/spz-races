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

-- ── Warmup (90s freeroam + customization window) ────────────────────────────
Config.WarmupTimeSeconds    = 90      -- free-drive after TP before countdown (0 = skip)
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

-- Overtake auto-clips. A pass triggers a real VIDEO clip recorded from the
-- overtaker's screen via `screencapture`, uploaded to FiveManage, and posted
-- to Discord. Recording starts the instant the pass is detected (so the clip
-- contains the overtake, not just the aftermath) and runs ClipDurationS.
-- Cooldown is per overtaking pair to stop spam in a back-and-forth battle.
Config.OvertakeCooldown = 20000
Config.Clip = {
  enabled     = true,
  durationS   = 10,     -- seconds of video captured per overtake
  maxWidth    = 1280,
  maxHeight   = 720,
  -- FiveManage: create a Media API token at https://fivemanage.com and paste
  -- it here. Without a token the clip system falls back to a screenshot still,
  -- then to a text-only Discord post.
  fivemanageUrl   = "https://api.fivemanage.com/api/v3/file",
  fivemanageToken = "",   -- e.g. "fmapi_xxxxxxxxxxxxxxxx"
}
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

-- ── Ghost-bots (cold-start field filler) ────────────────────────────────────
-- Thin races are backfilled with "ghost-bots": real stored human lines
-- (spz-raceline) replayed as SOLID, non-collidable cars driven by their
-- recorded timing. They fill the grid, appear in the live standings and push
-- your visible position, but grant NO rewards and do NOT affect
-- iRating/XP — humans are scored only against humans.
--
-- Requires stored lines on the track (someone must have driven it). A brand-new
-- track with zero lines simply gets no bots until one is set.
Config.Bots = {
  enabled     = true,
  targetField = 6,       -- top the grid up to this many total cars
  onlyWhenSolo = false,  -- true = bots only when you are the single human
  labelRange  = 80.0,    -- metres within which the floating "BOT" label draws
}

-- ── Ghost duels (async PvP wagers) ──────────────────────────────────────────
-- /duel <player|id> <track> <stake> — race an opponent's STORED best line (a
-- ghost) for credits. Reuses the Time-Trial harness (bucket, CP timing, ghost).
-- Server-authoritative: it compares its measured lap to the stored best_ms.
Config.Duel = {
  Enabled  = true,
  MinStake = 100,
  MaxStake = 10000,
  -- HouseFunded = true  → winnings are a house bounty; the (possibly offline)
  --   opponent is NEVER charged. Winner nets +stake (stake back + matched bonus).
  -- HouseFunded = false → the opponent's balance covers the matched stake: they
  --   lose it if their ghost is beaten, win the challenger's stake if it holds.
  --   Charges an offline player without consent — off by default.
  HouseFunded = true,
  -- Car for the challenger when the opponent's stored model can't be resolved to
  -- a registered race vehicle.
  FallbackModel = "sultan",
}

-- ── Debug ──────────────────────────────────────────────────────────────────
Config.Debug                = false

-- Personalised lap count per circuit by track length (server/lapcount.lua).
-- Long tracks get fewer laps, short tracks more, so total race distance stays
-- roughly even. Sprints are always 1 lap.
-- Threshold ~ the median lap length across all 75 circuits (~9.5 km), so the
-- split is roughly even: longer half = 2 laps, shorter half = 3.
Config.LongTrackMetres = 9500.0   -- a lap longer than this counts as "long"
Config.LongTrackLaps   = 2
Config.ShortTrackLaps  = 3

-- ── Rewind (Forza Horizon-style time rewind) ────────────────────────────────
-- Hold the key to scrub the car backward along its recent path; release to
-- resume driving from that point with the momentum it had back then. Bounded
-- only by the rolling history buffer — no use cap, no cooldown beyond a short
-- settle after release. Works in live Race (LIVE state) and Time Trial.
-- No leaderboard exploit: checkpoints must still be crossed for real, so every
-- gate you scrub back past has to be re-driven at racing speed.
Config.Rewind = {
  enabled           = true,
  key               = "R",
  bufferSeconds     = 10,     -- how far back you can scrub
  recordIntervalMs  = 66,     -- ~15 Hz history sampling
  playbackSpeedMult = 2.5,    -- scrub speed vs real time (10s buffer plays back in 4s)
  resumeCooldownMs  = 350,    -- short lockout after releasing before rewinding again

  -- ── Clock credit ─────────────────────────────────────────────────────────
  -- The clock rewinds WITH the car: scrub back 4 s and the race/lap timer runs
  -- backward by 4 s too, so the car and its time land at the same moment. That
  -- is what makes a rewind read as "undo" instead of "teleport + penalty".
  --   1.0 = full refund (Forza) · 0.0 = clock keeps running (old behaviour)
  --   anything between = partial refund, i.e. a rewind costs you the difference
  timeCreditFactor  = 1.0,
  -- Server-side ceiling on how much clock a single lap/run can win back, no
  -- matter how many rewinds are chained. Nothing above this is credited.
  maxCreditPerLapMs = 60000,
}

-- ── In-world record boards ─────────────────────────────────────────────────
-- Physical floating scoreboards showing the fastest lap holders for a track.
-- Walk near one and the top times render in the world. Each board is pinned to
-- a track name (must match a key/name in data/tracks.lua). Add as many as you
-- like — e.g. one at spawn, one at each track's start line.
Config.RecordBoards = {
    -- { coords = vector3(x, y, z), heading = 0.0, track = "10-80" },
    -- Removed: this board sat right on the after-race safe-zone TP spot
    -- (SafeZone -1323.8,-1199.1) so it rendered in the player's face every race.
    -- { coords = vector3(-1327.5, -1196.0, 5.6), heading = 120.0, track = "10-80" },
}
Config.BoardRange   = 12.0     -- metres: render when the player is this close
Config.BoardRefresh = 30000    -- ms between record re-fetches
