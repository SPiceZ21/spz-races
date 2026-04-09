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
    
    -- Notify all players
    TriggerClientEvent("spz_race:state_updated", -1, newState)
end

function StartPolling()
    if RaceSession.state ~= SPZ.RaceState.IDLE then return end
    
    -- Increment cycle count and alternate race type
    RaceSession.cycleCount = RaceSession.cycleCount + 1
    if Config.AlternateTypes then
        RaceSession.raceType = (RaceSession.cycleCount % 2 == 0) and SPZ.RaceType.SPRINT or SPZ.RaceType.CIRCUIT
    end

    -- Pick track logic would go here (interfacing with poll.lua)
    SetState(SPZ.RaceState.POLLING)
end

-- Export functions for other scripts
exports("SetRaceState", SetState)
exports("GetCurrentSession", function() return RaceSession end)

-- Initial IDLE check
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(5000)
        if RaceSession.state == SPZ.RaceState.IDLE then
            -- Logic to check player count for polling trigger
        end
    end
end)
