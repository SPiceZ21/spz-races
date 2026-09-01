-- client/copchase.lua
-- Street heat: NPC police that chase a racer who picks up a wanted level.
--
-- WHY THIS IS FULLY SCRIPTED, AND FULLY LOCAL
--
-- Vanilla dispatch is off server-wide (spz-core kills random cops, police
-- reports and all 15 dispatch services) because a race does not want the game
-- deciding to drop a helicopter on the pack mid-corner. So none of this is the
-- game's pursuit system: every car below is created, tasked, and deleted here.
--
-- It is also created NON-NETWORKED. Each racer is chased by their own pack, seen
-- only by them:
--
--   * a shared pack would have to belong to somebody, and that client's stalls
--     would be everyone's stalls;
--   * heat is per driver — the racer wrecking traffic is the one the police
--     want, not the leader who has driven clean;
--   * sixteen racers each with up to six networked cruisers is ~100 extra
--     networked vehicles in one bucket. Local entities cost the owning client
--     alone and never touch the network.
--
-- THEY DO NOT SHOOT. Not "usually" — there is no weapon on the ped and no path
-- to combat: weapons are stripped, drivebys are off, and every non-temporary
-- event is blocked so nothing can pull them out of the driving task. The only
-- pressure they apply is the car itself: they tail at low heat, and from three
-- stars they start throwing PITs.
--
-- Whether any of this runs at all is voted on with the traffic ballot
-- (server/poll.lua) and published as GlobalState.raceCopChase.

local CC = (Config and Config.CopChase) or {}

local STARS_PER_HEAT = 20          -- 20 heat per star, so 100 heat == 5 stars
local TICK_MS        = 250
local SPAWN_GAP_MS   = 2500        -- min gap between two units arriving

local active   = false
local heat     = 0.0
local stars    = 0
local units    = {}                -- { veh, ped, blip, pitUntil }
local lastSpawn   = 0
local lastPit     = 0
local escapeFor   = 0.0            -- seconds with nobody in range
local hitCooldown = 0              -- ms timer so one crash is not counted twice

local function cfg(key, fallback)
    local v = CC[key]
    if v == nil then return fallback end
    return v
end

