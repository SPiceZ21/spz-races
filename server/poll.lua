-- server/poll.lua

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

local pollActive     = false
local pollTimer      = 0
local pollGeneration = 0

function StartRacePoll()
    if RaceSession.state ~= SPZ.RaceState.IDLE
    and RaceSession.state ~= SPZ.RaceState.POLLING then return end

    if RaceSession.state ~= SPZ.RaceState.POLLING then
        SetRaceState(SPZ.RaceState.POLLING)
    end

    local phase      = RaceSession.pollPhase or 1
    local pollOptions = {}
    local uiOptions  = {}

    if phase == 1 then
        local tracks = GetWeightedTracks(RaceSession.raceType, Config.PollOptionsPerType or 2)
        if #tracks < 1 then
            print("[Race Poll] No tracks found for type: " .. tostring(RaceSession.raceType))
            ResetToIdle()
            return
        end

        pollOptions = tracks
        for _, track in ipairs(tracks) do
            table.insert(uiOptions, {
                name             = track.name,
                type             = track.type,
                laps             = track.laps,
                checkpointCount  = #track.checkpoints,
                recommendedClass = track.recommendedClass or "Any",
            })
        end

        RaceSession.pollVotes = {}
        for i = 1, #pollOptions do RaceSession.pollVotes[i] = 0 end
    elseif phase == 2 then
        local availableClasses = exports["spz-vehicles"]:GetRaceClasses()
        if not availableClasses or #availableClasses == 0 then
            print("[Race Poll] No race-eligible vehicles. Resetting.")
            ResetToIdle()
            return
        end

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

        if #vehicles == 0 then
            print("[Race Poll] GetPollPool returned nothing. Resetting.")
            ResetToIdle()
            return
        end

        pollOptions = vehicles
        for _, veh in ipairs(vehicles) do
            local meta = exports["spz-vehicles"]:GetClassMeta(veh.class)
            table.insert(uiOptions, {
                name    = veh.model,
                label   = veh.label,
                subtext = meta and meta.name or "Unknown",
                color   = meta and meta.color or "#FFFFFF",
                stats   = {
                    { label = "Speed", value = veh.top_speed or "??" },
                    { label = "Accel", value = veh.accel or "??" },
                },
            })
        end

        RaceSession.pollVotes = {}
        for i = 1, #pollOptions do RaceSession.pollVotes[i] = 0 end
    else
        -- Phase 3: how much ambient traffic to spawn inside the race world.
        pollOptions = { { level = "none" }, { level = "light" }, { level = "heavy" } }
        uiOptions = {
            { name = "none",  label = "No Traffic",    subtext = "Empty streets", color = "#9AA0A6", stats = {} },
            { name = "light", label = "Light Traffic", subtext = "A few cars",    color = "#FFB020", stats = {} },
            { name = "heavy", label = "Heavy Traffic", subtext = "Busy roads",    color = "#FF6200", stats = {} },
        }
        RaceSession.pollVotes = {}
        for i = 1, #pollOptions do RaceSession.pollVotes[i] = 0 end
    end

    RaceSession.pollOptions = pollOptions
    for _, player in pairs(RaceSession.players) do
        player.voted = false
    end

    -- Poll only appears for players who joined the queue — everyone else
    -- keeps freeroaming undisturbed.
    local phaseName = (phase == 1 and "track") or (phase == 2 and "vehicle") or "traffic"
    local pollPayload = {
        phase    = phaseName,
        options  = uiOptions,
        duration = Config.PollDuration,
        title    = (phase == 1 and "Choose Track") or (phase == 2 and "Choose Vehicle") or "Choose Traffic",
        subtitle = (phase == 1 and "VOTE FOR THE NEXT RACE") or (phase == 2 and "SELECT YOUR PERFORMANCE") or "SET THE ROAD DENSITY",
    }
    for src in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:pollOpen", src, pollPayload)
    end

    pollActive     = true
    pollTimer      = Config.PollDuration
    pollGeneration = pollGeneration + 1
    local myGen    = pollGeneration

    Citizen.CreateThread(function()
        while pollTimer > 0 and pollActive and pollGeneration == myGen do
            Citizen.Wait(1000)
            pollTimer = pollTimer - 1
            if pollTimer == 0 and pollGeneration == myGen then
                EndRacePoll()
            end
        end
    end)
