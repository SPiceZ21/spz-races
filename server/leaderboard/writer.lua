-- server/leaderboard/writer.lua
-- DB writes triggered by SPZ:raceEnd (server event from results.lua).

---@param results table
function LB_WriteRaceSession(results)
    MySQL.Async.execute(
        [[INSERT IGNORE INTO race_sessions
          (race_id, track, track_type, car_class, laps, player_count, duration_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?)]],
        {
            results.raceId,
            results.track,
            results.type,
            results.carClass,
            results.laps,
            #results.finishers + #results.dnf,
            results.duration,
        }
    )
end

---@param raceId  string
---@param players table  -- finishers + dnf combined
function LB_BulkWriteResults(raceId, players)
    if not players or #players == 0 then return end

    local placeholderGroup = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    local placeholders = {}
    local params = {}

    for _, p in ipairs(players) do
        local profile = exports["spz-identity"]:GetProfile(p.source)
        if profile then
            table.insert(placeholders, placeholderGroup)
            local row = {
                raceId,
                profile.id,
                p.position or 99,
                p.finish_time,
                p.best_lap,
                p.lap_times and json.encode(p.lap_times) or nil,
                p.points_earned or 0,
                p.sr_change     or 0,
                p.irating_change or 0,
                p.xp_earned     or 0,
                p.personal_best and 1 or 0,
                p.dnf           and 1 or 0,
                p.dnf_reason,
            }
            for _, v in ipairs(row) do table.insert(params, v) end
        end
    end

    if #placeholders == 0 then return end

    MySQL.Async.execute(
        "INSERT INTO race_results "
        .. "(race_id, player_id, position, finish_time, best_lap, lap_times, "
        .. "points_earned, sr_change, irating_change, xp_earned, personal_best, dnf, dnf_reason) "
        .. "VALUES " .. table.concat(placeholders, ", "),
        params
    )
end

---@param track      string
---@param trackType  string
---@param carClass   string
---@param finisher   table
function LB_UpdateTrackRecord(track, trackType, carClass, finisher)
    if finisher.dnf or not finisher.finish_time then return end
    local profile = exports["spz-identity"]:GetProfile(finisher.source)
    if not profile then return end

    MySQL.Async.execute(
        [[INSERT INTO track_records (track, track_type, car_class, player_id, best_time, best_lap)
          VALUES (?, ?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE
            best_time = IF(VALUES(best_time) < best_time, VALUES(best_time), best_time),
            best_lap  = IF(VALUES(best_time) < best_time, VALUES(best_lap),  best_lap),
            set_at    = IF(VALUES(best_time) < best_time, NOW(),             set_at)]],
        { track, trackType, carClass, profile.id, finisher.finish_time, finisher.best_lap }
    )
end
