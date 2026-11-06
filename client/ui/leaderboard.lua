-- client/ui/leaderboard.lua — leaderboard tablet page (/leaderboard, results, rank up).
-- Moved from spz-leaderboard/client/main.lua when it was merged into spz-races. Its page is still
-- the "spz-leaderboard" app in spz-hud; these locals send to that page only.
local SendNUIMessage, SetNuiFocus, SetNuiFocusKeepInput = SpzHudApp('spz-leaderboard')

-- client/main.lua
local isOpen = false

-- Base theme (server.cfg spz_theme_* convars via spz-core).
local function pushLeaderboardTheme(theme)
    if theme and next(theme) then
        SendNUIMessage({ action = 'theme', theme = theme })
    end
end
CreateThread(function()
    local ok, theme = pcall(function() return exports['spz-core']:GetTheme() end)
    if ok then pushLeaderboardTheme(theme) end
end)
AddEventHandler('SPZ:themeUpdated', function(theme) pushLeaderboardTheme(theme) end)

-- Default binding, declared once so the key registered here and the key the
-- race HUD prints are the same value.
-- Registry: Docs/keybinds.md
local KEY_BOARD = "F6"

-- The race this player last finished. Set by spz-races when results land, so
-- opening the board straight after a race lands on THAT race rather than making
-- the player hunt for it in the archive.
--
-- Only while the result is FRESH. The board is a general leaderboard as well as
-- a results screen; pressing the key an hour later should open the leaderboard,
-- not drop you back into a race you have stopped caring about.
local RESULTS_FRESH_MS = 5 * 60 * 1000

local lastRaceId = nil
local lastRaceAt = 0

RegisterNetEvent("SPZ:raceEnd", function(results)
    if results and results.raceId then
        lastRaceId = results.raceId
        lastRaceAt = GetGameTimer()
    end
end)

-- The deep-link target, or nil when there is nothing recent to show.
local function freshRaceOpts()
    if not lastRaceId then return nil end
    if (GetGameTimer() - lastRaceAt) > RESULTS_FRESH_MS then return nil end
    return { tab = "races", raceId = lastRaceId }
end

local function openBoard(opts)
    TriggerEvent("spz-analytics:feature", "leaderboard_open")   -- no-op without spz-analytics
    if isOpen then return end
    isOpen = true
    SetNuiFocus(true, true)
    pcall(function() exports['spz-core']:StartTablet() end)

    -- Name lets the UI mark and jump to the player's own row.
    local name = GetPlayerName(PlayerId())
    local ok, profile = pcall(function() return exports['spz-identity']:GetProfile() end)
    if ok and type(profile) == 'table' and profile.username then name = profile.username end

    SendNUIMessage({
        action = "open",
        player = name,
        -- nil for a normal open: the board starts where it always did.
        tab    = opts and opts.tab or nil,
        raceId = opts and opts.raceId or nil,
    })
end

local function closeBoard()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    pcall(function() exports['spz-core']:StopTablet() end)
    SendNUIMessage({ action = "close" })
end

-- spz-tutorial closes whatever it opened when the tour moves on.
AddEventHandler("spz-tutorial:closeUI", function() closeBoard() end)


-- F6. Straight into the race you just drove when one has just finished,
-- otherwise the leaderboard as it always opened.
RegisterCommand("leaderboard", function() openBoard(freshRaceOpts()) end, false)

-- Straight to the race you just drove. Called by spz-raceUI's post-race stats
-- screen ([Enter]); falls back to the plain board if no race has finished this
-- session (the race id arrives with SPZ:raceEnd, once the whole field is done).
-- Explicit results command: ignores the freshness window, because asking for
-- results by name means you want them however long ago the race was.
RegisterCommand("raceresults", function()
    openBoard(lastRaceId and { tab = "races", raceId = lastRaceId } or nil)
end, false)

exports("OpenLastRaceResults", function()
    openBoard(lastRaceId and { tab = "races", raceId = lastRaceId } or nil)
end)
RegisterKeyMapping("leaderboard", "Race results / leaderboard", "keyboard", KEY_BOARD)
RegisterKeyMapping("leaderboard", "Race results / leaderboard (controller)", "PAD_DIGITALBUTTON", "SELECT_INDEX")

-- Tell the race HUD which key opens results, so the in-race key strip prints it
-- alongside the recovery keys. spz-races pushes its own keys the same way; this
-- resource owns this one, so it pushes it itself rather than raceUI hardcoding
-- a value that lives here.
CreateThread(function()
    while GetResourceState("spz-races") ~= "started" do Wait(500) end
    pcall(function()
        exports["spz-races"]:SetKeyHints({ results = { cmd = "leaderboard", default = KEY_BOARD, pad = "SELECT_INDEX" } })
    end)
end)

-- ESC / Backspace fallback close
CreateThread(function()
    while true do
        if isOpen then
            if IsControlJustPressed(0, 200) or IsControlJustPressed(0, 177) then
                closeBoard()
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)

RegisterNUICallback("rerollRival", function(_, cb)
    local res = lib.callback.await("spz-progression:rerollRival", false)
    if res and res.ok then lib.notify({ description = "New rival drawn", type = "success" })
    else lib.notify({ description = (res and res.error) or "Failed", type = "error" }) end
    cb(res or { ok = false })
end)

RegisterNUICallback("lbClose", function(_, cb)
    closeBoard()
    cb("ok")
end)

