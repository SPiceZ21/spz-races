-- server/queue.lua

-- Players who tried to join while a race/break/prep was active. They freeroam
-- until the current race ends, then are auto-enrolled into the next cycle.
-- Kept at module scope so it survives the RaceSession reset during cleanup.
PendingNextCycle = PendingNextCycle or {}

local function Notify(src, msg, msgType)
    SPZ.Notify(src, msg, msgType or "info", 4000)
end

function JoinQueue(src)
    if Player(src).state.inRace or Player(src).state.inQueue then
        Notify(src, "You are already in a race or queue")
        return false
    end

    -- Mid-cycle join → freeroam now, auto-join the next race.
    if RaceSession.state ~= SPZ.RaceState.IDLE then
        if Player(src).state.pendingRace then
            Notify(src, "You're already set to join the next race — freeroam until it starts")
            return false
        end
        PendingNextCycle[src] = true
        Player(src).state:set("pendingRace", true, true)
        Notify(src, "Race in progress — freeroam now, you'll auto-join the next race", "info")
        return true
    end

    if GetQueueCount() >= (Config.MaxPlayersPerRace or 16) then
        Notify(src, "The race queue is currently full")
        return false
    end

    RaceSession.players[src] = CreatePlayerRaceData(src)

    Player(src).state:set("inQueue",       true,            true)
    Player(src).state:set("queuePosition", GetQueueCount(), true)

    local count = GetQueueCount()
    Notify(src, string.format("Joined queue (%d players waiting)", count), "success")
    BroadcastQueueUpdate()

    if count >= (Config.MinPlayersToStart or 1) then
        local delay = (Config.PollWaitTime or 2) * 1000
        Citizen.SetTimeout(delay, function()
            -- Re-check threshold after delay in case someone left
            if RaceSession.state == SPZ.RaceState.IDLE
            and GetQueueCount() >= (Config.MinPlayersToStart or 1) then
                StartRacePoll()
            end
        end)
    end

    return true
end

function LeaveQueue(src)
    -- Cancel a pending next-cycle enrolment (freeroaming, not yet in a queue).
    if PendingNextCycle[src] then
        PendingNextCycle[src] = nil
        Player(src).state:set("pendingRace", false, true)
        Notify(src, "Cancelled — you won't auto-join the next race", "info")
        return
    end

    if not RaceSession.players[src] then return end

    local activePhases = {
        [SPZ.RaceState.WAITING]   = true,
        [SPZ.RaceState.COUNTDOWN] = true,
        [SPZ.RaceState.LIVE]      = true,
    }

    if activePhases[RaceSession.state] then
        MarkDNF(src, "Abandoned Race")
        Notify(src, "You abandoned the race.", "error")
        return
    end

    RaceSession.players[src] = nil

    Player(src).state:set("inQueue",       false, true)
    Player(src).state:set("queuePosition", nil,   true)
    Player(src).state:set("queueClass",    nil,   true)

    Notify(src, "Left the queue", "info")
    BroadcastQueueUpdate()

    if RaceSession.state == SPZ.RaceState.POLLING
    and GetQueueCount() < (Config.MinPlayersToStart or 1) then
        ResetToIdle()
    end
end

function GetQueueCount()
    local n = 0
    for _ in pairs(RaceSession.players) do n = n + 1 end
    return n
end

function GetQueuePlayers()
    local players = {}
    for src in pairs(RaceSession.players) do
        table.insert(players, src)
    end
    return players
end

function IsQueued(src)
    return RaceSession.players[src] ~= nil
end

-- Enrol everyone who freeroamed during the last race into the new cycle.
-- Called once the engine is back to IDLE (after intermission).
function FlushPendingToQueue()
    for src in pairs(PendingNextCycle) do
        PendingNextCycle[src] = nil
        if GetPlayerName(src) then
            Player(src).state:set("pendingRace", false, true)
            JoinQueue(src)
        end
    end
end

function ClearPending(src)
    if PendingNextCycle[src] then
        PendingNextCycle[src] = nil
        if GetPlayerName(src) then
            Player(src).state:set("pendingRace", false, true)
        end
    end
end

exports("JoinQueue",      JoinQueue)
exports("LeaveQueue",     LeaveQueue)
exports("GetQueueCount",  GetQueueCount)
exports("GetQueuePlayers", GetQueuePlayers)
exports("IsQueued",       IsQueued)
exports("FlushPendingToQueue", FlushPendingToQueue)
exports("ClearPending",   ClearPending)
