-- server/showcase.lua
-- After each race, park the vehicle that was raced as a static showcase at a
-- fixed spot near the safe zone. Server-spawned (networked) so everyone sees it;
-- the previous showcase is removed each time so only the latest race car stands.

local SHOWCASE_COORDS  = vector3(-1319.44, -1217.39, 4.82)
local SHOWCASE_HEADING = 31.7

local currentShowcase = nil

local function clearShowcase()
    if currentShowcase and DoesEntityExist(currentShowcase) then
        DeleteEntity(currentShowcase)
    end
    currentShowcase = nil
end

local function spawnShowcase(model)
    if not model then return end
    local hash = (type(model) == "number") and model or GetHashKey(model)

    clearShowcase()

    local veh = CreateVehicle(hash, SHOWCASE_COORDS.x, SHOWCASE_COORDS.y, SHOWCASE_COORDS.z,
        SHOWCASE_HEADING, true, false)
    if not veh or veh == 0 then return end
    currentShowcase = veh

    -- A freshly server-created vehicle isn't fully realized on the same tick, so
    -- freeze/invincible can no-op. Apply once the entity actually exists.
    CreateThread(function()
        local deadline = GetGameTimer() + 3000
        while veh == currentShowcase and not DoesEntityExist(veh) and GetGameTimer() < deadline do
            Wait(0)
        end
        if veh ~= currentShowcase or not DoesEntityExist(veh) then return end

        SetEntityRoutingBucket(veh, 0)              -- freeroam bucket so all can see it
        FreezeEntityPosition(veh, true)             -- static display
        SetEntityInvincible(veh, true)
        SetVehicleDoorsLocked(veh, 2)               -- locked / non-enterable (best-effort server-side)
        -- Client-side enforcement runs off this tag (server door natives are flaky).
        Entity(veh).state:set("spzShowcase", true, true)

        print(("[showcase] Parked race car '%s' at the showcase spot."):format(tostring(model)))
    end)
end

-- Fires several times per race (per-finisher + final). Only act on the real
-- race end (ENDED state = ProcessRaceResults), so we spawn exactly once.
AddEventHandler("SPZ:raceEnd", function()
    if RaceSession.state ~= SPZ.RaceState.ENDED then return end
    local model = RaceSession.carClass and RaceSession.carClass.model
    spawnShowcase(model)
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then clearShowcase() end
end)

exports("ClearShowcase", clearShowcase)