local function levelSpec(n)
    local levels = CC.Levels or {}
    return levels[n] or levels[#levels] or { units = 1, pit = false, pitEvery = 0, speed = 40.0 }
end

-- ── Model loading ────────────────────────────────────────────────────────────

local function loadModel(name)
    local hash = type(name) == "number" and name or GetHashKey(name)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

local function pick(list, fallback)
    if type(list) ~= "table" or #list == 0 then return fallback end
    return list[math.random(1, #list)]
end

-- ── Unit lifecycle ───────────────────────────────────────────────────────────

local function destroyUnit(u)
    if u.blip and DoesBlipExist(u.blip) then RemoveBlip(u.blip) end
    if u.ped and DoesEntityExist(u.ped) then
        SetEntityAsMissionEntity(u.ped, true, true)
        DeleteEntity(u.ped)
    end
    if u.veh and DoesEntityExist(u.veh) then
        SetEntityAsMissionEntity(u.veh, true, true)
        DeleteEntity(u.veh)
    end
end

local function clearPack()
    for _, u in ipairs(units) do destroyUnit(u) end
    units = {}
end

--- A road point roughly `back` metres behind the racer, so units arrive in the
--- mirror instead of materialising across the bonnet. Falls back to the raw
--- offset when the node lookup fails (off-road sections, tunnels).
local function spawnPointBehind(veh, back)
    local pos = GetEntityCoords(veh)
    local h   = math.rad(GetEntityHeading(veh))
    local bx  = pos.x + math.sin(h) * back
    local by  = pos.y - math.cos(h) * back

    local ok, node, heading = GetClosestVehicleNodeWithHeading(bx, by, pos.z, 1, 3.0, 0)
    if ok and node then
        -- A node the racer is about to drive past is no use as an ambush point.
        if #(node - pos) >= (cfg("SpawnMinDist", 60.0)) then
            return node, heading or 0.0
        end
    end
    return vector3(bx, by, pos.z), math.deg(h)
end

--- Task a unit onto the racer. `TaskVehicleChase` is the pursuit driver: it
--- reads the target's speed and cuts corners, where a plain "drive to my
--- coordinates" mission arrives where the racer WAS.
local function taskChase(u, speed)
    if not DoesEntityExist(u.ped) then return end
    ClearPedTasks(u.ped)
    SetDriveTaskDrivingStyle(u.ped, 786603)     -- rushed: ignores lights, still steers round obstacles
    SetDriveTaskCruiseSpeed(u.ped, speed)
    SetTaskVehicleChaseIdealPursuitDistance(u.ped, 8.0)
    -- Chase the PED, not the car: a racer who bails out or gets swapped into a
    -- recovery vehicle is still the one being chased.
    TaskVehicleChase(u.ped, PlayerPedId())
    u.pitUntil = 0
end

--- Ram the racer's car for a beat, then fall back into the chase. Mission type
--- 8 is Ram — the closest the driving AI gets to a PIT, and the only contact
--- these units ever make.
local function taskPit(u, targetVeh, speed, durationMs)
    if not DoesEntityExist(u.ped) or not DoesEntityExist(targetVeh) then return end
    ClearPedTasks(u.ped)
    TaskVehicleMission(u.ped, u.veh, targetVeh, 8, speed + 10.0, 786603, 5.0, 0.0, true)
    u.pitUntil = GetGameTimer() + durationMs
end

local function spawnUnit(targetVeh, speed)
    local vehHash = loadModel(pick(CC.Models, "police"))
    local pedHash = loadModel(pick(CC.PedModels, "s_m_y_cop_01"))
    if not vehHash or not pedHash then return end

    local coords, heading = spawnPointBehind(targetVeh, cfg("SpawnBehind", 130.0))

    local veh = CreateVehicle(vehHash, coords.x, coords.y, coords.z, heading, false, false)
    if not DoesEntityExist(veh) then return end
    SetEntityAsMissionEntity(veh, true, true)     -- population culling must not eat a live pursuer
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleHasBeenOwnedByPlayer(veh, false)
    SetVehicleDoorsLocked(veh, 4)                 -- nobody is jacking a pursuit car
    if cfg("Sirens", true) then
        SetVehicleSiren(veh, true)
        SetSirenWithNoDriver(veh, true)
    end

    local ped = CreatePed(26, pedHash, coords.x, coords.y, coords.z, heading, false, false)
    if not DoesEntityExist(ped) then
        DeleteEntity(veh)
        return
    end
    SetPedIntoVehicle(ped, veh, -1)
    SetEntityAsMissionEntity(ped, true, true)

    -- ── Disarmed, permanently ────────────────────────────────────────────────
    -- The brief is "chase and PIT, never shoot", so the ped is stripped of the
    -- means and of the triggers. Blocking non-temporary events is the load
    -- bearing line: without it the ped reacts to gunfire, crashes and the
    -- player's wanted level by abandoning the drive task and getting out.
    RemoveAllPedWeapons(ped, true)
    SetPedCanSwitchWeapon(ped, false)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedCombatAttributes(ped, 2, false)     -- no drivebys
    SetPedCombatAttributes(ped, 5, false)     -- never "always fight"
    SetPedCombatAttributes(ped, 46, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCanBeDraggedOut(ped, false)
    SetPedAsCop(ped, false)                   -- a scripted driver, not a dispatch unit
    SetPedRelationshipGroupHash(ped, GetHashKey("CIVMALE"))
    SetPedKeepTask(ped, true)
    SetPedCanBeTargettedByPlayer(ped, PlayerId(), false)

    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)

    local blip = AddBlipForEntity(veh)
    SetBlipSprite(blip, 56)
    SetBlipColour(blip, 38)
    SetBlipScale(blip, 0.75)
    SetBlipAsShortRange(blip, true)

    local u = { veh = veh, ped = ped, blip = blip, pitUntil = 0 }
    units[#units + 1] = u
    taskChase(u, speed)
    lastSpawn = GetGameTimer()
end

-- ── Heat ─────────────────────────────────────────────────────────────────────

local function starsFor(h)
    local max = cfg("MaxStars", 5)
    local n = math.floor(h / STARS_PER_HEAT)
    if n > max then n = max end
    if n < 0 then n = 0 end
    return n
end

--- My cops are mine. They exist only on my client, so a cruiser leaning on
--- another racer's car would shove an entity whose owner is about to correct it
--- — a shunt only I can see, on a car I am not allowed to touch (spz-core
--- ghosts every player pair for exactly this reason). So the pack is ghosted
--- against every other player the same way, and can only ever hit ME.
local function ghostAgainstOtherPlayers()
    if #units == 0 then return end
    local myId = PlayerId()
    for _, p in ipairs(GetActivePlayers()) do
        if p ~= myId then
            local oped = GetPlayerPed(p)
            local oveh = GetVehiclePedIsIn(oped, false)
            for _, u in ipairs(units) do
                if DoesEntityExist(u.veh) and DoesEntityExist(oped) then
                    SetEntityNoCollisionEntity(u.veh, oped, false)
                    SetEntityNoCollisionEntity(oped, u.veh, false)
                    if oveh ~= 0 then
                        SetEntityNoCollisionEntity(u.veh, oveh, false)
                        SetEntityNoCollisionEntity(oveh, u.veh, false)
                    end
                end
            end
        end
    end
end

local function nearestUnitDist(pos)
    local best = math.huge
    for _, u in ipairs(units) do
        if DoesEntityExist(u.veh) then
            local d = #(GetEntityCoords(u.veh) - pos)
            if d < best then best = d end
        end
    end
    return best
end

--- Heat earned this tick. Speed alone tops out around two stars; the rest is
--- paid for in wreckage, which is what actually reads as "the police want you".
local function accrueHeat(veh, dt, copClose)
    local kmh = GetEntitySpeed(veh) * 3.6
    local gained = 0.0

    if kmh >= cfg("SpeedKmh", 130) then
        gained = gained + cfg("SpeedHeatPerSec", 3.5) * dt
    end

    local now = GetGameTimer()
    if now >= hitCooldown then
        -- A cruiser's own PIT lands as vehicle damage; counting it would let the
        -- police escalate the chase by chasing, so contact is ignored while one
        -- of them is on top of the racer.
        if HasEntityBeenDamagedByAnyPed(veh) then
            gained = gained + cfg("HeatPerPedHit", 22)
            hitCooldown = now + 1200
        elseif HasEntityBeenDamagedByAnyVehicle(veh) and not copClose then
            gained = gained + cfg("HeatPerVehHit", 9)
            hitCooldown = now + 1200
        end
        ClearEntityLastDamageEntity(veh)
    end

    if gained > 0 then return gained end
    return -(cfg("HeatDecayPerSec", 2.0) * dt)
end

-- ── Main loop ────────────────────────────────────────────────────────────────

local function shouldRun()
    if CC.Enabled == false then return false end
    if not LocalPlayer.state.inRace then return false end
    if not GlobalState.raceCopChase then return false end
    return GlobalState.raceState == "LIVE"
end

local function stopChase(reason)
    if not active and #units == 0 and heat == 0 then return end
    active, heat, stars, escapeFor = false, 0.0, 0, 0.0
    clearPack()
    if cfg("UseNativeWanted", false) then
        SetPlayerWantedLevel(PlayerId(), 0, false)
        SetPlayerWantedLevelNow(PlayerId(), false)
    end
    if reason then
        lib.notify({ title = "HEAT", description = reason, type = "success", duration = 4000 })
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        local dt = TICK_MS / 1000

        if not shouldRun() then
            stopChase(nil)
            Wait(500)
            goto continue
        end

        do
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh == 0 or not DoesEntityExist(veh) then goto continue end

            active = true
            local pos      = GetEntityCoords(veh)
            local nearest  = nearestUnitDist(pos)
            local copClose = nearest < 15.0

            heat = heat + accrueHeat(veh, dt, copClose)
            local ceiling = cfg("MaxStars", 5) * STARS_PER_HEAT
            if heat > ceiling then heat = ceiling end
            if heat < 0 then heat = 0 end

            local newStars = starsFor(heat)
            if newStars > stars then
                lib.notify({
                    title = "WANTED",
                    description = ("%d star%s — police are on you"):format(newStars, newStars == 1 and "" or "s"),
                    type = "error", duration = 3500,
                })
            end
            stars = newStars

            if cfg("UseNativeWanted", false) then
                SetPlayerWantedLevel(PlayerId(), stars, false)
                SetPlayerWantedLevelNow(PlayerId(), false)
                SetPoliceIgnorePlayer(PlayerId(), true)   -- our units only; vanilla stays out
            end

            if stars == 0 then
                if #units > 0 then clearPack() end
                escapeFor = 0.0
                goto continue
            end

            local spec = levelSpec(stars)

            -- Recycle anything that has lost the race, then top the pack back up
            -- to the level's strength.
            for i = #units, 1, -1 do
                local u = units[i]
                local gone = (not DoesEntityExist(u.veh)) or (not DoesEntityExist(u.ped))
                    or IsEntityDead(u.ped)
                    or #(GetEntityCoords(u.veh) - pos) > cfg("DespawnDist", 320.0)
                if gone then
                    destroyUnit(u)
                    table.remove(units, i)
                end
            end

            -- Trim on the way DOWN a star level too, so losing heat visibly
            -- thins the pack instead of only slowing the next spawn.
            while #units > spec.units do
                destroyUnit(units[#units])
                table.remove(units, #units)
            end

            if #units < spec.units and (GetGameTimer() - lastSpawn) >= SPAWN_GAP_MS then
                spawnUnit(veh, spec.speed or 45.0)
            end

            -- PIT window. One unit at a time — a whole pack ramming at once is a
            -- pinball table, not a pursuit.
            local now = GetGameTimer()
            for _, u in ipairs(units) do
                if u.pitUntil ~= 0 and now >= u.pitUntil then
                    taskChase(u, spec.speed or 45.0)
                end
            end
            if spec.pit and (spec.pitEvery or 0) > 0
            and (now - lastPit) >= (spec.pitEvery * 1000) then
                local closest, cd = nil, math.huge
                for _, u in ipairs(units) do
                    if DoesEntityExist(u.veh) and u.pitUntil == 0 then
                        local d = #(GetEntityCoords(u.veh) - pos)
                        if d < cd then closest, cd = u, d end
                    end
                end
                if closest and cd < 40.0 then
                    taskPit(closest, veh, spec.speed or 45.0, cfg("PitDurationMs", 4000))
                    lastPit = now
                end
            end

            ghostAgainstOtherPlayers()

            -- Shaking them. Nothing in range for long enough and the whole thing
            -- is called off — the alternative is a pack that trails a racer for
            -- the rest of a 3-lap circuit.
            if nearest > cfg("EscapeDist", 170.0) then
                escapeFor = escapeFor + dt
                if escapeFor >= cfg("EscapeSeconds", 12) then
                    stopChase("You lost them")
                end
            else
                escapeFor = 0.0
            end
        end

        ::continue::
    end
end)

-- ── HUD ──────────────────────────────────────────────────────────────────────
-- spz-core hides HUD components 1-22 every frame, wanted stars included, so the
-- readout is drawn here rather than by unhiding the vanilla one.

CreateThread(function()
    while true do
        if active and stars > 0 and cfg("Hud", true) ~= false then
            local label = ("WANTED  %s"):format(string.rep("*", stars))
            if escapeFor > 0 then
                local left = math.ceil(cfg("EscapeSeconds", 12) - escapeFor)
                if left > 0 then label = label .. ("   LOSING THEM  %ds"):format(left) end
            end

            SetTextFont(4)
            SetTextScale(0.0, 0.42)
            SetTextCentre(true)
            SetTextColour(255, 90, 90, 230)
            SetTextOutline()
            BeginTextCommandDisplayText("STRING")
            AddTextComponentSubstringPlayerName(label)
            EndTextCommandDisplayText(0.5, 0.055)
            Wait(0)
        else
            Wait(400)
        end
    end
end)

-- ── Teardown ─────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:tpToSafeZone", function() stopChase(nil) end)

AddStateBagChangeHandler("raceCopChase", "global", function(_, _, value)
    if not value then stopChase(nil) end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then clearPack() end
end)

exports("GetChaseStars", function() return stars end)
exports("IsCopChaseActive", function() return active and stars > 0 end)
