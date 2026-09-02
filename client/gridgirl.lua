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

local PED_MODEL  = `g_f_y_lost_01`
local ANIM_DICT  = "random@street_race"
local ANIM_CLIP  = "grid_girl_race_start"

-- Where she comes from and where she ends up, both relative to the start point
-- and expressed in the grid's own frame: +right is the passenger side of the
-- field, +forward is down the track.
local WALK_IN_SIDE   = 9.0   -- metres off to the side she starts from
local WALK_IN_AHEAD  = 4.0   -- ...and how far up the road, so she crosses in
local MARK_AHEAD     = 6.0   -- her mark, up the road from the start line

-- The walk is fitted to the time available rather than run at a fixed speed:
-- the start sequence is configurable (Config.StagingTimeSeconds +
-- Config.CountdownSeconds) and a fixed 1.2 m/s stroll simply did not arrive in
-- time on a short one — she was still walking when the lights went out.
--
-- So the server says when GO is, the wind-up is reserved out of that, and
-- whatever is left is the walk. The speed is clamped at both ends: too slow
-- and she drifts, too fast and a walk cycle turns into a moonwalk.
local WALK_SPEED_MIN = 0.9
local WALK_SPEED_MAX = 2.2
local ARRIVE_MARGIN_MS = 700   -- settle on the mark before the wind-up starts

-- `grid_girl_race_start` is 72.6 seconds / 1480 frames: a whole performance —
-- idling, playing to the grid, and somewhere inside it the actual drop — not a
-- three second swing. Two consequences, and both used to be wrong here:
--
--   * it cannot be reserved wholesale ahead of GO. Doing that left a negative
--     walk window on any sane start sequence, so she snapped to her mark and
--     began the clip immediately, putting the drop about a minute AFTER the
--     lights.
--   * it has to be entered PART WAY THROUGH. The drop is at some phase inside
--     the clip, and the only way to land it on GO is to start playing at
--     (drop − lead) and let it run.
--
-- Which frame the drop is on cannot be read off the file from here, so it is
-- config rather than a guess baked into the code: set Config.FlagAnimDropTime
-- to the time in seconds at which she actually drops her arms, and the wind-up
-- is scheduled backwards from it. Use /flagdrop (below) to find it.
--
-- Left unset, she simply performs the clip from the top while the grid forms,
-- which is a flag girl doing her job in the middle of the road — just not one
-- whose swing is synchronised to the lights.
local FLAG_LEAD_MS   = 2500    -- visible wind-up before the drop
local ANIM_FALLBACK  = 72.6    -- clip length, if GetAnimDuration is unavailable

local girl = nil
local flagTimer = nil          -- token for the pending swing, so a restart cancels it

local function heldEntity(e) return e and e ~= 0 and DoesEntityExist(e) end

local function cleanup()
    -- Invalidate any scheduled swing first: a timer that fires after the ped is
    -- gone is harmless, but one that fires into the NEXT race's ped is not.
    flagTimer = nil
    if heldEntity(girl) then
        SetEntityAsMissionEntity(girl, true, true)
        DeleteEntity(girl)
    end
    girl = nil
end

-- Model + anim dict, or nil if either never streams in. Everything downstream
-- is skipped rather than half-done: a T-posing ped standing on the start line
-- is worse than no ped at all.
local function loadAssets()
    RequestModel(PED_MODEL)
    RequestAnimDict(ANIM_DICT)

    local deadline = GetGameTimer() + 5000
    while (not HasModelLoaded(PED_MODEL) or not HasAnimDictLoaded(ANIM_DICT))
      and GetGameTimer() < deadline do
        Citizen.Wait(50)
    end

    return HasModelLoaded(PED_MODEL) and HasAnimDictLoaded(ANIM_DICT)
end

-- Ground the point she walks to. The start coordinate is the vehicle grid's
-- Z, which is wheel height on the road surface; dropping a ped straight onto it
-- is close enough everywhere flat and visibly wrong on camber.
local function groundZ(x, y, z)
    local ok, gz = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
    return ok and gz or z
