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
    }
    return player
end

-- Command to join the race queue (simple placeholder)
RegisterCommand("joinrace", function(src, args)
    if RaceSession.state == SPZ.RaceState.IDLE then
        if not RaceSession.players[src] then
            RaceSession.players[src] = CreatePlayerRaceData(src)
            print(string.format("[Race Engine] Player %s joined the queue.", GetPlayerName(src)))
            
            -- Trigger state change to POLLING if min players reached
            if CountPlayers() >= 1 then -- Min player count for testing
                StartPolling()
            end
        end
    end
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
