-- server/queue.lua

local function GetPlayerState(src)
    -- Assuming spz-identity framework exists
    return exports["spz-identity"]:GetPlayerState(src)
end

local function SetPlayerState(src, state)
    exports["spz-identity"]:SetPlayerState(src, state)
end

local function HasLicense(src, index)
    return exports["spz-identity"]:HasLicense(src, index)
end

local function Notify(src, msg)
    -- Placeholder for notification system
    TriggerClientEvent("spz_race:notify", src, msg)
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

    -- 3. HasLicense(source, 0)? (Class C)
    if not HasLicense(src, 0) then
        Notify(src, "Class C license required to join")
        return false
    end

    -- 3.5 Check Max Capacity
    if GetQueueCount() >= (Config.MaxPlayersPerRace or 16) then
        Notify(src, "The race queue is currently full")
        return false
    end

    -- 4. Add to RaceSession.players[source]
    RaceSession.players[src] = CreatePlayerRaceData(src)
    
    -- 5. SetPlayerState(source, "QUEUED")
    SetPlayerState(src, "QUEUED")

    -- 6. Notify "Joined queue (X players waiting)"
    local count = GetQueueCount()
    Notify(src, string.format("Joined queue (%s players waiting)", count))

    -- 7. If count >= Config.MinPlayersToStart → start pre-poll countdown
    if count >= Config.MinPlayersToStart then
        StartPolling()
    end
    
    return true
end

function LeaveQueue(src)
    -- 6.2 LeaveQueue Logic
    if RaceSession.players[src] then
        RaceSession.players[src] = nil
        SetPlayerState(src, "IDLE")

        local count = GetQueueCount()
        -- If count drops below Config.MinPlayersToStart during POLLING
        if RaceSession.state == SPZ.RaceState.POLLING and count < Config.MinPlayersToStart then
            -- Note: We need a way to cancel the current poll
            if exports["spz-races"]:ResetToIdle then
                exports["spz-races"]:ResetToIdle()
            end
        end
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
