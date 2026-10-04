-- server/srace.lua — /srace: an admin picks the track and the car, no poll.
--
-- Rides the normal race cycle. The admin's pick is stored as ForcedRace and
-- StartRacePoll (poll.lua) applies it instead of opening a ballot, so the
-- world spawn, warmup, countdown, results and replays all run as usual. The
-- admin is put in the queue automatically; "now" starts with whoever is
-- queued, "window" opens the normal join window first so others can /joinrace.

ForcedRace = nil   -- { track, selection, by }

local function isAdmin(src)
    local ok, allowed = pcall(function() return exports["spz-core"]:HasPermission(src, "spz.admin") end)
    return (ok and allowed == true) or IsPlayerAceAllowed(src, "spz.admin")
end

--- Called from StartRacePoll. Applies the admin pick exactly the way
--- EndRacePoll applies a poll winner. Returns true when it took over.
function ApplyForcedRace()
    local f = ForcedRace
    if not f then return false end
    ForcedRace = nil

    local track, selection = f.track, f.selection
    RaceSession.raceType     = track.type or "circuit"
    GlobalState:set("raceType", RaceSession.raceType, true)
    RaceSession.track        = track
    RaceSession.selection    = selection
    RaceSession.carClassId   = selection.class
    RaceSession.trafficLevel = "none"
    RaceSession.copChase     = false
    GlobalState:set("raceTraffic", "none", true)
    GlobalState:set("raceCopChase", false, true)

    local meta = exports["spz-vehicles"]:GetClassMeta(selection.class)
    RaceSession.carClass = {
        name     = meta and meta.name or "Open",
        category = selection.label,
        color    = meta and meta.color or "#FF6200",
        model    = selection.model,
    }

    print(("[srace] %s set the race: %s | %s"):format(f.by, track.name, tostring(selection.model)))

    for src in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:pollResult", src, {
            phase = "final", track = track.name, class = RaceSession.carClass,
            type = track.type, laps = track.laps, traffic = "none", chase = false,
        })
    end
    SetRaceState(SPZ.RaceState.WAITING)
    return true
end

-- ── Menu data ────────────────────────────────────────────────────────────────

lib.callback.register("spz-races:srace:options", function(src)
    if not isAdmin(src) then return nil end

    local tracks = {}
    for id, t in pairs(SPZ.Tracks or {}) do
        tracks[#tracks + 1] = {
            id = id, name = t.name, type = t.type or "circuit", laps = t.laps,
            cps = t.checkpoints and #t.checkpoints or 0,
        }
    end
    table.sort(tracks, function(a, b) return a.name < b.name end)

    local classes = {}
    for _, classId in ipairs(exports["spz-vehicles"]:GetRaceClasses() or {}) do
        local meta = exports["spz-vehicles"]:GetClassMeta(classId)
        local cars = {}
        for _, v in ipairs(exports["spz-vehicles"]:GetPollPool(classId, 500) or {}) do
            cars[#cars + 1] = { model = v.model, label = v.label or v.model }
        end
        table.sort(cars, function(a, b) return a.label < b.label end)
        if #cars > 0 then
            classes[#classes + 1] = { id = classId, name = meta and meta.name or tostring(classId),
                                      color = meta and meta.color, cars = cars }
        end
    end
    table.sort(classes, function(a, b) return a.name < b.name end)

    return { tracks = tracks, classes = classes, state = RaceSession.state, queued = GetQueueCount() }
end)

-- ── Start ────────────────────────────────────────────────────────────────────

lib.callback.register("spz-races:srace:start", function(src, data)
    if not isAdmin(src) then return false, "Admins only." end
    if type(data) ~= "table" then return false, "Bad request." end

    local track = SPZ.Tracks and SPZ.Tracks[data.trackId]
    if not track then return false, "Unknown track." end

    -- The car must be a real race-eligible model; never trust the menu.
    local selection
    for _, classId in ipairs(exports["spz-vehicles"]:GetRaceClasses() or {}) do
        for _, v in ipairs(exports["spz-vehicles"]:GetPollPool(classId, 500) or {}) do
            if v.model == data.model then selection = v; break end
        end
        if selection then break end
    end
    if not selection then return false, "That car isn't race-eligible." end

    local state = RaceSession.state
    if state ~= SPZ.RaceState.IDLE and state ~= SPZ.RaceState.POLLING then
        return false, "A race is already running. Wait for it to finish."
    end
    if RaceSession.intermissionActive then return false, "Wait for the intermission to end." end

    ForcedRace = { track = track, selection = selection, by = GetPlayerName(src) or tostring(src) }
    if GetResourceState("spz-analytics") == "started" then
        pcall(function() exports["spz-analytics"]:Track("admin_race") end)
        pcall(function() exports["spz-analytics"]:AdminAction(src, "srace",
            ("%s in %s (%s)"):format(track.name, tostring(selection.model), tostring(data.mode or "now"))) end)
    end

    -- The admin races too.
    if not Player(src).state.inQueue and not Player(src).state.inRace then JoinQueue(src) end

    -- Start it directly. Never go through StartRacePoll: that opens the
    -- random vote if anything (an old poll.lua, the join timer) gets there
    -- first. ApplyForcedRace sets WAITING itself, which is what a finished
    -- vote does, so the rest of the race runs as normal.
    if state == SPZ.RaceState.POLLING then
        if ClosePollForForced then ClosePollForForced() end   -- drop the open vote
        ApplyForcedRace()
    elseif data.mode == "window" then
        -- Our own countdown, ending 1 s before the normal join window would
        -- open a vote. Once the race is WAITING, that window finds nothing to do.
        local secs = math.max(5, (Config.JoinWindowSeconds or 30) - 1)
        TriggerClientEvent("SPZ:joinWindow", -1, { seconds = secs })
        local pick = ForcedRace
        SetTimeout(secs * 1000, function()
            if ForcedRace ~= pick then return end               -- replaced or already used
            if RaceSession.state == SPZ.RaceState.POLLING and ClosePollForForced then ClosePollForForced() end
            if RaceSession.state == SPZ.RaceState.IDLE or RaceSession.state == SPZ.RaceState.POLLING then
                ApplyForcedRace()
            else
                ForcedRace = nil
                SPZ.Notify(src, "Admin race cancelled: the race state changed.", "error", 6000)
            end
        end)
    else
        ApplyForcedRace()
    end

    for _, sid in ipairs(GetPlayers()) do
        SPZ.Notify(tonumber(sid), ("Admin race: %s in %s%s"):format(track.name, selection.label or selection.model,
            data.mode == "window" and " · /joinrace to enter" or ""), "inform", 6000)
    end
    return true
end)
