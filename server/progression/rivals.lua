-- server/progression/rivals.lua — progression: rivals.
-- Moved from spz-progression/server/rivals.lua when it was merged into spz-races.

-- server/rivals.lua
-- Rival system. Each player is paired with another of similar iRating. When
-- you set a lap that beats your rival's stored best on a track, you both get
-- pinged — async competition that works whether the rival is online or not.
--
-- Beat detection reads the racelines store (best_ms per player+track, written
-- by spz-raceline on every improved lap). A per-session dedupe set means the
-- "you beat your rival" ping fires once per track, not every lap.

local Notified = {}   -- [playerId] = { [track] = true }  (in-memory, per boot)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function profileId(src)
    local ok, p = pcall(function() return exports["spz-core"]:GetProfile(src) end)
    return ok and p and p.id or nil
end

local function nameOf(playerId)
    local row = MySQL.single.await("SELECT username FROM players WHERE id = ?", { playerId })
    return row and row.username or "Unknown"
end

-- online source for a given DB player id (nil if offline)
local function srcOf(playerId)
    for _, src in ipairs(GetPlayers()) do
        if profileId(tonumber(src)) == playerId then return tonumber(src) end
    end
    return nil
end

local function notify(src, title, msg, ntype)
    if not src then return end
    TriggerClientEvent("ox_lib:notify", src, {
        title = title, description = msg, type = ntype or "inform", duration = 8000,
    })
end

local function discord(title, msg, fields)
    if GetResourceState("spz-discord") ~= "started" then return end
    pcall(function()
        exports["spz-discord"]:Success("race", title, msg, fields)
    end)
end

-- ── Rival assignment ──────────────────────────────────────────────────────────

-- Nearest iRating player who isn't me and isn't banned.
local function pickRival(playerId)
    local me = MySQL.single.await("SELECT i_rating FROM players WHERE id = ?", { playerId })
    if not me then return nil end

    local row = MySQL.single.await([[
        SELECT id FROM players
        WHERE id != ? AND (banned IS NULL OR banned = 0)
        ORDER BY ABS(i_rating - ?) ASC
        LIMIT 1
    ]], { playerId, me.i_rating or 1500 })
    return row and row.id or nil
end

local function getRival(playerId)
    local row = MySQL.single.await("SELECT rival_id FROM rivals WHERE player_id = ?", { playerId })
    if row then return row.rival_id end

    local rid = pickRival(playerId)
    if not rid then return nil end
    MySQL.query.await(
        "INSERT INTO rivals (player_id, rival_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE rival_id = VALUES(rival_id)",
        { playerId, rid }
    )
    return rid
end

-- Assign on join (once the profile is loaded)
AddEventHandler("SPZ:playerReady", function(src)
    CreateThread(function()
        Wait(2000)
        local pid = profileId(src)
        if not pid then return end
        local rid = getRival(pid)
        if rid then
            Notified[pid] = {}   -- fresh session dedupe
        end
    end)
end)

-- ── Beat detection ────────────────────────────────────────────────────────────
-- Fires on any completed race/TT lap (same event spz-raceline listens to).

AddEventHandler("spz-raceline:lapCompleted", function(src, track, lapMs)
    if type(track) ~= "string" or type(lapMs) ~= "number" or lapMs <= 0 then return end

    CreateThread(function()
        local pid = profileId(src)
        if not pid then return end

        local rid = getRival(pid)
        if not rid then return end

        Notified[pid] = Notified[pid] or {}
        if Notified[pid][track] then return end   -- already told them this session

        local rivalBest = MySQL.scalar.await(
            "SELECT best_ms FROM racelines WHERE player_id = ? AND track = ? LIMIT 1",
            { rid, track }
        )
        if not rivalBest then return end          -- rival has no time here yet
        if lapMs >= rivalBest then return end      -- didn't beat them

        Notified[pid][track] = true

        local myName    = nameOf(pid)
        local rivalName = nameOf(rid)
        local gap       = (rivalBest - lapMs) / 1000

        -- Logged for the dashboards' rivalry feed.
        MySQL.insert([[
            INSERT INTO rival_events
                (kind, track, actor_player_id, target_player_id, new_ms, old_ms, margin_ms)
            VALUES ('player', ?, ?, ?, ?, ?, ?)
        ]], { track, pid, rid, lapMs, rivalBest, rivalBest - lapMs })

        -- You (online — you just drove it)
        notify(src, "RIVAL BEATEN",
            ("You beat your rival %s on %s by %.2fs!"):format(rivalName, track, gap), "success")

        -- Your rival (if online)
        local rsrc = srcOf(rid)
        notify(rsrc, "RIVAL ALERT",
            ("%s just beat your time on %s by %.2fs. Reclaim it."):format(myName, track, gap), "warning")

        discord("Rival Beaten",
            ("**%s** beat rival **%s** on **%s** by %.2fs"):format(myName, rivalName, track, gap),
            {
                { name = "Track",  value = track,                    inline = true },
                { name = "Margin", value = ("%.2fs"):format(gap),    inline = true },
            })
    end)
end)

