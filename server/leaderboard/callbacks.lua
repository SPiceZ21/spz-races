-- server/leaderboard/callbacks.lua
-- Listens for SPZ:raceEnd and registers all tablet-facing callbacks.
-- Replaces spz-leaderboard entirely.

-- ── Write on race end ────────────────────────────────────────────────────────

AddEventHandler("SPZ:raceEnd", function(results)
    LB_WriteRaceSession(results)

    local allPlayers = {}
    for _, f in ipairs(results.finishers) do table.insert(allPlayers, f) end
    for _, d in ipairs(results.dnf)       do table.insert(allPlayers, d) end
    LB_BulkWriteResults(results.raceId, allPlayers)

    for _, finisher in ipairs(results.finishers) do
        LB_UpdateTrackRecord(results.track, results.type, results.carClass, finisher)
    end

    -- Bust stale caches
    LBCache.Bust("standings")
    LBCache.Bust("records:" .. (results.track or ""))
    LBCache.Bust("activity:")
    -- The race that just finished has to appear in the archive immediately;
    -- a player pressing F6 at the results screen is the main way it is read.
    LBCache.Bust("archive:")
    LBCache.Bust("stats:")
end)

-- ── ox_lib callbacks (tablet data endpoints) ─────────────────────────────────

local function safeCall(fn, fallback, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        print("^1[spz-races] LB callback error: " .. tostring(result) .. "^7")
        return fallback
    end
    return result
end

lib.callback.register("spz-races:getGlobalStandings", function(source, data)
    return safeCall(LB_GetGlobalStandings, {}, data and data.limit)
end)

lib.callback.register("spz-races:getClassStandings", function(source, data)
    return safeCall(LB_GetClassStandings, {}, data and (data.class or data.tier) or "D", data and data.limit)
end)

lib.callback.register("spz-races:getTrackRecords", function(source, data)
    return safeCall(LB_GetTrackRecords, {}, data and data.track, data and data.carClass, data and data.limit)
end)

lib.callback.register("spz-races:getPlayerStats", function(source, data)
    local target = (data and data.source) or source
    return safeCall(LB_GetPlayerStats, nil, target)
end)

-- Ghost duels: server-wide feed plus the caller's own record.
lib.callback.register("spz-races:getDuelBoard", function(source, data)
    return {
        record = safeCall(LB_GetDuelRecord, {}, source),
        rows   = safeCall(LB_GetDuelFeed, {}, data and data.limit),
    }
end)

-- Heatmap calendar (day x track counts) for the My-stats charts.
lib.callback.register("spz-races:getPlayerActivity", function(source, data)
    return safeCall(LB_GetPlayerActivity, {}, source, data and data.days)
end)

-- Per-track career summary, used by the My-stats track filter.
lib.callback.register("spz-races:getPlayerTrackSummary", function(source)
    return safeCall(LB_GetPlayerTrackSummary, {}, source)
end)

lib.callback.register("spz-races:getPlayerHistory", function(source, data)
    return safeCall(LB_GetPlayerHistory, { rows = {}, hasMore = false }, source, data and data.page, data and data.pageSize)
end)

lib.callback.register("spz-races:getAllTrackRecords", function(source, data)
    return safeCall(LB_GetAllTrackRecords, {}, data and data.carClass or nil)
end)

lib.callback.register("spz-races:getPersonalRecords", function(source)
    return safeCall(LB_GetPersonalRecords, {}, source)
end)

-- Race archive: the list of finished races, and the full classification of one.
lib.callback.register("spz-races:getRaceArchive", function(source, data)
    return safeCall(LB_GetRaceArchive, {}, data and data.limit, data and data.page)
end)

lib.callback.register("spz-races:getRaceResults", function(source, data)
    return safeCall(LB_GetRaceResults, nil, data and data.raceId)
end)

lib.callback.register("spz-races:getActivityFeed", function(source, data)
    return safeCall(LB_GetActivityFeed, {}, data and data.limit)
end)

-- In-world record board: overall fastest lap per track (any class), from the
-- racelines store — the same record-holder data the ghost/rival systems use.
local _boardCache = {}   -- [track] = { at = ms, rows = {} }
lib.callback.register("spz-races:getBoardRecords", function(source, data)
    local track = data and data.track
    local limit = math.min((data and data.limit) or 5, 10)
    if type(track) ~= "string" then return {} end

    local hit = _boardCache[track]
    if hit and (GetGameTimer() - hit.at) < 30000 then return hit.rows end

    local rows = MySQL.query.await([[
        SELECT r.best_ms, p.username
        FROM racelines r
        JOIN players p ON p.id = r.player_id
        WHERE r.track = ?
        ORDER BY r.best_ms ASC
        LIMIT ?
    ]], { track, limit }) or {}

    local out = {}
    for i, row in ipairs(rows) do
        out[i] = { rank = i, name = row.username or "Unknown", ms = row.best_ms }
    end
    _boardCache[track] = { at = GetGameTimer(), rows = out }
    return out
end)
