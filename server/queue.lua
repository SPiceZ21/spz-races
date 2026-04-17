-- server/queue.lua

local function GetPlayerState(src)
    return exports["spz-core"]:GetPlayerState(src)
end

local function SetPlayerState(src, state)
    exports["spz-core"]:SetPlayerState(src, state)
end

local function HasLicense(src, classId)
    local tier = exports["spz-identity"]:GetLicenseTier(src) or 0
    return tier >= classId
end

local function Notify(src, msg, msgType)
    TriggerClientEvent("spz-lib:Notify", src, msg, msgType or "info", 4000)
end

function JoinQueue(src)
    -- 6.1 JoinQueue Logic

    -- 1. RaceSession.state == "IDLE"?
    if RaceSession.state ~= SPZ.RaceState.IDLE then
        Notify(src, "A race is in progress — wait for next cycle")
        return false
    end

    -- 2. Already in a race or queue?
    local playerState = GetPlayerState(src)
    if playerState == "RACING" or playerState == "QUEUED" then
        Notify(src, "You are already in a race or queue")
        return false
    end

    -- 3. Check Max Capacity
    if GetQueueCount() >= (Config.MaxPlayersPerRace or 16) then
        Notify(src, "The race queue is currently full")
        return false
    end

    -- 4. Add to RaceSession.players[source]
    RaceSession.players[src] = CreatePlayerRaceData(src)
    
    -- 5. SetPlayerState(source, "QUEUED")
    SetPlayerState(src, "QUEUED")

    -- 6. Notify and broadcast
    local count = GetQueueCount()
    Notify(src, string.format("Joined queue (%s players waiting)", count), "success")
    BroadcastQueueUpdate()

    -- 7. If count >= Config.MinPlayersToStart → start poll
    if count >= Config.MinPlayersToStart then
        StartPolling()
    end

    return true
end

function LeaveQueue(src)
    -- 6.2 LeaveQueue Logic
    if not RaceSession.players[src] then return end

    RaceSession.players[src] = nil
    SetPlayerState(src, "FREEROAM")
    Notify(src, "Left the queue", "info")
    BroadcastQueueUpdate()

    local count = GetQueueCount()
    if RaceSession.state == SPZ.RaceState.POLLING and count < Config.MinPlayersToStart then
        exports["spz-races"]:ResetToIdle()
    end
end

-- 6.3 Status Exports
function GetQueueCount()
    local count = 0
    for _ in pairs(RaceSession.players) do
        count = count + 1
    end
    return count
end

function GetQueuePlayers()
    local players = {}
    for src, _ in pairs(RaceSession.players) do
        table.insert(players, src)
    end
    return players
end

function IsQueued(src)
    return RaceSession.players[src] ~= nil
end

exports("JoinQueue", JoinQueue)
exports("LeaveQueue", LeaveQueue)
exports("GetQueueCount", GetQueueCount)
exports("GetQueuePlayers", GetQueuePlayers)
exports("IsQueued", IsQueued)