-- ── /rival — show current rival + gap on the track you last raced ────────────

RegisterCommand("rival", function(source)
    local src = source
    CreateThread(function()
        local pid = profileId(src)
        if not pid then return end
        local rid = getRival(pid)
        if not rid then
            notify(src, "Rival", "No rival assigned yet — race a bit and check back.", "inform")
            return
        end
        local rivalName = nameOf(rid)
        local ir = MySQL.scalar.await("SELECT i_rating FROM players WHERE id = ?", { rid }) or 1500
        notify(src, "Your Rival",
            ("%s  ·  %d iR — beat their track times to climb."):format(rivalName, ir), "inform")
    end)
end, false)

-- ── Periodic re-pairing: keeps rivals near your current iRating ──────────────

CreateThread(function()
    while true do
        Wait(30 * 60 * 1000)   -- every 30 min
        for _, s in ipairs(GetPlayers()) do
            local src = tonumber(s)
            local pid = profileId(src)
            if pid then
                local rid = pickRival(pid)
                if rid then
                    MySQL.query.await(
                        "INSERT INTO rivals (player_id, rival_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE rival_id = VALUES(rival_id)",
                        { pid, rid })
                end
            end
        end
    end
end)

-- ── Leaderboard tablet: rival card + head-to-head times ──────────────────────
-- Returns the caller's rival and a per-track comparison of stored best laps.
-- Times stay in milliseconds; the UI formats them.

