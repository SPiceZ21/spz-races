-- Initialize Global Framework Object if not already present
SPZ = SPZ or {}

-- 5.1 Race State Enum
SPZ.RaceState = {
  IDLE      = "IDLE",
  POLLING   = "POLLING",
  WAITING   = "WAITING",
  COUNTDOWN = "COUNTDOWN",
  LIVE      = "LIVE",
  ENDED     = "ENDED",
  CLEANUP   = "CLEANUP",
}

-- 4. Race Types
SPZ.RaceType = {
  CIRCUIT = "circuit",
  SPRINT  = "sprint",
}
