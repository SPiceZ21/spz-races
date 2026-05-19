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
    LBCache.Bust("stats:")
end)

-- ── SPZ.Callbacks (tablet data endpoints) ───────────────────────────────────

local function safeCall(fn, fallback, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        print("^1[spz-races] LB callback error: " .. tostring(result) .. "^7")
        return fallback
    end
    return result
end

SPZ.Callbacks.Register("spz-races:getGlobalStandings", function(source, cb, data)
    cb(safeCall(LB_GetGlobalStandings, {}, data and data.limit))
end)

SPZ.Callbacks.Register("spz-races:getClassStandings", function(source, cb, data)
    cb(safeCall(LB_GetClassStandings, {}, data and (data.class or data.tier) or "D", data and data.limit))
end)

SPZ.Callbacks.Register("spz-races:getTrackRecords", function(source, cb, data)
    cb(safeCall(LB_GetTrackRecords, {}, data and data.track, data and data.carClass, data and data.limit))
end)

SPZ.Callbacks.Register("spz-races:getPlayerStats", function(source, cb, data)
    local target = (data and data.source) or source
    cb(safeCall(LB_GetPlayerStats, nil, target))
end)

SPZ.Callbacks.Register("spz-races:getPlayerHistory", function(source, cb, data)
    cb(safeCall(LB_GetPlayerHistory, { rows = {}, hasMore = false }, source, data and data.page, data and data.pageSize))
end)

SPZ.Callbacks.Register("spz-races:getAllTrackRecords", function(source, cb, data)
    cb(safeCall(LB_GetAllTrackRecords, {}, data and data.carClass or nil))
end)

SPZ.Callbacks.Register("spz-races:getPersonalRecords", function(source, cb)
    cb(safeCall(LB_GetPersonalRecords, {}, source))
end)

SPZ.Callbacks.Register("spz-races:getActivityFeed", function(source, cb, data)
    cb(safeCall(LB_GetActivityFeed, {}, data and data.limit))
end)
