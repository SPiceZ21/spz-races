-- server/leaderboard/stats.lua

local function FormatHistoryRows(rows)
    local formatted = {}
    for _, row in ipairs(rows) do
        local cls = row.car_class
        if type(cls) == "number" then
            cls = LBConfig.TierToClass[cls] or "C"
        end
        table.insert(formatted, {
            track           = row.track or "Unknown",
            car_class       = cls or "D",
            finish_position = row.position or 0,
            best_lap_ms     = row.best_lap or 0,
            points_earned   = row.points_earned or 0,
            sr_delta        = row.sr_change or 0,
            raced_at        = row.created_at or "",
            dnf             = row.dnf == 1,
        })
    end
    return formatted
end

local EMPTY_STATS = {
    total_races = 0, wins = 0, podiums = 0, dnfs = 0,
    win_rate = 0, podium_rate = 0, dnf_rate = 0,
    avg_position = 0, total_points = 0, total_xp = 0,
    best_lap_ms = nil, best_lap_track = nil, iRating = 1000, sr = 3.0
}

function LB_GetPlayerStats(source)
    local cacheKey = "stats:" .. tostring(source)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(source) end)
    if not ok or not profile then return EMPTY_STATS end

    local agg = MySQL.query.await(
        [[SELECT
            COUNT(*)                                           AS total_races,
            SUM(CASE WHEN position  = 1   THEN 1 ELSE 0 END) AS wins,
            SUM(CASE WHEN position <= 3   THEN 1 ELSE 0 END) AS podiums,
            SUM(CASE WHEN dnf       = 1   THEN 1 ELSE 0 END) AS dnfs,
            AVG(NULLIF(position, 99))                         AS avg_position,
            SUM(points_earned)                                AS total_points
          FROM race_results
          WHERE player_id = ?]],
        { profile.id }
    )

    local a          = (agg and agg[1]) or {}
    local total      = tonumber(a.total_races) or 0
    local wins       = tonumber(a.wins)    or 0
    local podiums    = tonumber(a.podiums) or 0
    local dnfs       = tonumber(a.dnfs)    or 0

    local stats = {
        total_races   = total,
        wins          = wins,
        podiums       = podiums,
        dnfs          = dnfs,
        win_rate      = total > 0 and (wins / total) or 0,
        podium_rate   = total > 0 and (podiums / total) or 0,
        dnf_rate      = total > 0 and (dnfs / total) or 0,
        avg_position  = tonumber(a.avg_position) or 0,
        total_points  = tonumber(a.total_points) or 0,
        total_xp      = profile.xp or 0,
        iRating       = profile.i_rating or 1000,
        sr            = profile.sr or 3.0,
        rank          = profile.rank or "D-5",
        level         = profile.level or 1,
    }

    LBCache.Set(cacheKey, stats, LBConfig.StatsCacheTTL)
    return stats
end

function LB_GetPlayerHistory(source, page, pageSize)
    pageSize = pageSize or LBConfig.HistoryPageSize
    page     = page or 1
    local offset = (page - 1) * pageSize

    local profile = exports["spz-identity"]:GetProfile(source)
    if not profile then return { rows = {}, hasMore = false } end

    local rows = MySQL.query.await(
        [[SELECT
            rs.track, rs.car_class,
            rr.position, rr.finish_time, rr.best_lap,
            rr.points_earned, rr.sr_change,
            rr.personal_best, rr.dnf, rr.created_at
          FROM race_results rr
          JOIN race_sessions rs ON rs.race_id = rr.race_id
          WHERE rr.player_id = ?
          ORDER BY rr.created_at DESC
          LIMIT ? OFFSET ?]],
        { profile.id, pageSize + 1, offset }
    ) or {}

    local hasMore = #rows > pageSize
    if hasMore then table.remove(rows) end

    return {
        rows    = FormatHistoryRows(rows),
        hasMore = hasMore,
        page    = page,
    }
end

