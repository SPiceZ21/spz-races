-- client/startcam.lua
-- The camera move that opens a race.
--
-- Runs from the moment the grid is formed to the moment the lights go out: a
-- slow push in from BEHIND the field, up the centre line and toward the flag
-- girl, settling just behind the grid — where the player's own car sits in the
-- foreground and she is framed beyond it, both in one clean shot. Then a blend
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

-- The move runs from behind the field to just behind it, travelling FORWARD up
-- the centre line toward the flag girl. Offsets are in the grid's own frame:
-- +forward is down the track, +right is the passenger side.
--
-- It used to run the other way — starting up the road ahead of the grid and
-- looking back at it — which framed the field but put the flag girl's back to
-- the camera and never showed what the driver was about to look at. Coming in
-- from behind instead means the car is always in the foreground and she is
-- always beyond it, which is the shot: car, road, starter.
local CAM_FWD_START    = -20.0  -- metres BEHIND the grid at the wide end
local CAM_FWD_END      = -5.0   -- ...and where it settles, just off the tail
local CAM_HEIGHT_START = 5.5    -- high and back, looking over the field
local CAM_HEIGHT_END   = 1.9    -- down to just above roof height
local CAM_SIDE_START   = 3.0    -- slight three-quarter, not dead-on...
local CAM_SIDE_END     = 1.6    -- ...easing toward the centre line as it closes
local FOV_START        = 55.0
local FOV_END          = 42.0

-- Where she stands, from client/gridgirl.lua (MARK_AHEAD). The camera looks at
-- her the whole way in, so the two files have to agree on where she is.
local GIRL_AHEAD       = 6.0
local LOOK_HEIGHT      = 1.1    -- chest height on her mark

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

    -- Both framings sit BEHIND the grid and look forward past it, so the move
    -- is a push in toward the start line rather than a pull back off it.
    local wide  = c + (forward * CAM_FWD_START) + (right * CAM_SIDE_START) + vec3(0.0, 0.0, CAM_HEIGHT_START)
    local close = c + (forward * CAM_FWD_END)   + (right * CAM_SIDE_END)   + vec3(0.0, 0.0, CAM_HEIGHT_END)

    -- Aimed at the flag girl on her mark, which is also straight up the centre
    -- line: on a split grid the two packs straddle that line, so both are in
    -- frame on the way in, and the shot settles on the person about to start
    -- the race.
    local look = c + (forward * GIRL_AHEAD) + vec3(0.0, 0.0, LOOK_HEIGHT)

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
