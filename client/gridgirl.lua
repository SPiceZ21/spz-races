-- client/gridgirl.lua
-- The flag girl who starts the race.
--
-- Split-mode grids leave a lane down the middle of the field
-- (Config.RaceStartMode = "split", see shared/race_states.lua). This is what
-- stands in it: a local ped who walks out from the side of the road, takes up
-- position on the centre line facing the grid, and drops the field away at GO.
--
-- She is a LOCAL ped on every client, deliberately:
--   * nothing to replicate, so she costs the race bucket nothing and cannot be
--     shoved, shot or driven through by another player's car;
--   * every client sees her hit her mark at the same moment relative to their
--     own countdown, instead of one client's ped lagging for everybody;
--   * cleanup is unconditional — no netId to chase if a client drops.

-- ── The roster ───────────────────────────────────────────────────────────────
--
-- Six models, drawn in random ORDER rather than at random: the list is shuffled
-- and then worked through one race at a time, and only reshuffled once it is
-- empty. Independent random picks would hand you the same girl three races
-- running often enough to look broken; a shuffled bag guarantees all six appear
-- before any of them repeats.
--
-- `props` and `components` are what each model actually offers. The component
-- count is not used as a slot index — GTA's component slots are fixed IDs and a
-- model simply has fewer variations in some of them — but `props = 0` is load
-- bearing: a model with no prop variations must not be asked for a random one,
-- which is how you get a floating hat or nothing at all.
local PED_MODELS = {
    { model = `a_f_y_runner_01`,    props = 1, components = 5 },
    { model = `csb_anita`,          props = 1, components = 5 },
    { model = `csb_stripper_01`,    props = 0, components = 7 },
    { model = `mp_f_deadhooker`,    props = 0, components = 5 },
    { model = `s_f_y_bartender_01`, props = 0, components = 4 },
    { model = `s_f_y_hooker_01`,    props = 1, components = 5 },
}

local pedBag = {}

