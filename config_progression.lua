-- config_progression.lua — XP, SR, iRating and rank points rules.
-- Moved from spz-progression/config.lua when it was merged into spz-races. Read as Config.Progression.<option>.

-- spz-progression/config.lua
Config.Progression = {}
local Config = Config.Progression
-- ══════════════════════════════════════════════════════════════════════════
--  RANK (ranking v3) — the ONE rules table for rank. See Docs/ranking-design.md
--  and Docs/report-v3/ranking-v3.pdf. Rank is display/prestige only: nothing
--  may gate cars, tracks or classes on it.
-- ══════════════════════════════════════════════════════════════════════════
Config.Rules = {
  version = 3,

  -- Ladder: 4 classes x 5 sub-ranks (5 = entry, 1 = top). RP to enter each
  -- class and the RP step between its sub-ranks. Titles come from
  -- spz-identity/shared/ranks.lua (SPZ.RankNames).
  tiers = {
    { id = 0, letter = "C", enter = 0,    step = 50   },
    { id = 1, letter = "B", enter = 250,  step = 180  },
    { id = 2, letter = "A", enter = 1150, step = 540  },
    { id = 3, letter = "S", enter = 3850, step = 1000 },
  },
  boardSize = 100,           -- S-1 players numbered #1..#100

  -- The formula
  slope         = 60,        -- RP between last and winner (before weight)
  breakEven     = 0.35,      -- finishing percentile where base RP is ~0
  participation = 2,         -- flat RP for taking part
  weightDivisor = 5,         -- w = min(1, (N-1)/weightDivisor): full from 6 players
  strengthScale = 2000,      -- RP difference that moves the field factor by 1.0
  strengthMin   = 0.5,
  strengthMax   = 1.5,

  -- Big fields (there is NO maximum field size anywhere)
  podium            = { 10, 6, 3 },  -- extra RP for P1..P3
  podiumFrom        = 8,             -- 0 at N <= 8 ...
  podiumFull        = 24,            -- ... full from N >= 24
  streakTopFraction = 0.10,          -- streak zone = top max(3, ceil(10% of N))
  streakTopMin      = 3,

  -- Supports (raise gains only)
  clean       = 0.15,        -- zero incidents
  streakStep  = 0.05,        -- per consecutive streak-zone finish
  streakMax   = 0.20,
  boostCap    = 1.5,
  perfectLap  = 10,          -- flat RP, granted on SPZ:perfectLap
  trackRecord = 10,          -- flat RP, granted on spz-raceline:recordTaken

  -- Safety
  ratedMinField      = 2,    -- N below this: no RP / SR / iRating / top-3 change
  minDurationSeconds = 45,   -- shorter races are void
  dailyCap           = 300,  -- max positive RP per UTC day
}

-- ── Pace tuning (XP only) ─────────────────────────────────────────────────
Config.Pace = "MEDIUM"  -- "CASUAL"|"MEDIUM"|"HARDCORE"

Config.PaceMultipliers = {
  CASUAL   = { xp = 1.50 },
  MEDIUM   = { xp = 1.00 },
  HARDCORE = { xp = 0.65 },
}

-- ── XP rewards (level is a reward, not a rank input) ──────────────────────
Config.XPRewards = {
  positions  = { 250, 175, 125, 100, 85, 75, 65, 55 },
  dnf        = 25,
  perLap     = 10,           -- max 5 laps counted
  maxLapBonus = 50,
  cleanRace  = 25,
  personalBest = 50,
  trackRecord  = 100,
}

-- Car class multiplier on XP (keyed by class letter or tier number).
Config.ClassMultipliers = {
  [0] = 1.00, C = 1.00, D = 1.00,
  [1] = 1.25, B = 1.25,
  [2] = 1.50, A = 1.50,
  [3] = 1.75, S = 1.75,
}

-- ── SR (display stat) ─────────────────────────────────────────────────────
Config.SR = {
  finishGain        = 0.05,
  top3Gain          = 0.10,
  top5Gain          = 0.05,
  pbGain            = 0.03,
  dnfPenalty        = -0.20,
  collisionPenalty  = -0.02,
  collisionCapPerRace = -0.10,
  dailyMaxGain      = 0.50,
  dailyMaxLoss      = -0.40,
  startingValue     = 2.0,
  min               = 0.00,
  max               = 5.00,
}

-- ── iRating (display stat + rival matching) — zero-sum pairwise Elo ───────
Config.IRating = {
  k             = 32,
  startingValue = 1500,
  min           = 0,
  max           = 5000,
}

-- ── Bonus modifiers ───────────────────────────────────────────────────────
Config.Bonuses = {
  comeback = {
    minPositionsGained = 5,
    xpBonus           = 50,
  },
}

-- ── Perfect lap (all sectors purple in one lap) ────────────────────────────
Config.PerfectLap = {
  xp      = 150,
  credits = 500,
}

-- ── Anti-abuse (XP) ───────────────────────────────────────────────────────
Config.AntiAbuse = {
  minSecondsBetweenRaces  = 60,    -- below halves XP
  minFinishersForFullXP   = 3,
  smallRacePenalty        = 0.50,  -- multiplier when < min finishers
  sameTrackThreshold      = 4,     -- penalty after this many races same track
  sameTrackPenalty4       = 0.75,
  sameTrackPenalty5plus   = 0.50,
}

