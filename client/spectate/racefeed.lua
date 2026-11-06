-- client/spectate/racefeed.lua — spectate (racefeed).
-- Moved from spz-spectate/client/racefeed.lua when it was merged into spz-races.
-- Its page is still the "spz-spectate" app in spz-hud; these locals send to that page only.
local SendNUIMessage, SetNuiFocus, SetNuiFocusKeepInput = SpzHudApp('spz-spectate')
local Config = Config.Spectate

-- client/racefeed.lua
-- Passive live-standings board for players outside the race. No focus, no
-- input, no NUI cursor — it is a read-only overlay you drive past.
--
-- Sits top-right, clear of the spectator bar this resource renders along the
-- bottom, so both can be up at once without overlapping.

local CFG  = (Config and Config.Board) or {}
local KEYS = CFG.keys or {}

local lastBoard = nil

-- View state. `lastSize` remembers which size to come back to when the board is
-- un-hidden, so hiding is never destructive to the player's chosen size.
local VIEWS    = { full = true, mini = true, hidden = true }
local view     = VIEWS[CFG.defaultView] and CFG.defaultView or "full"
local lastSize = view ~= "hidden" and view or "full"

-- ── Audience ─────────────────────────────────────────────────────────────────
-- Racers already carry the full tower in spz-raceUI; a second one would just
-- cover the road. Everyone else — freeroamers, spectators, and (by config) the
-- queue waiting for the next cycle — is the audience for this board.
--
-- Not yet in the world either: spz-spawn publishes `spawned` / `spawnMenuOpen`
-- as client-local statebags, and the board was painting over the spawn menu (and
-- over the moment the loading screen came down) for anyone who joined while a
-- race was running. Both are nil when spz-spawn is not running, which reads as
-- "in the world" so the board is never lost on a server without it.
local function isAudience()
    local st = LocalPlayer.state
    if st.spawnMenuOpen then return false end
    if st.spawned == false then return false end
    if st.inRace then return false end
    if st.inQueue and CFG.showToQueued == false then return false end
    return true
end

local function paint()
    if CFG.enabled == false or view == "hidden"
    or not lastBoard or not lastBoard.active or not isAudience() then
        SendNUIMessage({ action = "boardHide" })
        return
    end
    SendNUIMessage({
        action  = "board",
        board   = lastBoard,
        view    = view,
        maxRows = (view == "mini") and (CFG.miniRows or 3) or (CFG.maxRows or 8),
        keys    = { cycle = KEYS.cycle or "", hide = KEYS.hide or "" },
    })
end

RegisterNetEvent("spz-spectate:board", function(board)
    lastBoard = board
    paint()
end)

-- inRace / inQueue flip without a new board arriving (you finish, you DNF, you
-- join the queue), and the board has to follow that immediately rather than at
-- the next standings tick.
local myBag = ("player:%s"):format(GetPlayerServerId(PlayerId()))
AddStateBagChangeHandler("inRace",  myBag, function() paint() end)
AddStateBagChangeHandler("inQueue", myBag, function() paint() end)

-- Same for leaving the spawn menu: the board has to appear the moment the
-- player is actually in the world, not at the next standings tick.
AddStateBagChangeHandler("spawned",       myBag, function() paint() end)
AddStateBagChangeHandler("spawnMenuOpen", myBag, function() paint() end)

-- Joining mid-race: ask for the current board instead of waiting a tick.
CreateThread(function()
    Wait(2000)
    TriggerServerEvent("spz-spectate:requestBoard")
end)

-- ── View control ─────────────────────────────────────────────────────────────
-- Feedback is the board itself changing, not a toast: this fires on a keypress
-- the player just made, and a notification per press would be noise. The one
-- case that does need words is hiding — the board vanishing looks identical to
-- the board breaking, so that transition says where it went.
local function setView(next)
    if not VIEWS[next] then return end
    view = next
    if next ~= "hidden" then lastSize = next end
    paint()
end

local CYCLE = { full = "mini", mini = "hidden", hidden = "full" }

local function hiddenNotice(key, cmd)
    lib.notify({
        title = "Race board",
        description = ("Hidden — %s to bring it back")
            :format((key ~= "" and key) or ("/" .. cmd)),
        type = "info",
    })
end

RegisterCommand("raceboard", function()
    local nextView = CYCLE[view] or "full"
    setView(nextView)
    if nextView == "hidden" then hiddenNotice(KEYS.cycle or "", "raceboard") end
end, false)

RegisterCommand("raceboard_hide", function()
    if view == "hidden" then
        setView(lastSize)
    else
        setView("hidden")
        hiddenNotice(KEYS.hide or "", "raceboard_hide")
    end
end, false)

RegisterKeyMapping("raceboard", "Race board: cycle full / mini / hidden", "keyboard", KEYS.cycle or "")
RegisterKeyMapping("raceboard_hide", "Race board: hide or restore", "keyboard", KEYS.hide or "")

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then SendNUIMessage({ action = "boardHide" }) end
end)
