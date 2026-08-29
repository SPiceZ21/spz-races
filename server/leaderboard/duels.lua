-- server/leaderboard/duels.lua
-- Ghost-duel views for the leaderboard tablet. Read-only: settlement itself
-- lives in server/duel.lua.

-- Recent duels across the server, newest settlement first.
function LB_GetDuelFeed(limit)
    limit = math.min(tonumber(limit) or 50, 100)
    local cacheKey = ("duels:feed:%d"):format(limit)
    local cached = LBCache.Get(cacheKey)
    if cached then return cached end

    local rows = MySQL.query.await(
        [[SELECT
            d.id, d.track, d.stake, d.target_ms, d.result_ms, d.outcome,
            d.created_at, d.settled_at,
            c.username   AS challenger,
            c.avatar_url AS challenger_avatar,
            o.username   AS opponent,
            o.avatar_url AS opponent_avatar
          FROM duels d
          JOIN players c ON c.id = d.challenger_id
          JOIN players o ON o.id = d.opponent_id
          ORDER BY COALESCE(d.settled_at, d.created_at) DESC
          LIMIT ?]],
        { limit }
    ) or {}

    local out = {}
    for _, r in ipairs(rows) do
        local target = tonumber(r.target_ms) or 0
        local result = tonumber(r.result_ms)
        out[#out + 1] = {
            id                = r.id,
            track             = r.track or "Unknown",
            stake             = tonumber(r.stake) or 0,
            outcome           = r.outcome or "pending",
            target_ms         = target,
            result_ms         = result,
            target_f          = LB_FormatTime(target),
            result_f          = result and LB_FormatTime(result) or nil,
            margin_ms         = result and (target - result) or nil,   -- +ve = challenger faster
            challenger        = r.challenger or "Racer",
            challenger_avatar = r.challenger_avatar,
            opponent          = r.opponent or "Racer",
            opponent_avatar   = r.opponent_avatar,
            created_at        = r.created_at,
            settled_at        = r.settled_at,
        }
    end

    LBCache.Set(cacheKey, out, 10)
    return out
end

-- The caller's own duel record — both as challenger and as the ghost.
function LB_GetDuelRecord(source)
    local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(source) end)
    if not ok or not profile then return {} end

    local row = MySQL.single.await(
        [[SELECT
            COUNT(*)                                                   AS total,
            SUM(CASE WHEN outcome = 'win'     THEN 1 ELSE 0 END)       AS wins,
            SUM(CASE WHEN outcome = 'loss'    THEN 1 ELSE 0 END)       AS losses,
            SUM(CASE WHEN outcome = 'pending' THEN 1 ELSE 0 END)       AS pending,
            SUM(CASE WHEN outcome = 'win'  THEN stake ELSE 0 END)      AS won_credits,
            SUM(CASE WHEN outcome = 'loss' THEN stake ELSE 0 END)      AS lost_credits
          FROM duels
          WHERE challenger_id = ?]],
        { profile.id }
    ) or {}

    -- Duels where someone raced this player's ghost.
    local defended = MySQL.single.await(
        [[SELECT
            COUNT(*)                                             AS total,
            SUM(CASE WHEN outcome = 'loss' THEN 1 ELSE 0 END)    AS defended
          FROM duels
          WHERE opponent_id = ?]],
        { profile.id }
    ) or {}

    local total = tonumber(row.total) or 0
    local wins  = tonumber(row.wins) or 0

    return {
        total         = total,
        wins          = wins,
        losses        = tonumber(row.losses) or 0,
        pending       = tonumber(row.pending) or 0,
        win_rate      = total > 0 and (wins / total) or 0,
        won_credits   = tonumber(row.won_credits) or 0,
        lost_credits  = tonumber(row.lost_credits) or 0,
        challenged    = tonumber(defended.total) or 0,
        defended      = tonumber(defended.defended) or 0,
    }
end
