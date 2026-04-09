-- client/main.lua

-- ghost car behavior
RegisterNetEvent("SPZ:applyNoCollision", function(targetServerId)
    local myPed = PlayerPedId()
    local targetId = GetPlayerFromServerId(targetServerId)
    
    -- Ensure the target player is actually active and resolved on this client
    if targetId ~= -1 then
        local targetPed = GetPlayerPed(targetId)
        if DoesEntityExist(targetPed) then
            -- Both directions — A ignores B and B ignores A
            SetEntityNoCollisionEntity(myPed, targetPed, false)
            SetEntityNoCollisionEntity(targetPed, myPed, false)
            
            -- Also apply to vehicles if peds are in them
            local myVeh = GetVehiclePedIsIn(myPed, false)
            local targetVeh = GetVehiclePedIsIn(targetPed, false)
            
            if DoesEntityExist(myVeh) and DoesEntityExist(targetVeh) then
                SetEntityNoCollisionEntity(myVeh, targetVeh, false)
                SetEntityNoCollisionEntity(targetVeh, myVeh, false)
            end
        end
    end
end)
