-- client/checkpoints.lua
-- SPZ-Races checkpoint visualizer.
--
-- Visuals:
--   • Custom GATE PROPS (start / finish / checkpoint) at every gate post
--     (left+right) when the player is in range
--   • Numbered MINIMAP BLIPS, shade-graded by distance from active CP
--   • CP-controlled GPS ROUTE LINE on minimap (drawn via SetBlipRoute on the
--     active blip — NOT via player's M-key waypoint, so player can still set
--     their own waypoint without conflict, and we can't be overridden).
--
-- No 3D world cylinder checkpoints — hit detection lives in
-- client/hit_detector.lua (gate-radius distance check).

-- ── State ──────────────────────────────────────────────────────────────────
local CurrentCheckpoints = {}
local CurrentCPIndex     = 1
local RaceState          = "IDLE"
local TrackType          = "circuit"   -- "circuit" | "sprint"

-- ── Minimap blips ──────────────────────────────────────────────────────────
local AllBlips = {}

local SPRITE_PENDING = 1
local SPRITE_ACTIVE  = 164
local SPRITE_FINISH  = 38

local COLOUR_ACTIVE  = 17   -- bright orange — active (next) CP
local COLOUR_NEAR    = 4    -- white         — 1 CP ahead
local COLOUR_PENDING = 46   -- dark orange   — far CPs
local COLOUR_FINISH  = 2    -- green         — finish line

local SCALE_ACTIVE  = 1.1
local SCALE_NEAR    = 0.85
local SCALE_PENDING = 0.6
local SCALE_FINISH  = 1.5


-- ── Helpers ────────────────────────────────────────────────────────────────

local function _finishIdx(total)
    return TrackType == "circuit" and 1 or total
end

local function _nearIdx(idx, total)
    if idx < total then
        return idx + 1
    elseif TrackType == "circuit" then
        return 1
    end
    return nil
end

local function _cpLabel(idx, total)
    local fi = _finishIdx(total)
    if idx == 1 and TrackType == "circuit" then
        return "Start / Finish"
    elseif idx == 1 then
        return "Start"
    elseif idx == fi then
        return string.format("Finish (CP %d)", idx)
    else
        return string.format("CP %d", idx)
    end
end

-- Time Trial drives the same visuals outside of the race state machine
local TTMode = false

local function _isRaceActive()
    return TTMode
        or RaceState == "LIVE"
        or RaceState == "WARMUP"
        or RaceState == "COUNTDOWN"
        or RaceState == "STAGING"
end

-- ── Custom gate props (streamed from stream/, declared in fxmanifest) ───────
local PROP_START      = `bzzz_start_a`
local PROP_FINISH     = `bzzz_finish_a`
local PROP_CHECKPOINT = `bzzz_checkpoint_a`

local GateProps = {}   -- [cpIndex] = { left = handle, right = handle }

local function _gateModelFor(idx, total)
    -- Circuit: CP1 is the shared start/finish line → start post.
    -- Sprint: CP1 = start, last CP = finish, everything else = checkpoint.
    if idx == 1 then return PROP_START end
    if idx == _finishIdx(total) then return PROP_FINISH end
    return PROP_CHECKPOINT
end

local function _removeGate(idx)
    local g = GateProps[idx]
    if not g then return end
    if g.left  and DoesEntityExist(g.left)  then DeleteObject(g.left)  end
    if g.right and DoesEntityExist(g.right) then DeleteObject(g.right) end
    GateProps[idx] = nil
end

local function _clearAllGates()
    for idx in pairs(GateProps) do _removeGate(idx) end
    GateProps = {}
end

local function _gateHeading(idx, cp)
    -- Heading is stored per checkpoint by the creator/editor; fall back to
    -- aiming at the next checkpoint.
    if cp.heading then return cp.heading end
    local nxt = CurrentCheckpoints[_nearIdx(idx, #CurrentCheckpoints) or idx]
    if nxt and nxt ~= cp then
        return math.deg(math.atan(-(nxt.coords.x - cp.coords.x), nxt.coords.y - cp.coords.y)) % 360
    end
    return 0.0
end

local function _placeGateProp(model, pos, heading)
    local obj = CreateObject(model, pos.x, pos.y, pos.z, false, false, false)
    if obj == 0 then return nil end
    SetEntityHeading(obj, heading)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)   -- drive straight through the gate
    SetEntityAsMissionEntity(obj, true, true)
    return obj
end

local function _spawnGate(idx)
    if GateProps[idx] then return end

    local cp = CurrentCheckpoints[idx]
    if not cp then return end

    local model = _gateModelFor(idx, #CurrentCheckpoints)
    if not IsModelInCdimage(model) then return end   -- prop not streamed yet

    if not HasModelLoaded(model) then
        RequestModel(model)
        return   -- retry next proximity tick
    end

    local heading = _gateHeading(idx, cp)

    -- Posts sit at the gate edges, not the centre. The right-hand post is
    -- flipped 180° so both banners face the oncoming driver.
    local left  = cp.left  and _placeGateProp(model, cp.left,  heading) or nil
    local right = cp.right and _placeGateProp(model, cp.right, (heading + 180.0) % 360.0) or nil

    -- Gates without left/right data (older tracks) fall back to the centre.
    if not left and not right then
        left = _placeGateProp(model, cp.coords, heading)
    end

    if left or right then
        GateProps[idx] = { left = left, right = right }
    end
end
-- ── Minimap blips ──────────────────────────────────────────────────────────

local function _clearAllBlips()
    for _, blip in ipairs(AllBlips) do
        if DoesBlipExist(blip) then
            SetBlipRoute(blip, false)   -- tear down route line first
            RemoveBlip(blip)
        end
    end
    AllBlips = {}
end

local function _buildBlips(checkpoints)
    _clearAllBlips()
    local total = #checkpoints
    local fi    = _finishIdx(total)

    for i, cp in ipairs(checkpoints) do
        local blip     = AddBlipForCoord(cp.coords.x, cp.coords.y, cp.coords.z)
        local isFinish = (i == fi)

        SetBlipSprite(blip, isFinish and SPRITE_FINISH or SPRITE_PENDING)
        SetBlipColour(blip, isFinish and COLOUR_FINISH or COLOUR_PENDING)
        SetBlipScale(blip,  isFinish and SCALE_FINISH  or SCALE_PENDING)
        SetBlipAsShortRange(blip, not isFinish)
        SetBlipRoute(blip, false)

        if not isFinish then
            ShowNumberOnBlip(blip, i)
        end

        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(_cpLabel(i, total))
        EndTextCommandSetBlipName(blip)

        AllBlips[i] = blip
    end
end

local function _styleBlips(idx)
    local total = #CurrentCheckpoints
    if total == 0 then return end
    local fi   = _finishIdx(total)
    local near = _nearIdx(idx, total)

    for i, blip in ipairs(AllBlips) do
        if not DoesBlipExist(blip) then goto continue end

        local isFinish = (i == fi)
        local isActive = (i == idx)
        local isNear   = (near ~= nil) and (i == near) and not isFinish

        if isActive then
            -- Active (next) CP — orange diamond, GPS route line ON, orange route
            SetBlipSprite(blip,       SPRITE_ACTIVE)
            SetBlipColour(blip,       COLOUR_ACTIVE)
            SetBlipScale(blip,        SCALE_ACTIVE)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip,     10)
            SetBlipRoute(blip,        true)
            SetBlipRouteColour(blip,  COLOUR_ACTIVE)

        elseif isNear then
            -- Near (idx+1) — white dot, no route
            SetBlipSprite(blip,       SPRITE_PENDING)
            SetBlipColour(blip,       COLOUR_NEAR)
            SetBlipScale(blip,        SCALE_NEAR)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip,     5)
            SetBlipRoute(blip,        false)

        elseif isFinish then
            -- Finish — green big circle, no route (unless it's also active)
            SetBlipSprite(blip,       SPRITE_FINISH)
            SetBlipColour(blip,       COLOUR_FINISH)
            SetBlipScale(blip,        SCALE_FINISH)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip,     9)
            SetBlipRoute(blip,        false)

        else
            -- Far CPs — dark orange dot, short range, no route
            SetBlipSprite(blip,       SPRITE_PENDING)
            SetBlipColour(blip,       COLOUR_PENDING)
            SetBlipScale(blip,        SCALE_PENDING)
            SetBlipAsShortRange(blip, true)
            SetBlipPriority(blip,     1)
            SetBlipRoute(blip,        false)
        end
        ::continue::
    end
end

-- Route enforcer — re-asserts SetBlipRoute on active CP every 2s in case
-- something external clears it (other resources, scope changes, etc.).
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(2000)
        if not _isRaceActive() then goto continue end

        local activeBlip = AllBlips[CurrentCPIndex]
        if activeBlip and DoesBlipExist(activeBlip) then
            if not IsBlipShortRange(activeBlip) then
                -- Re-enable route in case it got cleared
                SetBlipRoute(activeBlip,       true)
                SetBlipRouteColour(activeBlip, COLOUR_ACTIVE)
            end
        end

        ::continue::
    end
end)

