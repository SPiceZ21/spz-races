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
-- ─────────────────────────────────────────────────────────────────────────────
-- THE THREE THINGS THAT MADE THE OLD PURSUIT READ AS BROKEN
--
-- 1. THE WANTED LEVEL TRACKED THE SPEEDOMETER, NOT THE POLICE.
--
--    Heat was earned by going fast and lost by everything else, with decay
--    running unconditionally. So the star row said the opposite of what was
--    happening: flat out on an empty straight with the pack a street back it
--    CLIMBED, and a cruiser leaning on the door at 60 km/h through traffic bled
--    it away. Further away = more wanted. Caught = less wanted.
--
--    Now heat has two separate sources and one rule about decay:
--
--      OFFENCE heat   speed and wreckage. It STARTS a pursuit, and the speeding
--                     half of it stops buying stars at SpeedMaxStars.
--      PURSUIT heat   the pursuit clock. It ESCALATES a pursuit, and it only
--                     ticks while a unit actually has CONTACT.
--
--    and: heat NEVER decays while anything has contact. Not slower — never.
--    Being caught cannot lower the heat, and running from a pack that has eyes
--    on you raises it. Both directions now point the right way.
--
-- 2. THE PURSUIT COULD EVAPORATE WITH A CRUISER IN THE MIRROR.
--
--    Escape was a distance test against the nearest car, and the pack was also
--    deleted outright the moment heat decayed under one star — which, with
--    unconditional decay, happened while the police were still on top of you.
--
--    Escape is now a CONTACT test. A unit has contact while it is close, or
--    while it can see you, or while it saw you a moment ago and is still in
--    range. The chopper has contact on its own sightline, so an air unit
--    overhead means you have not lost anybody. Contact must be broken, stay
--    broken through a grace window, and then stay broken for the whole escape
--    countdown — and regaining it at any point puts the counter back to zero.
--    Nothing else deletes the pack.
--
-- 3. THEY ARRIVED ALREADY BEATEN.
--
--    A unit was created STATIONARY on a node a fixed 130 m behind a car doing
--    250 km/h. It then had to accelerate from nothing while the racer kept
--    going: the gap grew from the first frame and the pursuit lived two streets
--    back for the rest of the race.
--
--    Units now arrive ALREADY ROLLING at the racer's pace, the spawn gap is
--    measured in seconds of your speed rather than in metres, the first unit of
--    a pursuit skips the spawn cooldown entirely, and anything that falls behind
--    gets a bounded catch-up assist that eases off once it is on you.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- HOW THEY BEHAVE ONCE THEY ARE THERE
--
-- By default (Config.CopChase.VanillaBehaviour) the peds are REAL cops as far as
-- the game is concerned — SetPedAsCop, the COP relationship group, a real wanted
-- level — so the base game's own police AI does the pursuing: how they read the
-- road, how they commit to a corner, how they follow you through a mistake.
--
-- THEY STILL DO NOT SHOOT. Not "usually": there is no weapon on the ped, no
-- driveby, and BF_CanLeaveVehicle is off, so there is no path from a pursuit to
-- a firefight. The base game supplies the driving brain; the car remains the
-- only pressure they ever apply.
--
-- Vanilla DISPATCH is off too (spz-core kills all 15 services), so the wanted
-- level summons nothing — every car on the road is one this file asked for.
--
-- Set VanillaBehaviour false for the fully scripted pack, which additionally
-- blocks non-temporary events so nothing can pull a unit out of its drive task.
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

-- Line-of-sight trace flags. Map and objects block a sightline; VEHICLES do
-- not, deliberately — a pursuit that loses you because a bus pulled across the
-- junction is a pursuit that loses you at random.
local LOS_FLAGS      = 17

-- A unit that saw you this recently is still considered to have you even with
-- the sightline broken. Without this the pack "loses" you at every blind corner
-- and the escape countdown starts flashing on a straight piece of road.
local SIGHT_MEMORY_MS = 4000

-- A surplus unit is not deleted while the racer is looking at it; this is how
-- long it may stay surplus before it goes anyway.
local SURPLUS_GRACE_MS = 8000

local active   = false
local heat     = 0.0
local stars    = 0
local units    = {}                -- pursuit cars: { veh, ped, blip, role, ... }
local block    = nil               -- { units = {...}, at, placedAt, scored }
local lastSpawn   = 0
local lastPit     = 0
local lastBlock   = 0
local lastChatter = 0
local flankSide   = 1              -- alternates so flankers do not stack on one side
local escapeFor   = 0.0            -- seconds the escape countdown has been running
local hitCooldown = 0              -- ms timer so one crash is not counted twice
local lastWantedSig = ""           -- last payload pushed to the raceUI star row

-- ── Pursuit state ───────────────────────────────────────────────────────────
-- CLEAR    nobody is after you. Offence heat bleeds away here.
-- PURSUIT  you are wanted and the pack is out. Heat is LOCKED: it cannot fall.
-- EVADING  the pack is out but nothing has contact. The escape clock runs and
--          heat finally bleeds — this is the only place shaking them pays.
local phase        = "CLEAR"
local pursuitSince = 0             -- ms the current pursuit started
local contactAt    = 0             -- ms anything last had contact
local contactEver  = false         -- has anything had contact in THIS pursuit
local pendingHeat  = 0.0           -- one-off bonuses queued for the next heat step
local starsSince   = 0             -- ms the current star level was reached
local debugHud     = false

local function cfg(key, fallback)
    local v = CC[key]
    if v == nil then return fallback end
    return v
end

