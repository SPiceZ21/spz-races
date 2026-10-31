-- client/lockin.lua
-- While you're in a race (warmup, staging, countdown, live — the whole time the
-- inRace statebag is set), you can't leave the car and the car takes no damage.
-- inRace goes true at world spawn (server/world.lua) and false on finish/DNF/
-- cleanup, so this naturally covers warmup + the race and releases you after.
--
-- Damage is also handled globally by spz-vehfunc/godmode; this re-asserts it for
-- the race vehicle so it holds even if that resource is absent or a flag gets
-- reset by the grid unfreeze.

local EXIT_VEHICLE = 75   -- INPUT_VEH_EXIT

-- Ambient peds (voted traffic) could drag racers out of the car and start
-- fights during warmup. While in a race they ignore you and can't carjack you.
local calmed = false
local function calmPeds(on)
    local pid, ped = PlayerId(), PlayerPedId()
    SetEveryoneIgnorePlayer(pid, on)
    SetPlayerCanBeHassledByGangs(pid, not on)
    SetPedCanBeDraggedOut(ped, not on)
    calmed = on
end

CreateThread(function()
    while true do
        if LocalPlayer.state.inRace then
            -- Block bailing out of the car for the whole race.
            DisableControlAction(0, EXIT_VEHICLE, true)
            if not calmed then calmPeds(true) end
            SetPedCanBeDraggedOut(PlayerPedId(), false)   -- ped can change on respawn

            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if veh ~= 0 and DoesEntityExist(veh) then
                SetEntityInvincible(veh, true)
                SetVehicleCanBeVisiblyDamaged(veh, false)
                SetVehicleTyresCanBurst(veh, false)
                SetVehicleWheelsCanBreak(veh, false)
            end

            Wait(0)
        else
            if calmed then calmPeds(false) end
            Wait(300)
        end
    end
end)
