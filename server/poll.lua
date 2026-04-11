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
    if RaceSession.state ~= SPZ.RaceState.POLLING then return end

    local tracks = GetWeightedTracks(RaceSession.raceType, Config.PollOptionsPerType or 2)

    if #tracks < 1 then
        print("[Race Poll] Error: No tracks found for type " .. RaceSession.raceType)
        exports["spz-races"]:ResetToIdle()
        return
    end

    RaceSession.pollOptions = { tracks = tracks }
    RaceSession.pollVotes   = { tracks = {0, 0} }

    for _, player in pairs(RaceSession.players) do
        player.voted = false
    end

    print(string.format("[Poll] Starting poll for %s type. Options: %s, %s",
        RaceSession.raceType, tracks[1].name, tracks[2] and tracks[2].name or "N/A"))

    -- Lightweight track data for UI (strip coordinates)
    local uiTracks = {}
    for _, track in ipairs(tracks) do
        table.insert(uiTracks, {
            name             = track.name,
            type             = track.type,
            laps             = track.laps,
            checkpointCount  = #track.checkpoints,
            recommendedClass = track.recommendedClass or "Any",
        })
    end

    TriggerClientEvent("SPZ:pollOpen", -1, {
        tracks   = uiTracks,
        duration = Config.PollDuration,
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

    local votes = RaceSession.pollVotes.tracks
    local trackIdx
    if votes[1] == votes[2] then
        trackIdx = math.random(1, 2)
    else
        trackIdx = votes[1] > votes[2] and 1 or 2
    end

    RaceSession.track = RaceSession.pollOptions.tracks[trackIdx]

    -- Fixed car — no class voting, all players use the same vehicle
    RaceSession.carClass = { name = "Open", category = "Equal", color = "#FF6200" }

    TriggerClientEvent("SPZ:pollResult", -1, {
        track  = RaceSession.track.name,
        class  = RaceSession.carClass,
        type   = RaceSession.track.type,
        laps   = RaceSession.track.laps,
        winner = { trackIdx = trackIdx - 1 },
    })

    exports["spz-races"]:SetRaceState(SPZ.RaceState.WAITING)
end

-- 7.4 Vote Collection (track only)
RegisterNetEvent("SPZ:pollVote", function(trackIdx)
    local src = source
    if not pollActive then return end

    local player = RaceSession.players[src]
    if not player or player.voted then return end

    if trackIdx < 1 or trackIdx > 2 then return end

    player.voted = true
    RaceSession.pollVotes.tracks[trackIdx] = RaceSession.pollVotes.tracks[trackIdx] + 1

    -- Early tally if everyone voted
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

exports("StartRacePoll", StartRacePoll)