end

RegisterNetEvent("SPZ:gridFormed", function(data)
    if not data or not data.coords then return end
    cleanup()

    local c   = data.coords
    local rad = math.rad(data.heading or 0.0)
    local forward = vec3(-math.sin(rad), math.cos(rad), 0.0)
    local right   = vec3(math.cos(rad), math.sin(rad), 0.0)

    -- Her mark is UP the road from the start line, not on it: standing level
    -- with the front row would put her inside the two packs rather than in
    -- front of them, and out of shot for the cars on the far side.
    local mark  = c + (forward * MARK_AHEAD)
    local entry = c + (forward * WALK_IN_AHEAD) + (right * WALK_IN_SIDE)

    local goAt = GetGameTimer() + (tonumber(data.goInMs) or 14000)

    Citizen.CreateThread(function()
        if not loadAssets() then
            print("^3[spz-races] Flag girl assets did not stream in — skipping.^7")
            return
        end

        local ex, ey = entry.x, entry.y
        local ez = groundZ(ex, ey, entry.z)

        girl = CreatePed(4, PED_MODEL, ex, ey, ez, 0.0, false, false)
        SetModelAsNoLongerNeeded(PED_MODEL)
        if not heldEntity(girl) then girl = nil return end

        -- She is scenery. Nothing in the race may knock her over, and she must
        -- not react to sixteen engines revving in her face and run away — which
        -- is exactly what an ambient ped does when a car aims at her.
        SetEntityInvincible(girl, true)
        SetBlockingOfNonTemporaryEvents(girl, true)
        SetPedCanRagdoll(girl, false)
        SetPedCanBeTargetted(girl, false)
        SetPedConfigFlag(girl, 17, true)    -- never leaves its assigned area
        SetPedConfigFlag(girl, 128, true)   -- ignores combat / danger reactions
        SetEntityNoCollisionEntity(girl, PlayerPedId(), true)

        -- Only the WIND-UP is reserved, never the whole clip — see the note on
        -- FLAG_LEAD_MS. Whatever is left over is the walk.
        local walkMs = (goAt - GetGameTimer()) - FLAG_LEAD_MS - ARRIVE_MARGIN_MS

        -- Walk in from the side, at whatever pace lands her on the mark in
        -- time. A window too short for any credible walk (someone set the
        -- staging phase to a second or two) puts her straight on the mark
        -- rather than sprinting across the shot.
        local mx, my = mark.x, mark.y
        local mz = groundZ(mx, my, mark.z)
        local walkDist = #(vec3(mx, my, mz) - vec3(ex, ey, ez))

        local arrived = false
        if walkMs > 800 then
            local speed = walkDist / (walkMs / 1000)
            if speed < WALK_SPEED_MIN then speed = WALK_SPEED_MIN end
            if speed <= WALK_SPEED_MAX then
                TaskGoStraightToCoord(girl, mx, my, mz, speed, -1, 0.0, 0.0)

                -- Hold until she is there or her share of the window is spent.
                local arriveBy = GetGameTimer() + walkMs
                while heldEntity(girl) and GetGameTimer() < arriveBy do
                    if #(GetEntityCoords(girl) - vec3(mx, my, mz)) < 1.0 then
                        arrived = true
                        break
                    end
                    Citizen.Wait(100)
                end
            end
        end
        if not heldEntity(girl) then return end

        -- On the mark and facing back down the grid: she came from up the road,
        -- so her heading is the start heading reversed. Snapped rather than
        -- eased — an off-mark flag girl is more obviously wrong than a
        -- teleported one, and the walk has already sold the arrival.
        ClearPedTasks(girl)
        SetEntityCoordsNoOffset(girl, mx, my, mz, false, false, false)
        SetEntityHeading(girl, ((data.heading or 0.0) + 180.0) % 360.0)
        if not arrived and walkMs > 800 then
            print("^3[spz-races] Flag girl did not reach her mark in time — snapped to it.^7")
        end

        -- Enter the clip so the DROP lands on GO.
        --
        -- Guarded by a token so a race cancelled between here and the lights
        -- does not animate a ped that has already been cleaned up — or, worse,
        -- the next race's.
        local token = {}
        flagTimer = token

        local clipLen = GetAnimDuration(ANIM_DICT, ANIM_CLIP)
        if not clipLen or clipLen <= 0 then clipLen = ANIM_FALLBACK end

        local dropAt = tonumber(Config and Config.FlagAnimDropTime)
        if dropAt then
            -- Enter `lead` before the drop, so the wind-up is visible and the
            -- drop itself coincides with the lights.
            --
            -- A drop nearer the start of the clip than the lead cannot have the
            -- full wind-up, so the lead is shortened to whatever run-up exists
            -- rather than clamping the phase to 0 — clamping kept the entry
            -- time and lost the difference, firing the drop early.
            local leadMs = math.min(FLAG_LEAD_MS, math.floor(dropAt * 1000))
            local phase  = (dropAt - leadMs / 1000) / clipLen
            if phase < 0.0 then phase = 0.0 end
            if phase > 0.99 then phase = 0.99 end

            local waitMs = goAt - leadMs - GetGameTimer()
            if waitMs < 0 then waitMs = 0 end

            Citizen.SetTimeout(waitMs, function()
                if flagTimer ~= token or not heldEntity(girl) then return end
                if HasAnimDictLoaded(ANIM_DICT) then
                    TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 0, phase, false, false, false)
                end
            end)
        else
            -- Drop point unknown: perform the clip from the top for the whole
            -- run-up. Not synchronised to the lights, but a flag girl going
            -- through her routine beats one standing to attention.
            if HasAnimDictLoaded(ANIM_DICT) then
                TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 0, 0.0, false, false, false)
            end
        end
    end)
