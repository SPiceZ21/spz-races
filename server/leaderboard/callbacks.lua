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

lib.callback.register("spz-races:getPlayerHistory", function(source, data)
    return safeCall(LB_GetPlayerHistory, { rows = {}, hasMore = false }, source, data and data.page, data and data.pageSize)
end)

lib.callback.register("spz-races:getAllTrackRecords", function(source, data)
    return safeCall(LB_GetAllTrackRecords, {}, data and data.carClass or nil)
end)

lib.callback.register("spz-races:getPersonalRecords", function(source)
    return safeCall(LB_GetPersonalRecords, {}, source)
end)

lib.callback.register("spz-races:getActivityFeed", function(source, data)
    return safeCall(LB_GetActivityFeed, {}, data and data.limit)
end)
