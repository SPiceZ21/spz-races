-- client/copchase.lua
-- Street heat: NPC police that hunt a racer who picks up a wanted level.
--
-- WHY THIS IS FULLY SCRIPTED, AND FULLY LOCAL
--
-- Vanilla dispatch is off server-wide (spz-core kills random cops, police
-- reports and all 15 dispatch services) because a race does not want the game
-- deciding to drop a helicopter on the pack mid-corner. So none of this is the
-- game's pursuit system: every car below is created, tasked, and deleted here.
--
-- It is also created NON-NETWORKED. Each racer is hunted by their own pack, seen
-- only by them:
--
--   * a shared pack would have to belong to somebody, and that client's stalls
--     would be everyone's stalls;
--   * heat is per driver — the racer wrecking traffic is the one the police
--     want, not the leader who has driven clean;
--   * sixteen racers each with six networked cruisers is ~100 extra networked
--     vehicles in one bucket. Local entities cost the owning client alone.
--
-- HOW THEY HUNT
--
-- Not as a queue of identical cars in your mirror. The pack has roles and it
-- plays the road ahead of you as well as the road behind:
--
--   TAIL       holds station behind. Pressure, and the car that follows you
--              through a mistake.
--   FLANK      lives alongside, alternating sides, and is what actually boxes
--              you in — and what puts a car where a PIT can be thrown from.
--   INTERCEPT  never chases. It is placed on the road AHEAD of where you are
--              pointed and comes at you head-on. This is the one that stops the
--              pursuit being a rear-view mirror game.
--   ROADBLOCK  two cruisers parked across the road in front, called out on the
--              radio before you get there.
--
-- PITs are thrown on GEOMETRY, not on a timer: a unit has to be close, behind
-- your rear quarter, and you have to be slow enough that the hit spins you
-- rather than launching you. The timer is only a floor on how often.
--
-- THEY DO NOT SHOOT. Not "usually" — there is no weapon on the ped and no path
-- to combat: weapons stripped, drivebys off, and every non-temporary event
-- blocked so nothing can pull them out of the driving task. The only pressure
-- they apply is the car.
--
-- Whether any of this runs at all is voted on with the traffic ballot
-- (server/poll.lua) and published as GlobalState.raceCopChase.

local CC = (Config and Config.CopChase) or {}

-- Driving style, written out rather than pasted as a magic number, because the
-- bits are the whole behaviour:
--   4    avoid vehicles        steer round traffic instead of stopping behind it
--   8    avoid empty vehicles  parked cars are obstacles, not walls
--   16   avoid peds            they chase; they do not mow down the pavement
--   32   avoid objects
--   512  allow wrong way       a pursuit that respects one-way streets loses
--   1048576 shortest path      cut the route, do not tour the block
-- Deliberately ABSENT: 1 (stop before vehicles), 2 (stop before peds) and 128
-- (stop at lights) — every one of those is a cop parked at a red light while the
-- racer disappears.
local PURSUIT_STYLE  = 4 + 8 + 16 + 32 + 512 + 1048576

local STARS_PER_HEAT = 20          -- 20 heat per star, so 100 heat == 5 stars
local TICK_MS        = 200
local SPAWN_GAP_MS   = 2200        -- min gap between two units arriving

local active   = false
local heat     = 0.0
local stars    = 0
local units    = {}                -- pursuit cars: { veh, ped, blip, role, ... }
local block    = nil               -- { cars = {...}, peds = {...}, blips = {...}, at, placedAt }
local lastSpawn   = 0
local lastPit     = 0
local lastBlock   = 0
local lastChatter = 0
local flankSide   = 1              -- alternates so flankers do not stack on one side
local escapeFor   = 0.0            -- seconds with nobody in range
local hitCooldown = 0              -- ms timer so one crash is not counted twice

local function cfg(key, fallback)
    local v = CC[key]
    if v == nil then return fallback end
    return v
end

