-- server/progression/rank_admin.lua — progression: rank_admin.
-- Moved from spz-progression/server/rank_admin.lua when it was merged into spz-races.
local Config = Config.Progression

-- server/rank_admin.lua
-- Flat RP grants (perfect lap, track record), the player /rank readout, and the
-- rank tools behind spz-admin's menu (Players -> player -> Rank, and the
-- Ranking page).
--
-- There are deliberately NO admin chat commands here: every admin control
-- lives in the spz-admin menu, which checks the admin ace on each callback
-- before calling these exports. (The old /spz seasonreset command also
-- replaced spz-core's own /spz dispatcher, and the season reset is gone.)

local Log   = SPZ.Logger("spz-progression")
local Rules = Config.Rules

local function Rows() return SPZ.RankRows end
local function DayKey() return os.date("!%Y-%m-%d") end

local function Reply(src, msg, kind)
    if src == 0 then print("[spz-progression] " .. msg) return end
    SPZ.Notify(src, msg, kind or "info", 8000)
end

-- ── Flat RP (perfect lap, track record) ───────────────────────────────────
-- Positive only, respects the daily cap, never touches the streak.
function GrantFlatRP(src, amount, reason)
    src = tonumber(src)
    if not src or not amount or amount <= 0 then return 0 end
    local p = exports["spz-core"]:GetProfile(src)
    if not p then return 0 end

    local rp      = tonumber(p.rank_points) or 0
    local dayKey  = DayKey()
    local dayGain = (p.rp_day_key == dayKey) and (tonumber(p.rp_day_gain) or 0) or 0
    local delta, after = SPZ.RP.Apply(rp, amount, SPZ.Rank.ClassFloor(rp, Rules), dayGain, Rules)
    if delta <= 0 then return 0 end

    local rankBefore, tierBefore = p.rank or "C-5", tonumber(p.license_tier) or 0
    local rank, tier = SPZ.Rank.For(after, Rows())
    exports["spz-core"]:UpdateProfile(src, {
        rank_points = after, rank = rank,
        rp_day_key = dayKey, rp_day_gain = dayGain + delta,
        alltime_points = (p.alltime_points or 0) + delta,
    })
    if tier > tierBefore then
        exports["spz-core"]:UnlockLicense(src, tier, "rank_points", rank)
    end
    NotifyRankChange(src, rankBefore, rank)
    TriggerClientEvent("SPZ:rpGranted", src, { rp = delta, reason = reason, rank = rank })
    Log.info(("Flat RP src=%s +%d (%s)"):format(src, delta, reason or "bonus"))
    return delta
end
exports("GrantFlatRP", GrantFlatRP)

AddEventHandler("SPZ:perfectLap", function(source, info)
    if (info and (info.rewind_ms or 0) > 0) then return end
    GrantFlatRP(source, Rules.perfectLap, "PERFECT LAP")
end)

-- A genuine change of hands or a brand-new record (not a holder improving
-- their own time) — same rule spz-raceline uses for its announcement.
AddEventHandler("spz-raceline:recordTaken", function(info)
    if not info or not info.newSrc then return end
    if info.oldPid and info.oldPid == info.newPid then return end
    GrantFlatRP(info.newSrc, Rules.trackRecord, "TRACK RECORD")
end)

-- ── Player command: /rank ─────────────────────────────────────────────────
RegisterCommand("rank", function(src)
    if src == 0 then return end
    local p = exports["spz-core"]:GetProfile(src)
    if not p then return end
    local rp = tonumber(p.rank_points) or 0
    local rank = SPZ.Rank.For(rp, Rows())
    local frac, nextRank = SPZ.Rank.Progress(rp, Rows())
    local ok, title = pcall(function() return exports["spz-core"]:GetRankName(rank) end)
    title = ok and title or ""
    Reply(src, ("%s %s — %d RP%s · streak %d"):format(rank, title, rp,
        nextRank and (" · %d%% to %s"):format(math.floor(frac * 100), nextRank) or "",
        tonumber(p.rank_streak) or 0))
end, false)

-- ── Admin tools (called only from spz-admin's menu callbacks) ─────────────
-- Each returns plain data; spz-admin owns permission checks, confirmations and
-- the audit log.

local function OnlineByPlayerId()
    local map = {}
    for _, s in ipairs(GetPlayers()) do
        local p = exports["spz-core"]:GetProfile(tonumber(s))
        if p then map[p.id] = tonumber(s) end
    end
    return map
end

--- Rank card for one online player.
local function AdminRankInfo(target)
    target = tonumber(target)
    local p = target and exports["spz-core"]:GetProfile(target)
    if not p then return nil end
    local rp = tonumber(p.rank_points) or 0
    local rank = SPZ.Rank.For(rp, Rows())
    local frac, nextRank = SPZ.Rank.Progress(rp, Rows())
    local rows = MySQL.query.await([[
        SELECT race_id, position, n_field, delta, voided, created_at FROM rank_awards
        WHERE player_id = ? ORDER BY id DESC LIMIT 10
    ]], { p.id }) or {}
    return {
        playerId  = p.id,
        rp        = rp,
        rank      = rank,
        nextRank  = nextRank,
        progress  = frac,
        streak    = tonumber(p.rank_streak) or 0,
        today     = (p.rp_day_key == DayKey()) and (tonumber(p.rp_day_gain) or 0) or 0,
        dailyCap  = Rules.dailyCap,
        sr        = tonumber(p.sr) or 0,
        iRating   = tonumber(p.i_rating) or 0,
        recent    = rows,
    }
end
exports("AdminRankInfo", AdminRankInfo)

--- Set one online player's RP. Rank and class letter follow from it.
local function AdminSetRP(target, value)
    target, value = tonumber(target), tonumber(value)
    local p = target and exports["spz-core"]:GetProfile(target)
    if not p or not value or value < 0 then return false, "Invalid player or value" end
    value = math.floor(value)
    local before, oldRP = p.rank or "C-5", tonumber(p.rank_points) or 0
    local rank, tier = SPZ.Rank.For(value, Rows())
    exports["spz-core"]:UpdateProfile(target, { rank_points = value, rank = rank, license_tier = tier })
    NotifyRankChange(target, before, rank)
    Log.warn(("ADMIN setrp: player %s %d RP -> %d RP (%s)"):format(p.id, oldRP, value, rank))
    return true, ("%d RP -> %d RP (%s)"):format(oldRP, value, rank)
end
exports("AdminSetRP", AdminSetRP)

--- Most recent scored races, for the void picker.
local function AdminRecentRaces(limit)
    limit = math.max(1, math.min(tonumber(limit) or 15, 50))
    return MySQL.query.await([[
        SELECT race_id, COUNT(*) AS players, SUM(voided) AS voided_rows,
               DATE_FORMAT(MAX(created_at), '%Y-%m-%d %H:%i') AS at, SUM(GREATEST(delta, 0)) AS rp_given
        FROM rank_awards GROUP BY race_id ORDER BY MAX(id) DESC LIMIT ?
    ]], { limit }) or {}
end
exports("AdminRecentRaces", AdminRecentRaces)

--- Reverse every non-voided award of a race. Rank lock still applies: the
--- reversal never drops a player below the floor of their current class.
local function AdminVoidRace(raceId)
    if type(raceId) ~= "string" or raceId == "" then return false, "No race id" end
    local rows = MySQL.query.await("SELECT id, player_id, delta FROM rank_awards WHERE race_id = ? AND voided = 0", { raceId }) or {}
    if #rows == 0 then return false, "Nothing left to void in " .. raceId end

    local online = OnlineByPlayerId()
    for _, r in ipairs(rows) do
        local s = online[r.player_id]
        if s then
            local p = exports["spz-core"]:GetProfile(s)
            local rp = tonumber(p.rank_points) or 0
            local after = math.max(SPZ.Rank.ClassFloor(rp, Rules), rp - r.delta)
            local rank, tier = SPZ.Rank.For(after, Rows())
            local before = p.rank
            exports["spz-core"]:UpdateProfile(s, { rank_points = after, rank = rank, license_tier = tier })
            NotifyRankChange(s, before, rank)
        else
            local row = MySQL.single.await("SELECT rank_points FROM players WHERE id = ?", { r.player_id })
            if row then
                local rp = tonumber(row.rank_points) or 0
                local after = math.max(SPZ.Rank.ClassFloor(rp, Rules), rp - r.delta)
                local rank, tier = SPZ.Rank.For(after, Rows())
                MySQL.update.await("UPDATE players SET rank_points = ?, `rank` = ?, license_tier = ? WHERE id = ?",
                    { after, rank, tier, r.player_id })
            end
        end
        MySQL.update.await("UPDATE rank_awards SET voided = 1 WHERE id = ?", { r.id })
    end
    TriggerEvent("SPZ:rankVoided", raceId)
    Log.warn(("ADMIN voidrace: %s (%d awards)"):format(raceId, #rows))
    return true, ("Voided %d award(s) in %s"):format(#rows, raceId)
end
exports("AdminVoidRace", AdminVoidRace)

--- Overview numbers for the Ranking page.
local function AdminRankStats()
    local classes = { C = 0, B = 0, A = 0, S = 0 }
    for _, t in ipairs(MySQL.query.await("SELECT license_tier, COUNT(*) AS n FROM players GROUP BY license_tier") or {}) do
        local letter = ({ [0] = "C", "B", "A", "S" })[tonumber(t.license_tier) or 0]
        if letter then classes[letter] = tonumber(t.n) or 0 end
    end
    local today = MySQL.single.await([[
        SELECT COUNT(DISTINCT race_id) AS races, COUNT(*) AS awards FROM rank_awards
        WHERE created_at >= UTC_DATE() AND voided = 0
    ]]) or {}
    local capped = MySQL.scalar.await("SELECT COUNT(*) FROM players WHERE rp_day_key = ? AND rp_day_gain >= ?",
        { DayKey(), Rules.dailyCap }) or 0
    local top = MySQL.query.await("SELECT username, rank_points, `rank` FROM players WHERE banned = 0 ORDER BY rank_points DESC LIMIT 10") or {}
    return {
        classes = classes, racesToday = tonumber(today.races) or 0, awardsToday = tonumber(today.awards) or 0,
        capHits = tonumber(capped) or 0, dailyCap = Rules.dailyCap, top = top,
    }
end
exports("AdminRankStats", AdminRankStats)