end

function EndRacePoll()
    if not pollActive then return end
    pollActive = false

    local votes    = RaceSession.pollVotes
    local maxVotes = -1
    local winners  = {}

    for i, count in ipairs(votes) do
        if count > maxVotes then
            maxVotes = count
            winners  = { i }
        elseif count == maxVotes then
            table.insert(winners, i)
        end
    end

    local winnerIdx = winners[math.random(1, #winners)]
    local phase     = RaceSession.pollPhase or 1

    if phase == 1 then
        RaceSession.track = RaceSession.pollOptions[winnerIdx]
        print("[Poll] Track selected: " .. RaceSession.track.name)

        for src in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:pollResult", src, {
                winner = { index = winnerIdx },
                phase  = "track",
            })
        end

        Citizen.SetTimeout(0, function()
            RaceSession.pollPhase = 2
            StartRacePoll()
        end)
    elseif phase == 3 then
        -- Traffic density vote resolved → store level + broadcast to clients so
        -- the density controller knows how thick to make the race traffic.
        local pick = RaceSession.pollOptions[winnerIdx]
        RaceSession.trafficLevel = (pick and pick.level) or "none"
        GlobalState:set("raceTraffic", RaceSession.trafficLevel, true)
        print("[Poll] Traffic level selected: " .. RaceSession.trafficLevel)

        for src in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:pollResult", src, {
                winner = { index = winnerIdx },
                phase  = "traffic",
                traffic = RaceSession.trafficLevel,
            })
        end

        SetRaceState(SPZ.RaceState.WAITING)
    else
        local selection = RaceSession.pollOptions[winnerIdx]
        if not selection then
            print("[Race Poll] Selection nil for winnerIdx " .. tostring(winnerIdx))
            ResetToIdle()
            return
        end

        RaceSession.selection  = selection
        RaceSession.carClassId = selection.class
        local meta = exports["spz-vehicles"]:GetClassMeta(selection.class)
        RaceSession.carClass = {
            name     = meta and meta.name or "Open",
            category = selection.label,
            color    = meta and meta.color or "#FF6200",
            model    = selection.model,
        }

        for src in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:pollResult", src, {
                winner = { index = winnerIdx },
                phase  = "vehicle",
                track  = RaceSession.track.name,
                class  = RaceSession.carClass,
                type   = RaceSession.track.type,
                laps   = RaceSession.track.laps,
            })
        end

        -- Vehicle chosen → let the winner ring show, then run the traffic vote
        -- before the world spins up.
        Citizen.SetTimeout(1500, function()
            RaceSession.pollPhase = 3
            StartRacePoll()
        end)
    end
end

RegisterNetEvent("SPZ:pollVote", function(data, sourceOverride)
    local src = tonumber(sourceOverride or source)
    if not src then return end

    if not pollActive then return end

    local player = RaceSession.players[src]
    if not player or player.voted then return end
    if not data or not data.index then return end

    local index = tonumber(data.index)
    if not index or index < 1 or index > #RaceSession.pollVotes then return end

    player.voted = true
    RaceSession.pollVotes[index] = RaceSession.pollVotes[index] + 1

    local allVoted    = true
    local playerCount = 0
    for pSrc, pData in pairs(RaceSession.players) do
        if GetPlayerName(pSrc) then
            playerCount = playerCount + 1
            if not pData.voted then allVoted = false end
        else
            RaceSession.players[pSrc] = nil
        end
    end

    if allVoted and playerCount > 0 then
        print("[Race Poll] All participants voted early.")
        EndRacePoll()
    end
end)

exports("StartRacePoll", StartRacePoll)
