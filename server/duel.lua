-- server/duel.lua
-- Ghost duels: async PvP wagers. A challenger stakes credits and races an
-- opponent's STORED best line (a ghost) on a track. Beat the opponent's stored
-- time → win the pot; miss it → forfeit the stake. The opponent need not be
-- online — it's their recorded line, not them.
--
-- Reuses the Time-Trial harness (timetrail.lua) for the bucket, checkpoint
-- timing and ghost. This file owns the wager: validation, escrow, the duels
-- ledger and settlement. The server is the sole authority on the outcome — it
-- compares its own measured lap time to the stored best_ms; the client never
-- reports who won.

-- spz-races does not load spz-core's shared logger, so SPZ.Logger is nil in this
-- environment — calling it aborted the whole resource at load. Use it when it is
-- there, otherwise fall back to a printing stub with the same API.
local Log = (SPZ and SPZ.Logger and SPZ.Logger("spz-duel")) or (function()
    local function out(level, msg, ...)
        local ok, formatted = pcall(string.format, msg, ...)
        print(("[spz-duel] [%s]: %s"):format(level, ok and formatted or msg))
    end
    return {
        debug = function(msg, ...) out("DEBUG", msg, ...) end,
        info  = function(msg, ...) out("INFO",  msg, ...) end,
        warn  = function(msg, ...) out("WARN",  msg, ...) end,
        error = function(msg, ...) out("ERROR", msg, ...) end,
    }
end)()
local DUEL = nil   -- Config.Duel, resolved on first use

local function cfg()
    DUEL = DUEL or (Config.Duel or {})
    return DUEL
end

-- ── Credit helpers ────────────────────────────────────────────────────────────

local function addCreditsOnline(src, amount, reason)
    local prof = exports["spz-identity"]:GetProfile(src)
    if not prof then return end
    exports["spz-identity"]:UpdateProfile(src, { credits = (prof.credits or 0) + amount })
    MySQL.insert("INSERT INTO economy_transactions (player_id, amount, balance, reason) VALUES (?, ?, ?, ?)",
        { prof.id, amount, (prof.credits or 0) + amount, reason })
end

local function addCreditsByPid(pid, amount, reason)
    MySQL.update.await("UPDATE players SET credits = credits + ? WHERE id = ?", { amount, pid })
    local bal = MySQL.scalar.await("SELECT credits FROM players WHERE id = ?", { pid }) or 0
    MySQL.insert("INSERT INTO economy_transactions (player_id, amount, balance, reason) VALUES (?, ?, ?, ?)",
        { pid, amount, bal, reason })
end

-- ── Resolution ────────────────────────────────────────────────────────────────

-- Map a player_id back to an online source, or nil.
local function srcFromPid(pid)
    for _, sid in ipairs(GetPlayers()) do
        local s = tonumber(sid)
        local ok, prof = pcall(function() return exports["spz-identity"]:GetProfile(s) end)
        if ok and prof and prof.id == pid then return s end
    end
    return nil
end

-- Resolve an opponent argument (server id or username) to { pid, name }.
local function resolveOpponent(arg)
    -- Online server id?
    local asId = tonumber(arg)
    if asId and GetPlayerName(asId) ~= nil then
        local ok, prof = pcall(function() return exports["spz-identity"]:GetProfile(asId) end)
        if ok and prof and prof.id then return { pid = prof.id, name = prof.username or GetPlayerName(asId) } end
    end

    -- Online by name (case-insensitive)?
    local low = tostring(arg):lower()
    for _, sid in ipairs(GetPlayers()) do
        local s = tonumber(sid)
        local ok, prof = pcall(function() return exports["spz-identity"]:GetProfile(s) end)
        if ok and prof and prof.username and prof.username:lower() == low then
            return { pid = prof.id, name = prof.username }
        end
    end

    -- Offline by name in the DB.
    local row = MySQL.query.await(
        "SELECT id, username FROM players WHERE LOWER(username) = ? LIMIT 1", { low })
    if row and row[1] then return { pid = row[1].id, name = row[1].username } end

    return nil
end