-- Proximity thread — every 500 ms, keep gate props spawned at every CP within
-- Config.GateRange and removed beyond it.
Citizen.CreateThread(function()
    while true do
        if _isRaceActive() and #CurrentCheckpoints > 0 then
            local playerPos = GetEntityCoords(PlayerPedId())
            local range     = (Config and Config.GateRange) or 130.0
            local range2    = range * range

            for i, cp in ipairs(CurrentCheckpoints) do
                local dx    = playerPos.x - cp.coords.x
                local dy    = playerPos.y - cp.coords.y
                local dist2 = dx*dx + dy*dy

                if dist2 <= range2 then
                    _spawnGate(i)      -- custom start / finish / checkpoint prop
                else
                    _removeGate(i)
                end
            end

            Citizen.Wait(500)
        else
            _clearAllGates()
            Citizen.Wait(1000)
        end
    end
end)

-- ── Apply active CP state ──────────────────────────────────────────────────

local function _applyActive(idx)
    _styleBlips(idx)
end

-- ── Net events ─────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, startIdx, trackType)
    print(string.format("[Checkpoints] Loading %d checkpoints (type: %s)", #checkpoints, trackType or "circuit"))
    _clearAllGates()   -- drop the previous track's gate props

    TrackType          = trackType or "circuit"
    CurrentCheckpoints = checkpoints
    CurrentCPIndex     = startIdx or 1

    _buildBlips(checkpoints)
    _applyActive(CurrentCPIndex)
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(newIndex)
    -- Periodic resyncs re-send the CURRENT index — only chime and restyle
    -- when the checkpoint actually advanced.
    if newIndex == CurrentCPIndex then return end
    CurrentCPIndex = newIndex
    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    _applyActive(CurrentCPIndex)
end)

RegisterNetEvent("SPZ:lapComplete", function(lapNum, lapTimeMs)
    PlaySoundFrontend(-1, "CHECKPOINT_UNDER_THE_BRIDGE_STUNT", "HUD_MINI_GAME_SOUNDSET", 1)
end)

-- ── Race lifecycle ─────────────────────────────────────────────────────────

local function _onRaceStateChange(newState)
    RaceState = newState
    if newState == "IDLE" or newState == "CLEANUP" then
            _clearAllGates()
        _clearAllBlips()
        CurrentCheckpoints = {}
        CurrentCPIndex     = 1
    end
end

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _onRaceStateChange(value) end
end)

