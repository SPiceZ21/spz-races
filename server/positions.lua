-- server/positions.lua

-- 13.1 Position Calculation
local function GetDistToNextCP(source, pData)
    if not RaceSession.track or not RaceSession.track.checkpoints then return 9999.0 end
    
    local cpIndex = pData.current_cp
    local cp = RaceSession.track.checkpoints[cpIndex]
    if not cp then return 9999.0 end

    local ped = GetPlayerPed(source)
    if not DoesEntityExist(ped) then return 9999.0 end

    local playerPos = GetEntityCoords(ped)
    local cpPos = vector3(cp.coords.x, cp.coords.y, cp.coords.z)
    return #(playerPos - cpPos)
end

function CalculatePositions()
    local ranked = {}

    for source, pData in pairs(RaceSession.players) do
        if not pData.dnf then
            table.insert(ranked, {
                source    = source,
                finished  = pData.finished,
                lap       = pData.current_lap,
                cp        = pData.current_cp,
                finish_time = pData.finish_time or 0,
                -- Distance to next checkpoint (tiebreak)
                dist      = GetDistToNextCP(source, pData),
            })
        end
    end

    -- Sort logic: 
    -- 1. Finished players first (by finish_time asc)
    -- 2. Then by lap descending
    -- 3. Then by cp descending
    -- 4. Finally by distance to next CP ascending (closer is better)
    table.sort(ranked, function(a, b)
        if a.finished ~= b.finished then return a.finished end
        if a.finished and b.finished then return a.finish_time < b.finish_time end
        
        if a.lap ~= b.lap then return a.lap > b.lap end
        if a.cp  ~= b.cp  then return a.cp  > b.cp  end
        return a.dist < b.dist
    end)

    -- Update the actual player data objects
    for i, entry in ipairs(ranked) do
        RaceSession.players[entry.source].position = i
    end

    return ranked
end

-- 13.2 Periodic Broadcast
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(Config.PositionBroadcastInterval or 1000)
        
        if RaceSession.state == SPZ.RaceState.LIVE then
            local ranked = CalculatePositions()
            local payload = {}

            for i, entry in ipairs(ranked) do
                local pData = RaceSession.players[entry.source]
                table.insert(payload, {
                    source   = entry.source,
                    name     = pData.name,
                    crew_tag = pData.crew_tag,
                    position = i,
                    lap      = pData.current_lap,
                    finished = pData.finished,
                })
            end

            -- Broadcasting to everyone in the race (effectively -1 as racers are isolated in bucket)
            TriggerClientEvent("SPZ:positionUpdate", -1, payload)
        end
    end
end)

-- Manual update trigger (e.g. immediately after a CP hit or finish)
function UpdateAllPositions()
    CalculatePositions()
    -- We can optionally force a broadcast here too if we want immediate HUD updates
end

-- Export for external systems
exports("UpdatePositions", UpdateAllPositions)
exports("CalculatePositions", CalculatePositions)
