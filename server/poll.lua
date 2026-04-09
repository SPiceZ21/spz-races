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
                table.remove(pool, idx) -- Ensure unique selection
                break
            end
        end
    end
    return selected
end

-- 7.2 Class Eligibility
local function GetEligibleClasses(players)
    local minTier = 3 -- Start at max tier
    for source, _ in pairs(players) do
        -- Identity check for each participant
        local tier = exports["spz-identity"]:GetLicenseTier(source) or 0
        if tier < minTier then minTier = tier end
    end
    
    local eligible = {}
    for i = 0, minTier do 
        table.insert(eligible, i) 
    end

    -- Shuffle eligible classes to pick two
    for i = #eligible, 2, -1 do
        local j = math.random(i)
        eligible[i], eligible[j] = eligible[j], eligible[i]
    end

    return { eligible[1], eligible[2] or eligible[1] }
end

local pollActive = false
local pollTimer = 0

function StartRacePoll()
    if RaceSession.state ~= SPZ.RaceState.POLLING then return end
    
    local tracks = GetWeightedTracks(RaceSession.raceType, 2)
    local classes = GetEligibleClasses(RaceSession.players)

    if #tracks < 1 then
        print("[Race Poll] Error: No tracks found for type " .. RaceSession.raceType)
        exports["spz-races"]:ResetToIdle()
        return
    end

    RaceSession.pollOptions = {
        tracks = tracks,
        classes = classes
    }
    
    RaceSession.pollVotes = {
        tracks = {0, 0},
        classes = {0, 0}
    }

    -- Reset voter status for all participants
    for _, player in pairs(RaceSession.players) do
        player.voted = false
    end

    print(string.format("[Poll] Starting poll for %s type. Options: %s, %s", 
        RaceSession.raceType, tracks[1].name, tracks[2] and tracks[2].name or "N/A"))

    TriggerClientEvent("SPZ:pollOpen", -1, {
        tracks  = tracks,
        classes = classes,
        duration = Config.PollDuration,
    })

    pollActive = true
    pollTimer = Config.PollDuration

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

    local function TallyWinner(votes)
        if votes[1] == votes[2] then
            return math.random(1, 2) -- Tiebreak
        end
        return votes[1] > votes[2] and 1 or 2
    end

    local trackIdx = TallyWinner(RaceSession.pollVotes.tracks)
    local classIdx = TallyWinner(RaceSession.pollVotes.classes)

    RaceSession.track    = RaceSession.pollOptions.tracks[trackIdx]
    RaceSession.carClass = RaceSession.pollOptions.classes[classIdx]

    TriggerClientEvent("SPZ:pollResult", -1, {
        track    = RaceSession.track.name,
        class    = RaceSession.carClass,
        type     = RaceSession.track.type,
        laps     = RaceSession.track.laps,
    })

    -- Advance state machine to WAITING
    exports["spz-races"]:SetRaceState(SPZ.RaceState.WAITING)
end

-- 7.4 Vote Collection
RegisterNetEvent("SPZ:pollVote", function(trackIdx, classIdx)
    local src = source
    if not pollActive then return end
    
    local player = RaceSession.players[src]
    if not player or player.voted then return end

    -- Validation
    if trackIdx < 1 or trackIdx > 2 or classIdx < 1 or classIdx > 2 then return end

    player.voted = true
    RaceSession.pollVotes.tracks[trackIdx] = RaceSession.pollVotes.tracks[trackIdx] + 1
    RaceSession.pollVotes.classes[classIdx] = RaceSession.pollVotes.classes[classIdx] + 1

    -- Trigger tally early if everyone has voted
    local allVoted = true
    for _, p in pairs(RaceSession.players) do
        if not p.voted then
            allVoted = false
            break
        end
    end

    if allVoted then
        EndRacePoll()
    end
end)

-- Export for state machine
exports("StartRacePoll", StartRacePoll)
