-- server/leaderboard/standings.lua

function LB_GetGlobalStandings(limit)
    limit = math.min(limit or LBConfig.DefaultStandingsLimit, LBConfig.MaxStandingsLimit)
    local cacheKey = ("standings:global:%d"):format(limit)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    -- Row-level columns plus the career aggregates the expanded panel shows.
    local rows = MySQL.query.await(
        [[SELECT
            p.id,
            p.username       AS name,
            p.rank           AS rank_title,
            p.license_tier,
            p.alltime_points AS points,
            p.sr,
            p.i_rating       AS iRating,
            p.level,
            p.avatar_url     AS avatar,
            p.playtime,
            p.last_race_track,
            p.last_race_at,
            p.created_at,
            COUNT(rr.id)                                            AS races,
            SUM(CASE WHEN rr.position = 1 THEN 1 ELSE 0 END)        AS wins,
            SUM(CASE WHEN rr.position <= 3 AND rr.dnf = 0 THEN 1 ELSE 0 END) AS podiums,
            SUM(CASE WHEN rr.dnf = 1 THEN 1 ELSE 0 END)             AS dnfs,
            AVG(NULLIF(rr.position, 99))                            AS avg_position
          FROM players p
          LEFT JOIN race_results rr ON rr.player_id = p.id
          WHERE p.banned = 0
          GROUP BY p.id
          ORDER BY p.alltime_points DESC, p.sr DESC
          LIMIT ?]],
        { limit }
    ) or {}

    local standings = {}
    for i, row in ipairs(rows) do
        local races = tonumber(row.races) or 0
        local wins  = tonumber(row.wins) or 0
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
            avatar      = row.avatar,
            -- expanded panel only
            total_races  = races,
            wins         = wins,
            podiums      = tonumber(row.podiums) or 0,
            dnfs         = tonumber(row.dnfs) or 0,
            win_rate     = races > 0 and (wins / races) or 0,
            avg_position = tonumber(row.avg_position) or 0,
            playtime     = tonumber(row.playtime) or 0,
            last_track   = row.last_race_track,
            last_race_at = tonumber(row.last_race_at) or 0,
            joined_at    = row.created_at,
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
            p.avatar_url     AS avatar,
            p.alltime_points,
            p.sr,
            p.i_rating       AS iRating,
            p.level,
            p.last_race_track,
            p.last_race_at,
            COUNT(rr.id)     AS total_races,
            SUM(CASE WHEN rr.position = 1 THEN 1 ELSE 0 END) AS wins,
            SUM(CASE WHEN rr.position <= 3 AND rr.dnf = 0 THEN 1 ELSE 0 END) AS podiums,
            SUM(CASE WHEN rr.dnf = 1 THEN 1 ELSE 0 END)      AS dnfs,
            AVG(NULLIF(rr.position, 99))                     AS avg_position,
            MIN(NULLIF(rr.best_lap, 0))                      AS best_lap_ms
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
            avatar      = row.avatar,
            -- expanded panel only
            iRating      = tonumber(row.iRating) or 1000,
            level        = tonumber(row.level) or 1,
            podiums      = tonumber(row.podiums) or 0,
            dnfs         = tonumber(row.dnfs) or 0,
            avg_position = tonumber(row.avg_position) or 0,
            best_lap_ms  = tonumber(row.best_lap_ms) or nil,
            best_lap_f   = row.best_lap_ms and LB_FormatTime(row.best_lap_ms) or nil,
            last_track   = row.last_race_track,
            last_race_at = tonumber(row.last_race_at) or 0,
        })
    end

    LBCache.Set(cacheKey, standings, LBConfig.StandingsCacheTTL)
    return standings
end
