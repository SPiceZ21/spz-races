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
    if RaceSession.players[src] then
        RaceSession.players[src] = nil
        print(string.format("[Race Engine] Player %s left the race.", GetPlayerName(src)))
    end
end)
