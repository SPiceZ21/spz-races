-- server/leaderboard/config.lua
-- Absorbed from spz-leaderboard. All leaderboard tunables live here.

LBConfig = {}

LBConfig.DefaultStandingsLimit = 25
LBConfig.MaxStandingsLimit     = 100

LBConfig.DefaultRecordsLimit   = 15
LBConfig.MaxRecordsLimit       = 50

LBConfig.HistoryPageSize       = 20

LBConfig.StandingsCacheTTL     = 30    -- seconds
LBConfig.RecordsCacheTTL       = 60
LBConfig.StatsCacheTTL         = 15

-- Map class letter → license_tier integer (mirrors spz-identity)
LBConfig.ClassToTier = { S=1, A=2, B=3, C=4, D=5 }
LBConfig.TierToClass = { [1]="S", [2]="A", [3]="B", [4]="C", [5]="D" }