local function levelSpec(n)
    local levels = CC.Levels or {}
    return levels[n] or levels[#levels]
        or { tail = 1, flank = 0, intercept = 0, pit = false, pitEvery = 0, roadblock = 0, speed = 40.0 }
end

--- Short radio callouts. Throttled hard: the pack does something interesting
--- every few seconds and a line for each would be a wall of notifications.
local function chatter(msg, kind)
    if cfg("Chatter", true) == false then return end
    local now = GetGameTimer()
    if now - lastChatter < 3500 then return end
    lastChatter = now
    lib.notify({ title = "POLICE", description = msg, type = kind or "error", duration = 3000 })
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

--- Faster body styles once the pack is serious, so four stars does not look
--- exactly like one star with more cars in it.
local function cruiserModel()
    if stars >= 4 then return pick(CC.FastModels, pick(CC.Models, "police2")) end
    return pick(CC.Models, "police")
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

local function clearBlock()
    if not block then return end
    for _, u in ipairs(block.units) do destroyUnit(u) end
    block = nil
end

local function clearPack()
    for _, u in ipairs(units) do destroyUnit(u) end
    units = {}
    clearBlock()
end

local function countRole(role)
    local n = 0
    for _, u in ipairs(units) do if u.role == role then n = n + 1 end end
    return n
end

-- ── Placement ────────────────────────────────────────────────────────────────

--- A road point `dist` metres along the racer's heading (negative = behind).
--- Snapped to a vehicle node, because a cruiser dropped onto a pavement or a
--- roof is a comedy unit, not a pursuit unit.
local function roadPointAlong(veh, dist)
    local pos = GetEntityCoords(veh)
    local h   = math.rad(GetEntityHeading(veh))
    local fx  = -math.sin(h)
    local fy  =  math.cos(h)
    local tx  = pos.x + fx * dist
    local ty  = pos.y + fy * dist

    local ok, node, heading = GetClosestVehicleNodeWithHeading(tx, ty, pos.z, 1, 3.0, 0)
    if ok and node and #(node - pos) >= cfg("SpawnMinDist", 60.0) then
        return node, heading or 0.0
    end
    return nil
end

--- Where the racer will BE, not where they are: an intercept placed on the
--- current heading is placed behind a car that is already turning. The velocity
--- vector is the closest cheap read on where the road is taking them.
local function projectedPoint(veh, seconds)
    local pos = GetEntityCoords(veh)
    local v   = GetEntityVelocity(veh)
    local tx, ty = pos.x + v.x * seconds, pos.y + v.y * seconds

    local ok, node, heading = GetClosestVehicleNodeWithHeading(tx, ty, pos.z, 1, 3.0, 0)
    if ok and node and #(node - pos) >= cfg("SpawnMinDist", 60.0) then
        return node, heading or 0.0
    end
    return nil
end

-- ── Tasking ──────────────────────────────────────────────────────────────────

--- Cruise target tracks the racer instead of sitting on a fixed number, so a
--- unit neither crawls behind a slow car nor gets left for dead by a fast one.
local function pursuitSpeed(racerVeh, spec)
    local mine = GetEntitySpeed(racerVeh) * cfg("SpeedMatch", 1.12)
    local floor = math.max(cfg("SpeedFloor", 30.0), spec.speed or 40.0)
    if mine < floor then mine = floor end
    local ceil = cfg("SpeedCeiling", 82.0)
    if mine > ceil then mine = ceil end
    return mine
end

local function applyRole(u, speed)
    if not DoesEntityExist(u.ped) then return end
    ClearPedTasks(u.ped)
    SetDriveTaskDrivingStyle(u.ped, PURSUIT_STYLE)
    SetDriveTaskCruiseSpeed(u.ped, speed)

    local targetVeh = GetVehiclePedIsIn(PlayerPedId(), false)

    if u.role == "flank" and targetVeh ~= 0 then
        -- Escort mode 1/2 is left/right of the target. This is the role that
        -- makes the pack feel coordinated: two flankers on opposite sides is
        -- being boxed, and it happens without any of them being scripted to
        -- "box" — the geometry does it. On foot there is nothing to flank, so
        -- they fall through to the chase below.
        TaskVehicleEscort(u.ped, u.veh, targetVeh,
            u.side == 1 and 1 or 2, speed, PURSUIT_STYLE, 6.0, 0, 8.0)
    else
        -- Chase the PED, not the car: a racer who bails out or gets swapped into
        -- a recovery vehicle is still the one being hunted.
        SetTaskVehicleChaseIdealPursuitDistance(u.ped, u.role == "tail" and 7.0 or 4.0)
        TaskVehicleChase(u.ped, PlayerPedId())
    end
    u.pitUntil  = 0
    u.taskSpeed = speed
end

--- Ram the racer's car for a beat, then fall back into the role. Mission type 8
--- is Ram — the closest the driving AI gets to a PIT, and the only contact these
--- units ever make on purpose.
local function taskPit(u, targetVeh, speed, durationMs)
    if not DoesEntityExist(u.ped) or not DoesEntityExist(targetVeh) then return end
    ClearPedTasks(u.ped)
    TaskVehicleMission(u.ped, u.veh, targetVeh, 8, speed + 12.0, PURSUIT_STYLE, 5.0, 0.0, true)
    u.pitUntil = GetGameTimer() + durationMs
end

-- ── Unit watchdog ────────────────────────────────────────────────────────────
--
-- The "memory" problem. A GTA driving task is not a standing order — it ends,
-- quietly, and the ped then sits there having forgotten it was in a pursuit:
--
--   * TaskVehicleChase completes or drops when the target leaves its range, and
--     a chase task that has ended looks exactly like a cop idling at a kerb;
--   * a spin, a wall or traffic leaves the car stopped with the task still
--     nominally running, and nothing restarts it;
--   * a ped knocked out of the driver seat has no task at all.
--
-- So every unit is checked on the tick: is it still driving, is it still moving,
-- is its driver still in it. Anything that answers no is re-issued its role. A
-- unit that is genuinely stuck AND out of sight is picked up and put back on the
-- road behind the racer instead of being abandoned — done only off-screen, and
-- on a cooldown, so nobody ever watches a police car teleport.

local STUCK_SPEED   = 2.0      -- m/s below this counts as not moving
local STUCK_FOR_MS  = 3500     -- ...for this long
local RECOVER_GAP   = 9000     -- min ms between recoveries of the same unit

local function reseat(u)
    if GetPedInVehicleSeat(u.veh, -1) == u.ped then return true end
    if not DoesEntityExist(u.ped) or not DoesEntityExist(u.veh) then return false end
    TaskWarpPedIntoVehicle(u.ped, u.veh, -1)
    return true
end

--- Put a lost unit back in the fight. Behind the racer, on a node, facing the
--- right way — the same placement a fresh spawn gets, without paying for a new
--- car and a new ped.
local function recover(u, racerVeh, speed, now)
    if (now - (u.recoveredAt or 0)) < RECOVER_GAP then return false end
    if IsEntityOnScreen(u.veh) then return false end   -- never in view

    local coords, heading = roadPointAlong(racerVeh, -cfg("SpawnBehind", 130.0))
    if not coords then return false end

    SetEntityCoords(u.veh, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(u.veh, heading or 0.0)
    SetVehicleOnGroundProperly(u.veh)
    SetVehicleEngineOn(u.veh, true, true, false)
    reseat(u)
    applyRole(u, speed)

    u.recoveredAt = now
    u.stuckSince  = nil
    return true
end

--- Returns false if the unit is beyond saving and should be recycled.
local function tickUnit(u, racerVeh, speed, now)
    if not DoesEntityExist(u.veh) or not DoesEntityExist(u.ped) then return false end
    if u.role == "block" then return true end          -- a roadblock is meant to sit still

    -- Driver knocked out of the seat, or never made it in.
    if GetPedInVehicleSeat(u.veh, -1) ~= u.ped then
        if not reseat(u) then return false end
        applyRole(u, speed)
        return true
    end

    -- Engine floor. These cars are deleted when the chase ends, so the only
    -- thing a dying engine buys is a pursuit unit rolling to a halt two corners
    -- after the PIT it just threw.
    if GetVehicleEngineHealth(u.veh) < 350.0 then
        SetVehicleEngineHealth(u.veh, 500.0)
    end

    -- Flipped. Nothing recovers from this on its own.
    if IsEntityUpsidedown(u.veh) then
        if not recover(u, racerVeh, speed, now) then return false end
        return true
    end

    -- Stopped for long enough to be stuck rather than merely slow.
    if GetEntitySpeed(u.veh) < STUCK_SPEED then
        u.stuckSince = u.stuckSince or now
        if (now - u.stuckSince) > STUCK_FOR_MS then
            -- Re-issuing the task is the cheap fix and works when the task has
            -- simply ended; the warp is the fallback when it is wedged.
            if (now - (u.retaskedAt or 0)) > 2500 then
                u.retaskedAt = now
                applyRole(u, speed)
            elseif not recover(u, racerVeh, speed, now) then
                return false          -- wedged, in view, nothing to be done: recycle
            end
        end
    else
        u.stuckSince = nil
    end

    return true
end

-- ── Spawning ─────────────────────────────────────────────────────────────────

--- Strip a cop ped of every route to violence and every reason to leave the
--- driving seat. Blocking non-temporary events is the load-bearing line:
--- without it the ped reacts to crashes, gunfire and the player's wanted level
--- by abandoning the drive task and getting out of the car.
--- The driving half. Without this a cop ped drives like ambient traffic wearing
--- a siren: default ability and aggression are civilian values, and a civilian
--- driver brakes for junctions, lifts in traffic and gives up a corner rather
--- than commit to it. That is what "brainless" actually was — not the tasking,
--- the driver.
local function makeDriver(ped)
    SetDriverAbility(ped, 1.0)          -- maximum car control
    SetDriverAggressiveness(ped, 1.0)   -- will commit, will not lift
    SetDriverRacingModifier(ped, 1.0)   -- drives it like a race, not a commute
    -- Steer around obstacles instead of stopping dead at them. The driving style
    -- says "avoid"; these say "and keep moving while you do".
    SetPedSteersAroundPeds(ped, true)
    SetPedSteersAroundObjects(ped, true)
    SetPedSteersAroundVehicles(ped, true)
end

local function disarm(ped)
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
end

--- One cruiser with a driver in it, placed and made permanent. Returns the unit
--- table, or nil if the models or the ground would not cooperate.
local function makeUnit(coords, heading, role)
    local vehHash = loadModel(cruiserModel())
    local pedHash = loadModel(pick(CC.PedModels, "s_m_y_cop_01"))
    if not vehHash or not pedHash then return nil end

    local veh = CreateVehicle(vehHash, coords.x, coords.y, coords.z, heading, false, false)
    if not DoesEntityExist(veh) then return nil end
    SetEntityAsMissionEntity(veh, true, true)   -- population culling must not eat a live pursuer
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleDoorsLocked(veh, 4)               -- nobody is jacking a pursuit car

    -- A pursuit unit that is disabled by its own first PIT is not a pursuit
    -- unit. Strong axles and unburstable tyres keep contact a shunt rather than
    -- a retirement — which matters more here than realism, because these cars
    -- are deleted at the end of the chase either way.
    SetVehicleHasStrongAxles(veh, true)
    SetVehicleTyresCanBurst(veh, false)
    SetVehicleStrong(veh, true)
    if cfg("Sirens", true) then
        SetVehicleSiren(veh, true)
        SetSirenWithNoDriver(veh, true)
    end

    -- Enough engine to hold station against a race car. Fixed per star level, so
    -- a genuinely faster car still pulls away — it just has to be driven.
    local boost = (CC.PowerBoost or {})[stars] or 0.3
    SetVehicleEnginePowerMultiplier(veh, boost * 100.0)
    ModifyVehicleTopSpeed(veh, 1.0 + boost)
    SetVehicleHasBeenOwnedByPlayer(veh, false)

    local ped = CreatePed(26, pedHash, coords.x, coords.y, coords.z, heading, false, false)
    if not DoesEntityExist(ped) then
        DeleteEntity(veh)
        return nil
    end
    SetPedIntoVehicle(ped, veh, -1)
    SetEntityAsMissionEntity(ped, true, true)
    disarm(ped)
    makeDriver(ped)

    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)

    local blip = AddBlipForEntity(veh)
    SetBlipSprite(blip, 56)
    SetBlipColour(blip, role == "intercept" and 49 or 38)
    SetBlipScale(blip, 0.75)
    SetBlipAsShortRange(blip, true)

    return { veh = veh, ped = ped, blip = blip, role = role, pitUntil = 0, born = GetGameTimer() }
end

local function spawnPursuit(racerVeh, role, speed)
    local coords, heading

    if role == "intercept" then
        -- Ahead, facing back down the road at you.
        coords, heading = projectedPoint(racerVeh, 6.0)
        if not coords then
            coords, heading = roadPointAlong(racerVeh, cfg("SpawnAhead", 240.0))
        end
        if heading then heading = (heading + 180.0) % 360.0 end
    else
        coords, heading = roadPointAlong(racerVeh, -cfg("SpawnBehind", 130.0))
    end
    if not coords then return false end

    local u = makeUnit(coords, heading or 0.0, role)
    if not u then return false end

    if role == "flank" then
        u.side = flankSide
        flankSide = flankSide == 1 and 2 or 1
    end

    units[#units + 1] = u
    applyRole(u, speed)
    lastSpawn = GetGameTimer()

    if role == "intercept" then
        chatter("Unit ahead of you — they are coming head-on", "error")
    elseif role == "flank" then
        chatter(u.side == 1 and "Unit coming up your left" or "Unit coming up your right", "warning")
    end
    return true
end

-- ── Roadblock ────────────────────────────────────────────────────────────────

--- Two cruisers parked nose to nose across the road ahead. They are not tasked
--- at all — a roadblock that drives is just two more chase cars. It is called
--- out when it goes up, because a block you cannot see coming is a wall, not a
--- decision.
local function placeRoadblock(racerVeh)
    local coords, heading = roadPointAlong(racerVeh, cfg("RoadblockAhead", 320.0))
    if not coords then return false end

    local across = (heading + 90.0) % 360.0
    local rad    = math.rad(across)
    local rx, ry = math.cos(rad), math.sin(rad)

    local made = {}
    for i = -1, 1, 2 do
        local cx = coords.x + rx * (2.6 * i)
        local cy = coords.y + ry * (2.6 * i)
        local u  = makeUnit(vector3(cx, cy, coords.z), across, "block")
        if u then
            -- Handbrake, not frozen. A frozen entity is immovable geometry, and
            -- hitting one at racing speed launches the car rather than stopping
            -- it. On the handbrake the block is heavy enough to punish a racer
            -- who drives straight at it, and light enough that doing so is a
            -- decision with a survivable outcome.
            SetVehicleHandbrake(u.veh, true)
            SetVehicleEngineOn(u.veh, false, true, true)
            SetVehicleSiren(u.veh, true)
            made[#made + 1] = u
        end
    end

    if #made == 0 then return false end
    block = { units = made, placedAt = GetGameTimer(), at = coords }
    lastBlock = GetGameTimer()
    chatter("Roadblock ahead — find another way", "error")
    return true
end

local function tickRoadblock(pos)
    if not block then return end
    local age  = GetGameTimer() - block.placedAt
    local dist = #(block.at - pos)
    -- Torn down once it has been dealt with (passed, or left far behind) or when
    -- it has stood long enough that the racer clearly went another way.
    if age > (cfg("RoadblockLifeSec", 40) * 1000) or dist > cfg("DespawnDist", 340.0) then
        clearBlock()
    end
end

-- ── Ghosting ─────────────────────────────────────────────────────────────────

--- My cops are mine. They exist only on my client, so a cruiser leaning on
--- another racer's car would shove an entity whose owner is about to correct it
--- — a shunt only I can see, on a car I am not allowed to touch (spz-core ghosts
--- every player pair for exactly this reason). So the pack is ghosted against
--- every other player, and can only ever hit ME.
local function ghostAgainstOtherPlayers()
    if #units == 0 and not block then return end
    local myId = PlayerId()

    local all = {}
    for _, u in ipairs(units) do all[#all + 1] = u end
    if block then for _, u in ipairs(block.units) do all[#all + 1] = u end end

    for _, p in ipairs(GetActivePlayers()) do
        if p ~= myId then
            local oped = GetPlayerPed(p)
            local oveh = GetVehiclePedIsIn(oped, false)
            for _, u in ipairs(all) do
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

-- ── Heat ─────────────────────────────────────────────────────────────────────

local function starsFor(h)
    local max = cfg("MaxStars", 5)
    local n = math.floor(h / STARS_PER_HEAT)
    if n > max then n = max end
    if n < 0 then n = 0 end
    return n
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

-- ── PIT selection ────────────────────────────────────────────────────────────

--- A PIT is a geometry problem, not a timer.
---
--- The hit has to land on a rear quarter, from close, while the target is slow
--- enough that a nudge spins it. Thrown from anywhere at any speed it is not a
--- PIT — it is a cruiser rear-ending a race car at 300 km/h, which launches both
--- and reads as the game glitching rather than as the police doing something.
---
--- So: behind the halfway line of the car, inside a rear-quarter cone, within
--- touching distance, and under a speed ceiling. Returns the best-placed unit or
--- nil, which is a perfectly good answer — they wait for the corner.
local function pitCandidate(racerVeh, pos)
    if GetEntitySpeed(racerVeh) > 48.0 then return nil end   -- ~170 km/h

    local h  = math.rad(GetEntityHeading(racerVeh))
    local fx, fy = -math.sin(h), math.cos(h)

    local best, bestScore = nil, -1
    for _, u in ipairs(units) do
        if u.pitUntil == 0 and u.role ~= "intercept" and DoesEntityExist(u.veh) then
            local cp = GetEntityCoords(u.veh)
            local dx, dy = cp.x - pos.x, cp.y - pos.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1.0 and d < 11.0 then
                -- Ahead/behind, as a fraction: -1 is directly behind.
                local along = (dx * fx + dy * fy) / d
                if along < 0.25 then
                    -- Prefer the one closest to the rear quarter and closest in.
                    local score = (0.25 - along) * (12.0 - d)
                    if score > bestScore then best, bestScore = u, score end
                end
            end
        end
    end
    return best
end

-- ── Main loop ────────────────────────────────────────────────────────────────

local function shouldRun()
    if CC.Enabled == false then return false end
    if not LocalPlayer.state.inRace then return false end
    if not GlobalState.raceCopChase then return false end
    return GlobalState.raceState == "LIVE"
end

local function stopChase(reason)
    if not active and #units == 0 and not block and heat == 0 then return end
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

--- Bring the pack up to the star level's shape. Roles are filled in the order
--- they matter: something behind you first, then something beside you, then
--- something in front.
local function maintainPack(racerVeh, spec, speed)
    if (GetGameTimer() - lastSpawn) < SPAWN_GAP_MS then return end

    if countRole("tail") < (spec.tail or 0) then
        spawnPursuit(racerVeh, "tail", speed)
    elseif countRole("flank") < (spec.flank or 0) then
        spawnPursuit(racerVeh, "flank", speed)
    elseif countRole("intercept") < (spec.intercept or 0) then
        spawnPursuit(racerVeh, "intercept", speed)
    end
end

--- Drop units the level no longer calls for, so losing a star visibly thins the
--- pack rather than only slowing the next spawn.
---
--- The FARTHEST surplus unit goes first. Deleting by table order is how a
--- cruiser vanishes out of your mirror while it is leaning on your rear
--- quarter, which reads as the script breaking; the one three streets back
--- disappearing is something nobody ever sees.
local function trimPack(spec, pos)
    local want = { tail = spec.tail or 0, flank = spec.flank or 0, intercept = spec.intercept or 0 }

    local order = {}
    for i = 1, #units do order[i] = i end
    table.sort(order, function(a, b)
        local ua, ub = units[a], units[b]
        local da = DoesEntityExist(ua.veh) and #(GetEntityCoords(ua.veh) - pos) or math.huge
        local db = DoesEntityExist(ub.veh) and #(GetEntityCoords(ub.veh) - pos) or math.huge
        return da < db
    end)

    -- Nearest first: they claim the slots their role still has, and whatever is
    -- left over at the back of the queue is surplus.
    local doomed = {}
    for _, i in ipairs(order) do
        local role = units[i].role
        if (want[role] or 0) > 0 then
            want[role] = want[role] - 1
        else
            doomed[i] = true
        end
    end

    for i = #units, 1, -1 do
        if doomed[i] then
            destroyUnit(units[i])
            table.remove(units, i)
        end
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
                if #units > 0 or block then clearPack() end
                escapeFor = 0.0
                goto continue
            end

            local spec  = levelSpec(stars)
            local speed = pursuitSpeed(veh, spec)
            local now   = GetGameTimer()

            -- Recycle anything that has lost the race, been wrecked, or (for an
            -- intercept) already been driven past — its job is done the moment
            -- it is behind you, and it becomes a tail unit rather than a car
            -- driving the wrong way down the road forever.
            for i = #units, 1, -1 do
                local u = units[i]
                local broken = (not DoesEntityExist(u.veh)) or (not DoesEntityExist(u.ped))
                    or IsEntityDead(u.ped) or not IsVehicleDriveable(u.veh, false)

                local dead = broken
                if not broken then
                    if #(GetEntityCoords(u.veh) - pos) > cfg("DespawnDist", 340.0) then
                        -- Adrift, but not beaten. Most cars out at the despawn
                        -- radius are stuck on a kerb two corners back, so they
                        -- get one off-screen pick-up before being retired —
                        -- recovering costs nothing, while replacing costs a
                        -- spawn and puts a fresh car in the mirror out of thin
                        -- air.
                        dead = not recover(u, veh, speed, now)
                    else
                        dead = not tickUnit(u, veh, speed, now)
                    end
                end

                if dead then
                    destroyUnit(u)
                    table.remove(units, i)
                elseif u.role == "intercept" and (now - u.born) > 9000 then
                    u.role = "tail"
                    applyRole(u, speed)
                end
            end

            trimPack(spec, pos)
            maintainPack(veh, spec, speed)
            tickRoadblock(pos)

            -- Roles are re-issued when the pace has actually moved: the cruise
            -- target tracks the racer, and a task set at 40 m/s does not become
            -- a task at 70 m/s on its own. Re-tasking on a fixed interval
            -- instead would restart the chase mid-corner every few seconds and
            -- make them drive worse, not better.
            for _, u in ipairs(units) do
                if u.pitUntil ~= 0 then
                    if now >= u.pitUntil then applyRole(u, speed) end
                elseif math.abs((u.taskSpeed or 0) - speed) > 6.0 then
                    applyRole(u, speed)
                end
            end

            -- PIT: one at a time, on geometry, no more often than the level says.
            if spec.pit and (spec.pitEvery or 0) > 0
            and (now - lastPit) >= (spec.pitEvery * 1000) then
                local u = pitCandidate(veh, pos)
                if u then
                    taskPit(u, veh, speed, cfg("PitDurationMs", 3500))
                    lastPit = now
                    chatter("They are going for a PIT", "error")
                end
            end

            -- Roadblock, only while there is road ahead to block.
            if (spec.roadblock or 0) > 0 and not block
            and (now - lastBlock) >= (spec.roadblock * 1000)
            and GetEntitySpeed(veh) > 15.0 then
                placeRoadblock(veh)
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
