-- server/leaderboard/standings.lua

function LB_GetGlobalStandings(limit)
    limit = math.min(limit or LBConfig.DefaultStandingsLimit, LBConfig.MaxStandingsLimit)
    local cacheKey = ("standings:global:%d"):format(limit)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows = MySQL.query.await(
        [[SELECT
            p.username       AS name,
            p.rank           AS rank_title,
            p.license_tier,
            p.alltime_points AS points,
            p.sr,
            p.i_rating       AS iRating,
            p.level
          FROM players p
          WHERE p.banned = 0
          ORDER BY p.alltime_points DESC, p.sr DESC
          LIMIT ?]],
        { limit }
    ) or {}

    local standings = {}
    for i, row in ipairs(rows) do
        table.insert(standings, {
            rank        = i,
            name        = row.name or "Racer",
            crewTag     = nil,
            rank_title  = row.rank_title or "D-5",
            tier        = LBConfig.TierToClass[row.license_tier] or "D",
            level       = row.level or 1,
            points      = row.points or 0,
            sr          = row.sr or 3.0,
            iRating     = row.iRating or 1000,
        })
    end

    LBCache.Set(cacheKey, standings, LBConfig.StandingsCacheTTL)
    return standings
end

-- classLetter: "S","A","B","C","D"
function LB_GetClassStandings(classLetter, limit)
    limit = math.min(limit or LBConfig.DefaultStandingsLimit, LBConfig.MaxStandingsLimit)
    local tier = LBConfig.ClassToTier[classLetter] or 5
    local cacheKey = ("standings:class:%s:%d"):format(classLetter, limit)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows = MySQL.query.await(
        [[SELECT
            p.username       AS name,
            p.rank           AS rank_title,
            p.class_points   AS points,
            p.alltime_points,
            p.sr,
            COUNT(rr.id)     AS total_races,
            SUM(CASE WHEN rr.position = 1 THEN 1 ELSE 0 END) AS wins
          FROM players p
          LEFT JOIN race_results rr ON rr.player_id = p.id
          WHERE (p.license_tier = ? OR ? = 5) AND p.banned = 0
          GROUP BY p.id
          ORDER BY p.class_points DESC, p.alltime_points DESC
          LIMIT ?]],
        { tier, tier, limit }
    ) or {}

    local standings = {}
    for i, row in ipairs(rows) do
        local tr = tonumber(row.total_races) or 0
        local w = tonumber(row.wins) or 0
        table.insert(standings, {
            rank        = i,
            name        = row.name or "Racer",
            crewTag     = nil,
            rank_title  = row.rank_title or "D-5",
            points      = row.points or 0,
            sr          = row.sr or 3.0,
            total_races = tr,
            wins        = w,
            win_rate    = tr > 0 and (w / tr) or 0,
        })
    end

    LBCache.Set(cacheKey, standings, LBConfig.StandingsCacheTTL)
    return standings
end
