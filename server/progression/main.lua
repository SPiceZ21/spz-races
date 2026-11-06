-- server/progression/main.lua — progression: main.
-- Moved from spz-progression/server/main.lua when it was merged into spz-races.
local Config = Config.Progression

-- server/main.lua
-- Race -> progression pipeline (ranking v3).
--
-- Runs once per race on SPZ:raceEnd (never SPZ:racerFinished — that fires per
-- finisher with an incomplete field). Order of work:
--
--   1. map the race payload to entries (the ONLY translation point from
--      spz-races fields: personal_best, collisions, laps, rewind_ms ...)
--   2. drop anyone already awarded for this race (rank_awards ledger)
--   3. snapshot every player's RP / iRating BEFORE changing anything, so the
--      result never depends on loop order
--   4. compute XP, SR, iRating and RP per player with the pure domain/ code
--   5. write each profile once, write the award rows in one insert, emit
--      SPZ:progressionApplied once for the whole race
--
-- Rank, SR, iRating and the top-3 count only move in RATED races
-- (N >= Config.Rules.ratedMinField). A solo race still pays XP, nothing else —
-- that closes the old solo-farming hole (+25 iRating / free top-3 per race).
-- There is no maximum field size anywhere in this file.

local Log   = SPZ.Logger("spz-progression")
local Rules = Config.Rules
local Rows  = SPZ.Rank.BuildTable(Rules)
SPZ.RankRows = Rows

local function DayNumber() return math.floor(os.time() / 86400) end
local function DayKey()    return os.date("!%Y-%m-%d") end

-- DNF reasons that remove a player from the field entirely instead of
-- counting as last place.
local EXCLUDED_REASONS = { admin = true, dq = true, cheat = true }

-- Racers who disconnected before results were scored are no longer in
-- spz-identity's cache. They still count in the field (a rage-quit is a DNF,
-- and removing them would change everyone else's field size), so they are
-- loaded and written directly.
local OFFLINE_COLS = { "rank_points", "rank_streak", "rp_day_gain", "rp_day_key", "rank", "license_tier",
    "sr", "sr_daily_gain", "sr_daily_loss", "sr_day_marker", "i_rating", "xp", "level", "alltime_points",
    "top3_count", "last_race_at", "last_race_track", "same_track_count" }

local function LoadOffline(identifier)
    if not identifier then return nil end
    local row = MySQL.single.await("SELECT id, `" .. table.concat(OFFLINE_COLS, "`, `")
        .. "` FROM players WHERE identifier = ? LIMIT 1", { identifier })
    if row then row._offline = true end
    return row
end

