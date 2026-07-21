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
        [[SELECT p.username AS player, rs.track AS detail,
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
            player    = row.player or "Racer",
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