lib.callback.register("spz-progression:getRivalBoard", function(source)
    local pid = profileId(source)
    if not pid then return { rival = nil, tracks = {} } end

    local rid = getRival(pid)
    if not rid then return { rival = nil, tracks = {} } end

    local rival = MySQL.single.await(
        [[SELECT p.id, p.username, p.avatar_url, p.i_rating, p.rank, p.level,
                 p.alltime_points, r.assigned_at
          FROM rivals r
          JOIN players p ON p.id = r.rival_id
          WHERE r.player_id = ?]],
        { pid }
    )
    if not rival then return { rival = nil, tracks = {} } end

    local me = MySQL.single.await(
        -- `rank` is reserved in MySQL 8; unqualified it has to be quoted.
        "SELECT username, avatar_url, i_rating, `rank` AS rank_title FROM players WHERE id = ?", { pid }
    ) or {}

    -- One row per track either of you has driven; NULL means no time yet.
    -- The server-wide best and your standing on it give the expanded panel
    -- something the row itself doesn't already show.
    local rows = MySQL.query.await(
        [[SELECT r.track,
                 MAX(CASE WHEN r.player_id = ? THEN r.best_ms END) AS my_ms,
                 MAX(CASE WHEN r.player_id = ? THEN r.best_ms END) AS rival_ms,
                 (SELECT MIN(a.best_ms) FROM racelines a WHERE a.track = r.track)     AS track_best,
                 (SELECT p.username FROM racelines b JOIN players p ON p.id = b.player_id
                   WHERE b.track = r.track ORDER BY b.best_ms ASC LIMIT 1)            AS track_best_by,
                 (SELECT COUNT(*) FROM racelines c WHERE c.track = r.track)           AS drivers,
                 (SELECT COUNT(*) + 1 FROM racelines d
                   WHERE d.track = r.track
                     AND d.best_ms < MAX(CASE WHEN r.player_id = ? THEN r.best_ms END)) AS my_position
          FROM racelines r
          WHERE r.player_id IN (?, ?)
          GROUP BY r.track
          ORDER BY r.track ASC]],
        { pid, rid, pid, pid, rid }
    ) or {}

    local tracks, wins, losses = {}, 0, 0
    for _, r in ipairs(rows) do
        local mine  = tonumber(r.my_ms)
        local their = tonumber(r.rival_ms)
        if mine and their then
            if mine < their then wins = wins + 1 else losses = losses + 1 end
        end
        tracks[#tracks + 1] = {
            track    = r.track,
            my_ms    = mine,
            rival_ms = their,
            -- +ve margin = you are faster
            margin   = (mine and their) and (their - mine) or nil,
            -- expanded panel only
            track_best    = tonumber(r.track_best) or nil,
            track_best_by = r.track_best_by,
            drivers       = tonumber(r.drivers) or nil,
            my_position   = mine and (tonumber(r.my_position) or nil) or nil,
            gap_to_best   = (mine and r.track_best) and (mine - tonumber(r.track_best)) or nil,
        }
    end

    -- Recent takeovers either way, for the dashboard's activity list.
    local feedRows = MySQL.query.await([[
        SELECT e.track, e.new_ms, e.old_ms, e.margin_ms, e.created_at,
               e.actor_player_id, a.username AS actor, t.username AS target
        FROM rival_events e
        JOIN players a ON a.id = e.actor_player_id
        LEFT JOIN players t ON t.id = e.target_player_id
        WHERE e.kind = 'player'
          AND ((e.actor_player_id = ? AND e.target_player_id = ?)
            OR (e.actor_player_id = ? AND e.target_player_id = ?))
        ORDER BY e.created_at DESC
        LIMIT 12
    ]], { pid, rid, rid, pid }) or {}

    local feed = {}
    for _, r in ipairs(feedRows) do
        feed[#feed + 1] = {
            track = r.track, actor = r.actor, target = r.target,
            ours = r.actor_player_id == pid,
            new_ms = tonumber(r.new_ms), old_ms = tonumber(r.old_ms),
            margin_ms = tonumber(r.margin_ms), created_at = r.created_at,
        }
    end

    return {
        feed = feed,
        assigned_at = rival.assigned_at,
        me = {
            name    = me.username or "You",
            avatar  = me.avatar_url,
            iRating = tonumber(me.i_rating) or 1000,
            rank_title = me.rank_title,
        },
        rival = {
            name        = rival.username or "Rival",
            avatar      = rival.avatar_url,
            iRating     = tonumber(rival.i_rating) or 1000,
            rank_title  = rival.rank,
            level       = tonumber(rival.level) or 1,
            points      = tonumber(rival.alltime_points) or 0,
            assigned_at = rival.assigned_at,
        },
        head_to_head = { wins = wins, losses = losses, tracks = #tracks },
        tracks = tracks,
    }
end)

-- ── Redraw ────────────────────────────────────────────────────────────────────
-- Lets a driver pull a different rival once the current pairing has stood for a
-- while, so a mismatched draw isn't permanent.

local REROLL_COOLDOWN = 6 * 60 * 60   -- 6 hours

lib.callback.register("spz-progression:rerollRival", function(source)
    local pid = profileId(source)
    if not pid then return { ok = false, error = "No profile" } end

    local age = tonumber(MySQL.scalar.await(
        "SELECT TIMESTAMPDIFF(SECOND, assigned_at, NOW()) FROM rivals WHERE player_id = ? LIMIT 1", { pid }))
    if age and age < REROLL_COOLDOWN then
        local mins = math.ceil((REROLL_COOLDOWN - age) / 60)
        return { ok = false, error = ("Rival was just drawn — try again in %d min"):format(mins) }
    end

    local current = getRival(pid)
    local myIr = MySQL.scalar.await("SELECT i_rating FROM players WHERE id = ? LIMIT 1", { pid }) or 1500

    -- Closest rating that is neither us nor the rival we already have.
    local next_ = MySQL.scalar.await([[
        SELECT id FROM players
        WHERE id <> ? AND banned = 0 AND (? IS NULL OR id <> ?)
        ORDER BY ABS(COALESCE(i_rating, 1500) - ?) ASC
        LIMIT 1
    ]], { pid, current, current, myIr })
    if not next_ then return { ok = false, error = "No other driver to match against" } end

    MySQL.query.await(
        "INSERT INTO rivals (player_id, rival_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE rival_id = VALUES(rival_id), assigned_at = NOW()",
        { pid, next_ })
    return { ok = true }
end)
