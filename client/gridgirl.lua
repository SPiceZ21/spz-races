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
-- It is played so that the FLAG DROP lands on GO. The clip's final seconds are
-- her walking off the road, and that walk-off is found by sampling the clip's
-- root motion (walkOffPhase, below). The drop sits a fixed beat before it, set
-- by Config.FlagAnimEndOffsetMs. After GO the clip simply carries on: she walks
-- off, and is removed when it runs out.
--
-- The clip is far longer than any start sequence, so it cannot be played from
-- the top — it is entered at whatever phase leaves exactly the remaining window
-- before the walk-off. That is the part that builds to the start.
--
-- Note what this does NOT need: a hand-measured timestamp inside the clip.
-- Both the clip length and the walk-off are read from the game.
local FLAG_END_OFFSET_MS = -3000 -- Config.FlagAnimEndOffsetMs: ms BEFORE GO the walk-off starts

-- ...and when it STARTS: this many milliseconds before the 3-2-1 begins. A lead
-- as long as staging has her performing from the moment the grid forms.
local FLAG_LEAD_MS = 9000       -- Config.FlagAnimLeadMs

-- How long she stays on her mark after GO, so she is not deleted out from under
-- the field as it launches past her.
local LINGER_MS = 5000

local ANIM_FALLBACK = 72.6      -- clip length, if GetAnimDuration is unavailable

-- ── Where the performance ends ───────────────────────────────────────────────
--
-- The clip does not end on the flag drop: its last few seconds are her walking
-- off the road. Timing the clip's END to GO therefore showed only that walk —
-- no routine, just a girl strolling away as the lights went out.
--
-- So the performance is timed to end where the walk-off BEGINS, and that point
-- is found from the clip itself rather than a hand-measured number: the root
-- motion is sampled across the clip, and the walk-off is the final continuous
-- stretch in which she is travelling. Everything before it is the routine.
local SAMPLE_STEP_S  = 0.25   -- seconds between root-motion samples
local WALK_SPEED_MPS = 0.4    -- faster than this counts as walking
local STILL_SAMPLES  = 3      -- this many slow samples in a row ends the walk

local walkOffCache = {}       -- [clipLen] = phase, computed once per clip

--- Phase (0..1) at which she starts walking off, or 1.0 if the clip ends still.
local function walkOffPhase(clipLen)
    if walkOffCache[clipLen] then return walkOffCache[clipLen] end

    local steps = math.floor(clipLen / SAMPLE_STEP_S)
    if steps < 2 then return 1.0 end

    local pos = {}
    for i = 0, steps do
        local p = GetAnimInitialOffsetPosition(ANIM_DICT, ANIM_CLIP,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0, i / steps, 2)
        pos[i] = p
    end

    local stepSec = clipLen / steps
    local function speedAt(i)
        local a, b = pos[i - 1], pos[i]
        return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) / stepSec
    end

    -- A clip that finishes standing has no walk-off to avoid.
    if speedAt(steps) < WALK_SPEED_MPS then
        walkOffCache[clipLen] = 1.0
        return 1.0
    end

    -- Walk back from the end through the moving stretch. It ends at the first
    -- run of STILL_SAMPLES slow samples, so a footfall that briefly slows the
    -- root does not cut it short.
    local start, still = steps, 0
    for i = steps, 1, -1 do
        if speedAt(i) >= WALK_SPEED_MPS then
            start, still = i - 1, 0
        else
            still = still + 1
            if still >= STILL_SAMPLES then break end
        end
    end

    local phase = start / steps
    walkOffCache[clipLen] = phase
    return phase
end

local girl = nil
local flagTimer = nil          -- token for the pending swing, so a restart cancels it

-- When her clip runs out (local timestamp), so she is removed after she has
-- finished walking off rather than mid-stride in front of the field.
local clipEndsAt = nil

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
    flagTimer  = nil
    clipEndsAt = nil
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

