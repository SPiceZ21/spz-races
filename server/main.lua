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

-- Command to join the race queue
RegisterCommand("joinrace", function(src, args)
    exports["spz-races"]:JoinQueue(src)
end, false)

-- Command to leave the race queue
RegisterCommand("leaverace", function(src, args)
    exports["spz-races"]:LeaveQueue(src)
end, false)

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