-- Activity feed: latest race results across all players (server-wide)
function LB_GetActivityFeed(limit)
    limit = math.min(limit or 50, 100)
    local cacheKey = ("activity:%d"):format(limit)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows = MySQL.query.await(
        [[SELECT p.username AS player, p.avatar_url AS avatar, p.rank AS rank_title,
                 rs.track AS detail, rs.car_class,
                 rr.position, rr.created_at AS timestamp
          FROM race_results rr
          JOIN players p        ON p.id      = rr.player_id
          JOIN race_sessions rs ON rs.race_id = rr.race_id
          ORDER BY rr.created_at DESC
          LIMIT ?]],
        { limit }
    ) or {}

    local feed = {}
    for _, row in ipairs(rows) do
        local action = row.position == 1 and "won a race at" or ("finished P" .. row.position .. " at")
        table.insert(feed, {
            player     = row.player or "Racer",
            avatar     = row.avatar,
            rank_title = row.rank_title,
            car_class  = type(row.car_class) == "number"
                         and (LBConfig.TierToClass[row.car_class] or "D")
                         or row.car_class,
            action    = action,
            detail    = row.detail or "Track",
            title     = (row.player or "Racer") .. " " .. action .. " " .. (row.detail or "Track"),
            raced_at  = row.timestamp or "",
            timestamp = row.timestamp or "",
        })
    end

    LBCache.Set(cacheKey, feed, 10)
    return feed
end

-- Daily race counts for the My-stats heatmap. Grouped by day AND track so the
-- UI can filter the calendar without a second round trip.
function LB_GetPlayerActivity(source, days)
    days = math.min(tonumber(days) or 364, 730)
    local cacheKey = ("activity:player:%s:%d"):format(tostring(source), days)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(source) end)
    if not ok or not profile then return {} end

    local rows = MySQL.query.await(
        [[SELECT
            DATE(rr.created_at)                              AS day,
            rs.track                                         AS track,
            COUNT(*)                                         AS races,
            SUM(CASE WHEN rr.position = 1 THEN 1 ELSE 0 END) AS wins,
            SUM(CASE WHEN rr.dnf = 1 THEN 1 ELSE 0 END)      AS dnfs
          FROM race_results rr
          JOIN race_sessions rs ON rs.race_id = rr.race_id
          WHERE rr.player_id = ?
            AND rr.created_at >= (CURDATE() - INTERVAL ? DAY)
          GROUP BY day, rs.track
          ORDER BY day ASC]],
        { profile.id, days }
    ) or {}

    local out = {}
    for _, row in ipairs(rows) do
        table.insert(out, {
            day    = tostring(row.day):sub(1, 10),
            track  = row.track or "Unknown",
            races  = tonumber(row.races) or 0,
            wins   = tonumber(row.wins) or 0,
            dnfs   = tonumber(row.dnfs) or 0,
        })
    end

    LBCache.Set(cacheKey, out, LBConfig.StatsCacheTTL)
    return out
end

-- Per-track career summary — feeds the track filter with counts that cover
-- every race, not just the page of history the charts plot.
function LB_GetPlayerTrackSummary(source)
    local cacheKey = "tracksum:" .. tostring(source)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(source) end)
    if not ok or not profile then return {} end

    local rows = MySQL.query.await(
        [[SELECT
            rs.track                                         AS track,
            COUNT(*)                                         AS races,
            SUM(CASE WHEN rr.position = 1 THEN 1 ELSE 0 END) AS wins,
            SUM(CASE WHEN rr.position <= 3 AND rr.dnf = 0 THEN 1 ELSE 0 END) AS podiums,
            SUM(CASE WHEN rr.dnf = 1 THEN 1 ELSE 0 END)      AS dnfs,
            AVG(NULLIF(rr.position, 99))                     AS avg_position,
            MIN(NULLIF(rr.best_lap, 0))                      AS best_lap_ms,
            SUM(rr.points_earned)                            AS points
          FROM race_results rr
          JOIN race_sessions rs ON rs.race_id = rr.race_id
          WHERE rr.player_id = ?
          GROUP BY rs.track
          ORDER BY races DESC]],
        { profile.id }
    ) or {}

    local out = {}
    for _, row in ipairs(rows) do
        table.insert(out, {
            track        = row.track or "Unknown",
            races        = tonumber(row.races) or 0,
            wins         = tonumber(row.wins) or 0,
            podiums      = tonumber(row.podiums) or 0,
            dnfs         = tonumber(row.dnfs) or 0,
            avg_position = tonumber(row.avg_position) or 0,
            best_lap_ms  = tonumber(row.best_lap_ms) or nil,
            best_lap_f   = row.best_lap_ms and LB_FormatTime(row.best_lap_ms) or nil,
            points       = tonumber(row.points) or 0,
        })
    end

    LBCache.Set(cacheKey, out, LBConfig.StatsCacheTTL)
    return out
end