-- Resolve a track argument (name or index key) to { track, index }.
local function resolveTrack(arg)
    -- Direct index key
    if SPZ.Tracks[arg] then return SPZ.Tracks[arg], arg end
    local asNum = tonumber(arg)
    if asNum and SPZ.Tracks[asNum] then return SPZ.Tracks[asNum], asNum end

    local low = tostring(arg):lower()
    for idx, t in pairs(SPZ.Tracks) do
        if t.name and t.name:lower() == low then return t, idx end
    end
    return nil
end

-- ── Settlement (called from timetrail.lua on the timed lap) ──────────────────

function OnDuelLap(src, s, lapTime)
    local d = s.duel
    local c = cfg()
    local win = lapTime < d.targetMs
    local houseFunded = c.HouseFunded ~= false

    if win then
        -- Stake back + matched winnings = stake * 2 to the challenger.
        addCreditsOnline(src, d.stake * 2, "Ghost duel won")
        if not houseFunded then
            -- Opponent's balance covers the matched stake.
            addCreditsByPid(d.oppPid, -d.stake, "Ghost duel lost (defended)")
        end
    else
        -- Stake already escrowed; it's forfeit. Opponent "defends".
        if not houseFunded then
            addCreditsByPid(d.oppPid, d.stake, "Ghost duel won (defended)")
        end
    end

    -- Ledger
    MySQL.update(
        "UPDATE duels SET result_ms = ?, outcome = ?, settled_at = CURRENT_TIMESTAMP WHERE id = ?",
        { lapTime, win and "win" or "loss", d.duelId })

    -- Notify challenger
    local function fmt(ms)
        local m = math.floor(ms / 60000); local sec = (ms % 60000) / 1000
        return ("%d:%06.3f"):format(m, sec)
    end
    SPZ.Notify(src, win
        and ("DUEL WON vs %s — %s beats %s. +%d credits!"):format(d.oppName, fmt(lapTime), fmt(d.targetMs), d.stake)
        or  ("DUEL LOST vs %s — %s vs target %s. -%d credits."):format(d.oppName, fmt(lapTime), fmt(d.targetMs), d.stake),
        win and "success" or "error", 9000)

    -- Async ping to the opponent if they're online.
    local oppSrc = srcFromPid(d.oppPid)
    if oppSrc then
        SPZ.Notify(oppSrc, win
            and ("Your ghost was BEATEN by a challenger on %s (%s)."):format(s.track.name, fmt(lapTime))
            or  ("Your ghost DEFENDED a duel on %s (challenger ran %s)."):format(s.track.name, fmt(lapTime)),
            win and "warning" or "success", 8000)
    end

    -- Discord
    pcall(function()
        exports["spz-log"]:Log("duel", "Ghost Duel",
            ("%s challenged %s's ghost on %s for %d — %s (%s vs %s)")
            :format(GetPlayerName(src) or "?", d.oppName, s.track.name, d.stake,
                    win and "CHALLENGER WON" or "CHALLENGER LOST", fmt(lapTime), fmt(d.targetMs)),
            win and "success" or "warning")
    end)

    Log.info(("Duel %s settled: challenger=%s opp=%s stake=%d win=%s")
        :format(d.duelId, d.challengerPid, d.oppPid, d.stake, tostring(win)))

    EndDuelSession(src)
end

-- ── /duel <name|id> <track...> <stake> ────────────────────────────────────────

