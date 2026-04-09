-- client/checkpoints.lua
local currentCheckpoints = {}
local nextCheckpointIndex = 1
local lastHitTime = 0

function LoadTrack(trackData)
    currentCheckpoints = trackData.checkpoints
    nextCheckpointIndex = 1
    
    -- Clear old blips/markers if any
    -- Render first CP
end

RegisterNetEvent("spz_race:track_data", function(trackData)
    LoadTrack(trackData)
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if #currentCheckpoints > 0 then
            local playerPed = PlayerPedId()
            local coords = GetEntityCoords(playerPed)
            local targetCP = currentCheckpoints[nextCheckpointIndex]
            
            if targetCP then
                -- Render marker
                DrawMarker(1, targetCP.x, targetCP.y, targetCP.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 5.0, 5.0, 5.0, 255, 0, 0, 100, false, true, 2, nil, nil, false)
                
                -- Simple hit detection (replace with hit_detector.lua for precision)
                local dist = Vdist(coords.x, coords.y, coords.z, targetCP.x, targetCP.y, targetCP.z)
                if dist < 5.0 and GetGameTimer() - lastHitTime > 1000 then
                    lastHitTime = GetGameTimer()
                    
                    -- Trigger server hit
                    TriggerServerEvent("spz_race:checkpoint_hit", nextCheckpointIndex)
                    
                    -- Logic to advance nextCheckpointIndex (server will sync it back or client handles it)
                    -- In a real implementation, we'd wait for server confirmation or predict
                end
            end
        end
    end
end)

-- Receive sync for current_cp from server
RegisterNetEvent("spz_race:sync_cp", function(nextCP)
    nextCheckpointIndex = nextCP
end)