end)

-- GO. The swing is already running and lands about now; all that is left is to
-- take her off the road once the field has gone past.
RegisterNetEvent("SPZ:go", function()
    if not heldEntity(girl) then return end
    Citizen.SetTimeout(5000, cleanup)
end)

-- ── Finding the drop frame ───────────────────────────────────────────────────
-- /flagdrop [seconds]
--
-- Spawns her in front of you and plays the clip from `seconds` in, printing the
-- phase it maps to. Scrub until you see the arms come down, then put that time
-- in Config.FlagAnimDropTime and the swing lands on the lights.
--
-- With no argument it plays from the top and prints the clip's real length, so
-- the 72.6s figure can be confirmed against whatever the game actually loads.
RegisterCommand("flagdrop", function(_, args)
    local at = tonumber(args[1])

    Citizen.CreateThread(function()
        if not loadAssets() then
            print("^1[spz-races] Flag girl assets failed to load.^7")
            return
        end

        cleanup()

        local ped = PlayerPedId()
        local fwd = GetEntityForwardVector(ped)
        local pos = GetEntityCoords(ped) + (fwd * 3.0)

        girl = CreatePed(4, PED_MODEL, pos.x, pos.y, pos.z, 0.0, false, false)
        SetModelAsNoLongerNeeded(PED_MODEL)
        if not heldEntity(girl) then girl = nil return end

        SetEntityInvincible(girl, true)
        SetBlockingOfNonTemporaryEvents(girl, true)
        SetEntityHeading(girl, (GetEntityHeading(ped) + 180.0) % 360.0)

        local len = GetAnimDuration(ANIM_DICT, ANIM_CLIP)
        if not len or len <= 0 then len = ANIM_FALLBACK end

        local phase = at and math.max(0.0, math.min(0.99, at / len)) or 0.0
        TaskPlayAnim(girl, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 0, phase, false, false, false)

        print(("^2[spz-races] %s/%s — length %.2fs, playing from %.2fs (phase %.4f).^7")
            :format(ANIM_DICT, ANIM_CLIP, len, phase * len, phase))
        print("^2[spz-races] Note the time the arms drop, then set Config.FlagAnimDropTime to it.^7")
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
