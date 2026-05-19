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

-- Map class letter → license_tier integer (mirrors spz-identity: 0=C 1=B 2=A 3=S)
LBConfig.ClassToTier = { C=0, B=1, A=2, S=3 }
LBConfig.TierToClass = { [0]="C", [1]="B", [2]="A", [3]="S" }
