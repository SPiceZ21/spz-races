-- server/cleanup.lua

-- 16.2 Cycle Logic
local function NextCycleType()
    local cycleOrder = Config.CycleOrder or { "circuit", "sprint" }
    local index = (RaceSession.cycleCount % #cycleOrder) + 1
    return cycleOrder[index]
end

-- 16.1 Cleanup Sequence
function RunRaceCleanup(results)
    -- Manually set state to CLEANUP for internal listeners
    exports["spz-races"]:SetRaceState(SPZ.RaceState.CLEANUP)

    print("[Race Engine] Initiating final sequence cleanup.")
    
    -- ... (rest of the loop remains same)
    for source, _ in pairs(RaceSession.players) do
        -- Clear track entities
        if GetResourceState("spz-vehicles") == "started" then
            exports["spz-vehicles"]:DespawnVehicle(source)
        end

        -- Redistribution to freeroam
        exports["spz-core"]:AssignPlayerToBucket(source, 0)
        exports["spz-core"]:SetPlayerState(source, "IDLE")

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

    -- Return state machine to IDLE
    exports["spz-races"]:SetRaceState(SPZ.RaceState.IDLE)

    -- Trigger intermission period
    if StartIntermission then
        StartIntermission(results)
    end
end

-- Export for state machine integration
exports("RunRaceCleanup", RunRaceCleanup)