-- Runs until she is removed, including her walk-off after GO: that is exactly
-- when the field launches past her, so the collision pairs must stay fresh.
local function keepAboveGround(myGen)
    Citizen.CreateThread(function()
        while generation == myGen and heldEntity(girl) do
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

    -- When the lights go out, as a local timestamp. Everything below is timed
    -- backwards off this one number.
    local goAt = GetGameTimer() + (tonumber(data.goInMs) or 14000)

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
        keepAboveGround(myGen)

        -- ── The performance: starts before the count, ends on GO ────────
        --
        -- She idles on her mark through staging, starts the clip a beat before
        -- the 3-2-1 begins, and the clip runs out as the lights do.
        if not HasAnimDictLoaded(ANIM_DICT) then return end

        local countdownMs = (tonumber(data.countdown) or 5) * 1000
        local leadMs      = tonumber(Config and Config.FlagAnimLeadMs) or FLAG_LEAD_MS
        local startAt     = goAt - countdownMs - leadMs

        local waitMs = startAt - GetGameTimer()
        if waitMs > 0 then Citizen.Wait(waitMs) end
        if stale() or not heldEntity(girl) then return end

        -- The dict is re-requested here. It was loaded during staging and
        -- nothing pins it: streaming is free to evict an anim dict nobody is
        -- playing. It must be back BEFORE the clip is measured below —
        -- GetAnimDuration on an evicted dict returns 0, which used to drop the
        -- timing onto the 72.6s fallback for whatever clip was really loaded.
        RequestAnimDict(ANIM_DICT)
        local dictBy = GetGameTimer() + 1000
        while not HasAnimDictLoaded(ANIM_DICT) and GetGameTimer() < dictBy do
            Citizen.Wait(0)
        end
        if stale() or not heldEntity(girl) then return end
        if not HasAnimDictLoaded(ANIM_DICT) then
            print("^3[spz-races] Flag girl anim dict gone at GO — skipping the routine.^7")
            return
        end

        local clipLen = GetAnimDuration(ANIM_DICT, ANIM_CLIP)
        if not clipLen or clipLen <= 0 then clipLen = ANIM_FALLBACK end

        -- The walk-off is found from the clip; the flag drop sits a fixed beat
        -- before it. Config.FlagAnimEndOffsetMs is how long before GO the
        -- walk-off lands, so a NEGATIVE value puts it after GO — and at -3000
        -- the drop itself lands on the lights.
        local endPhase = walkOffPhase(clipLen)

        -- The window is measured HERE, on the frame the clip actually starts,
        -- not when it was scheduled. Streaming the model, waiting for collision
        -- and the idle above have all eaten real time, and a phase computed
        -- before any of that would overrun the lights by however long it took.
        local endLead   = tonumber(Config and Config.FlagAnimEndOffsetMs) or FLAG_END_OFFSET_MS
        local windowSec = ((goAt - endLead) - GetGameTimer()) / 1000
        if windowSec < 0.1 then windowSec = 0.1 end

        -- Enter at the phase that leaves exactly `window` of clip before the
        -- walk-off, so it lands where the offset says.
        local phase = endPhase - (windowSec / clipLen)
        if phase < 0.0 then phase = 0.0 end
        if phase > endPhase - 0.01 then phase = math.max(0.0, endPhase - 0.01) end

        -- Whatever ambient task the ped picked up has to go first. A ped created
        -- with CreatePed is handed one, and TaskPlayAnim landing on top of it is
        -- how you get a flag girl who wanders off mid-performance.
        ClearPedTasks(girl)

        -- Flag 2 = HOLD LAST FRAME. The clip plays through her walk-off after
        -- GO; with flag 0 the ped would be handed back to normal AI when it
        -- ends and wander. Holding the last frame leaves her standing where the
        -- walk-off put her until cleanup takes her.
        TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 2, phase, false, false, false)

        -- A task issued in the same frame as ClearPedTasks is occasionally
        -- dropped. Checking costs one Wait and turns a silent no-show into a
        -- second attempt.
        Citizen.Wait(150)
        if stale() or not heldEntity(girl) then return end

        if not IsEntityPlayingAnim(girl, ANIM_DICT, ANIM_CLIP, 3) then
            ClearPedTasks(girl)
            TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 2, phase, false, false, false)
            print("^3[spz-races] Flag girl anim did not take — retried.^7")
        end

        -- The clip started 150ms ago (the check above).
        clipEndsAt = GetGameTimer() - 150 + math.floor((1.0 - phase) * clipLen * 1000)

        print(("^2[spz-races] Flag girl: clip %.1fs, walk-off at %.1fs, entering at %.1fs, %.1fs to GO.^7")
            :format(clipLen, endPhase * clipLen, phase * clipLen, windowSec))
    end)
end)

-- GO. The flag has just dropped and the clip carries on into her walk-off. She
-- is neither frozen nor stripped of collision: the road has to keep holding her
-- up while she walks, and the field already passes through her (the pairs are
-- kept fresh by keepAboveGround). She is removed once the clip has run out.
local MAX_AFTER_GO_MS = 15000

RegisterNetEvent("SPZ:go", function()
    if not heldEntity(girl) then return end

    local waitMs = LINGER_MS
    if clipEndsAt then
        waitMs = math.max(LINGER_MS, clipEndsAt - GetGameTimer() + 500)
    end
    -- Waited long enough now that a new grid could have formed meanwhile; only
    -- remove the girl this GO belonged to.
    local myGen = generation
    Citizen.SetTimeout(math.min(waitMs, MAX_AFTER_GO_MS), function()
        if generation == myGen then cleanup() end
    end)
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
        keepAboveGround(generation)

        local len = GetAnimDuration(ANIM_DICT, ANIM_CLIP)
        if not len or len <= 0 then len = ANIM_FALLBACK end

        local walkAt = walkOffPhase(len) * len

        -- No argument: the last 14 seconds before the walk-off, which is what a
        -- default 9s stage + 5s count shows in a race.
        local from  = at or math.max(0.0, walkAt - 14.0)
        local phase = math.max(0.0, math.min(0.99, from / len))
        TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 0, phase, false, false, false)

        print(("^2[spz-races] %s/%s — length %.2fs, walk-off detected at %.2fs, playing from %.2fs.^7")
            :format(ANIM_DICT, ANIM_CLIP, len, walkAt, phase * len))
        print("^2[spz-races] In a race the flag drop (Config.FlagAnimEndOffsetMs before the walk-off) lands on GO.^7")
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