local function SaveOffline(profile, changes)
    local sets, params = {}, {}
    for _, col in ipairs(OFFLINE_COLS) do
        if changes[col] ~= nil then
            sets[#sets + 1] = "`" .. col .. "` = ?"
            params[#params + 1] = changes[col]
        end
    end
    if #sets == 0 then return end
    params[#params + 1] = profile.id
    MySQL.update.await("UPDATE players SET " .. table.concat(sets, ", ") .. " WHERE id = ?", params)
end

-- ── 1. Map spz-races results -> entries ───────────────────────────────────
local function MapRace(results)
    local entries = {}

    local function add(r, dnf)
        if not r or not r.source then return end
        if dnf and EXCLUDED_REASONS[r.dnf_reason or ""] then return end
        local profile = exports["spz-identity"]:GetProfile(r.source)
        if not profile then profile = LoadOffline(r.identifier) end
        if not profile then return end
        local incidents = r.collisions and #r.collisions or 0
        entries[#entries + 1] = {
            src          = r.source,
            profile      = profile,
            position     = (not dnf) and r.position or nil,
            dnf          = dnf,
            incidents    = incidents,
            clean        = (not dnf) and incidents == 0,
            personalBest = (not dnf) and r.personal_best == true and (r.rewind_ms or 0) == 0,
            rewindMs     = r.rewind_ms or 0,
            laps         = results.laps or 0,
            class        = results.carClass,
        }
    end

    for _, f in ipairs(results.finishers or {}) do add(f, false) end
    for _, d in ipairs(results.dnf or {})       do add(d, true)  end

    -- Finishers keep their race order but are renumbered 1..k (positions can
    -- have gaps once excluded players are removed); every DNF shares last.
    table.sort(entries, function(a, b)
        if a.dnf ~= b.dnf then return not a.dnf end
        if a.dnf then return false end
        return a.position < b.position
    end)
    local n = #entries
    local k = 0
    for _, e in ipairs(entries) do
        if e.dnf then e.position = n else k = k + 1; e.position = k end
    end
    return entries
end

-- ── XP anti-abuse (unchanged rules, XP only) ──────────────────────────────
local function XPMultiplier(profile, raceData, finishers, now)
    local m = 1.0
    local aa = Config.AntiAbuse
    if profile.last_race_at and profile.last_race_at > 0
       and (now - profile.last_race_at) < aa.minSecondsBetweenRaces then
        m = m * 0.5
    end
    if finishers < aa.minFinishersForFullXP then
        m = m * aa.smallRacePenalty
    end
    local sameCount = 0
    if profile.last_race_track == raceData.trackId then
        sameCount = (profile.same_track_count or 0) + 1
        if sameCount >= aa.sameTrackThreshold then
            m = m * ((sameCount == aa.sameTrackThreshold) and aa.sameTrackPenalty4 or aa.sameTrackPenalty5plus)
        end
    end
    return m, sameCount
end

-- ── Award ledger ──────────────────────────────────────────────────────────
local function AlreadyAwarded(raceId)
    local done = {}
    local rows = MySQL.query.await("SELECT player_id FROM rank_awards WHERE race_id = ?", { raceId }) or {}
    for _, r in ipairs(rows) do done[r.player_id] = true end
    return done
end

local function WriteAwards(rows)
    if #rows == 0 then return end
    local groups, params = {}, {}
    for _, a in ipairs(rows) do
        groups[#groups + 1] = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())"
        for _, v in ipairs({ a.race_id, a.player_id, a.n_field, a.position, a.rp_before,
                             a.rp_after, a.delta, a.breakdown, Rules.version, 0 }) do
            params[#params + 1] = v
        end
    end
    MySQL.query.await(
        "INSERT IGNORE INTO rank_awards (race_id, player_id, n_field, position, rp_before, rp_after, "
        .. "delta, breakdown, rules_ver, voided, created_at) VALUES " .. table.concat(groups, ", "),
        params)
end

-- race_results rows are written by spz-races on the same event; fill in the
-- real deltas. Its insert can land after ours, so retry briefly until the row
-- exists (bounded, and harmless if it never does).
local function BackfillRaceResults(raceId, rows)
    if #rows == 0 then return end
    CreateThread(function()
        local pending = rows
        for attempt = 1, 5 do
            local left = {}
            for _, r in ipairs(pending) do
                local n = MySQL.update.await([[
                    UPDATE race_results SET points_earned = ?, sr_change = ?, irating_change = ?, xp_earned = ?
                    WHERE race_id = ? AND player_id = ?
                ]], { r.rp, r.sr, r.ir, r.xp, raceId, r.player_id })
                if not n or n == 0 then left[#left + 1] = r end
            end
            if #left == 0 then return end
            pending = left
            Wait(1000 * attempt)
        end
    end)
end

-- ── Rank change notification (shared with admin commands) ──────────────────
function NotifyRankChange(src, oldRank, newRank)
    if not oldRank or oldRank == newRank then return end
    local dir = SPZ.Rank.Compare(oldRank, newRank, Rows)
    TriggerEvent("SPZ:rankChanged", src, oldRank, newRank, dir > 0)
    TriggerClientEvent("SPZ:rankChanged", src, {
        oldRank = oldRank, newRank = newRank, isPromotion = dir > 0,
    })
end

-- ── The pipeline ──────────────────────────────────────────────────────────
local function ProcessRace(results)
    if not results or (not results.finishers and not results.dnf) then return end
    if (results.duration or 0) < Rules.minDurationSeconds then
        Log.info(("Race %s void: under %ds"):format(tostring(results.raceId), Rules.minDurationSeconds))
        return
    end

    local raceId  = results.raceId
    local entries = MapRace(results)
    local n       = #entries
    if n == 0 then return end

    local rated   = n >= Rules.ratedMinField
    local now     = os.time()
    local day     = DayNumber()
    local dayKey  = DayKey()
    local finishers = #(results.finishers or {})

    -- 2. idempotency: a race id is only ever scored once per player
    local done = {}
    if raceId and raceId ~= "N/A" then done = AlreadyAwarded(raceId) end

    -- 3. snapshot before any write
    local totalRP = 0
    local irField = {}
    for _, e in ipairs(entries) do
        local p = e.profile
        e.rpBefore   = tonumber(p.rank_points) or 0
        e.irBefore   = tonumber(p.i_rating) or Config.IRating.startingValue
        e.srBefore   = tonumber(p.sr) or Config.SR.startingValue
        e.rankBefore = p.rank or "C-5"
        e.tierBefore = tonumber(p.license_tier) or 0
        e.skip       = done[p.id] == true
        totalRP = totalRP + e.rpBefore
        irField[#irField + 1] = { key = e.src, rating = e.irBefore, position = e.position, dnf = e.dnf }
    end

    local irDeltas = rated and SPZ.IRating.Deltas(irField, Config.IRating) or {}
    local streakTop = SPZ.RP.StreakTop(n, Rules)

    local awards, resultsRows, applied = {}, {}, {}

    for _, e in ipairs(entries) do
        if not e.skip then
            local p   = e.profile
            local src = e.src

            -- XP (every race, rated or not)
            local xpMult, sameCount = XPMultiplier(p, results, finishers, now)
            local xpGain = math.floor(exports["spz-races"]:CalculateXP({
                dnf = e.dnf, position = e.position, class = e.class, laps = e.laps,
                cleanRace = e.clean, personalBest = e.personalBest,
            }) * xpMult)
            local oldLevel = p.level or 1
            local newXP    = (p.xp or 0) + xpGain
            local newLevel = exports["spz-races"]:LevelFromXP(newXP)

            local changes = {
                xp = newXP, level = newLevel,
                last_race_at = now, last_race_track = results.trackId,
                same_track_count = sameCount,
            }

            local srApplied, irDelta, rpDelta, rpRaw = 0, 0, 0, 0
            local rankAfter, tierAfter = e.rankBefore, e.tierBefore
            local rpAfter = e.rpBefore

            if rated then
                -- SR with daily caps
                local srDelta = SPZ.SR.Delta({
                    dnf = e.dnf, position = e.position,
                    personalBest = e.personalBest, incidents = e.incidents,
                }, Config.SR)
                local newSR, appliedSR, srDay = SPZ.SR.Apply(e.srBefore, srDelta, {
                    gain = p.sr_daily_gain, loss = p.sr_daily_loss, marker = p.sr_day_marker,
                }, day, Config.SR)
                srApplied = appliedSR
                changes.sr = newSR
                changes.sr_daily_gain, changes.sr_daily_loss, changes.sr_day_marker = srDay.gain, srDay.loss, srDay.marker

                -- iRating (zero-sum Elo)
                irDelta = irDeltas[src] or 0
                changes.i_rating = SPZ.IRating.Clamp(e.irBefore + irDelta, Config.IRating)

                -- Rank Points
                local fieldAvg = (n > 1) and (totalRP - e.rpBefore) / (n - 1) or 0
                local streak   = tonumber(p.rank_streak) or 0
                rpRaw = SPZ.RP.Compute({
                    position = e.position, n = n, rp = e.rpBefore, fieldAvg = fieldAvg,
                    dnf = e.dnf, clean = e.clean, streak = streak,
                }, Rules)
                local dayGain = (p.rp_day_key == dayKey) and (tonumber(p.rp_day_gain) or 0) or 0
                local floor   = SPZ.Rank.ClassFloor(e.rpBefore, Rules)
                rpDelta, rpAfter = SPZ.RP.Apply(e.rpBefore, rpRaw, floor, dayGain, Rules)
                rankAfter, tierAfter = SPZ.Rank.For(rpAfter, Rows)

                changes.rank_points    = rpAfter
                changes.rank_streak    = ((not e.dnf) and e.position <= streakTop) and (streak + 1) or 0
                changes.rp_day_key     = dayKey
                changes.rp_day_gain    = dayGain + math.max(0, rpDelta)
                changes.rank           = rankAfter
                changes.alltime_points = (p.alltime_points or 0) + math.max(0, rpDelta)
                if (not e.dnf) and e.position <= 3 then
                    changes.top3_count = (p.top3_count or 0) + 1
                end

                awards[#awards + 1] = {
                    race_id = raceId, player_id = p.id, n_field = n, position = e.position,
                    rp_before = e.rpBefore, rp_after = rpAfter, delta = rpDelta,
                    breakdown = json.encode({ raw = rpRaw, streak = streak, clean = e.clean,
                                              fieldAvg = math.floor(fieldAvg), dnf = e.dnf }),
                }
            end

            local offline = p._offline == true
            if offline then
                changes.license_tier = tierAfter
                SaveOffline(p, changes)
            else
                exports["spz-identity"]:UpdateProfile(src, changes)

                -- Class promotion: spz-identity stores it, audits it and is the
                -- single emitter of SPZ:licenseUnlocked.
                if tierAfter > e.tierBefore then
                    exports["spz-identity"]:UnlockLicense(src, tierAfter, "rank_points", rankAfter)
                end
                NotifyRankChange(src, e.rankBefore, rankAfter)
                if newLevel > oldLevel then
                    TriggerEvent("SPZ:levelUp", src, oldLevel, newLevel)
                end
            end

            local xpCur  = exports["spz-races"]:XPRequired(newLevel)
            local xpNext = exports["spz-races"]:XPRequired(newLevel + 1)
            local rankProgress, nextRank = SPZ.Rank.Progress(rpAfter, Rows)

            if not offline then TriggerClientEvent("SPZ:progressionUpdate", src, {
                rated        = rated,
                xpGain       = xpGain,
                xpProgress   = (xpNext > xpCur) and (newXP - xpCur) / (xpNext - xpCur) or 0,
                level        = newLevel,
                levelUp      = newLevel > oldLevel,
                rpGain       = rpDelta,
                rp           = rpAfter,
                rank         = rankAfter,
                nextRank     = nextRank,
                rankProgress = rankProgress,
                rankUp       = SPZ.Rank.Compare(e.rankBefore, rankAfter, Rows) > 0,
                -- legacy names read by spz-races/client/nui_bridge.lua
                pointsGain   = rpDelta,
                cpProgress   = rankProgress,
                srDelta      = srApplied,
                irDelta      = irDelta,
            }) end

            resultsRows[#resultsRows + 1] = { player_id = p.id, rp = rpDelta, sr = srApplied, ir = irDelta, xp = xpGain }
            applied[#applied + 1] = {
                source = (not offline) and src or nil, offline = offline, playerId = p.id, position = e.position, dnf = e.dnf, rated = rated,
                rpBefore = e.rpBefore, rpAfter = rpAfter, rpDelta = rpDelta,
                rankBefore = e.rankBefore, rankAfter = rankAfter,
                tierBefore = e.tierBefore, tierAfter = tierAfter,
                srBefore = e.srBefore, srAfter = changes.sr or e.srBefore,
                irBefore = e.irBefore, irAfter = changes.i_rating or e.irBefore,
                xpGain = xpGain,
            }
        end
    end

    if raceId and raceId ~= "N/A" then
        local ok, err = pcall(WriteAwards, awards)
        if not ok then Log.error("rank_awards insert failed: " .. tostring(err)) end
        BackfillRaceResults(raceId, resultsRows)
    end

    -- One event for the whole race (analytics, Discord, UI consumers).
    TriggerEvent(SPZ.Events.PROGRESSION_APPLIED or "SPZ:progressionApplied", {
        raceId = raceId, trackId = results.trackId, n = n, rated = rated, players = applied,
    })
end

AddEventHandler(SPZ.Events.RACE_END or "SPZ:raceEnd", function(results)
    CreateThread(function()
        local ok, err = pcall(ProcessRace, results)
        if not ok then Log.error("ProcessRace failed: " .. tostring(err)) end
    end)
end)

-- ── Keep the stored rank consistent with RP on join ───────────────────────
-- Covers the backfill and any manual DB edit: rank string and class letter are
-- always derived from rank_points, never authoritative on their own.
function SyncRankFromRP(src)
    local p = exports["spz-identity"]:GetProfile(src)
    if not p then return end
    local rank, tier = SPZ.Rank.For(tonumber(p.rank_points) or 0, Rows)
    local changes = {}
    if p.rank ~= rank then changes.rank = rank end
    if (tonumber(p.license_tier) or 0) ~= tier then changes.license_tier = tier end
    if next(changes) then exports["spz-identity"]:UpdateProfile(src, changes) end
end

AddEventHandler("SPZ:playerReady", function(src)
    SyncRankFromRP(src)
end)

CreateThread(function()
    Wait(2000)
    for _, s in ipairs(GetPlayers()) do SyncRankFromRP(tonumber(s)) end
end)

-- ── Read exports ──────────────────────────────────────────────────────────