local function heliCfg(key, fallback)
    local h = CC.Heli or {}
    if h[key] == nil then return fallback end
    return h[key]
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function levelSpec(n)
    local levels = CC.Levels or {}
    return levels[n] or levels[#levels]
        or { tail = 1, flank = 0, intercept = 0, pit = false, pitEvery = 0, roadblock = 0, speed = 40.0 }
end

--- The player and the thing a cop should be looking at. While the racer is in a
--- car, trace to the CAR: tracing to the ped inside it can be blocked by its own
--- bodywork, which would read as the police losing a driver sitting in plain
--- sight on an open road.
local function targetEntity(ped, veh)
    if veh ~= 0 and DoesEntityExist(veh) then return veh end
    return ped
end

-- ── Dispatch radio ───────────────────────────────────────────────────────────
--
-- The audio half of a callout. Two independent pieces, because they fail
-- differently:
--
--   squelch  the CB radio key-up/key-down click. A frontend sound, always
--            available, and on its own it is most of what sells "that came over
--            a radio" rather than out of thin air.
--
--   report   real police-scanner lines via PlayPoliceReport. The valid names
--            are a game-audio list, not an API, so they live in config as data
--            rather than baked in here — an unknown name is silently nothing,
--            which is exactly why it must be editable without touching code.
--
-- spz-core calls CancelCurrentPoliceReport every frame while cops are disabled,
-- which would cut a report off the moment it started. LocalPlayer.state.copHeat
-- is the flag that tells it to leave the scanner alone while a pursuit is live.
local function radioCfg(key, fallback)
    local r = CC.Radio or {}
    if r[key] == nil then return fallback end
    return r[key]
end

local lastReport = 0

local function radioReport()
    local list = radioCfg("Reports", nil)
    if type(list) ~= "table" or #list == 0 then return end

    local now = GetGameTimer()
    -- Scanner lines are long. Overlapping two is noise, not chatter.
    if (now - lastReport) < (radioCfg("ReportGapMs", 9000)) then return end
    lastReport = now

    PlayPoliceReport(list[math.random(#list)], 0.0)
end

local function radioSquelch()
    if radioCfg("Squelch", true) == false then return end
    PlaySoundFrontend(-1, "Start_Squelch", "CB_RADIO_SFX", true)
end

--- Sound for a callout, independent of whether the text is shown: a server can
--- run a silent HUD and still want the radio, or the reverse.
local function radioCall()
    if radioCfg("Enabled", true) == false then return end
    radioSquelch()
    radioReport()
end

local function chatter(msg, kind)
    local now = GetGameTimer()
    if now - lastChatter < 3500 then return end
    lastChatter = now

    -- Radio first, and independent of the text: a server running a silent HUD
    -- still wants the callout to be audible.
    radioCall()

    if cfg("Chatter", true) == false then return end
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

--- How far back a unit is put, expressed as SECONDS of the racer's speed rather
--- than as a fixed number of metres.
---
--- A fixed 130 m is two different things: a long way back in an alley at 60
--- km/h, and less than two seconds at 250 km/h on the freeway. Reading it as a
--- time gap makes the arrival feel the same at both ends of the speed range, and
--- it is the first half of why the pack now actually turns up.
local function spawnBehindDist(ent)
    local base = cfg("SpawnBehind", 130.0)
    if ent and ent ~= 0 and DoesEntityExist(ent) then
        local bySpeed = GetEntitySpeed(ent) * cfg("BehindSec", 2.2)
        if bySpeed > 0.0 then base = bySpeed end
    end
    return clamp(base, cfg("SpawnBehindMin", 75.0), cfg("SpawnBehindMax", 200.0))
end

--- A road point `dist` metres along the racer's heading (negative = behind).
--- Snapped to a vehicle node, because a cruiser dropped onto a pavement or a
--- roof is a comedy unit, not a pursuit unit.
local function roadPointAlong(ent, dist)
    local pos = GetEntityCoords(ent)
    local h   = math.rad(GetEntityHeading(ent))
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

--- The behind-point a chase unit arrives on, pushed further back if the obvious
--- one would put a police car into view out of thin air. Three attempts, then it
--- takes the first valid point regardless — a unit that arrives slightly visibly
--- is better than a pursuit with nothing in it.
local function behindPoint(ent, base)
    local firstC, firstH
    for _, mult in ipairs({ 1.0, 1.3, 1.65 }) do
        local c, h = roadPointAlong(ent, -(base * mult))
        if c then
            if not firstC then firstC, firstH = c, h end
            if cfg("SpawnOffScreen", true) == false then return c, h end
            if not IsSphereVisible(c.x, c.y, c.z + 1.0, 3.0) then return c, h end
        end
    end
    return firstC, firstH
end

--- Where the racer will BE, not where they are: an intercept placed on the
--- current heading is placed behind a car that is already turning. The velocity
--- vector is the closest cheap read on where the road is taking them.
local function projectedPoint(ent, seconds)
    local pos = GetEntityCoords(ent)
    local v   = GetEntityVelocity(ent)
    local tx, ty = pos.x + v.x * seconds, pos.y + v.y * seconds

    local ok, node, heading = GetClosestVehicleNodeWithHeading(tx, ty, pos.z, 1, 3.0, 0)
    if ok and node and #(node - pos) >= cfg("SpawnMinDist", 60.0) then
        return node, heading or 0.0
    end
    return nil
end

-- ── Contact ──────────────────────────────────────────────────────────────────
--
-- The single question the whole pursuit hangs on: does anybody still have you?
--
-- It replaces the old "is the nearest car within 170 m" test, which answered no
-- for a cruiser three metres behind you round a blind corner and yes for one
-- that had long since given up on a parallel street. A unit has you when:
--
--   * it is inside ContactCloseDist — that close it does not need a sightline;
--   * OR it is inside ContactDist AND has a clear line to you;
--   * OR it is inside ContactDist and had a line to you within the last few
--     seconds. This is the corner case, literally: pursuit units do not forget
--     a car the instant a building comes between them.
--
-- The chopper is included, on its own longer sightline. It used to be excluded
-- from the escape test entirely, because it holds station overhead and counting
-- its DISTANCE would have made escape impossible above two stars. Counting its
-- SIGHT gives it the job it has in the base game: while it can see you, you have
-- not lost anybody — and a tunnel, an underpass or a car park takes its eyes
-- away and starts the clock.

local function scanContact(pos, target, now)
    local nearestGround = math.huge
    local nearest       = math.huge
    local contact       = false

    local closeD  = cfg("ContactCloseDist", 45.0)
    local seeD    = cfg("ContactDist", cfg("EscapeDist", 175.0))
    local heliD   = heliCfg("SightDist", 280.0)
    local heliOn  = heliCfg("HoldsContact", true) ~= false

    for _, u in ipairs(units) do
        if DoesEntityExist(u.veh) then
            local d = #(GetEntityCoords(u.veh) - pos)
            u.gap = d
            if d < nearest then nearest = d end

            local maxSee = (u.role == "heli") and heliD or seeD
            local sees   = false

            if u.role == "heli" then
                if heliOn and d <= heliD then
                    sees = HasEntityClearLosToEntity(u.veh, target, LOS_FLAGS)
                end
            else
                if d < nearestGround then nearestGround = d end
                if d <= closeD then
                    sees = true
                elseif d <= maxSee then
                    sees = HasEntityClearLosToEntity(u.veh, target, LOS_FLAGS)
                end
            end

            if sees then
                u.lastSeen = now
                u.seeing   = true
                contact    = true
            else
                u.seeing = false
                -- Sight memory: still in range and saw you a moment ago.
                if d <= maxSee and (now - (u.lastSeen or 0)) < SIGHT_MEMORY_MS then
                    contact = true
                end
            end
        else
            u.gap, u.seeing = math.huge, false
        end
    end

    -- A roadblock is police standing in the road. Driving up to one is not
    -- getting away from them.
    if block and block.at and #(block.at - pos) <= seeD then
        contact = true
    end

    return contact, nearestGround, nearest
end

-- ── Tasking ──────────────────────────────────────────────────────────────────

--- 0 at the hold distance, 1 once a unit is CatchUpSpan metres further back than
--- the assist threshold. Everything about keeping up scales off this one number.
local function catchUpFrac(gap)
    local from = cfg("CatchUpFrom", 55.0)
    if not gap or gap <= from then return 0.0 end
    local span = cfg("CatchUpSpan", 130.0)
    if span <= 0 then return 1.0 end
    return clamp((gap - from) / span, 0.0, 1.0)
end

--- Cruise target for one unit. Tracks the racer's speed as before, but with two
--- bands on top of it:
---
---   behind   extra speed proportional to how far back it is, so a unit that
---            lost ground closes it instead of settling into a permanent tow.
---   holding  inside HoldDist the assist is off entirely and it matches pace.
---            A pursuit unit that is already on you and still being told to go
---            16 m/s faster does not apply pressure, it rear-ends you.
local function pursuitSpeed(ent, spec, gap, holding)
    local mine = (ent and ent ~= 0 and DoesEntityExist(ent)) and GetEntitySpeed(ent) or 0.0
    local ceil = cfg("SpeedCeiling", 82.0)

    if holding then
        -- Matching pace, with just enough over to stay attached.
        return clamp(math.max(mine * 1.02, 8.0), 8.0, ceil)
    end

    local want  = mine * cfg("SpeedMatch", 1.12)
    local floor = math.max(cfg("SpeedFloor", 30.0), spec.speed or 40.0)
    want = want + catchUpFrac(gap) * cfg("CatchUpSpeed", 16.0)
    if want < floor then want = floor end
    return clamp(want, 0.0, ceil)
end

--- The same number, per unit, with the hold band given hysteresis.
---
--- Without it a unit oscillating either side of HoldDist flips between "sit on
--- them" and "close the gap" several times a second, and because a big enough
--- change of target re-issues the drive task, that is a pursuit car whose brain
--- is wiped twice a second while it is driving. It goes in at HoldDist and does
--- not come out again until it is properly adrift.
local function unitSpeed(u, ent, spec)
    local gap  = u.gap or math.huge
    local hold = cfg("HoldDist", 22.0)

    if u.holding then
        if gap > hold * 1.6 then u.holding = false end
    elseif gap < hold then
        u.holding = true
    end

    return pursuitSpeed(ent, spec, gap, u.holding)
end

--- Engine output. Fixed per star level, plus the same bounded catch-up term, so
--- a unit that has been left behind has the power to come back — and loses it
--- again the moment it is on you.
---
--- The two halves are written on different schedules on purpose:
---
---   POWER      SetVehicleEnginePowerMultiplier is a plain set, so it can track
---              the catch-up band. Quantised anyway, because writing a new
---              multiplier to a car five times a second for a whole race is
---              pointless work.
---   TOP SPEED  ModifyVehicleTopSpeed is only headroom — it decides what the
---              car is ALLOWED to reach, not what it asks for — so it is
---              written once per star level, with the catch-up allowance
---              already included. That also keeps it off the per-tick path,
---              which matters: it is the one native here whose repeat-call
---              behaviour is not worth betting a pursuit on.
local function applyPower(u, gap)
    if not DoesEntityExist(u.veh) then return end

    local base = (CC.PowerBoost or {})[stars] or 0.3

    if u.topAt ~= stars then
        u.topAt = stars
        ModifyVehicleTopSpeed(u.veh, 1.0 + base + cfg("CatchUpPower", 0.45))
    end

    local q = math.floor((base + catchUpFrac(gap) * cfg("CatchUpPower", 0.45)) * 20.0 + 0.5) / 20.0
    if u.powerAt == q then return end
    u.powerAt = q
    SetVehicleEnginePowerMultiplier(u.veh, q * 100.0)
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
--- car and a new ped. It is also handed the racer's pace on arrival, for the
--- same reason a fresh spawn is: a recovered unit dropped at a standstill is a
--- unit that needs recovering again in ten seconds.
local function recover(u, ent, speed, now)
    if (now - (u.recoveredAt or 0)) < RECOVER_GAP then return false end
    if IsEntityOnScreen(u.veh) then return false end   -- never in view

    local coords, heading = behindPoint(ent, spawnBehindDist(ent))
    if not coords then return false end

    SetEntityCoords(u.veh, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(u.veh, heading or 0.0)
    SetVehicleOnGroundProperly(u.veh)
    SetVehicleEngineOn(u.veh, true, true, false)
    reseat(u)
    applyRole(u, speed)

    if cfg("SpawnAtSpeed", true) then
        local launch = clamp(GetEntitySpeed(ent), 0.0, cfg("SpeedCeiling", 82.0))
        if launch > 4.0 then SetVehicleForwardSpeed(u.veh, launch) end
    end

    u.recoveredAt = now
    u.stuckSince  = nil
    return true
end

--- Returns false if the unit is beyond saving and should be recycled.
local function tickUnit(u, ent, speed, now)
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
        if not recover(u, ent, speed, now) then return false end
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
            elseif not recover(u, ent, speed, now) then
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

local function vanillaCop(ped)
    -- Real police, as far as the game is concerned. SetPedAsCop plus the COP
    -- relationship group is what makes the base-game AI treat the wanted player
    -- as a suspect rather than as traffic — without both, an armed ped in a
    -- police uniform still just drives.
    SetPedAsCop(ped, true)
    SetPedRelationshipGroupHash(ped, GetHashKey("COP"))

    -- The police BRAIN, without the gun. Every route from a pursuit to a
    -- firefight is cut here, and cut at the source rather than by hoping the AI
    -- never takes it:
    RemoveAllPedWeapons(ped, true)
    SetPedCanSwitchWeapon(ped, false)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedCombatAttributes(ped, 2, false)    -- no drivebys
    SetPedCombatAttributes(ped, 3, false)    -- BF_CanLeaveVehicle: they stay in the car
    SetPedCombatAttributes(ped, 5, false)    -- never "always fight"
    SetPedCombatAttributes(ped, 46, false)
    SetPedFleeAttributes(ped, 0, false)
    SetPedAccuracy(ped, cfg("Accuracy", 25))

    -- Armour anyway: a unit that dies to a shunt leaves a corpse in a cruiser
    -- in the middle of the race, which is worse than one that shrugs it off.
    SetPedArmour(ped, cfg("Armour", 100))

    SetPedKeepTask(ped, true)
    SetPedCanBeDraggedOut(ped, false)
    SetPedCanBeTargettedByPlayer(ped, PlayerId(), false)
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

--- One cruiser with a driver in it, placed and made permanent. `launch` is the
--- speed it is moving at the instant it exists — see the header: a unit created
--- at a standstill behind a car at racing pace has already lost the pursuit
--- before its first frame, and no amount of engine multiplier gets that back.
--- Returns the unit table, or nil if the models or the ground would not
--- cooperate.
local function makeUnit(coords, heading, role, launch)
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

    SetVehicleHasBeenOwnedByPlayer(veh, false)

    local ped = CreatePed(26, pedHash, coords.x, coords.y, coords.z, heading, false, false)
    if not DoesEntityExist(ped) then
        DeleteEntity(veh)
        return nil
    end
    SetPedIntoVehicle(ped, veh, -1)
    SetEntityAsMissionEntity(ped, true, true)
    if cfg("VanillaBehaviour", true) then vanillaCop(ped) else disarm(ped) end
    makeDriver(ped)

    -- Rolling on arrival. Applied last, after the ped is seated and the engine
    -- is on, because a forward speed set on an empty car is thrown away the
    -- moment a driver takes over.
    if launch and launch > 4.0 and cfg("SpawnAtSpeed", true) then
        SetVehicleForwardSpeed(veh, clamp(launch, 0.0, cfg("SpeedCeiling", 82.0)))
    end

    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)

    local blip = AddBlipForEntity(veh)
    SetBlipSprite(blip, 56)
    SetBlipColour(blip, role == "intercept" and 49 or 38)
    SetBlipScale(blip, 0.75)
    SetBlipAsShortRange(blip, true)

    local u = { veh = veh, ped = ped, blip = blip, role = role,
                pitUntil = 0, born = GetGameTimer(), gap = math.huge }
    applyPower(u, 0.0)
    return u
end

-- ── Air support ──────────────────────────────────────────────────────────────
--
-- One maverick, holding station over the racer with its searchlight on them.
--
-- TaskHeliChase is the base game's own air-pursuit task — the same one the
-- police chopper flies in single player — so the flying is not scripted here
-- either: it is given the target and an offset to hold, and left to it.
--
-- It never rams, never blocks and never PITs. Its whole job is that ducking
-- into a side street stops working, which is what it does in the base game —
-- and, now that its sightline counts as contact, that ducking into a side
-- street also stops the escape clock from starting.

--- A point in the air, `behind` metres back down the racer's heading and
--- `height` metres up. No node snapping — it is a helicopter.
local function airPointBehind(ent)
    local pos = GetEntityCoords(ent)
    local h   = math.rad(GetEntityHeading(ent))
    local d   = heliCfg("Behind", 45.0)
    return vec3(pos.x + math.sin(h) * d,
                pos.y - math.cos(h) * d,
                pos.z + heliCfg("Height", 45.0))
end

local function taskHeli(u)
    if not DoesEntityExist(u.ped) then return end
    ClearPedTasks(u.ped)
    -- Offsets are relative to the target: straight overhead, at height.
    TaskHeliChase(u.ped, PlayerPedId(), 0.0, 0.0, heliCfg("Height", 45.0))
    u.taskedAt = GetGameTimer()
end

local function spawnHeli(ent)
    if heliCfg("Enabled", true) == false then return false end

    local vehHash = loadModel(heliCfg("Model", "polmav"))
    local pedHash = loadModel(heliCfg("PedModel", "s_m_y_cop_01"))
    if not vehHash or not pedHash then return false end

    local at      = airPointBehind(ent)
    local heading = GetEntityHeading(ent)

    local veh = CreateVehicle(vehHash, at.x, at.y, at.z, heading, false, false)
    if not DoesEntityExist(veh) then return false end
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleEngineOn(veh, true, true, false)
    -- Spawned already flying: without this it drops while the rotor spools up,
    -- which from the ground reads as a helicopter falling out of the sky.
    SetHeliBladesFullSpeed(veh)
    SetVehicleTyresCanBurst(veh, false)
    SetVehicleStrong(veh, true)
    if cfg("Sirens", true) then SetVehicleSiren(veh, true) end

    local ped = CreatePed(26, pedHash, at.x, at.y, at.z, heading, false, false)
    if not DoesEntityExist(ped) then
        DeleteEntity(veh)
        return false
    end
    SetPedIntoVehicle(ped, veh, -1)
    SetEntityAsMissionEntity(ped, true, true)
    if cfg("VanillaBehaviour", true) then vanillaCop(ped) else disarm(ped) end
    SetPedCanBeDraggedOut(ped, false)

    if heliCfg("Searchlight", true) then
        SetVehicleSearchlight(veh, true, false)
    end

    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)

    local blip
    if heliCfg("Blip", true) then
        blip = AddBlipForEntity(veh)
        SetBlipSprite(blip, 43)          -- helicopter
        SetBlipColour(blip, 38)
        SetBlipScale(blip, 0.8)
        SetBlipAsShortRange(blip, false) -- it is meant to be seen coming
    end

    local u = { veh = veh, ped = ped, blip = blip, role = "heli",
                pitUntil = 0, born = GetGameTimer(), gap = math.huge }
    units[#units + 1] = u
    taskHeli(u)
    lastSpawn = GetGameTimer()

    chatter("Air unit is up — they have eyes on you", "error")
    return true
end

--- Put a strayed chopper back over the racer. No off-screen condition and no
--- node lookup: there is nothing to snap to at altitude, and a helicopter
--- crossing the sky to rejoin is a thing you see in the base game anyway.
local function recoverHeli(u, ent)
    if not DoesEntityExist(u.veh) then return false end
    local at = airPointBehind(ent)
    SetEntityCoords(u.veh, at.x, at.y, at.z, false, false, false, false)
    SetEntityHeading(u.veh, GetEntityHeading(ent))
    SetHeliBladesFullSpeed(u.veh)
    if GetPedInVehicleSeat(u.veh, -1) ~= u.ped then
        TaskWarpPedIntoVehicle(u.ped, u.veh, -1)
    end
    taskHeli(u)
    return true
end

-- Everything the chopper needs per tick. Deliberately NOT tickUnit: upside
-- down, stuck-on-a-kerb and put-it-back-on-the-road are all meaningless in the
-- air, and SetVehicleOnGroundProperly on a flying helicopter is a crash.
local HELI_RETASK_MS = 8000

local function tickHeli(u, ent, now)
    if not DoesEntityExist(u.veh) or not DoesEntityExist(u.ped) then return false end
    if IsEntityDead(u.ped) or not IsVehicleDriveable(u.veh, false) then return false end

    if GetPedInVehicleSeat(u.veh, -1) ~= u.ped then
        TaskWarpPedIntoVehicle(u.ped, u.veh, -1)
        taskHeli(u)
        return true
    end

    -- The chase task ends quietly like any other. Re-issuing it on a slow timer
    -- is cheaper than polling task status and costs nothing when it is already
    -- running.
    if (now - (u.taskedAt or 0)) > HELI_RETASK_MS then
        taskHeli(u)
    end

    if heliCfg("Searchlight", true) then
        SetVehicleSearchlight(u.veh, true, false)
    end

    return true
end

local function spawnPursuit(ent, role, spec)
    local coords, heading
    local mySpeed = (ent and ent ~= 0 and DoesEntityExist(ent)) and GetEntitySpeed(ent) or 0.0

    if role == "intercept" then
        -- Ahead, facing back down the road at you.
        coords, heading = projectedPoint(ent, 6.0)
        if not coords then
            coords, heading = roadPointAlong(ent, cfg("SpawnAhead", 240.0))
        end
        if heading then heading = (heading + 180.0) % 360.0 end
    else
        coords, heading = behindPoint(ent, spawnBehindDist(ent))
    end
    if not coords then return false end

    -- An intercept is coming AT you, so it only needs road speed; a chase unit
    -- is coming after you and needs yours. Both start moving — nothing in this
    -- pack is ever created at a standstill on an open road again.
    local launch = (role == "intercept") and math.min(mySpeed * 0.6, 30.0) or mySpeed

    local u = makeUnit(coords, heading or 0.0, role, launch)
    if not u then return false end

    if role == "flank" then
        u.side = flankSide
        flankSide = flankSide == 1 and 2 or 1
    end

    u.gap = #(coords - GetEntityCoords(ent))
    units[#units + 1] = u
    applyRole(u, unitSpeed(u, ent, spec))
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
local function placeRoadblock(ent)
    local coords, heading = roadPointAlong(ent, cfg("RoadblockAhead", 320.0))
    if not coords then return false end

    local across = (heading + 90.0) % 360.0
    local rad    = math.rad(across)
    local rx, ry = math.cos(rad), math.sin(rad)

    local made = {}
    for i = -1, 1, 2 do
        local cx = coords.x + rx * (2.6 * i)
        local cy = coords.y + ry * (2.6 * i)
        local u  = makeUnit(vector3(cx, cy, coords.z), across, "block", nil)
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
    block = { units = made, placedAt = GetGameTimer(), at = coords, scored = false }
    lastBlock = GetGameTimer()
    chatter("Roadblock ahead — find another way", "error")
    return true
end

--- Blocks are torn down once dealt with, and going THROUGH one instead of
--- around it is an escalation: it is the most obviously deliberate thing a
--- racer can do to the police short of ramming one.
local function tickRoadblock(pos, speed)
    if not block then return end
    local age  = GetGameTimer() - block.placedAt
    local dist = #(block.at - pos)

    if not block.scored and dist < 12.0 and speed > 15.0 then
        block.scored = true
        pendingHeat = pendingHeat + cfg("HeatPerRoadblockRun", 14)
        chatter("He is going straight through the block", "error")
    end

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

--- Stars from heat, with hysteresis in BOTH directions of the word: a level is
--- entered the moment the band is crossed, and given up only after falling a
--- clear margin below it AND holding there.
---
--- Without this the level oscillates across a band boundary at a couple of hertz
--- — and every oscillation spawns or deletes a police car, because the pack
--- shape is read off the star level. The flicker was visible as cruisers
--- appearing and vanishing in the mirror for no reason at all.
local function starsFor(h, current, now)
    local maxStars = cfg("MaxStars", 5)
    local n = clamp(math.floor(h / STARS_PER_HEAT), 0, maxStars)

    if n < current then
        -- Must be a clear margin below the band we are currently in...
        local floorOfCurrent = current * STARS_PER_HEAT
        if h > (floorOfCurrent - cfg("StarDropMargin", 6.0)) then
            return current
        end
        -- ...and must have been at this level long enough to have meant it.
        if (now - starsSince) < (cfg("StarDwellSec", 5.0) * 1000) then
            return current
        end
    end

    return n
end

--- Offence heat: what you did, split into the two halves that escalate
--- differently.
---
--- SPEED is an offence, not a manhunt — it is capped at SpeedMaxStars by the
--- caller, so a clean fast lap cannot summon a helicopter.
--- WRECKAGE is uncapped, because ploughing through traffic and peds is exactly
--- what should take a chase to four and five stars.
---
--- Returns two numbers: speed heat this tick, crash heat this tick.
local function offenceHeat(veh, dt, copClose)
    local kmh  = GetEntitySpeed(veh) * 3.6
    local fast = 0.0
    local hit  = 0.0

    if kmh >= cfg("SpeedKmh", 130) then
        fast = cfg("SpeedHeatPerSec", 3.5) * dt
    end

    local now = GetGameTimer()
    if now >= hitCooldown then
        -- A cruiser's own PIT lands as vehicle damage; counting it would let the
        -- police escalate the chase by chasing, so contact is ignored while one
        -- of them is on top of the racer.
        if HasEntityBeenDamagedByAnyPed(veh) then
            hit = cfg("HeatPerPedHit", 22)
            hitCooldown = now + 1200
        elseif HasEntityBeenDamagedByAnyVehicle(veh) and not copClose then
            hit = cfg("HeatPerVehHit", 9)
            hitCooldown = now + 1200
        end
        ClearEntityLastDamageEntity(veh)
    end

    return fast, hit
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
        if u.pitUntil == 0 and u.role ~= "intercept" and u.role ~= "heli"
        and DoesEntityExist(u.veh) then
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
    phase, pursuitSince, contactAt, contactEver = "CLEAR", 0, 0, false
    pendingHeat, starsSince = 0.0, 0
    clearPack()

    -- Hands the scanner back to spz-core, which resumes cancelling reports.
    LocalPlayer.state:set("copHeat", false, false)

    -- Clear the star row now rather than up to a tick later: the pursuit ending
    -- is the moment the driver is looking for confirmation of.
    lastWantedSig = ""
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:UpdateWanted({ stars = 0 })
    end
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
---
--- The FIRST unit of a pursuit skips the spawn cooldown outright, and while the
--- pack is under half strength more than one may arrive per tick. A four-star
--- pursuit used to take the better part of fifteen seconds to actually field
--- four cars, by which point the racer was a district away and the whole thing
--- was a formality.
local function maintainPack(ent, spec, now)
    local want = (spec.tail or 0) + (spec.flank or 0) + (spec.intercept or 0) + (spec.heli or 0)
    if want <= 0 then return end

    local have  = #units
    local first = (have == 0) and cfg("FirstUnitInstant", true) ~= false
    if not first and (now - lastSpawn) < cfg("SpawnGapMs", 1600) then return end

    -- Two at a time only while the pack is genuinely thin; once it is most of
    -- the way there the arrivals space out again so units do not appear in pairs
    -- in the mirror.
    local budget = 1
    if have * 2 < want then budget = math.max(1, cfg("SpawnBurst", 2)) end

    for _ = 1, budget do
        local made
        if countRole("tail") < (spec.tail or 0) then
            made = spawnPursuit(ent, "tail", spec)
        elseif countRole("flank") < (spec.flank or 0) then
            made = spawnPursuit(ent, "flank", spec)
        elseif countRole("intercept") < (spec.intercept or 0) then
            made = spawnPursuit(ent, "intercept", spec)
        elseif countRole("heli") < (spec.heli or 0) then
            made = spawnHeli(ent)
        end
        if not made then return end
    end
end

--- Drop units the level no longer calls for, so losing a star visibly thins the
--- pack rather than only slowing the next spawn.
---
--- Two rules about WHICH one goes, and both exist because of how deleting the
--- wrong one looks:
---
---   * the FARTHEST surplus unit goes first. Deleting by table order is how a
---     cruiser vanishes out of your mirror while it is leaning on your rear
---     quarter, which reads as the script breaking.
---   * a surplus unit that is ON SCREEN is spared and tried again next tick. A
---     police car cannot be allowed to blink out of existence while it is being
---     looked at — that was half of "they just disappear". It goes anyway once
---     it has been surplus for SURPLUS_GRACE_MS, so the pack cannot grow a
---     permanent tail of units nobody is allowed to delete.
local function trimPack(spec, now)
    local want = { tail = spec.tail or 0, flank = spec.flank or 0,
                   intercept = spec.intercept or 0, heli = spec.heli or 0 }

    local order = {}
    for i = 1, #units do order[i] = i end
    table.sort(order, function(a, b)
        return (units[a].gap or math.huge) < (units[b].gap or math.huge)
    end)

    -- Nearest first: they claim the slots their role still has, and whatever is
    -- left over at the back of the queue is surplus.
    local doomed = {}
    for _, i in ipairs(order) do
        local role = units[i].role
        if (want[role] or 0) > 0 then
            want[role] = want[role] - 1
            units[i].surplusSince = nil
        else
            doomed[i] = true
        end
    end

    for i = #units, 1, -1 do
        if doomed[i] then
            local u = units[i]
            u.surplusSince = u.surplusSince or now
            local overdue = (now - u.surplusSince) > SURPLUS_GRACE_MS
            if overdue or not (DoesEntityExist(u.veh) and IsEntityOnScreen(u.veh)) then
                destroyUnit(u)
                table.remove(units, i)
            end
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
            local now    = GetGameTimer()
            local ped    = PlayerPedId()
            local veh    = GetVehiclePedIsIn(ped, false)
            local onFoot = (veh == 0) or not DoesEntityExist(veh)

            -- On foot the pursuit CONTINUES. Bailing out used to freeze the
            -- whole tick, which left the pack holding whatever task it had and
            -- the escape clock stopped: getting out of the car was a way to put
            -- the police on pause.
            local subject = onFoot and ped or veh
            local pos     = GetEntityCoords(subject)
            local target  = targetEntity(ped, veh)

            active = true

            -- ── Who has you ────────────────────────────────────────────────
            local contact, nearestGround = scanContact(pos, target, now)
            local copClose = nearestGround < 15.0

            if contact then
                contactAt   = now
                contactEver = true
            end
            -- Contact is "recent" through the grace window, so a corner or an
            -- underpass is not an escape.
            local graceMs      = cfg("ContactGraceSec", 2.5) * 1000
            local contactRecent = contactEver and (now - contactAt) <= graceMs

            -- ── Heat ───────────────────────────────────────────────────────
            local speedGain, crashGain = 0.0, 0.0
            if not onFoot then
                speedGain, crashGain = offenceHeat(veh, dt, copClose)
            end

            -- Speeding buys stars only up to its own ceiling; wreckage does not
            -- have one.
            local speedCeil = math.min(cfg("SpeedMaxStars", cfg("OffenceMaxStars", 2)),
                                       cfg("MaxStars", 5)) * STARS_PER_HEAT
            if speedGain > 0 and heat < speedCeil then
                heat = math.min(heat + speedGain, speedCeil)
            end
            if crashGain > 0 then heat = heat + crashGain end

            -- One-off bonuses: driving through a roadblock, surviving a PIT.
            if pendingHeat > 0 then
                heat = heat + pendingHeat
                pendingHeat = 0.0
            end

            -- Pursuit escalation, and the decay rule that is the whole point of
            -- the rework:
            --
            --   contact   heat RISES with the pursuit clock and never falls.
            --   no contact, pack still out   it bleeds at the evade rate.
            --   nothing after you at all     it bleeds at the idle rate.
            if contactRecent then
                if (now - pursuitSince) > (cfg("PursuitGraceSec", 6.0) * 1000) then
                    heat = heat + cfg("PursuitHeatPerSec", 1.5) * dt
                end
            elseif #units > 0 or block then
                -- Out but not on you. Note the contactEver guard: before the
                -- FIRST contact of a pursuit nothing bleeds, because the units
                -- are still closing and have not had their chance yet. Without
                -- it a pursuit could decay itself out of existence during the
                -- few seconds it takes the first car to reach the racer.
                if contactEver then
                    heat = heat - cfg("EvadeDecayPerSec", 1.2) * dt
                end
            elseif speedGain <= 0 and crashGain <= 0 then
                heat = heat - cfg("IdleDecayPerSec", cfg("HeatDecayPerSec", 2.0)) * dt
            end

            local ceiling = cfg("MaxStars", 5) * STARS_PER_HEAT
            heat = clamp(heat, 0.0, ceiling)

            -- While anything has you, you are wanted. Full stop. This is the
            -- floor that stops the pack being deleted out from under a cruiser
            -- that is physically touching the car.
            if contactRecent and heat < STARS_PER_HEAT then heat = STARS_PER_HEAT end

            -- ── Stars ──────────────────────────────────────────────────────
            local newStars = starsFor(heat, stars, now)
            if newStars ~= stars then
                if newStars > stars then
                    lib.notify({
                        title = "WANTED",
                        description = ("%d star%s — police are on you"):format(newStars, newStars == 1 and "" or "s"),
                        type = "error", duration = 3500,
                    })
                end
                stars      = newStars
                starsSince = now
            end

            -- ── Phase ──────────────────────────────────────────────────────
            if stars > 0 and phase == "CLEAR" then
                phase        = "PURSUIT"
                pursuitSince = now
                escapeFor    = 0.0
                if not contact then contactAt, contactEver = 0, false end
            end

            -- EVADING is reachable only AFTER a first contact. A pursuit whose
            -- units have not reached the racer yet is still a pursuit — putting
            -- it into EVADING would start the escape countdown on a pack that
            -- has not had its chance, and call the whole thing off before the
            -- first cruiser was ever in the mirror.
            if phase ~= "CLEAR" then
                if contactRecent or not contactEver then
                    phase     = "PURSUIT"
                    escapeFor = 0.0
                else
                    phase = "EVADING"
                end
            end

            -- While this is set, spz-core leaves the police scanner alone so a
            -- report can actually finish playing.
            local heatOn = stars > 0 and radioCfg("Enabled", true) ~= false
            if heatOn ~= LocalPlayer.state.copHeat then
                LocalPlayer.state:set("copHeat", heatOn, false)
            end

            if cfg("UseNativeWanted", false) then
                SetPlayerWantedLevel(PlayerId(), stars, false)
                SetPlayerWantedLevelNow(PlayerId(), false)
                -- Ignoring the player is what the scripted-only pack wanted: no
                -- vanilla reaction at all. The game's police AI needs the exact
                -- opposite — a suspect it is allowed to notice.
                SetPoliceIgnorePlayer(PlayerId(), not cfg("VanillaBehaviour", true))
            end

            -- Nothing wanted, nobody on you: the pursuit is over on the spot.
            -- Note the contactRecent guard — this is the line that used to delete
            -- the whole pack while it was still on top of the racer.
            if stars == 0 and not contactRecent then
                if #units > 0 or block then stopChase("You lost them") end
                phase, escapeFor = "CLEAR", 0.0
                goto continue
            end

            local spec = levelSpec(math.max(stars, 1))

            -- ── Units ──────────────────────────────────────────────────────
            -- Recycle anything that has lost the race, been wrecked, or (for an
            -- intercept) already been driven past — its job is done the moment
            -- it is behind you, and it becomes a tail unit rather than a car
            -- driving the wrong way down the road forever.
            for i = #units, 1, -1 do
                local u = units[i]
                local broken = (not DoesEntityExist(u.veh)) or (not DoesEntityExist(u.ped))
                    or IsEntityDead(u.ped) or not IsVehicleDriveable(u.veh, false)

                local speed = unitSpeed(u, subject, spec)
                local dead  = broken

                if not broken and u.role == "heli" then
                    -- Its own path entirely: air recovery, air tick.
                    if (u.gap or math.huge) > cfg("DespawnDist", 340.0) then
                        dead = not recoverHeli(u, subject)
                    else
                        dead = not tickHeli(u, subject, now)
                    end
                elseif not broken then
                    applyPower(u, u.gap)
                    if (u.gap or math.huge) > cfg("DespawnDist", 340.0) then
                        -- Adrift, but not beaten. Most cars out at the despawn
                        -- radius are stuck on a kerb two corners back, so they
                        -- get one off-screen pick-up before being retired —
                        -- recovering costs nothing, while replacing costs a
                        -- spawn and puts a fresh car in the mirror out of thin
                        -- air.
                        dead = not recover(u, subject, speed, now)
                    else
                        dead = not tickUnit(u, subject, speed, now)
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

            -- Background radio while the pursuit runs, so it is not silent
            -- between events. Separate cadence from the callouts, and it goes
            -- through the same overlap guard so the two cannot talk over
            -- each other.
            local ambientSec = radioCfg("AmbientEverySec", 0)
            if ambientSec and ambientSec > 0
            and (now - lastChatter) > (ambientSec * 1000) then
                lastChatter = now
                radioCall()
            end

            trimPack(spec, now)
            maintainPack(subject, spec, now)
            tickRoadblock(pos, GetEntitySpeed(subject))

            -- Re-task when the pace a unit was GIVEN has drifted from the pace it
            -- now needs. With the catch-up assist that number is per unit, so a
            -- car that has dropped back gets its new target immediately while
            -- one sitting on the bumper is left alone. Re-tasking everything on
            -- a fixed interval instead would restart the chase mid-corner every
            -- few seconds and make them drive worse, not better.
            for _, u in ipairs(units) do
                if u.role ~= "heli" and u.role ~= "block" and DoesEntityExist(u.ped) then
                    local speed = unitSpeed(u, subject, spec)
                    if u.pitUntil ~= 0 then
                        if now >= u.pitUntil then
                            -- They threw one and you are still going. That is an
                            -- escalation in anyone's book.
                            if not onFoot and GetEntitySpeed(subject) > 10.0 then
                                pendingHeat = pendingHeat + cfg("HeatPerPitSurvived", 6)
                            end
                            applyRole(u, speed)
                        end
                    elseif math.abs((u.taskSpeed or 0) - speed) > 5.0
                       and (now - (u.speedTaskAt or 0)) > 1500 then
                        -- A floor on how often a drive task may be restarted for
                        -- pace alone. Re-issuing it wipes what the driving AI
                        -- had worked out about the corner it is in, so it is
                        -- worth doing occasionally and ruinous to do constantly.
                        u.speedTaskAt = now
                        applyRole(u, speed)
                    else
                        -- Cheap nudge: keeps the cruise target honest between
                        -- full re-tasks without restarting the drive task.
                        SetDriveTaskCruiseSpeed(u.ped, speed)
                    end
                end
            end

            -- PIT: one at a time, on geometry, no more often than the level says.
            if not onFoot and spec.pit and (spec.pitEvery or 0) > 0
            and (now - lastPit) >= (spec.pitEvery * 1000) then
                local u = pitCandidate(veh, pos)
                if u then
                    taskPit(u, veh, unitSpeed(u, subject, spec), cfg("PitDurationMs", 3500))
                    lastPit = now
                    chatter("They are going for a PIT", "error")
                end
            end

            -- Roadblock, only while there is road ahead to block.
            if not onFoot and (spec.roadblock or 0) > 0 and not block
            and (now - lastBlock) >= (spec.roadblock * 1000)
            and GetEntitySpeed(veh) > 15.0 then
                placeRoadblock(veh)
            end

            ghostAgainstOtherPlayers()

            -- ── Shaking them ───────────────────────────────────────────────
            -- The escape clock runs ONLY in EVADING — nothing has you, and the
            -- grace window has already expired. Regaining contact zeroes it
            -- above, so a unit reacquiring you at eleven seconds puts you back
            -- to the start.
            --
            -- Before the first contact of a pursuit the clock does not run at
            -- all: units are still closing and have not had their chance yet.
            -- The one exception is a pursuit that never finds you — a pack that
            -- spawns into unreachable geometry would otherwise follow you for
            -- the rest of the race — so that expires on its own timer.
            if phase == "EVADING" then
                escapeFor = escapeFor + dt
                if escapeFor >= cfg("EscapeSeconds", 14) then
                    stopChase("You lost them")
                end
            elseif not contactEver and pursuitSince > 0
               and (now - pursuitSince) > (cfg("NoContactTimeoutSec", 40) * 1000) then
                stopChase("They never found you")
            end
        end

        ::continue::
    end
end)

-- ── HUD ─────────────────────────────────────────────────────────────────
-- The star readout is spz-raceUI's, not a DrawText from here. spz-core hides HUD
-- components 1-22 every frame, the vanilla stars among them, so something has to
-- draw them — and a five-star row belongs with every other race readout rather
-- than as the one piece of text this file paints on the screen itself.
--
-- Pushed on CHANGE, not per frame. The payload is three numbers and the element
-- redraws itself, so sending every frame would be a per-frame NUI message for a
-- row that changes a handful of times in a whole race.

local function pushWanted()
    if GetResourceState("spz-raceUI") ~= "started" then return end

    local show = active and stars > 0 and cfg("Hud", true) ~= false

    local left = 0
    if show and phase == "EVADING" and escapeFor > 0 then
        left = math.max(0, math.ceil(cfg("EscapeSeconds", 14) - escapeFor))
    end

    local sig = ("%s|%d|%d"):format(tostring(show), show and stars or 0, left)
    if sig == lastWantedSig then return end
    lastWantedSig = sig

    exports["spz-raceUI"]:UpdateWanted({
        stars  = show and stars or 0,
        max    = cfg("MaxStars", 5),
        escape = left > 0 and left or nil,
    })
end

CreateThread(function()
    while true do
        Wait(250)
        pushWanted()
    end
end)

-- ── Seeing the star row without a pursuit ────────────────────────────────────
-- /wantedtest [stars] [escapeSeconds]
--
-- Pushes a level straight at the HUD. The real readout only appears when cop
-- chase was voted in AND heat has been earned AND the race is LIVE, which is
-- three conditions deep before anything is on screen — far too much to have to
-- arrange every time the element itself needs looking at.
--
-- It writes nothing and starts nothing: the next real tick of pushWanted
-- overwrites whatever this put there, so it cannot leave the HUD lying.
--
--   /wantedtest        3 stars
--   /wantedtest 5      5 stars
--   /wantedtest 5 8    5 stars, "LOSING THEM 8s"
--   /wantedtest 0      clear it
RegisterCommand("wantedtest", function(_, args)
    if GetResourceState("spz-raceUI") ~= "started" then
        print("^1[spz-races] spz-raceUI is not started.^7")
        return
    end

    local n = tonumber(args[1]) or 3
    local esc = tonumber(args[2])

    exports["spz-raceUI"]:UpdateWanted({
        stars  = n,
        max    = cfg("MaxStars", 5),
        escape = esc and esc > 0 and esc or nil,
    })

    -- The signature cache would suppress the next real push if it happened to
    -- match what was just faked.
    lastWantedSig = ""

    print(("^2[spz-races] wanted test: %d star%s%s^7"):format(
        n, n == 1 and "" or "s", esc and (", losing them " .. esc .. "s") or ""))
end, false)

-- ── Watching the pursuit think ───────────────────────────────────────────────
-- /copdebug
--
-- Every number the tick above decides on, on screen, live. This exists because
-- all three of the behaviours that had to be fixed here were invisible from the
-- driving seat: whether the heat was climbing or bleeding, whether anything
-- actually had contact, and how far back each unit really was. Tuning any of the
-- config values by feel alone means guessing at all three.
--
-- Draws nothing unless it has been switched on.
local function dbg(text, line)
    SetTextFont(4)
    SetTextScale(0.30, 0.30)
    SetTextColour(255, 255, 255, 215)
    SetTextOutline()
    SetTextEntry("STRING")
    AddTextComponentString(text)
    DrawText(0.015, 0.30 + (line * 0.019))
end

CreateThread(function()
    while true do
        if not debugHud then
            Wait(400)
        else
            Wait(0)
            local line = 0
            dbg(("~y~COP CHASE~s~  phase ~b~%s~s~  heat ~b~%.1f~s~  stars ~b~%d~s~")
                :format(phase, heat, stars), line)
            line = line + 1
            dbg(("contactEver ~b~%s~s~  since contact ~b~%.1fs~s~  escape ~b~%.1f/%ds~s~")
                :format(tostring(contactEver),
                        contactAt > 0 and (GetGameTimer() - contactAt) / 1000 or -1,
                        escapeFor, cfg("EscapeSeconds", 14)), line)
            line = line + 1
            dbg(("units ~b~%d~s~  block ~b~%s~s~")
                :format(#units, block and "yes" or "no"), line)
            line = line + 1

            local spec = levelSpec(math.max(stars, 1))
            local subj = GetVehiclePedIsIn(PlayerPedId(), false)
            if subj == 0 then subj = PlayerPedId() end

            for i, u in ipairs(units) do
                dbg(("  %d %-9s gap ~b~%6.1fm~s~ %s cruise ~b~%.0f~s~ pwr ~b~%.2f~s~")
                    :format(i, u.role, u.gap or -1,
                            u.seeing and "~g~SEES~s~" or "~r~blind~s~",
                            pursuitSpeed(subj, spec, u.gap, u.holding), u.powerAt or 0), line)
                line = line + 1
            end
        end
    end
end)

RegisterCommand("copdebug", function()
    debugHud = not debugHud
    print(("^2[spz-races] cop chase debug %s^7"):format(debugHud and "ON" or "OFF"))
end, false)

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
exports("GetChasePhase", function() return phase end)
