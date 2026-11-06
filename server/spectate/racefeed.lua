-- server/spectate/racefeed.lua — spectate (racefeed).
-- Moved from spz-spectate/server/racefeed.lua when it was merged into spz-races.
local Config = Config.Spectate

-- server/racefeed.lua
-- Live race board for everyone outside the race.
--
-- This file owns no race state. spz-races already computes the running order
-- once per tick and emits it as SPZ:standings for exactly this kind of
-- out-of-race consumer; the board is that payload, trimmed and paired with the
-- session's meta (track, lap, class). Nothing here re-derives a position.
--
-- Racers are excluded on the CLIENT rather than here: the payload is small, one
-- broadcast is cheaper than filtering per player every tick, and a racer's own
-- statebags are what decide whether they are racing.

local CFG = (Config and Config.Board) or {}

local Board = nil        -- current snapshot, nil when no race is live
local holdTimer = 0      -- generation guard for the post-race hold

local function raceMeta()
    local ok, info = pcall(function() return exports["spz-races"]:GetRaceInfo() end)
    if not ok or not info then return {} end
    return {
        track = info.track,
        type  = info.type,
        laps  = info.laps,
        class = info.carClass,
    }
end

local function Broadcast()
    TriggerClientEvent("spz-spectate:board", -1, Board)
end

-- ── Standings feed ───────────────────────────────────────────────────────────
-- Emitted by spz-races/server/positions.lua on its own throttle
-- (Config.StandingsBroadcastInterval).
AddEventHandler("SPZ:standings", function(payload, version)
    if CFG.enabled == false then return end
    if type(payload) ~= "table" then return end

    local meta = raceMeta()
    local rows = {}
    local leadLap = nil

    for _, e in ipairs(payload) do
        rows[#rows + 1] = {
            position = e.position,
            name     = e.name,
            gap      = e.gap,
            interval = e.interval,
            lap      = e.lap,
            dc       = e.dc or false,
            finished = e.finished or false,
            nation   = e.nation,
            number   = e.raceNumber,
            crew     = e.crew_tag,
        }
        if not leadLap or (e.lap or 1) > leadLap then leadLap = e.lap or 1 end
    end

    Board = {
        active  = true,
        final   = false,
        version = version,
        track   = meta.track,
        type    = meta.type,
        lap     = leadLap or 1,
        laps    = meta.laps or 1,
        class   = meta.class,
        rows    = rows,
    }

    Broadcast()
end)

-- ── Final classification ─────────────────────────────────────────────────────
-- The standings feed stops the moment the race leaves LIVE, which would drop the
-- board at the flag — the one moment a spectator most wants to look at it. Hold
-- the finishing order up for the results window instead.
AddEventHandler("SPZ:raceEnd", function(results)
    if CFG.enabled == false or not results then return end

    local rows = {}
    for _, f in ipairs(results.finishers or {}) do
        rows[#rows + 1] = {
            position = f.position,
            name     = f.name,
            gap      = f.finish_time and ("%.2f"):format(f.finish_time / 1000) or "--",
            lap      = results.laps,
            finished = true,
            crew     = f.crew_tag,
        }
    end
    for _, d in ipairs(results.dnf or {}) do
        rows[#rows + 1] = { position = nil, name = d.name, gap = "DNF", dnf = true }
    end

    Board = {
        active = true,
        final  = true,
        track  = results.track,
        type   = results.type,
        lap    = results.laps,
        laps   = results.laps,
        class  = results.carClass,
        rows   = rows,
    }
    Broadcast()

    holdTimer = holdTimer + 1
    local this = holdTimer
    SetTimeout(CFG.holdAfterFinishMs or 12000, function()
        -- A new race may have started inside the hold; only the newest hold may
        -- clear the board.
        if this ~= holdTimer then return end
        Board = nil
        Broadcast()
    end)
end)

-- ── Lifecycle ────────────────────────────────────────────────────────────────
-- A cancelled cycle never reaches SPZ:raceEnd, so the board would otherwise sit
-- on a dead race until the next one starts.
AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if not value or CFG.enabled == false then return end
    if value == "IDLE" or value == "CLEANUP" then
        if Board and not Board.final then
            holdTimer = holdTimer + 1   -- cancel any pending hold
            Board = nil
            Broadcast()
        end
    end
end)

-- A player joining mid-race gets the current board rather than waiting for the
-- next standings tick.
RegisterNetEvent("spz-spectate:requestBoard", function()
    local src = source
    TriggerClientEvent("spz-spectate:board", src, Board)
end)

exports("GetBoard", function() return Board end)
