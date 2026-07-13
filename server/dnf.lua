-- server/dnf.lua

-- 14.2 MarkDNF Logic
function MarkDNF(source, reason)
    local pData = RaceSession.players[source]
    if not pData or pData.finished or pData.dnf then return end

    print(string.format("[Race Engine] Player %s (%s) DNF! Reason: %s", pData.name, source, reason))

    pData.dnf = true
    pData.dnf_reason = reason
    pData.finish_time = nil

    -- 14.2 Despawn Vehicle
    if GetResourceState("spz-vehicles") == "started" then
        exports["spz-vehicles"]:DespawnVehicle(source)
    end

    -- 14.2 Notify remaining racers
    BroadcastToRacers("SPZ:playerDNF", {
        source = source,
        name   = pData.name,
        reason = reason,
    })

    -- Return to default bucket and clean up state
    exports["spz-core"]:AssignPlayerToBucket(source, 0)

    -- Clear race statebags
    Player(source).state:set("inRace",       false, true)
    Player(source).state:set("inQueue",      false, true)
    Player(source).state:set("queueClass",   nil,   true)
    Player(source).state:set("raceId",       nil,   true)
    Player(source).state:set("raceClass",    nil,   true)
    Player(source).state:set("raceTrack",    nil,   true)
    Player(source).state:set("racePosition", nil,   true)
    Player(source).state:set("raceLap",      nil,   true)
    Player(source).state:set("raceLaps",     nil,   true)
    Player(source).state:set("personalBest", nil,   true)
    Player(source).state:set("allTimeBest",  nil,   true)
    Player(source).state:set("raceTime",     nil,   true)
    Player(source).state:set("dnf",          true,  true)

    -- 14.3 Check if everyone is finished
    CheckAllFinished()
end

-- Backward compatibility for early implementation
function ProcessDNF(source, reason)
    MarkDNF(source, reason)
end

function CheckAllFinished()
    local allDone = true
    local participantsCount = 0
    
    for _, p in pairs(RaceSession.players) do
        participantsCount = participantsCount + 1
        if not p.finished and not p.dnf then
            allDone = false
            break
        end
    end
    
    if allDone and participantsCount > 0 then
        print("[Race Engine] All participants completed or DNF. Ending race session.")
        exports["spz-races"]:SetRaceState(SPZ.RaceState.ENDED)
    end
end

-- mid-race disconnects are handled in server/main.lua to centralized drop events
-- but we export MarkDNF for it to use.

exports("MarkDNF", MarkDNF)
exports("ProcessDNF", MarkDNF)
exports("CheckAllFinished", CheckAllFinished)
