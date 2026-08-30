-- server/leaderboard/archive.lua
-- Race archive: every finished race, and the full classification of any one of
-- them.
--
-- Nothing here writes anything. Both tables have been populated since day one —
-- writer.lua banks a `race_sessions` row and one `race_results` row per starter
-- at the end of every race — but no query ever read them back per race, so the
-- classification of a race you had just driven existed in the database and
-- nowhere a player could see it. This file is the missing read side.

-- ── Recent races ─────────────────────────────────────────────────────────────
-- One row per race, newest first, with the winner resolved in the same query.
-- The winner is a LEFT JOIN so a race where everybody DNF'd still appears —
-- those are exactly the races people want to look up afterwards.

function LB_GetRaceArchive(limit, page)
    limit = math.min(tonumber(limit) or 25, 100)
    page  = math.max(tonumber(page) or 1, 1)
    local offset = (page - 1) * limit

    local cacheKey = ("archive:%d:%d"):format(limit, page)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows = MySQL.query.await([[
        SELECT rs.race_id, rs.track, rs.track_type, rs.car_class, rs.laps,
               rs.player_count, rs.duration_ms, rs.created_at,
               w.username     AS winner_name,
               w.avatar_url   AS winner_avatar,
               rr.finish_time AS winner_time
        FROM race_sessions rs
        LEFT JOIN race_results rr
               ON rr.race_id = rs.race_id AND rr.position = 1 AND rr.dnf = 0
        LEFT JOIN players w ON w.id = rr.player_id
        ORDER BY rs.created_at DESC
        LIMIT ? OFFSET ?
    ]], { limit, offset }) or {}

    local out = {}
    for i, r in ipairs(rows) do
        local cls = r.car_class
        if type(cls) == "number" then cls = LBConfig.TierToClass[cls] or "D" end

        out[i] = {
            race_id      = r.race_id,
            track        = r.track or "Unknown",
            track_type   = r.track_type or "circuit",
            car_class    = cls or "D",
            laps         = r.laps or 1,
            player_count = r.player_count or 0,
            duration_ms  = r.duration_ms or 0,
            raced_at     = r.created_at or "",
            winner       = r.winner_name,          -- nil when nobody finished
            winner_avatar = r.winner_avatar,
            winner_time  = r.winner_time,
        }
    end

    LBCache.Set(cacheKey, out, 15)
    return out
end

-- ── One race, in full ────────────────────────────────────────────────────────
-- The classification as it was scored: finishers in position order, then DNFs.
-- Ordered in SQL rather than in Lua so paging or a LIMIT can be added later
-- without the order silently depending on how many rows were fetched.

function LB_GetRaceResults(raceId)
    if type(raceId) ~= "string" or raceId == "" then return nil end

    local cacheKey = "race:" .. raceId
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local session = MySQL.single.await([[
        SELECT race_id, track, track_type, car_class, laps,
               player_count, duration_ms, created_at
        FROM race_sessions WHERE race_id = ?
    ]], { raceId })

    if not session then return nil end

    local rows = MySQL.query.await([[
        SELECT rr.position, rr.finish_time, rr.best_lap, rr.lap_times,
               rr.points_earned, rr.sr_change, rr.irating_change, rr.xp_earned,
               rr.personal_best, rr.dnf, rr.dnf_reason,
               p.id AS player_id, p.username, p.avatar_url
        FROM race_results rr
        JOIN players p ON p.id = rr.player_id
        WHERE rr.race_id = ?
        ORDER BY rr.dnf ASC, rr.position ASC
    ]], { raceId }) or {}

    local cls = session.car_class
    if type(cls) == "number" then cls = LBConfig.TierToClass[cls] or "D" end

    local entries = {}
    for i, r in ipairs(rows) do
        local laps = nil
        if r.lap_times then
            -- Stored as JSON; a malformed or legacy value must not take the
            -- whole classification down with it.
            local ok, decoded = pcall(json.decode, r.lap_times)
            if ok and type(decoded) == "table" then laps = decoded end
        end

        entries[i] = {
            position       = r.dnf == 1 and nil or r.position,
            player_id      = r.player_id,
            name           = r.username or "Racer",
            avatar         = r.avatar_url,
            finish_time    = r.finish_time,
            best_lap       = r.best_lap,
            lap_times      = laps,
            points_earned  = r.points_earned or 0,
            sr_change      = r.sr_change or 0,
            irating_change = r.irating_change or 0,
            xp_earned      = r.xp_earned or 0,
            personal_best  = r.personal_best == 1,
            dnf            = r.dnf == 1,
            dnf_reason     = r.dnf_reason,
        }
    end

    -- Gap to the winner, computed here so every consumer shows the same number.
    local winnerTime = entries[1] and not entries[1].dnf and entries[1].finish_time or nil
    if winnerTime then
        for _, e in ipairs(entries) do
            if not e.dnf and e.finish_time then
                e.gap_ms = e.finish_time - winnerTime
            end
        end
    end

    local out = {
        race_id      = session.race_id,
        track        = session.track or "Unknown",
        track_type   = session.track_type or "circuit",
        car_class    = cls or "D",
        laps         = session.laps or 1,
        player_count = session.player_count or 0,
        duration_ms  = session.duration_ms or 0,
        raced_at     = session.created_at or "",
        entries      = entries,
    }

    -- Finished races are immutable, so this can cache hard.
    LBCache.Set(cacheKey, out, 300)
    return out
end
