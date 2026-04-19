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
    pollPhase    = 1, -- 1 = Track, 2 = Vehicle
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
                TriggerClientEvent("SPZ:spawnCheckpoints", src, RaceSession.track.checkpoints, 1, RaceSession.track.type)
            end
        end
        exports["spz-races"]:StartCountdownSequence()
    elseif newState == SPZ.RaceState.ENDED then
        local results = exports["spz-races"]:ProcessRaceResults()
        -- Wait for results screen, then run cleanup once
        Citizen.SetTimeout(Config.ResultsDisplayTime or 15000, function()
            exports["spz-races"]:RunRaceCleanup(results)
        end)
    elseif newState == SPZ.RaceState.CLEANUP then
        -- Informational only — cleanup is driven by the ENDED timeout above.
        -- Nothing to execute here to avoid double-despawn.
        print("[Race Engine] State: CLEANUP")
    end

    -- Notify all players
    TriggerClientEvent("spz_race:state_updated", -1, newState)
end

function StartPolling()
    if RaceSession.state ~= SPZ.RaceState.IDLE then return end

    -- Do not start a poll if nobody is queued — the idle loop will retry every 5 s
    local count = GetQueueCount and GetQueueCount() or 0
    if count < (Config.MinPlayersToStart or 1) then
        print(string.format("[Race Engine] StartPolling skipped — %d player(s) queued (need %d)", count, Config.MinPlayersToStart or 1))
        return
    end

    -- Race format (circuit/sprint) is already pre-determined during the previous cleanup phase
    RaceSession.pollPhase = 1
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

-- Polling loop — only fires when truly idle and not mid-intermission
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(5000)
        if RaceSession.state == SPZ.RaceState.IDLE and not RaceSession.intermissionActive then
            local count = exports["spz-races"]:GetQueueCount()
            if count >= (Config.MinPlayersToStart or 1) then
                StartPolling()
            end
        end
    end
end)
