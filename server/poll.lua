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

local function newPollId()
    return ("%d-%d-%06d"):format(os.time(), math.random(100000, 999999), GetGameTimer() % 1000000)
end

local rerollIndex, rerollVotes   -- defined with the reroll card below

local function SavePollAttempt(rerolled, track, vehicle, traffic, copChase, rerollPhase)
    local run = PollRun
    if not run then return end
    local eligible, voters = 0, 0
    for src in pairs(RaceSession.players) do
        eligible = eligible + 1
        local ballot = run.ballots[src]
        if ballot and ballot.phase > 1 then voters = voters + 1 end
    end
    pcall(function()
        MySQL.insert.await([[INSERT INTO race_poll_runs
            (poll_id, attempt, race_type, started_at, ended_at, eligible_count, voter_count, rerolled,
             track_winner, vehicle_winner, traffic_winner, cop_chase, cop_chase_yes, cop_chase_no,
             track_reroll_votes, vehicle_reroll_votes, reroll_phase)
            VALUES (?, ?, ?, ?, NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
                run.pollId, run.rerolls or 0, RaceSession.raceType or "unknown",
                run.startedAt,
                eligible, voters, rerolled and 1 or 0,
                track and track.name or nil, vehicle and vehicle.model or nil,
                traffic and traffic.level or nil,
                copChase == nil and nil or (copChase and 1 or 0),
                (run.chase and run.chase.yes) or 0,
                (run.chase and run.chase.no) or 0,
                rerollVotes(1, run), rerollVotes(2, run),
                rerollPhase,
            })
    end)
    local winners = { track = track and track.name, vehicle = vehicle and vehicle.model,
        traffic = traffic and traffic.level }
    for phaseIndex, phase in ipairs(PHASES) do
        for i, option in ipairs(run.options[phaseIndex] or {}) do
            local key = phase == "track" and option.name
                or phase == "vehicle" and option.model
                or option.level
            pcall(function()
                MySQL.insert.await([[INSERT INTO race_poll_options
                    (poll_id, attempt, phase, option_key, vote_count, winner)
                    VALUES (?, ?, ?, ?, ?, ?)]], {
                        run.pollId, run.rerolls or 0, phase, tostring(key or "unknown"),
                        (run.tally[phaseIndex] or {})[i] or 0,
                        winners[phase] == key and 1 or 0,
                    })
            end)
        end
        -- The reroll card is stored as an option too, so "votes per option"
        -- shows how often a set was rejected.
        if rerollIndex(phaseIndex, run) then
            pcall(function()
                MySQL.insert.await([[INSERT INTO race_poll_options
                    (poll_id, attempt, phase, option_key, vote_count, winner)
                    VALUES (?, ?, ?, ?, ?, ?)]], {
                        run.pollId, run.rerolls or 0, phase, "reroll",
                        rerollVotes(phaseIndex, run),
                        (rerolled and (rerollPhase == phase or rerollPhase == "both")) and 1 or 0,
                    })
            end)
        end
    end
end
--[[ {
    gen      = number,
    endsAt   = ms,
    options  = { [1] = {rawTrack...}, [2] = {rawVehicle...}, [3] = {rawTraffic...} },
    ui       = { [1] = {uiOpts...},   [2] = {...},           [3] = {...} },
    tally    = { [1] = {counts},      [2] = {counts},        [3] = {counts} },
    ballots  = { [src] = { phase = 1..4 } },   -- 4 == finished
} ]]

-- ── Option builders ──────────────────────────────────────────────────────────

--- @param avoid table|nil  track names the last ballot already offered
local function GetWeightedTracks(type, count, avoid)
    local pool, skipped = {}, {}
    for id, track in pairs(SPZ.Tracks) do
        -- Switched off in the admin track manager: never offered.
        if track.type == type and not track.disabled then
            local item = { id = id, weight = track.poll_weight or 1, track = track }
            if avoid and avoid[track.name] then
                skipped[#skipped + 1] = item
            else
                pool[#pool + 1] = item
            end
        end
    end

    -- A reroll should offer something NEW, but not at the cost of offering
    -- nothing: a server with three circuits cannot fill a fresh ballot twice.
    -- The previous set comes back only once the rest is exhausted.
    if #pool < count then
        for _, item in ipairs(skipped) do pool[#pool + 1] = item end
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
local function BuildTrackOptions(avoid)
    local tracks = GetWeightedTracks(RaceSession.raceType, Config.PollOptionsPerType or 2, avoid)
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

--- @param avoid table|nil  models the last ballot already offered
local function BuildVehicleOptions(avoid)
    local availableClasses = exports["spz-vehicles"]:GetRaceClasses()
    if not availableClasses or #availableClasses == 0 then return nil end

    for i = #availableClasses, 2, -1 do
        local j = math.random(1, i)
        availableClasses[i], availableClasses[j] = availableClasses[j], availableClasses[i]
    end

    -- Add-on priority, class level. The poll takes one car per class from the
    -- front of this list, so classes that contain add-on cars go first (still
    -- shuffled among themselves), then the rest. Inside a class,
    -- GetPollPool already fills from add-ons before vanilla. Both halves are
    -- needed: priority within a class does nothing if the shuffle hands the
    -- poll two classes the pack has no cars in.
    local ok, addonClasses = pcall(function()
        return exports["spz-vehicles"]:GetAddonRaceClasses()
    end)
    if ok and type(addonClasses) == "table" and next(addonClasses) then
        local first, rest = {}, {}
        for _, c in ipairs(availableClasses) do
            if addonClasses[c] then first[#first + 1] = c else rest[#rest + 1] = c end
        end
        for _, c in ipairs(rest) do first[#first + 1] = c end
        availableClasses = first
    end

    local TARGET     = Config.PollOptionsPerType or 2
    local vehicles   = {}
    local seenModels = {}

    for _, classId in ipairs(availableClasses) do
        if #vehicles >= TARGET then break end
        -- Ask for a few rather than one, so a car the last ballot already
        -- offered can be stepped over instead of costing the class its slot.
        local pool = exports["spz-vehicles"]:GetPollPool(classId, avoid and 4 or 1)
        for _, veh in ipairs(pool or {}) do
            if not seenModels[veh.model] and not (avoid and avoid[veh.model]) then
                seenModels[veh.model] = true
                table.insert(vehicles, veh)
                break
            end
        end
    end

    if #vehicles < TARGET then
        local extra = exports["spz-vehicles"]:GetPollPool(availableClasses[1], TARGET + 1)
        for _, v in ipairs(extra or {}) do
            if #vehicles >= TARGET then break end
            if not seenModels[v.model] and not (avoid and avoid[v.model]) then
                seenModels[v.model] = true
                table.insert(vehicles, v)
            end
        end
    end

    -- Still short because everything left was on the last ballot? Fill from
    -- the avoided set rather than hand back a ballot with one card on it.
    if #vehicles < TARGET and avoid then
        local extra = exports["spz-vehicles"]:GetPollPool(availableClasses[1], TARGET + 2)
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

-- ── Reroll card ─────────────────────────────────────────────────────────────
--
-- The track and car ballots end with a REROLL card: "none of these". It is
-- voted like any other card, and counted at the close, so nobody's vote is
-- wiped mid-poll. If the reroll card gets MORE votes than every single track
-- (or car) on its ballot, the whole set is redrawn and the poll runs again,
-- avoiding what was just rejected.
--
-- Capped by config (default once per poll): two rerolls of a three-track server
-- is the same three tracks again with the grid still waiting. Once the cap is
-- spent the card is not offered.

local REROLL_PHASES = { [1] = true, [2] = true }   -- track, car

local function rerollCfg()
    return (Config and Config.PollReroll) or {}
end

local function rerollEnabled()
    return rerollCfg().Enabled ~= false
end

local function rerollCap()
    return tonumber(rerollCfg().MaxPerPoll) or 1
end

local function RerollCard(phase)
    return {
        name    = "__reroll__",
        label   = "Reroll",
        reroll  = true,
        subtext = phase == 1 and "None of these tracks" or "None of these cars",
        color   = "#9AA0A6",
        stats   = {},
    }
end

--- Tally index of the reroll card on a phase, or nil when it is not offered.
function rerollIndex(phase, run)
    run = run or PollRun
    if not run or not run.rerollCard[phase] then return nil end
    return #run.options[phase] + 1
end

function rerollVotes(phase, run)
    run = run or PollRun
    local idx = rerollIndex(phase, run)
    return idx and (run.tally[phase][idx] or 0) or 0
end

--- True when the reroll card beat every real option on this phase.
local function RerollWon(phase)
    local r = rerollVotes(phase)
    if r == 0 then return false end
    local counts = PollRun.tally[phase]
    for i = 1, #PollRun.options[phase] do
        if (counts[i] or 0) >= r then return false end
    end
    return true
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

--- The set that was just on offer, so the next draw can avoid it.
local function OfferedSet()
    local tracks, models = {}, {}
    for _, t in ipairs(PollRun.options[1] or {}) do
        if t.name then tracks[t.name] = true end
    end
    for _, v in ipairs(PollRun.options[2] or {}) do
        if v.model then models[v.model] = true end
    end
    return tracks, models
end

function EndRacePoll()
    if not PollRun then return end

    -- Reroll first: if the reroll card out-voted every track or every car,
    -- there is no point deciding a winner out of options they rejected.
    local used = PollRun.rerolls or 0
    local trackReroll, carReroll = RerollWon(1), RerollWon(2)
    if (trackReroll or carReroll) and used < rerollCap() then
        SavePollAttempt(true, nil, nil, nil, nil,
            (trackReroll and carReroll) and "both" or trackReroll and "track" or "vehicle")
        local pollId = PollRun.pollId
        local avoidTracks, avoidModels = OfferedSet()
        local what = (trackReroll and carReroll) and "tracks and cars"
            or trackReroll and "tracks" or "cars"

        print(("[Race Poll] Reroll won on %s — redrawing (%d/%d used)."):format(what, used + 1, rerollCap()))

        for src in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:pollClosed", src)
            SPZ.Notify(src, ("Reroll won — new %s coming up"):format(what), "inform", 4000)
        end

        PollRun = nil
        StartRacePoll({
            rerolls = used + 1,
            pollId  = pollId,
            -- Only the rejected set is kept off the new ballot.
            avoid   = { tracks = trackReroll and avoidTracks or nil,
                        models = carReroll and avoidModels or nil },
        })
        return
    end

    local trackIdx   = WinnerOf(1)
    local vehicleIdx = WinnerOf(2)
    local trafficIdx = WinnerOf(3)

    local track     = PollRun.options[1][trackIdx]
    local selection = PollRun.options[2][vehicleIdx]
    local traffic   = PollRun.options[3][trafficIdx]
    local copChase  = ChaseWon()
    SavePollAttempt(false, track, selection, traffic, copChase)

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
        AnalyticsEvent("poll_no_winner")
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

--- Close every ballot and drop the run without a winner. Used by /srace (the
--- admin pick replaces the vote) and by ResetToIdle (nobody left to race).
function ClosePollForForced()
    if not PollRun then return end
    for src in pairs(RaceSession.players) do TriggerClientEvent("SPZ:pollClosed", src) end
    PollRun = nil
end

--- @param opts table|nil { rerolls = n, avoid = { tracks = {}, models = {} } }
---   Passed only when this run IS a reroll: `avoid` keeps the new ballot off
---   the set that was just rejected, and `rerolls` carries the count so the cap
---   survives the restart.
function StartRacePoll(opts)
    if RaceSession.state ~= SPZ.RaceState.IDLE
    and RaceSession.state ~= SPZ.RaceState.POLLING then return end

    -- /srace: an admin already picked the track and car (server/srace.lua).
    if ApplyForcedRace and ApplyForcedRace() then return end

    opts = opts or {}
    local avoid = opts.avoid

    local tracksRaw, tracksUi = BuildTrackOptions(avoid and avoid.tracks)
    if not tracksRaw then
        print("[Race Poll] No tracks found for type: " .. tostring(RaceSession.raceType))
        AnalyticsEvent("poll_no_tracks", RaceSession.raceType)
        ResetToIdle()
        return
    end

    local vehRaw, vehUi = BuildVehicleOptions(avoid and avoid.models)
    if not vehRaw then
        print("[Race Poll] No race-eligible vehicles. Resetting.")
        AnalyticsEvent("poll_no_cars")
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
        pollId  = opts.pollId or newPollId(),
        startedAt = os.date("%Y-%m-%d %H:%M:%S"),
        endsAt  = GetGameTimer() + window * 1000,
        options = { tracksRaw, vehRaw, trafRaw },
        ui      = { tracksUi, vehUi, trafUi },
        tally   = { {}, {}, {} },
        chase   = { yes = 0, no = 0 },   -- switch submitted with the traffic vote
        ballots = {},

        -- How many redraws this poll has already spent. The count rides through
        -- the restart (see EndRacePoll) so the cap means "per poll", not "per
        -- attempt".
        rerolls    = tonumber(opts.rerolls) or 0,
        rerollCard = {},   -- [phase] = true when the ballot ends with a reroll card
    }

    -- Reroll card on the track and car ballots while the cap has room.
    if rerollEnabled() and PollRun.rerolls < rerollCap() then
        for phase in pairs(REROLL_PHASES) do
            PollRun.rerollCard[phase] = true
            local ui = {}
            for i, o in ipairs(PollRun.ui[phase]) do ui[i] = o end
            ui[#ui + 1] = RerollCard(phase)
            PollRun.ui[phase] = ui
        end
    end

    for i = 1, #PHASES do
        for j = 1, #PollRun.options[i] + (PollRun.rerollCard[i] and 1 or 0) do PollRun.tally[i][j] = 0 end
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
            -- The session was reset under us (everyone left, /srace, abort):
            -- drop the poll instead of letting it pick a race for nobody.
            if RaceSession.state ~= SPZ.RaceState.POLLING then
                ClosePollForForced()
                return
            end
            if GetGameTimer() >= PollRun.endsAt then
                EndRacePoll()
                return
            end
        end
    end)
end

-- ── Voting ───────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:pollVote", function(data)
    local src = tonumber(source)
    if not src or not PollRun then return end

    local player = RaceSession.players[src]
    if not player then return end

    local ballot = PollRun.ballots[src]
    if not ballot or ballot.phase > #PHASES then return end   -- already finished

    local phase = ballot.phase
    local index = tonumber(data and data.index)
    local maxIndex = #PollRun.options[phase] + (PollRun.rerollCard[phase] and 1 or 0)
    if not index or index < 1 or index > maxIndex then return end

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

--- Someone left the queue mid-poll: if everyone still queued has finished
--- their ballot, decide now instead of waiting for the window.
function CheckPollComplete()
    if PollRun and RaceSession.state == SPZ.RaceState.POLLING and AllBallotsIn() then
        EndRacePoll()
    end
end

