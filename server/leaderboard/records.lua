-- server/leaderboard/records.lua

-- Used by checkpoints.lua internally (no cross-resource call needed)
function LB_GetPersonalBest(source, track, carClass)
    local profile = source and exports["spz-identity"]:GetProfile(source)
    if not profile then return nil end

    local result = MySQL.query.await(
        [[SELECT best_time FROM track_records
          WHERE track = ? AND car_class = ? AND player_id = ?
          LIMIT 1]],
        { track, tostring(carClass or "D"), profile.id }
    )
    if result and result[1] and result[1].best_time then
        return result[1].best_time
    end

    -- Fallback to racelines table if track_records has no entry
    local rl = MySQL.query.await(
        [[SELECT best_ms FROM racelines WHERE track = ? AND player_id = ? LIMIT 1]],
        { track, profile.id }
    )
    return rl and rl[1] and rl[1].best_ms or nil
end

-- Top N times for one track + class
function LB_GetTrackRecords(track, carClass, limit)
    limit = math.min(limit or LBConfig.DefaultRecordsLimit, LBConfig.MaxRecordsLimit)
    local cacheKey = ("records:track:%s:%s:%d"):format(track or "", carClass or "", limit)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows = MySQL.query.await(
        [[SELECT tr.best_time, tr.best_lap, tr.set_at,
                 p.username AS player_name, p.rank AS rank_title
          FROM track_records tr
          JOIN players p ON p.id = tr.player_id
          WHERE tr.track = ? AND tr.car_class = ?
          ORDER BY tr.best_time ASC
          LIMIT ?]],
        { track, tostring(carClass or "D"), limit }
    ) or {}

    local formatted = {}
    for i, row in ipairs(rows) do
        table.insert(formatted, {
            rank        = i,
            track       = track,
            track_name  = track,
            car_class   = carClass,
            player_name = row.player_name or "Racer",
            lap_time_ms = row.best_time,
            lap_time_f  = LB_FormatTime(row.best_time),
            set_at      = row.set_at,
        })
    end

    LBCache.Set(cacheKey, formatted, LBConfig.RecordsCacheTTL)
    return formatted
end

-- One best per track per class (for Records view)
function LB_GetAllTrackRecords(carClass)
    local cacheKey = ("records:all:%s"):format(carClass or "ALL")
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows = {}
    if carClass then
        rows = MySQL.query.await(
            [[SELECT tr.track, tr.car_class, MIN(tr.best_time) AS lap_time_ms,
                     (SELECT p.username FROM track_records tr2 JOIN players p ON p.id = tr2.player_id WHERE tr2.track = tr.track AND tr2.car_class = tr.car_class ORDER BY tr2.best_time ASC LIMIT 1) AS player_name
              FROM track_records tr
              WHERE tr.car_class = ?
              GROUP BY tr.track, tr.car_class
              ORDER BY tr.track ASC]],
            { tostring(carClass) }
        ) or {}
    else
        rows = MySQL.query.await(
            [[SELECT tr.track, tr.car_class, MIN(tr.best_time) AS lap_time_ms,
                     (SELECT p.username FROM track_records tr2 JOIN players p ON p.id = tr2.player_id WHERE tr2.track = tr.track AND tr2.car_class = tr.car_class ORDER BY tr2.best_time ASC LIMIT 1) AS player_name
              FROM track_records tr
              GROUP BY tr.track, tr.car_class
              ORDER BY tr.track ASC, tr.car_class ASC]],
            {}
        ) or {}
    end

    -- If track_records is empty, fallback to racelines table
    if #rows == 0 then
        rows = MySQL.query.await(
            [[SELECT r.track, 'S' AS car_class, MIN(r.best_ms) AS lap_time_ms,
                     (SELECT p.username FROM racelines r2 JOIN players p ON p.id = r2.player_id WHERE r2.track = r.track ORDER BY r2.best_ms ASC LIMIT 1) AS player_name
              FROM racelines r
              GROUP BY r.track
              ORDER BY r.track ASC]],
            {}
        ) or {}
    end

    local formatted = {}
    for _, row in ipairs(rows) do
        table.insert(formatted, {
            track       = row.track or "Unknown",
            track_name  = row.track or "Unknown",
            car_class   = row.car_class or "S",
            player_name = row.player_name or "Racer",
            lap_time_ms = row.lap_time_ms or 0,
            lap_time_f  = LB_FormatTime(row.lap_time_ms or 0),
            set_at      = row.set_at or nil,
        })
    end

    LBCache.Set(cacheKey, formatted, LBConfig.RecordsCacheTTL)
    return formatted
end

-- Personal best laps for a player across all tracks
function LB_GetPersonalRecords(source)
    local profile = source and exports["spz-identity"]:GetProfile(source)
    if not profile then return {} end

    local rows = MySQL.query.await(
        [[SELECT tr.track, tr.car_class, tr.best_time AS lap_time_ms, tr.set_at
          FROM track_records tr
          WHERE tr.player_id = ?
          ORDER BY tr.track ASC]],
        { profile.id }
    ) or {}

    local result = {}
    for _, row in ipairs(rows) do
        table.insert(result, {
            track       = row.track,
            track_name  = row.track,
            car_class   = row.car_class,
            lap_time_ms = row.lap_time_ms,
            lap_time_f  = LB_FormatTime(row.lap_time_ms),
            set_at      = row.set_at,
        })
    end
    return result
end
