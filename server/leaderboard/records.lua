-- server/leaderboard/records.lua

-- Used by checkpoints.lua internally (no cross-resource call needed)
function LB_GetPersonalBest(source, track, carClass)
    local profile = exports["spz-identity"]:GetProfile(source)
    if not profile then return nil end

    local result = MySQL.query.await(
        [[SELECT best_time FROM track_records
          WHERE track = ? AND car_class = ? AND player_id = ?
          LIMIT 1]],
        { track, carClass, profile.id }
    )
    return result and result[1] and result[1].best_time or nil
end

-- Top N times for one track + class
function LB_GetTrackRecords(track, carClass, limit)
    limit = math.min(limit or LBConfig.DefaultRecordsLimit, LBConfig.MaxRecordsLimit)
    local cacheKey = ("records:track:%s:%s:%d"):format(track, carClass, limit)
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
        { track, carClass, limit }
    )

    local formatted = {}
    for i, row in ipairs(rows) do
        table.insert(formatted, {
            rank        = i,
            track_name  = track,
            car_class   = carClass,
            player_name = row.player_name,
            lap_time_ms = row.best_time,
            lap_time_f  = LB_FormatTime(row.best_time),
            set_at      = row.set_at,
        })
    end

    LBCache.Set(cacheKey, formatted, LBConfig.RecordsCacheTTL)
    return formatted
end

-- One best per track per class (for Records app world records view)
-- carClass = nil → all classes
function LB_GetAllTrackRecords(carClass)
    local cacheKey = ("records:all:%s"):format(carClass or "ALL")
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows
    if carClass then
        rows = MySQL.query.await(
            [[SELECT tr.track, tr.car_class, tr.best_time AS lap_time_ms, tr.set_at,
                     p.username AS player_name
              FROM track_records tr
              JOIN players p ON p.id = tr.player_id
              WHERE tr.car_class = ?
                AND (tr.track, tr.car_class, tr.best_time) IN (
                    SELECT track, car_class, MIN(best_time)
                    FROM track_records
                    WHERE car_class = ?
                    GROUP BY track, car_class
                )
              ORDER BY tr.track ASC, tr.car_class ASC]],
            { carClass, carClass }
        )
    else
        rows = MySQL.query.await(
            [[SELECT tr.track, tr.car_class, tr.best_time AS lap_time_ms, tr.set_at,
                     p.username AS player_name
              FROM track_records tr
              JOIN players p ON p.id = tr.player_id
              WHERE (tr.track, tr.car_class, tr.best_time) IN (
                    SELECT track, car_class, MIN(best_time)
                    FROM track_records
                    GROUP BY track, car_class
              )
              ORDER BY tr.track ASC, tr.car_class ASC]],
            {}
        )
    end

    local formatted = {}
    for _, row in ipairs(rows) do
        table.insert(formatted, {
            track_name  = row.track,
            car_class   = row.car_class,
            player_name = row.player_name,
            lap_time_ms = row.lap_time_ms,
            lap_time_f  = LB_FormatTime(row.lap_time_ms),
            set_at      = row.set_at,
        })
    end

    LBCache.Set(cacheKey, formatted, LBConfig.RecordsCacheTTL)
    return formatted
end

-- Personal best laps for a player across all tracks
function LB_GetPersonalRecords(source)
    local profile = exports["spz-identity"]:GetProfile(source)
    if not profile then return {} end

    local rows = MySQL.query.await(
        [[SELECT tr.track, tr.car_class, tr.best_time AS lap_time_ms, tr.set_at,
                 (SELECT COUNT(*) = 0 FROM track_records t2
                  WHERE t2.track = tr.track AND t2.car_class = tr.car_class
                    AND t2.best_time < tr.best_time) AS is_wr
          FROM track_records tr
          WHERE tr.player_id = ?
          ORDER BY tr.track ASC, tr.car_class ASC]],
        { profile.id }
    )

    local result = {}
    for _, row in ipairs(rows) do
        table.insert(result, {
            track_name  = row.track,
            car_class   = row.car_class,
            lap_time_ms = row.lap_time_ms,
            lap_time_f  = LB_FormatTime(row.lap_time_ms),
            set_at      = row.set_at,
            is_wr       = row.is_wr == 1,
        })
    end
    return result
end
