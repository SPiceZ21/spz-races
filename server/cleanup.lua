-- server/cleanup.lua

-- 16.2 Cycle Logic
local function NextCycleType()
    local cycleOrder = Config.CycleOrder or { "circuit", "sprint" }
    local index = (RaceSession.cycleCount % #cycleOrder) + 1
    return cycleOrder[index]
end

-- 16.1 Cleanup Sequence
function RunRaceCleanup(results)
    -- Transition to CLEANUP state so other modules can react (no-op in state machine handler)
    if RaceSession.state ~= SPZ.RaceState.CLEANUP then
        exports["spz-races"]:SetRaceState(SPZ.RaceState.CLEANUP)
    end

    print("[Race Engine] Initiating final sequence cleanup.")
    
    -- ... (rest of the loop remains same)
    for source, _ in pairs(RaceSession.players) do
        -- Clear track entities
        if GetResourceState("spz-vehicles") == "started" then
            exports["spz-vehicles"]:DespawnVehicle(source)
        end

        -- Redistribution to freeroam
        exports["spz-core"]:AssignPlayerToBucket(source, 0)
        
        -- Clear race statebags
        Player(source).state:set("inRace",       false, true)
        Player(source).state:set("inQueue",      false, true)
        Player(source).state:set("queueClass",   nil,   true)
        Player(source).state:set("raceId",       nil,   true)
        Player(source).state:set("raceClass",    nil,   true)
        Player(source).state:set("raceTrack",    nil,   true)
        Player(source).state:set("raceLap",      nil,   true)
        Player(source).state:set("raceLaps",     nil,   true)
        Player(source).state:set("personalBest", nil,   true)
        Player(source).state:set("allTimeBest",  nil,   true)
        Player(source).state:set("racePosition", nil,   true)
        Player(source).state:set("raceTime",     nil,   true)

        -- Trigger client-side teleport to safe zone
        TriggerClientEvent("SPZ:tpToSafeZone", source)
    end

    -- 2. Terminate the isolated environment
    if RaceSession.bucketId and RaceSession.bucketId ~= 0 then
        Citizen.Wait(500)
        exports["spz-core"]:DeleteBucket(RaceSession.bucketId)
        print(string.format("[Race Engine] Bucket %s deleted.", RaceSession.bucketId))
    end

    -- 3. Reset the global session state for the next cycle
    local lastCycleCount = RaceSession.cycleCount or 0
    
    RaceSession = {
        state        = SPZ.RaceState.IDLE,
        raceId       = nil,
        raceType     = "circuit", -- default
        track        = nil,
        carClass     = 1,
        bucketId     = 0,
        startTime    = 0,
        players      = {},
        pollVotes    = {},
        pollOptions  = {},
        pollPhase    = 1,
        cycleCount   = lastCycleCount + 1,
    }

    -- Determine next race format
    RaceSession.raceType = NextCycleType()
    print(string.format("[Race Engine] Next cycle (#%d) initialized as: %s", RaceSession.cycleCount, RaceSession.raceType))

    -- Capture still-connected participants before clearing the session so they
    -- can be automatically re-queued after intermission.
    local prevPlayers = {}
    for src in pairs(RaceSession.players) do
        if GetPlayerName(src) then
            table.insert(prevPlayers, src)
        end
    end

    -- Block the idle polling loop BEFORE transitioning to IDLE so the
    -- 5-second polling thread cannot sneak in between the two writes.
    RaceSession.intermissionActive = true

    -- Return state machine to IDLE
    exports["spz-races"]:SetRaceState(SPZ.RaceState.IDLE)

    -- Broadcast queue update so UIs reflect the reset
    if BroadcastQueueUpdate then BroadcastQueueUpdate() end

    -- Trigger intermission period (pass previous players for auto-requeue)
    if StartIntermission then
        StartIntermission(results, prevPlayers)
    end
end

-- Export for state machine integration
exports("RunRaceCleanup", RunRaceCleanup)
