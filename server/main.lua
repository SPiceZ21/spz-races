-- server/main.lua

-- Initialize player race data for joining players
function CreatePlayerRaceData(src)
    local name = GetPlayerName(src)
    local player = {
        source        = src,
        name          = name,
        crew_tag      = nil,        -- Load from identity if exists
        license_tier  = 1,          -- Default
        current_lap   = 1,
        current_cp    = 1,
        lap_times     = {},
        sector_times  = {},
        finish_time   = nil,
        best_lap      = nil,
        position      = 0,
        finished      = false,
        dnf           = false,
        voted         = false,
        race_start_time = nil,
    }
    return player
end

-- Net events so clients (via spz-menu NUI bridge) can join/leave
RegisterNetEvent("SPZ:joinQueue", function()
    local src = source
    exports["spz-races"]:JoinQueue(src)
end)

RegisterNetEvent("SPZ:leaveQueue", function()
    local src = source
    exports["spz-races"]:LeaveQueue(src)
end)

-- Commands kept as admin/debug convenience
RegisterCommand("joinrace", function(src)
    exports["spz-races"]:JoinQueue(src)
end, false)

RegisterCommand("leaverace", function(src)
    exports["spz-races"]:LeaveQueue(src)
end, false)

-- Push current queue status to all clients so widgets update without polling
function BroadcastQueueUpdate()
    local count = exports["spz-races"]:GetQueueCount()
    TriggerClientEvent("SPZ:queueUpdated", -1, {
        count     = count,
        raceType  = RaceSession.raceType or "circuit",
        raceState = RaceSession.state,
    })
end

exports("BroadcastQueueUpdate", BroadcastQueueUpdate)

-- ── Fallback Resync Handler ──────────────────────────────────────────────────
-- Client requests a full truth dump when it suspects it is desynced.
RegisterNetEvent("SPZ:requestResync", function()
    local src = source
    local pData = RaceSession and RaceSession.players and RaceSession.players[src]
    if not pData then return end

    -- Re-send current checkpoint index so the hit-detector stays on track
    TriggerClientEvent("SPZ:nextCheckpoint", src, pData.current_cp)

    -- Re-send current race state so UI and markers correct themselves
    TriggerClientEvent("spz_race:state_updated", src, RaceSession.state)

    -- Re-broadcast current positions so the leaderboard is up-to-date
    if CalculatePositions and RaceSession.state == SPZ.RaceState.LIVE then
        local ranked = CalculatePositions()
        local payload = {}
        for i, entry in ipairs(ranked) do
            local pd = RaceSession.players[entry.source]
            table.insert(payload, {
                source   = entry.source,
                name     = pd.name,
                crew_tag = pd.crew_tag,
                position = i,
                lap      = pd.current_lap,
                finished = pd.finished,
            })
        end
        -- version = 0 so the client version guard does NOT reject it (resync always wins)
        TriggerClientEvent("SPZ:positionUpdate", src, payload, 0)
    end
end)

-- Export so spz-core cleanup.lua can call it
exports("HandlePlayerDisconnect", function(source)
    local pData = RaceSession and RaceSession.players and RaceSession.players[source]
    if not pData then return end
    local activePhases = {
        [SPZ.RaceState.WAITING]   = true,
        [SPZ.RaceState.COUNTDOWN] = true,
        [SPZ.RaceState.LIVE]      = true,
    }
    if activePhases[RaceSession.state] then
        if MarkDNF then MarkDNF(source, "disconnect") end
    else
        RaceSession.players[source] = nil
    end
end)

function CountPlayers()
    local count = 0
    for _, _ in pairs(RaceSession.players) do
        count = count + 1
    end
    return count
end

-- Clean up on drop
AddEventHandler("playerDropped", function(reason)
    local src = source
    local pData = RaceSession.players[src]
    
    if pData then
        -- 14.1 Mid-Race Disconnect
        local activePhases = {
            [SPZ.RaceState.WAITING] = true,
            [SPZ.RaceState.COUNTDOWN] = true,
            [SPZ.RaceState.LIVE] = true
        }

        if activePhases[RaceSession.state] then
            -- Transition to a DNF state rather than just vanishing, ensuring state consistency
            exports["spz-races"]:MarkDNF(src, "disconnect")
        else
            -- Standard cleanup for IDLE/POLLING states
            RaceSession.players[src] = nil
            print(string.format("[Race Engine] Player %s left the queue.", GetPlayerName(src)))
            
            -- If in polling, check if we still have enough players
            if RaceSession.state == SPZ.RaceState.POLLING then
                if exports["spz-races"]:GetQueueCount() < Config.MinPlayersToStart then
                    exports["spz-races"]:ResetToIdle()
                end
            end
        end
    end
end)
