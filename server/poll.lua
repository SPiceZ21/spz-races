-- server/poll.lua
--
-- Voting runs PER PLAYER, not in lockstep.
--
-- It used to be three synchronised rounds: everyone stared at the track ballot
-- until the slowest voter or the timer decided, then everyone moved to vehicles,
-- and so on. Fast voters spent most of the pre-race staring at a dead menu, and
-- anyone who queued mid-round never received the ballot at all.
--
-- Now every racer walks their own track -> vehicle -> traffic sequence as fast as
-- they like. Finish, and the menu closes and you are free until the grid forms.
-- All three option sets are built once up front (none depends on another), the
-- picks land in one shared tally, and the race is decided when the last ballot is
-- in or the window closes — whichever happens first.

local PHASES = { 'track', 'vehicle', 'traffic' }

local PollRun = nil
--[[ {
    gen      = number,
    endsAt   = ms,
    options  = { [1] = {rawTrack...}, [2] = {rawVehicle...}, [3] = {rawTraffic...} },
    ui       = { [1] = {uiOpts...},   [2] = {...},           [3] = {...} },
    tally    = { [1] = {counts},      [2] = {counts},        [3] = {counts} },
    ballots  = { [src] = { phase = 1..4 } },   -- 4 == finished
} ]]

-- ── Option builders ──────────────────────────────────────────────────────────

local function GetWeightedTracks(type, count)
    local pool = {}
    for id, track in pairs(SPZ.Tracks) do
        if track.type == type then
            table.insert(pool, { id = id, weight = track.poll_weight or 1, track = track })
        end
    end

    if #pool == 0 then return {} end
    if #pool <= count then
        local result = {}
        for _, item in ipairs(pool) do table.insert(result, item.track) end
        return result
    end

    local selected = {}
    for _ = 1, count do
        local totalWeight = 0
        for _, item in ipairs(pool) do totalWeight = totalWeight + item.weight end

        local r = math.random() * totalWeight
        local cumWeight = 0
        for idx, item in ipairs(pool) do
            cumWeight = cumWeight + item.weight
            if r <= cumWeight then
                table.insert(selected, item.track)
                table.remove(pool, idx)
                break
            end
        end
    end
    return selected
end

-- World XY of every checkpoint, in lap order — the ballot draws this as the
-- track's shape over the map so you vote on a route, not a name. Z is dropped
-- (the plot is top-down) and coords are rounded to a metre: this rides in the
-- ballot payload, and sub-metre precision is invisible at ~300 px wide.
--
-- Long tracks are thinned to PATH_MAX points by taking every Nth checkpoint,
-- with the last one always kept so a circuit still closes on its start line.
local PATH_MAX = 160

