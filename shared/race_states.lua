-- Initialize Global Framework Object
SPZ = exports["spz-lib"]:GetCoreObject()

-- 5.1 Race State Enum
SPZ.RaceState = {
  IDLE      = "IDLE",
  POLLING   = "POLLING",
  WAITING   = "WAITING",
  WARMUP    = "WARMUP",    -- free-drive lap before staging
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