--- The next model in the shuffled order, refilling when the bag runs dry.
---
--- `idx` is the SERVER'S pick, sent with the grid. It is used whenever there is
--- one, because she has to be the same girl on every screen — she is a local ped
--- created independently on each client, so without a shared choice one driver
--- would be waved off by a bartender and another by a runner in the same race.
---
--- Wrapped rather than trusted: the server's roster size and this table's are
--- two numbers in two files, and an index off the end of the list must resolve
--- to a girl rather than to nil.
---
--- With no index — /flagdrop, or a server that has not been restarted yet — it
--- falls back to a local shuffled bag, which still guarantees all six appear
--- before any of them repeats.
local function nextPed(idx)
    if idx then
        return PED_MODELS[((math.floor(idx) - 1) % #PED_MODELS) + 1]
    end

    if #pedBag == 0 then
        for i = 1, #PED_MODELS do pedBag[i] = PED_MODELS[i] end
        -- Fisher-Yates.
        for i = #pedBag, 2, -1 do
            local j = math.random(i)
            pedBag[i], pedBag[j] = pedBag[j], pedBag[i]
        end
    end
    return table.remove(pedBag)
end

--- Dress her. Component variations come from the game rather than from the
--- table above, because it knows the real per-slot counts for the model that
--- actually loaded; the table only decides whether props are asked for at all.
local function dress(ped, spec)
    SetPedRandomComponentVariation(ped, 0)
    if (spec.props or 0) > 0 then
        SetPedRandomProps(ped)
    else
        ClearAllPedProps(ped)
    end
end

local ANIM_DICT  = "random@street_race"
local ANIM_CLIP  = "grid_girl_race_start"

-- Her mark, relative to the start point and expressed in the grid's own frame:
-- +forward is down the track. UP the road from the start line rather than level
-- with it — standing level with the front row puts her inside the two packs
-- instead of in front of them, and out of shot for the cars on the far side.
local MARK_AHEAD = 6.0

-- She is PLACED on her mark, not walked to it. The walk-in was a fixed budget
-- fitted into whatever the start sequence had left, and it lost that fight
-- constantly: a short countdown left no window, a long asset load ate the rest,
-- and the failure mode was her sprinting or snapping to the mark in view. Being
-- there from the first frame has no failure mode.

-- ── The flag animation ───────────────────────────────────────────────────────
--
-- `grid_girl_race_start` is a 72-second performance — idling, playing to the
-- grid, and somewhere inside it the actual swing — not a three second drop.
--
-- It is started at a FIXED OFFSET FROM GO, and nothing tries to align a frame
-- inside the clip with the lights any more. That alignment needed the drop's
-- timestamp inside the animation, which cannot be read from script, so it lived
-- in config as a number somebody had to find by hand with /flagdrop — and when
-- it was wrong, or simply unset, the swing landed a minute late or ran from the
-- top while the grid was still forming.
--
-- One offset, measured from the moment the countdown ends, is a thing that can
-- be set by watching it once.
local FLAG_AFTER_GO_MS = 2000   -- Config.FlagAnimAfterGoMs overrides this

-- How long she stays after the animation starts, so the clip is actually seen
-- before she is removed.
local LINGER_MS = 5000

local ANIM_FALLBACK = 72.6      -- clip length, if GetAnimDuration is unavailable

local girl = nil
local flagTimer = nil          -- token for the pending swing, so a restart cancels it

-- Set at GO, when she is on her mark and frozen: from that point her height is
-- fixed and the ground keeper has nothing left to do, so it stops rather than
-- rewriting the same coordinate under a playing animation.
local pinned = false

-- Bumped every time a grid forms. The spawn runs on a thread that waits for
-- assets and collision, so a second SPZ:gridFormed arriving during that wait
-- used to leave TWO setup threads driving the same global: one spawning a ped
-- while the other walked it, which reads on screen as the girl flickering.
-- Each thread checks the generation it started with and bails if it is stale.
local generation = 0

local function heldEntity(e) return e and e ~= 0 and DoesEntityExist(e) end

local function cleanup()
    -- Invalidate any scheduled swing first: a timer that fires after the ped is
    -- gone is harmless, but one that fires into the NEXT race's ped is not.
    flagTimer = nil
    pinned    = false
    if heldEntity(girl) then
        SetEntityAsMissionEntity(girl, true, true)
        DeleteEntity(girl)
    end
    girl = nil
end

-- Model + anim dict, or nil if either never streams in. Everything downstream
-- is skipped rather than half-done: a T-posing ped standing on the start line
-- is worse than no ped at all.
local function loadAssets(model)
    RequestModel(model)
    RequestAnimDict(ANIM_DICT)

    local deadline = GetGameTimer() + 5000
    while (not HasModelLoaded(model) or not HasAnimDictLoaded(ANIM_DICT))
      and GetGameTimer() < deadline do
        Citizen.Wait(50)
    end

    return HasModelLoaded(model) and HasAnimDictLoaded(ANIM_DICT)
end

-- Ground the point she walks to. The start coordinate is the vehicle grid's
-- Z, which is wheel height on the road surface; dropping a ped straight onto it
-- is close enough everywhere flat and visibly wrong on camber.
local function groundZ(x, y, z)
    local ok, gz = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
    return ok and gz or z
end

-- ── Passing through the field ────────────────────────────────────────────────
--
-- She must not be a bollard: she stands in the lane a split grid opens up, and
-- sixteen cars launch through it. But she also has to WALK, and walking is what
-- makes this awkward — a ped with no collision at all has nothing holding it
-- up, and driving its height by hand every frame is what made her jitter and
-- sink.
--
-- So world collision stays ON — the road carries her, exactly as the engine
-- intends — and collision is switched off pair by pair against the only things
-- that can actually hit her: player peds and the cars they are in.
--
-- SetEntityNoCollisionEntity's third argument is thisFrameOnly, NOT "disable".
-- Passing `true` (as this used to) buys a single frame and then lapses, which
-- is why she was still solid. It is `false` here, and refreshed on a timer
-- because the pairs go stale: players stream in, and a driver who changes car
-- is a new entity that has never been paired with her.
local PAIR_REFRESH_MS = 500

local function passThroughField(ped)
    for _, pid in ipairs(GetActivePlayers()) do
        local other = GetPlayerPed(pid)
        if other ~= 0 and DoesEntityExist(other) then
            SetEntityNoCollisionEntity(ped, other, false)

            local veh = GetVehiclePedIsIn(other, false)
            if veh ~= 0 and DoesEntityExist(veh) then
                SetEntityNoCollisionEntity(ped, veh, false)
            end
        end
    end
end

-- ── Not ending up under the road ─────────────────────────────────────────────
--
-- A safety net, not a driver. The engine keeps her on the surface; this only
-- catches the case where she has ended up genuinely below it — spawned into a
-- gap in the streamed world, or pushed under by something.
--
-- It runs at a lazy tick and does nothing at all unless she is a clear half
-- metre under, because a correction every frame is a correction fighting the
-- walk cycle, which is what the jitter was.
local UNDER_GROUND_TOL = 0.5
local GROUND_CHECK_MS  = 250

local function keepAboveGround(myGen, isPinned)
    Citizen.CreateThread(function()
        while generation == myGen and heldEntity(girl) and not isPinned() do
            passThroughField(girl)

            local p = GetEntityCoords(girl)
            -- Probe from well above her so the trace starts in open air even
            -- when she is already partly buried.
            local ok, gz = GetGroundZFor_3dCoord(p.x, p.y, p.z + 3.0, false)

            if ok and p.z < gz - UNDER_GROUND_TOL then
                -- SetEntityCoords, NOT SetEntityCoordsNoOffset: the "no offset"
                -- variant puts the ped's ORIGIN on the given Z, and a ped's
                -- origin is around its waist — which is precisely how she ended
                -- up buried to the middle. This one lands her feet on it.
                SetEntityCoords(girl, p.x, p.y, gz, false, false, false, false)
            end

            Citizen.Wait(GROUND_CHECK_MS)
        end
    end)
end

RegisterNetEvent("SPZ:gridFormed", function(data)
    if not data or not data.coords then return end
    cleanup()

    generation = generation + 1
    local myGen = generation

    local c   = data.coords
    local rad = math.rad(data.heading or 0.0)
    local forward = vec3(-math.sin(rad), math.cos(rad), 0.0)

    local mark = c + (forward * MARK_AHEAD)

    Citizen.CreateThread(function()
        local function stale() return generation ~= myGen end

        -- Drawn before the load so the wait is spent on the model that is
        -- actually going to be used.
        local spec = nextPed(data.flagGirl)

        if not loadAssets(spec.model) then
            print("^3[spz-races] Flag girl assets did not stream in — skipping.^7")
            return
        end

        if stale() then return end

        -- Ask for the world around her mark BEFORE spawning her. Without it the
        -- ground query answers against whatever happens to be streamed, so she
        -- is created at the wrong height and visibly snaps once the real surface
        -- arrives — the flicker as she appears.
        RequestCollisionAtCoord(mark.x, mark.y, mark.z)
        local collisionBy = GetGameTimer() + 1500
        while not HasCollisionLoadedAroundEntity(PlayerPedId()) and GetGameTimer() < collisionBy do
            Citizen.Wait(50)
        end

        if stale() then return end

        local mz = groundZ(mark.x, mark.y, mark.z)

        -- Facing back down the grid: the field is behind her mark, so her
        -- heading is the start heading reversed.
        local heading = ((data.heading or 0.0) + 180.0) % 360.0

        girl = CreatePed(4, spec.model, mark.x, mark.y, mz, heading, false, false)
        SetModelAsNoLongerNeeded(spec.model)
        if not heldEntity(girl) then girl = nil return end

        dress(girl, spec)

        -- She is scenery. Nothing in the race may knock her over, and she must
        -- not react to sixteen engines revving in her face and run away — which
        -- is exactly what an ambient ped does when a car aims at her.
        SetEntityInvincible(girl, true)
        SetBlockingOfNonTemporaryEvents(girl, true)
        SetPedCanRagdoll(girl, false)
        SetPedCanBeTargetted(girl, false)
        SetPedConfigFlag(girl, 128, true)   -- ignores combat / danger reactions
        -- Her mark IS her assigned area now that she never leaves it, so this
        -- can go on at spawn rather than on arrival.
        SetPedConfigFlag(girl, 17, true)

        -- Cars and players pass through her; the road still holds her up.
        passThroughField(girl)
        keepAboveGround(myGen, function() return pinned end)

        -- Idle on the mark until GO. The clip is started by the SPZ:go handler
        -- below, so there is nothing scheduled from here that a cancelled race
        -- would have to chase down.
    end)
end)

-- GO. The countdown has ended; the flag swing is scheduled off this moment.
--
-- Cars have passed through her since she spawned, so the field launching is
-- already a non-event. What is left is to nail her down, start the clip, and
-- take her away once it has been seen.
RegisterNetEvent("SPZ:go", function()
    if not heldEntity(girl) then return end

    pinned = true
    FreezeEntityPosition(girl, true)
    -- Frozen first, THEN collision off. In that order there is nothing left to
    -- fall: her position is nailed for the few seconds before she is removed,
    -- so losing the ground under her costs nothing.
    SetEntityCollision(girl, false, false)

    local delay = tonumber(Config and Config.FlagAnimAfterGoMs) or FLAG_AFTER_GO_MS
    if delay < 0 then delay = 0 end

    -- Token, so a race cancelled between here and the swing does not animate a
    -- ped that has already been cleaned up — or, worse, the next race's.
    local token = {}
    flagTimer = token

    Citizen.SetTimeout(delay, function()
        if flagTimer ~= token or not heldEntity(girl) then return end
        if HasAnimDictLoaded(ANIM_DICT) then
            TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 0, 0.0, false, false, false)
        end
    end)

    -- Removed after the clip has had time to be seen, not after a fixed five
    -- seconds from GO — which, with a delay in front of it, could have deleted
    -- her before the animation started at all.
    Citizen.SetTimeout(delay + LINGER_MS, cleanup)
end)

-- ── Previewing the clip ──────────────────────────────────────────────────────
-- /flagdrop [seconds]
--
-- Spawns her in front of you and plays the clip from `seconds` in, so the
-- performance can be watched without starting a race.
--
-- With no argument it plays from the top — which is exactly what a race does —
-- and prints the clip's real length, so the 72.6s figure can be confirmed
-- against whatever the game actually loads.
RegisterCommand("flagdrop", function(_, args)
    local at = tonumber(args[1])

    Citizen.CreateThread(function()
        local spec = nextPed()

        if not loadAssets(spec.model) then
            print("^1[spz-races] Flag girl assets failed to load.^7")
            return
        end

        cleanup()

        local ped = PlayerPedId()
        local fwd = GetEntityForwardVector(ped)
        local pos = GetEntityCoords(ped) + (fwd * 3.0)

        girl = CreatePed(4, spec.model, pos.x, pos.y, pos.z, 0.0, false, false)
        SetModelAsNoLongerNeeded(spec.model)
        if not heldEntity(girl) then girl = nil return end

        dress(girl, spec)

        SetEntityInvincible(girl, true)
        SetBlockingOfNonTemporaryEvents(girl, true)
        SetEntityHeading(girl, (GetEntityHeading(ped) + 180.0) % 360.0)

        -- Same pass-through as the real thing, so what is being scrubbed
        -- here behaves like what turns up on the grid.
        passThroughField(girl)
        keepAboveGround(generation, function() return false end)

        local len = GetAnimDuration(ANIM_DICT, ANIM_CLIP)
        if not len or len <= 0 then len = ANIM_FALLBACK end

        local phase = at and math.max(0.0, math.min(0.99, at / len)) or 0.0
        TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 0, phase, false, false, false)

        print(("^2[spz-races] %s/%s — length %.2fs, playing from %.2fs (phase %.4f).^7")
            :format(ANIM_DICT, ANIM_CLIP, len, phase * len, phase))
        print("^2[spz-races] Config.FlagAnimAfterGoMs sets how long after GO this starts.^7")
    end)
end, false)

-- Any exit from the race takes her with it. A cancelled or aborted start would
-- otherwise leave a ped standing in the middle of the road until a restart.
RegisterNetEvent("SPZ:tpToSafeZone", cleanup)
AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then cleanup() end
end)

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value == "IDLE" or value == "CLEANUP" then cleanup() end
end)
