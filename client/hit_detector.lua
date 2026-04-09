-- client/hit_detector.lua

-- 11.3 Hit Detection (Client)
-- High-precision thread running during LIVE state for millisecond-perfect crossing detection.
Citizen.CreateThread(function()
    while true do
        local raceState = exports["spz-races"]:GetRaceState()
        
        if raceState == "LIVE" then
            local cp, cpIndex = exports["spz-races"]:GetCurrentCP()
            
            if cp then
                local playerPed = PlayerPedId()
                local playerPos = GetEntityCoords(playerPed)
                
                -- Distance check against CP center and assigned radius
                -- Using # operator for optimized vector distance calculation
                local dist = #(playerPos - cp.coords)
                
                if dist < (cp.radius or 5.0) then
                    -- Notify server of the hit
                    TriggerServerEvent("SPZ:checkpointHit", cpIndex)
                    
                    -- Brief wait to prevent multi-triggering on a single frame before index advances
                    Citizen.Wait(500)
                else
                    -- Tight loop during live race
                    Citizen.Wait(0)
                end
            else
                Citizen.Wait(100)
            end
        else
            -- Relaxed polling when not in a live race
            Citizen.Wait(500)
        end
    end
end)
