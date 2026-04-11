-- 9. No-Collision Handler
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

-- 10.2 Client Freeze Logic
RegisterNetEvent("SPZ:freezeRacer", function(freeze)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    
    -- Freeze positions to prevent any movement before green light
    FreezeEntityPosition(ped, freeze)
    if DoesEntityExist(veh) then
        FreezeEntityPosition(veh, freeze)
    end
    
    -- Toggle invincibility to prevent pre-race griefing or accidental damage
    SetEntityInvincible(ped, freeze)
    if DoesEntityExist(veh) then
        SetEntityInvincible(veh, freeze)
        SetVehicleTyresCanBurst(veh, not freeze) -- Prevent popped tires while frozen
    end
    
    if freeze then
        print("[Race] Frozen for countdown.")
    else
        print("[Race] Unfrozen - GO!")
    end
end)

-- HUD animations/triggers
RegisterNetEvent("SPZ:countdown", function(data)
    -- This event is typically handled by spz-hud, but we log it here for debug
    print("[Race] Countdown: " .. data.seconds)
end)

RegisterNetEvent("SPZ:go", function()
    print("[Race] Starting line crossed - GO GO GO!")
end)

-- Teleport player to safe zone after race cleanup.
-- Fires server-side in cleanup.lua after the race bucket is freed.
RegisterNetEvent("SPZ:tpToSafeZone", function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local sz  = Config.SafeZone
    local sh  = Config.SafeZoneHeading or 0.0

    if DoesEntityExist(veh) then
        SetEntityCoords(veh, sz.x, sz.y, sz.z, false, false, false, true)
        SetEntityHeading(veh, sh)
    else
        SetEntityCoords(ped, sz.x, sz.y, sz.z, false, false, false, true)
        SetEntityHeading(ped, sh)
    end

    print("[Race] Teleported to safe zone.")
end)