local function TrackPath(track)
    local cps = track.checkpoints
    if not cps or #cps < 2 then return nil end

    local step = math.max(1, math.ceil(#cps / PATH_MAX))
    local path = {}
    for i = 1, #cps, step do
        local c = cps[i].coords
        path[#path + 1] = { x = math.floor(c.x + 0.5), y = math.floor(c.y + 0.5) }
    end

    local last = cps[#cps].coords
    local tail = path[#path]
    if tail.x ~= math.floor(last.x + 0.5) or tail.y ~= math.floor(last.y + 0.5) then
        path[#path + 1] = { x = math.floor(last.x + 0.5), y = math.floor(last.y + 0.5) }
    end
    return path
end

--- @return table|nil raw options, table ui options
local function BuildTrackOptions()
    local tracks = GetWeightedTracks(RaceSession.raceType, Config.PollOptionsPerType or 2)
    if #tracks < 1 then return nil end

    local ui = {}
    for _, track in ipairs(tracks) do
        ui[#ui + 1] = {
            name             = track.name,
            type             = track.type,
            laps             = track.laps,
            checkpointCount  = #track.checkpoints,
            recommendedClass = track.recommendedClass or "Any",
            -- Preview: the route itself, plus whether it closes back on its
            -- start line (circuits) or ends elsewhere (sprints).
            path             = TrackPath(track),
            loop             = track.type == "circuit",
        }
    end
    return tracks, ui
end

local function BuildVehicleOptions()
    local availableClasses = exports["spz-vehicles"]:GetRaceClasses()
    if not availableClasses or #availableClasses == 0 then return nil end

    for i = #availableClasses, 2, -1 do
        local j = math.random(1, i)
        availableClasses[i], availableClasses[j] = availableClasses[j], availableClasses[i]
    end

    local TARGET     = Config.PollOptionsPerType or 2
    local vehicles   = {}
    local seenModels = {}

    for _, classId in ipairs(availableClasses) do
        if #vehicles >= TARGET then break end
        local pool = exports["spz-vehicles"]:GetPollPool(classId, 1)
        if pool and pool[1] and not seenModels[pool[1].model] then
            seenModels[pool[1].model] = true
            table.insert(vehicles, pool[1])
        end
    end

    if #vehicles < TARGET then
        local extra = exports["spz-vehicles"]:GetPollPool(availableClasses[1], TARGET + 1)
        for _, v in ipairs(extra or {}) do
            if #vehicles >= TARGET then break end
            if not seenModels[v.model] then
                seenModels[v.model] = true
                table.insert(vehicles, v)
            end
        end
    end

    if #vehicles == 0 then return nil end

    local ui = {}
    for _, veh in ipairs(vehicles) do
        local meta = exports["spz-vehicles"]:GetClassMeta(veh.class)
        ui[#ui + 1] = {
            name    = veh.model,
            label   = veh.label,
            subtext = meta and meta.name or "Unknown",
            color   = meta and meta.color or "#FFFFFF",
            stats   = {
                { label = "Speed", value = veh.top_speed or "??" },
                { label = "Accel", value = veh.accel or "??" },
            },
        }
    end
    return vehicles, ui
end

local function BuildTrafficOptions()
    local raw = { { level = "none" }, { level = "light" }, { level = "heavy" } }
    local ui  = {
        { name = "none",  label = "No Traffic",    subtext = "Empty streets", color = "#9AA0A6", stats = {} },
        { name = "light", label = "Light Traffic", subtext = "A few cars",    color = "#FFB020", stats = {} },
        { name = "heavy", label = "Heavy Traffic", subtext = "Busy roads",    color = "#FF6200", stats = {} },
    }
    return raw, ui
end

-- The cop chase rides ALONG WITH the traffic ballot rather than as a fourth
-- phase. It is the same question — how alive are the streets — and a whole
-- extra screen for one yes/no would have cost more time than the choice is
-- worth. One card click submits the level and the switch position together.
local function ChaseToggle()
    local cc = Config.CopChase or {}
    if cc.Enabled == false then return nil end
    return {
        key      = "chase",
        label    = "Cop Chase",
        onLabel  = "COPS ON",
        offLabel = "COPS OFF",
        hint     = "Pick up a wanted level and police hunt you. Ramming and PIT only — they never shoot.",
        default  = cc.Default == true,
    }
end

-- ── Ballot delivery ──────────────────────────────────────────────────────────

local TITLES = {
    { title = "Choose Track",   subtitle = "VOTE FOR THE NEXT RACE" },
    { title = "Choose Vehicle", subtitle = "SELECT YOUR PERFORMANCE" },
    { title = "Choose Traffic", subtitle = "SET THE ROAD DENSITY" },
}

--- Sends one player the ballot for the phase they are personally on.
local function SendPhase(src, phase)
    if not PollRun then return end

    local remaining = math.floor((PollRun.endsAt - GetGameTimer()) / 1000)
    if remaining < 2 then remaining = 2 end

    TriggerClientEvent("SPZ:pollOpen", src, {
        phase    = PHASES[phase],
        options  = PollRun.ui[phase],
        duration = remaining,        -- their clock is the shared deadline
        title    = TITLES[phase].title,
        subtitle = TITLES[phase].subtitle,
        -- Where this player is in their own run of the ballot. The UI shows it
        -- as "2/3" so a fast voter can see the finish line coming.
        step     = phase,
        steps    = #PHASES,
        toggle   = (phase == 3) and ChaseToggle() or nil,
    })
end

local function FinishBallot(src)
    TriggerClientEvent("SPZ:pollClosed", src)
    SPZ.Notify(src, "Votes in — freeroam until the grid forms", "success", 4000)
end

--- True once every queued racer has walked all three phases.
local function AllBallotsIn()
    if not PollRun then return false end
    local any = false
    for src in pairs(RaceSession.players) do
        any = true
        local b = PollRun.ballots[src]
        if not b or b.phase <= #PHASES then return false end
    end
    return any
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

local function WinnerOf(phase)
    local counts = PollRun.tally[phase]
    local best, winners = -1, {}
    for i = 1, #PollRun.options[phase] do
        local c = counts[i] or 0
        if c > best then best, winners = c, { i }
        elseif c == best then winners[#winners + 1] = i end
    end
    return winners[math.random(1, #winners)]
end

--- Cop chase is a straight majority of the switch positions submitted with the
--- traffic vote. A tie, or a poll nobody answered, falls to the config default —
--- never to "on", since a surprise police pack is the more disruptive outcome.
local function ChaseWon()
    local cc = Config.CopChase or {}
    if cc.Enabled == false then return false end
    local t = PollRun.chase
    if not t or (t.yes == 0 and t.no == 0) then return cc.Default == true end
    if t.yes == t.no then return cc.Default == true end
    return t.yes > t.no
end

function EndRacePoll()
    if not PollRun then return end

    local trackIdx   = WinnerOf(1)
    local vehicleIdx = WinnerOf(2)
    local trafficIdx = WinnerOf(3)

    local track     = PollRun.options[1][trackIdx]
    local selection = PollRun.options[2][vehicleIdx]
    local traffic   = PollRun.options[3][trafficIdx]
    local copChase  = ChaseWon()

    -- Close every ballot still open (players who never finished, or joined at the
    -- very end) so nobody is left holding a dead menu.
    for src in pairs(RaceSession.players) do
        local b = PollRun.ballots[src]
        if not b or b.phase <= #PHASES then
            TriggerClientEvent("SPZ:pollClosed", src)
        end
    end

    PollRun = nil

    if not track or not selection then
        print("[Race Poll] Poll produced no usable winner. Resetting.")
        ResetToIdle()
        return
    end

    RaceSession.track        = track
    RaceSession.selection    = selection
    RaceSession.carClassId   = selection.class
    RaceSession.trafficLevel = (traffic and traffic.level) or "none"
    RaceSession.copChase     = copChase
    GlobalState:set("raceTraffic",  RaceSession.trafficLevel, true)
    GlobalState:set("raceCopChase", copChase, true)

    local meta = exports["spz-vehicles"]:GetClassMeta(selection.class)
    RaceSession.carClass = {
        name     = meta and meta.name or "Open",
        category = selection.label,
        color    = meta and meta.color or "#FF6200",
        model    = selection.model,
    }

    print(("[Poll] Track: %s | Vehicle: %s | Traffic: %s | Cops: %s")
        :format(track.name, tostring(selection.model), RaceSession.trafficLevel,
                copChase and "on" or "off"))

    for src in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:pollResult", src, {
            phase   = "final",
            track   = track.name,
            class   = RaceSession.carClass,
            type    = track.type,
            laps    = track.laps,
            traffic = RaceSession.trafficLevel,
            chase   = copChase,
        })
    end

    SetRaceState(SPZ.RaceState.WAITING)
end

function StartRacePoll()
    if RaceSession.state ~= SPZ.RaceState.IDLE
    and RaceSession.state ~= SPZ.RaceState.POLLING then return end

    local tracksRaw, tracksUi = BuildTrackOptions()
    if not tracksRaw then
        print("[Race Poll] No tracks found for type: " .. tostring(RaceSession.raceType))
        ResetToIdle()
        return
    end

    local vehRaw, vehUi = BuildVehicleOptions()
    if not vehRaw then
        print("[Race Poll] No race-eligible vehicles. Resetting.")
        ResetToIdle()
        return
    end

    local trafRaw, trafUi = BuildTrafficOptions()

    if RaceSession.state ~= SPZ.RaceState.POLLING then
        SetRaceState(SPZ.RaceState.POLLING)
    end

    -- One window covers all three phases now that they run back to back per
    -- player, so the old per-phase duration is multiplied to keep the same
    -- overall budget for someone who reads every option.
    local window = (Config.PollDuration or 15) * #PHASES

    PollRun = {
        gen     = (PollRun and PollRun.gen or 0) + 1,
        endsAt  = GetGameTimer() + window * 1000,
        options = { tracksRaw, vehRaw, trafRaw },
        ui      = { tracksUi, vehUi, trafUi },
        tally   = { {}, {}, {} },
        chase   = { yes = 0, no = 0 },   -- switch submitted with the traffic vote
        ballots = {},
    }

    for i = 1, #PHASES do
        for j = 1, #PollRun.options[i] do PollRun.tally[i][j] = 0 end
    end

    local myGen = PollRun.gen

    for src in pairs(RaceSession.players) do
        PollRun.ballots[src] = { phase = 1 }
        SendPhase(src, 1)
    end

    Citizen.CreateThread(function()
        while PollRun and PollRun.gen == myGen do
            Citizen.Wait(500)
            if not PollRun or PollRun.gen ~= myGen then return end
            if GetGameTimer() >= PollRun.endsAt then
                EndRacePoll()
                return
            end
        end
    end)
end

-- ── Voting ───────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:pollVote", function(data, sourceOverride)
    local src = tonumber(sourceOverride or source)
    if not src or not PollRun then return end

    local player = RaceSession.players[src]
    if not player then return end

    local ballot = PollRun.ballots[src]
    if not ballot or ballot.phase > #PHASES then return end   -- already finished

    local phase = ballot.phase
    local index = tonumber(data and data.index)
    if not index or index < 1 or index > #PollRun.options[phase] then return end

    PollRun.tally[phase][index] = (PollRun.tally[phase][index] or 0) + 1

    -- Traffic card and cop switch arrive in the same submission, so the switch
    -- is counted here rather than on its own screen. Absent (older UI, or the
    -- switch disabled in config) simply does not vote either way.
    if phase == 3 and ChaseToggle() and type(data) == "table" and data.toggle ~= nil then
        local key = data.toggle and "yes" or "no"
        PollRun.chase[key] = PollRun.chase[key] + 1
    end

    ballot.phase = phase + 1

    if ballot.phase <= #PHASES then
        -- Straight on to their next choice — no waiting on anyone else.
        SendPhase(src, ballot.phase)
    else
        FinishBallot(src)
        -- Last ballot in? Start the race rather than burning the rest of the window.
        if AllBallotsIn() then EndRacePoll() end
    end
end)

-- ── Late joiners ─────────────────────────────────────────────────────────────
-- Someone queuing mid-poll simply starts their own sequence at phase 1; with
-- per-player pacing there is no round to have missed.
function SendActivePollTo(src)
    if not PollRun or not RaceSession.players[src] then return false end
    if PollRun.ballots[src] then return false end   -- already voting

    -- Not enough of the window left to make three choices: skip them so they do
    -- not hold up the start, and let the existing votes decide.
    if (PollRun.endsAt - GetGameTimer()) < 4000 then return false end

    PollRun.ballots[src] = { phase = 1 }
    SendPhase(src, 1)
    return true
end

exports("StartRacePoll", StartRacePoll)
exports("SendActivePollTo", SendActivePollTo)