RegisterCommand("duel", function(source, args)
    local src = source
    local c = cfg()
    if c.Enabled == false then return end

    if #args < 3 then
        SPZ.Notify(src, "Usage: /duel <player|id> <track> <stake>", "error")
        return
    end

    -- opponent = first arg, stake = last arg, track = everything between (name may
    -- contain spaces).
    local oppArg   = args[1]
    local stakeArg = args[#args]
    local trackArg = table.concat(args, " ", 2, #args - 1)
    local stake    = math.floor(tonumber(stakeArg) or 0)

    -- Busy checks
    if IsBusyInTT(src) then
        SPZ.Notify(src, "Finish your current session first (/quittt).", "error"); return
    end
    local st = Player(src).state
    if st and (st.inRace or st.inQueue) then
        SPZ.Notify(src, "You can't duel while in a race.", "error"); return
    end

    -- Stake bounds
    if stake < (c.MinStake or 1) then SPZ.Notify(src, ("Minimum stake is %d."):format(c.MinStake or 1), "error"); return end
    if stake > (c.MaxStake or math.huge) then SPZ.Notify(src, ("Maximum stake is %d."):format(c.MaxStake), "error"); return end

    -- Resolve challenger profile / balance
    local me = exports["spz-identity"]:GetProfile(src)
    if not me then SPZ.Notify(src, "Profile not ready.", "error"); return end
    if (me.credits or 0) < stake then SPZ.Notify(src, "Not enough credits.", "error"); return end

    -- Resolve track + opponent
    local track, trackIndex = resolveTrack(trackArg)
    if not track then SPZ.Notify(src, ("No track matching '%s'."):format(trackArg), "error"); return end
    if not track.checkpoints or #track.checkpoints < 2 then
        SPZ.Notify(src, "That track can't be dueled.", "error"); return
    end

    local opp = resolveOpponent(oppArg)
    if not opp then SPZ.Notify(src, ("No player matching '%s'."):format(oppArg), "error"); return end
    if opp.pid == me.id then SPZ.Notify(src, "You can't duel yourself.", "error"); return end

    -- Opponent must have a stored line on this track.
    local line = exports["spz-raceline"]:GetLineByPlayerId(opp.pid, track.name)
    if not line or not line.points or not line.ms or line.ms <= 0 then
        SPZ.Notify(src, ("%s has no stored line on %s."):format(opp.name, track.name), "error"); return
    end

    -- ── Escrow the stake immediately ──────────────────────────────────────────
    exports["spz-identity"]:UpdateProfile(src, { credits = (me.credits or 0) - stake })
    MySQL.insert("INSERT INTO economy_transactions (player_id, amount, balance, reason) VALUES (?, ?, ?, ?)",
        { me.id, -stake, (me.credits or 0) - stake, "Ghost duel stake" })

    -- Ledger row (pending)
    local duelId = MySQL.insert.await(
        "INSERT INTO duels (challenger_id, opponent_id, track, stake, target_ms) VALUES (?, ?, ?, ?, ?)",
        { me.id, opp.pid, track.name, stake, line.ms })

    -- Start the duel session (reuses the TT harness).
    local ok = StartDuelSession(src, {
        track = track, trackIndex = trackIndex,
        oppLine = { model = line.model, points = line.points },
        targetMs = line.ms, oppName = opp.name, oppPid = opp.pid,
        challengerPid = me.id, stake = stake, duelId = duelId,
    })

    if not ok then
        -- Refund on failure to start.
        exports["spz-identity"]:UpdateProfile(src, { credits = me.credits or 0 })
        MySQL.update("UPDATE duels SET outcome = 'void', settled_at = CURRENT_TIMESTAMP WHERE id = ?", { duelId })
        SPZ.Notify(src, "Couldn't start the duel — stake refunded.", "error")
        return
    end

    local function fmt(ms) local m=math.floor(ms/60000); return ("%d:%06.3f"):format(m,(ms%60000)/1000) end
    SPZ.Notify(src, ("DUEL: beat %s's %s on %s to win %d credits. Drive!")
        :format(opp.name, fmt(line.ms), track.name, stake), "info", 9000)
end, false)

-- Refund an unfinished duel — called by timetrail._endSession when a duel
-- session tears down without a settled lap (quit /quittt, disconnect, or a
-- failed start). The attempt never counted, so the escrowed stake comes back.
function RefundDuel(d)
    if not d or d.settled or d.refunded then return end
    d.refunded = true

    local src = srcFromPid(d.challengerPid)
    if src then
        addCreditsOnline(src, d.stake, "Ghost duel refunded")
        SPZ.Notify(src, ("Duel cancelled — %d credits refunded."):format(d.stake), "warning")
    else
        addCreditsByPid(d.challengerPid, d.stake, "Ghost duel refunded")
    end

    MySQL.update("UPDATE duels SET outcome = 'void', settled_at = CURRENT_TIMESTAMP WHERE id = ?", { d.duelId })
    Log.info(("Duel %s voided/refunded (stake %d)"):format(d.duelId, d.stake))
end
