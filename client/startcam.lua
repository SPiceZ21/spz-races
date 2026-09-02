-- client/startcam.lua
-- The camera move that opens a race.
--
-- Runs from the moment the grid is formed to the moment the lights go out: a
-- slow push down the centre line toward the front of the field, then a blend
-- back into the driver's own view on GO. The player is frozen for all of it
-- (SPZ:freezeRacer is asserted before SPZ:gridFormed is sent), so nothing is
-- taken away from them that they had — the alternative is staring at a
-- stationary bumper for the whole staging phase.
--
-- Two hard rules, both learned the expensive way in a racing HUD:
--
--   * the camera must ALWAYS be handed back. Every exit path here calls
--     release(), including the resource stopping mid-race, because a script cam
--     left rendering is a player with no way to see their own car.
--   * GO must never be blocked waiting on it. The blend back is asynchronous
--     and the race starts underneath it; a camera still interpolating is
--     cosmetic, a countdown that waits for one is not.

local CAM_HEIGHT_START = 3.2    -- metres up at the wide end
local CAM_HEIGHT_END   = 1.35   -- ...and at the close end, roughly bonnet height
local CAM_BACK_START   = 22.0   -- metres up the road, ahead of the grid
local CAM_BACK_END     = 9.0
local CAM_SIDE         = 4.5    -- offset off the centre line, so the shot is
                                -- three-quarter rather than dead-on
local FOV_START        = 50.0
local FOV_END          = 38.0

-- The push is NOT a fixed length. It runs the whole window the server gives
-- (staging + countdown), so it arrives at its closest framing exactly as the
-- lights go out — a 6.5s move inside a 3s staging phase was over before the
-- countdown even started, and the camera then sat still through the part that
-- mattered. Bounds only guard against a nonsensical config.
local MOVE_MS_MIN = 2500
local MOVE_MS_MAX = 30000
local BLEND_MS    = 900         -- hand-back at GO

local camA, camB = nil, nil
local active = false

local function destroyCam(cam)
    if cam and DoesCamExist(cam) then DestroyCam(cam, false) end
    return nil
end

-- Hand the view back to the game. Safe to call at any time, including when no
-- camera was ever created.
local function release(instant)
    if active then
        RenderScriptCams(false, not instant, instant and 0 or BLEND_MS, true, true)
        active = false
    end
    camA = destroyCam(camA)
    camB = destroyCam(camB)
end

RegisterNetEvent("SPZ:gridFormed", function(data)
    if not data or not data.coords then return end
    release(true)

    local c   = data.coords
    local rad = math.rad(data.heading or 0.0)
    local forward = vec3(-math.sin(rad), math.cos(rad), 0.0)
    local right   = vec3(math.cos(rad), math.sin(rad), 0.0)

    -- Both framings look back down the road at the grid from up ahead — the
    -- same direction the flag girl faces, so she is in shot on the way past.
    local wide  = c + (forward * CAM_BACK_START) + (right * CAM_SIDE) + vec3(0.0, 0.0, CAM_HEIGHT_START)
    local close = c + (forward * CAM_BACK_END)   + (right * (CAM_SIDE * 0.6)) + vec3(0.0, 0.0, CAM_HEIGHT_END)

    -- Aimed at the grid itself rather than at the player's own car: on a split
    -- grid the two packs straddle the centre line, and pointing at one of them
    -- puts the other out of frame.
    local look = c + vec3(0.0, 0.0, 1.0)

    camA = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA",
        wide.x, wide.y, wide.z, 0.0, 0.0, 0.0, FOV_START, false, 0)
    camB = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA",
        close.x, close.y, close.z, 0.0, 0.0, 0.0, FOV_END, false, 0)
    if not (camA and camB and DoesCamExist(camA) and DoesCamExist(camB)) then
        release(true)
        return
    end

    PointCamAtCoord(camA, look.x, look.y, look.z)
    PointCamAtCoord(camB, look.x, look.y, look.z)

    SetCamActive(camA, true)
    RenderScriptCams(true, false, 0, true, true)
    active = true

    -- The push itself, spanning the run-up to GO. Eased at both ends so it
    -- starts and settles rather than snapping into motion.
    local moveMs = tonumber(data.goInMs) or 14000
    if moveMs < MOVE_MS_MIN then moveMs = MOVE_MS_MIN end
    if moveMs > MOVE_MS_MAX then moveMs = MOVE_MS_MAX end

    SetCamActiveWithInterp(camB, camA, moveMs, 1, 1)
end)

-- GO hands the view back. Deliberately not awaited by anything — the race is
-- already live underneath the blend.
RegisterNetEvent("SPZ:go", function() release(false) end)

-- Every other way a race can end. A start that is cancelled, aborted or
-- restarted must not leave the player looking at the start line.
RegisterNetEvent("SPZ:tpToSafeZone", function() release(true) end)

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value == "IDLE" or value == "CLEANUP" or value == "LIVE" then release(false) end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then release(true) end
end)
