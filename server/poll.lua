-- server/poll.lua

-- 7.1 Track Pool Selection (Weighted Random)
local function GetWeightedTracks(type, count)
    local pool = {}
    for id, track in pairs(SPZ.Tracks) do
        if track.type == type then
            table.insert(pool, {id = id, weight = track.poll_weight or 1, track = track})
        end
    end

    if #pool == 0 then return {} end
    if #pool < count then
        local result = {}
        for _, item in ipairs(pool) do table.insert(result, item.track) end
        return result
    end

    local selected = {}
    for i = 1, count do
        local totalWeight = 0
        for _, item in ipairs(pool) do
            totalWeight = totalWeight + item.weight
        end

        local r = math.random() * totalWeight
        local currentWeight = 0
        for idx, item in ipairs(pool) do
            currentWeight = currentWeight + item.weight
            if r <= currentWeight then
                table.insert(selected, item.track)
                table.remove(pool, idx)
                break
            end
        end
    end
    return selected
end

local pollActive = false
local pollTimer = 0

function StartRacePoll()
    if RaceSession.state ~= SPZ.RaceState.IDLE and RaceSession.state ~= SPZ.RaceState.POLLING then return end
    
    if RaceSession.state ~= SPZ.RaceState.POLLING then
        exports["spz-races"]:SetRaceState(SPZ.RaceState.POLLING)
    end

    local phase = RaceSession.pollPhase or 1
    local pollOptions = {}
    local uiOptions = {}

    if phase == 1 then
        -- PHASE 1: TRACK SELECTION
        local tracks = GetWeightedTracks(RaceSession.raceType, Config.PollOptionsPerType or 2)
        if #tracks < 1 then
            print("[Race Poll] Error: No tracks found for type " .. RaceSession.raceType)
            exports["spz-races"]:ResetToIdle()
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
        
        RaceSession.pollVotes = { 0, 0 }
    else
        -- PHASE 2: VEHICLE SELECTION
        -- Picker 2 different classes randomly
        local classes = { 0, 1, 2, 3 }
        local selectedClasses = {}
        for i = 1, 2 do
            local idx = math.random(1, #classes)
            table.insert(selectedClasses, classes[idx])
            table.remove(classes, idx)
        end

        local vehicles = {}
        for _, classId in ipairs(selectedClasses) do
            local pool = exports["spz-vehicles"]:GetPollPool(classId, 1)
            if pool and pool[1] then
                table.insert(vehicles, pool[1])
            end
        end

        pollOptions = vehicles
        for _, veh in ipairs(vehicles) do
            local meta = exports["spz-vehicles"]:GetClassMeta(veh.class)
            table.insert(uiOptions, {
                name     = veh.model,
                label    = veh.label,
                subtext  = meta and meta.name or "Unknown",
                color    = meta and meta.color or "#FFFFFF",
                stats    = {
                    { label = "Speed", value = veh.top_speed or "??" },
                    { label = "Accel", value = veh.accel or "??" },
                }
            })
        end

        RaceSession.pollVotes = { 0, 0 }
    end

    RaceSession.pollOptions = pollOptions
    for _, player in pairs(RaceSession.players) do
        player.voted = false
    end

    TriggerClientEvent("SPZ:pollOpen", -1, {
        phase    = phase == 1 and "track" or "vehicle",
        options  = uiOptions,
        duration = Config.PollDuration,
        title    = phase == 1 and "Choose Track" or "Choose Vehicle",
        subtitle = phase == 1 and "VOTE FOR THE NEXT RACE" or "SELECT YOUR PERFORMANCE"
    })

    pollActive = true
    pollTimer  = Config.PollDuration

    Citizen.CreateThread(function()
        while pollTimer > 0 and pollActive do
            Citizen.Wait(1000)
            pollTimer = pollTimer - 1
            if pollTimer == 0 then
                EndRacePoll()
            end
        end
    end)
end

function EndRacePoll()
    if not pollActive then return end
    pollActive = false

    local votes = RaceSession.pollVotes
    local maxVotes = -1
    local winners = {}

    for i, count in ipairs(votes) do
        if count > maxVotes then
            maxVotes = count
            winners = {i}
        elseif count == maxVotes then
            table.insert(winners, i)
        end
    end

    local winnerIdx = winners[math.random(1, #winners)]
    local phase = RaceSession.pollPhase or 1

    if phase == 1 then
        -- Track phase ended
        RaceSession.track = RaceSession.pollOptions[winnerIdx]
        
        -- Transition to Vehicle Phase
        print("[Poll] Track selected: " .. RaceSession.track.name .. ". Transitioning to vehicle selection.")
        
        -- Brief pause for UI transition
        TriggerClientEvent("SPZ:pollResult", -1, {
            winner = { index = winnerIdx },
            phase = "track"
        })

        Citizen.SetTimeout(2000, function()
            RaceSession.pollPhase = 2
            StartRacePoll()
        end)
    else
        -- Vehicle phase ended
        local selection = RaceSession.pollOptions[winnerIdx]
        
        RaceSession.selection = selection
        -- Set carClass for the race engine
        local meta = exports["spz-vehicles"]:GetClassMeta(selection.class)
        RaceSession.carClass = { 
            name     = meta and meta.name or "Open", 
            category = selection.label, 
            color    = meta and meta.color or "#FF6200",
            model    = selection.model
        }

        TriggerClientEvent("SPZ:pollResult", -1, {
            winner = { index = winnerIdx },
            phase  = "vehicle",
            track  = RaceSession.track.name,
            class  = RaceSession.carClass,
            type   = RaceSession.track.type,
            laps   = RaceSession.track.laps,
        })

        exports["spz-races"]:SetRaceState(SPZ.RaceState.WAITING)
    end
end

-- 7.4 Vote Collection
RegisterNetEvent("SPZ:pollVote", function(data)
    local src = source
    if not pollActive then return end

    local player = RaceSession.players[src]
    if not player or player.voted then return end

    local index = data.index
    if not index or index < 1 or index > #RaceSession.pollVotes then return end

    player.voted = true
    RaceSession.pollVotes[index] = RaceSession.pollVotes[index] + 1

    -- Early tally if everyone voted
    local allVoted = true
    local playerCount = 0
    for _, p in pairs(RaceSession.players) do
        playerCount = playerCount + 1
        if not p.voted then
            allVoted = false
        end
    end

    if allVoted and playerCount > 0 then
        EndRacePoll()
    end
end)

exports("StartRacePoll", StartRacePoll)
