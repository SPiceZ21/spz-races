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

        SetEntityRoutingBucket(veh, 0)   -- freeroam bucket so all can see it

        -- Server-side entity API is a small subset of the client's: invincibility,
        -- door locks and freezing are CLIENT natives and are nil here (calling
        -- SetEntityInvincible threw and aborted the rest of this block, which is
        -- why the showcase car spawned unlocked and drivable).
        --
        -- The tag below is the whole contract: client/showcase.lua watches for it
        -- and locks the car on every client that streams it in.
        --
        -- Not frozen yet: SHOWCASE_COORDS is a ped-height Z, so a car created
        -- there hangs above the ground, and freezing it here pinned it mid-air.
        -- The owning client drops it onto the ground first and reports back
        -- (SPZ:showcaseGrounded below); only then is it frozen for everyone.
        Entity(veh).state:set("spzShowcase", true, true)

        print(("[showcase] Parked race car '%s' at the showcase spot."):format(tostring(model)))
    end)
end

-- The owning client has set the car on the ground properly. Snap the server's
-- copy to that spot and freeze it there for everyone.
RegisterNetEvent("SPZ:showcaseGrounded", function(netId, x, y, z)
    local src = source
    local veh = currentShowcase
    if not veh or not DoesEntityExist(veh) then return end
    if NetworkGetNetworkIdFromEntity(veh) ~= tonumber(netId) then return end
    if NetworkGetEntityOwner(veh) ~= src then return end
    if Entity(veh).state.spzShowcaseGrounded then return end

    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return end
    -- Only a small settle is legitimate; anything further is not a grounding.
    if #(vector3(x, y, z) - SHOWCASE_COORDS) > 5.0 then return end

    SetEntityCoords(veh, x, y, z, false, false, false, false)
    if FreezeEntityPosition then FreezeEntityPosition(veh, true) end
    Entity(veh).state:set("spzShowcaseGrounded", true, true)
end)

-- SPZ:raceEnd is now fired exactly once, from ProcessRaceResults. The state
-- guard is kept as a cheap assertion of that contract — per-finisher
-- notifications go out as SPZ:racerFinished instead.
AddEventHandler("SPZ:raceEnd", function()
    if RaceSession.state ~= SPZ.RaceState.ENDED then return end
    local model = RaceSession.carClass and RaceSession.carClass.model
    spawnShowcase(model)
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then clearShowcase() end
end)

exports("ClearShowcase", clearShowcase)
