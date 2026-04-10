-- config.lua
Config = {}

-- ── Queue ──────────────────────────────────────────────────────────────────
Config.MinPlayersToStart    = 1       -- min queue size to open poll
Config.PollWaitTime         = 10      -- seconds after threshold before poll opens
Config.MaxPlayersPerRace    = 16      -- hard cap on queue size

-- ── Poll ───────────────────────────────────────────────────────────────────
Config.PollDuration         = 30      -- seconds the poll stays open
Config.PollOptionsPerType   = 2       -- track options per poll (always 2)

-- ── Cycle ──────────────────────────────────────────────────────────────────
-- Rotation order. Repeats.
-- "circuit" = multi-lap, "sprint" = point-to-point
Config.CycleOrder           = { "circuit", "sprint" }  -- alternates each race

-- ── Countdown ──────────────────────────────────────────────────────────────
Config.CountdownSeconds     = 3       -- 3-2-1-GO

-- ── Race ───────────────────────────────────────────────────────────────────
Config.RaceTimeout          = 300000  -- 5 minutes — DNF anyone not finished
Config.PositionBroadcastInterval = 1000   -- ms between live position updates
Config.SpawnTimeout         = 8000    -- ms to wait per player vehicle spawn

-- ── Post-race ──────────────────────────────────────────────────────────────
Config.ResultsDisplayTime   = 15000   -- ms stats screen shown before TP back

-- ── Intermission ───────────────────────────────────────────────────────────
Config.IntermissionTime     = 60      -- seconds between races

-- ── Grid ───────────────────────────────────────────────────────────────────
-- Passed to SPZ.Math.GridPositions
Config.GridRowSpacing       = 8.0     -- metres front-to-back
Config.GridColSpacing       = 4.5     -- metres side-to-side

-- ── Debug ──────────────────────────────────────────────────────────────────
Config.Debug                = false
