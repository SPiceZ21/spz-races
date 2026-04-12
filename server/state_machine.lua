-- server/state_machine.lua
RaceSession = {
    state        = SPZ.RaceState.IDLE,
    raceId       = nil,
    raceType     = "circuit",
    track        = nil,
    carClass     = 1, -- Default class
    bucketId     = 0,
    startTime    = 0,
    players      = {},
    pollVotes    = {},
    pollOptions  = {},
    cycleCount   = 0,
}

local function SetState(newState)
    local oldState = RaceSession.state
    if oldState == newState then return end

    -- 5.2 Legal Transitions
    -- Validate transition logic here if required
    print(string.format("[Race Engine] State Transition: %s -> %s", oldState, newState))
    RaceSession.state = newState
    
    -- Handle logic for entering specific states
    if newState == SPZ.RaceState.WAITING then
        exports["spz-races"]:SetupRaceWorld()
    elseif newState == SPZ.RaceState.COUNTDOWN then
        -- Initialize track visuals for all participants
        if RaceSession.track and RaceSession.track.checkpoints then
            for src, _ in pairs(RaceSession.players) do
                TriggerClientEvent("SPZ:spawnCheckpoints", src, RaceSession.track.checkpoints, 1)
            end
        end
        exports["spz-races"]:StartCountdownSequence()
    elseif newState == SPZ.RaceState.ENDED then
        -- Process final standings and broadcast results
        local results = exports["spz-races"]:ProcessRaceResults()
        
        -- Automatic progression to cleanup after results are viewed
        Citizen.SetTimeout(Config.ResultsDisplayTime or 15000, function()
            exports["spz-races"]:RunRaceCleanup(results)
        end)
    elseif newState == SPZ.RaceState.CLEANUP then
        -- Execute the full cleanup sequence (redistribution, bucket deletion, session reset)
        exports["spz-races"]:RunRaceCleanup()
    end

    -- Notify all players
    TriggerClientEvent("spz_race:state_updated", -1, newState)
end

function StartPolling()
    if RaceSession.state ~= SPZ.RaceState.IDLE then return end
    
    -- Race format (circuit/sprint) is already pre-determined during the previous cleanup phase
    SetState(SPZ.RaceState.POLLING)
    
    -- Initiate the weighted track and class selection
    StartRacePoll()
end

function ResetToIdle()
    print("[Race Engine] Resetting to IDLE")
    RaceSession.pollVotes = {}
    RaceSession.pollOptions = {}
    SetState(SPZ.RaceState.IDLE)
end

-- Export functions for other scripts
exports("SetRaceState", SetState)
exports("ResetToIdle", ResetToIdle)
exports("StartPolling", StartPolling)
exports("GetCurrentSession", function() return RaceSession end)

-- Initial IDLE check
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(5000)
        if RaceSession.state == SPZ.RaceState.IDLE then
            local count = exports["spz-races"]:GetQueueCount()
            if count >= (Config.MinPlayersToStart or 1) then
                StartPolling()
            end
        end
    end
end)
