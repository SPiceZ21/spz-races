-- server/no_collision.lua

-- 9. No-Collision Handler
function ApplyRaceNoCollision()
    if not RaceSession.bucketId then return end
    
    -- Retrieve participants in the current race's isolated bucket
    local players = exports["spz-core"]:GetBucketPlayers(RaceSession.bucketId)
    if not players or #players < 2 then return end

    print(string.format("[Collision] Applying pairwise ghosting to %s participants", #players))

    for i = 1, #players do
        for j = i + 1, #players do
            local playerA = players[i]
            local playerB = players[j]
            
            -- Ped handle retrieval on server (Native 4.0+)
            -- Passing the target source is more reliable for client-side resolution
            TriggerClientEvent("SPZ:applyNoCollision", playerA, playerB)
            TriggerClientEvent("SPZ:applyNoCollision", playerB, playerA)
        end
    end
end

-- Export for world setup integration
exports("ApplyRaceNoCollision", ApplyRaceNoCollision)
