Config = {}

-- 4.3 Poll Behaviour by Type
-- true: both options are the same type, alternating each race
-- false: mixed pool (not currently the default mentioned by user)
Config.AlternateTypes = true 
Config.MinPlayersToStart = 2

Config.DefaultLaps = {
  min = 3,
  max = 5
}

-- Race State Timeouts (Seconds)
Config.Timeouts = {
  POLLING   = 30, -- or all voted
  WAITING   = 10, -- confirm spawn
  COUNTDOWN = 5,  -- GO signal
  RACE_MAX  = 600, -- 10 mins fallback
  CLEANUP   = 10
}