-- ── Replays (spz-replay) ─────────────────────────────────────────────────────
-- Optional: with spz-replay stopped, the archive simply shows no replay buttons.
local function replayIds(raceIds)
    if GetResourceState("spz-replay") ~= "started" or #raceIds == 0 then return {} end
    return lib.callback.await("spz-replay:hasReplays", false, raceIds) or {}
end

RegisterNUICallback("lbWatchReplay", function(data, cb)
    if GetResourceState("spz-replay") ~= "started" then
        cb({ ok = false, error = "Replays are offline." })
        return
    end
    closeBoard()
    local ok, err = exports["spz-replay"]:WatchRace(data.raceId)
    if not ok then lib.notify({ title = "Replays", description = err or "Couldn't open that replay.", type = "error" }) end
    cb({ ok = ok })
end)

-- NUI asks for a tab's data → we relay to spz-races leaderboard callbacks
RegisterNUICallback("lbFetch", function(data, cb)
    local tab   = data.tab
    local class = data.class or "S"

    if tab == "standings" then
        lib.callback("spz-races:getGlobalStandings", false, function(r) cb(r or {}) end, { limit = 50 })

    elseif tab == "classes" then
        lib.callback("spz-races:getClassStandings", false, function(r) cb(r or {}) end, { class = class, limit = 50 })

    elseif tab == "records" then
        lib.callback("spz-races:getAllTrackRecords", false, function(r) cb(r or {}) end, {})

    elseif tab == "rivals" then
        lib.callback("spz-progression:getRivalBoard", false, function(r) cb(r or {}) end)

    elseif tab == "duels" then
        lib.callback("spz-races:getDuelBoard", false, function(r) cb(r or {}) end, { limit = 50 })

    elseif tab == "races" then
        -- Archive list, or one race in full when the UI asks for a specific id.
        -- Each race is tagged with has_replay when spz-replay stored one.
        if data.raceId then
            lib.callback("spz-races:getRaceResults", false, function(r)
                r = r or {}
                local has = replayIds({ data.raceId })
                r.has_replay = has[tostring(data.raceId)] == true
                cb(r)
            end, { raceId = data.raceId })
        else
            lib.callback("spz-races:getRaceArchive", false, function(rows)
                rows = rows or {}
                local ids = {}
                for i, r in ipairs(rows) do ids[i] = r.race_id end
                local has = replayIds(ids)
                for _, r in ipairs(rows) do r.has_replay = r.race_id ~= nil and has[tostring(r.race_id)] == true end
                cb(rows)
            end, { limit = 40 })
        end

    elseif tab == "activity" then
        lib.callback("spz-races:getActivityFeed", false, function(r) cb(r or {}) end, { limit = 50 })

    elseif tab == "me" then
        -- Stats power the tiles; the recent-race history powers the charts.
        lib.callback("spz-races:getPlayerStats", false, function(stats)
            lib.callback("spz-races:getPlayerHistory", false, function(hist)
                lib.callback("spz-races:getPlayerActivity", false, function(activity)
                    lib.callback("spz-races:getPlayerTrackSummary", false, function(tracks)
                        cb({
                            stats    = stats or {},
                            history  = (hist and hist.rows) or {},
                            activity = activity or {},   -- day x track counts (heatmap)
                            tracks   = tracks or {},     -- career totals per track (filter)
                        })
                    end, {})
                end, { days = 364 })
            end, { page = 1, pageSize = 60 })
        end, {})

    else
        cb({})
    end
end)

-- ── Rank-up animation ───────────────────────────────────────────────────────
-- spz-progression fires this on every rank change; promotions get the
-- Blender build-up (ui/rankup.js, Assets/rankfx). It plays over gameplay
-- without taking focus.
--
-- One race can move the rank twice: the race's own RP, then a flat bonus a
-- moment later (perfect lap / track record, spz-progression GrantFlatRP). Each
-- fires SPZ:rankChanged, which played two animations back to back (C-5 → C-4,
-- then C-4 → C-3). Changes landing within MERGE_MS are folded into ONE
-- animation from the first old rank to the latest new rank.
local MERGE_MS = 2500
local pending = nil      -- { oldRank, newRank, token }

RegisterNetEvent("SPZ:rankChanged", function(d)
    if type(d) ~= "table" or not d.isPromotion then return end
    if pending then
        pending.newRank = d.newRank            -- keep the first old rank
    else
        pending = { oldRank = d.oldRank, newRank = d.newRank }
    end
    local token = {}
    pending.token = token
    SetTimeout(MERGE_MS, function()
        if not pending or pending.token ~= token then return end   -- a newer change extended the wait
        local p = pending
        pending = nil
        SendNUIMessage({ action = "rankUp", oldRank = p.oldRank, newRank = p.newRank, isPromotion = true })
        PlaySoundFrontend(-1, "RANK_UP", "HUD_AWARDS", true)
    end)
end)

-- /rankuptest <old> <new> — preview either animation:
--   /rankuptest B-5 A-1   tier change: full build
--   /rankuptest A-2 A-3   same tier:   the new bar lights up
RegisterCommand("rankuptest", function(_, args)
    SendNUIMessage({ action = "rankUp", oldRank = args[1] or "B-5", newRank = args[2] or "A-1", isPromotion = true })
    PlaySoundFrontend(-1, "RANK_UP", "HUD_AWARDS", true)
end, false)
