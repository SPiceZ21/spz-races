-- config.lua
Config = {}

-- ── Queue ──────────────────────────────────────────────────────────────────
Config.MinPlayersToStart    = 1       -- min queue size to open poll
Config.PollWaitTime         = 2       -- seconds after threshold before poll opens
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
Config.SpawnTimeout         = 30000   -- ms to wait per player vehicle spawn (full chain)

-- ── Physics ────────────────────────────────────────────────────────────────
Config.RaceAssists = {
  tcs = true,
  abs = true,
  esc = false,
  lc  = true,
}
-- ── Post-race ──────────────────────────────────────────────────────────────
Config.ResultsDisplayTime   = 15000   -- ms stats screen shown before TP back

-- ── Intermission ───────────────────────────────────────────────────────────
Config.IntermissionTime     = 60      -- seconds between races

-- ── Grid ───────────────────────────────────────────────────────────────────
-- Passed to SPZ.Math.GridPositions
Config.GridRowSpacing       = 8.0     -- metres front-to-back
Config.GridColSpacing       = 4.5     -- metres side-to-side

-- ── Safe Zone ──────────────────────────────────────────────────────────────
-- Location players are sent after race cleanup. Set to your paddock / lobby spawn.
Config.SafeZone             = vector3(-1323.8, -1199.1, 4.0)
Config.SafeZoneHeading      = 210.0

-- ── Checkpoints ────────────────────────────────────────────────────────────
-- How long (ms) a racer can go without hitting any checkpoint before they are
-- automatically DNF'd for idling / going off-route.
Config.IdleKickMs           = 120000  -- 2 minutes

-- Range (metres) within which checkpoint flares become visible.
-- Active (next) checkpoint always shows at full scale within this range.
-- Other nearby checkpoints show at reduced scale.
Config.FlareRange           = 130.0

-- GPS route colour index (GTA colour palette, 51 = bright yellow).
Config.GpsRouteColour       = 51

-- ── Debug ──────────────────────────────────────────────────────────────────
Config.Debug                = false
