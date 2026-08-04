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

CreateThread(function()
    while true do
        if LocalPlayer.state.inRace then
            -- Block bailing out of the car for the whole race.
            DisableControlAction(0, EXIT_VEHICLE, true)

            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if veh ~= 0 and DoesEntityExist(veh) then
                SetEntityInvincible(veh, true)
                SetVehicleCanBeVisiblyDamaged(veh, false)
                SetVehicleTyresCanBurst(veh, false)
                SetVehicleWheelsCanBreak(veh, false)
            end

            Wait(0)
        else
            Wait(300)
        end
    end
end)