Citizen.CreateThread(function()
    Citizen.Wait(0)
    local s = GlobalState.raceState
    if s then _onRaceStateChange(s) end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then
            _clearAllGates()
        _clearAllBlips()
    end
end)

-- ── Exports ────────────────────────────────────────────────────────────────

exports("GetCurrentCP", function()
    return CurrentCheckpoints[CurrentCPIndex], CurrentCPIndex
end)

exports("GetRaceState", function()
    return RaceState
end)

-- ── Time Trial reuse ───────────────────────────────────────────────────────
-- Lets spz-races/client/timetrail.lua drive the exact same visuals (custom
-- gate props + numbered blips + GPS route) without the race state machine.

exports("StartCheckpointVisuals", function(checkpoints, startIdx, trackType)
    _clearAllGates()
    TrackType          = trackType or "circuit"
    CurrentCheckpoints = checkpoints or {}
    CurrentCPIndex     = startIdx or 1
    TTMode             = true
    _buildBlips(CurrentCheckpoints)
    _applyActive(CurrentCPIndex)
end)

exports("SetActiveCheckpoint", function(idx)
    if not idx then return end
    CurrentCPIndex = idx
    _applyActive(CurrentCPIndex)
end)

exports("StopCheckpointVisuals", function()
    TTMode = false
    _clearAllGates()
    _clearAllBlips()
    CurrentCheckpoints = {}
    CurrentCPIndex     = 1
end)

exports("IsCheckpointVisualsActive", function()
    return _isRaceActive() and #CurrentCheckpoints > 0
end)
