-- client/checkpoints.lua
-- Invisible checkpoints: no cylinders, no gate props.
-- Gate positions are marked by always-on looped particle flares that appear
-- whenever the player is within Config.FlareRange metres of a checkpoint.
-- Active (next) checkpoint uses a larger flare scale; others use a smaller scale.

local CurrentCheckpoints = {}
local CurrentCPIndex     = 1
local RaceState          = "IDLE"
local TrackType          = "circuit"   -- "circuit" | "sprint"

-- ── Blips ──────────────────────────────────────────────────────────────────
local AllBlips  = {}
local RouteBlip = nil

local SPRITE_PENDING = 1
local SPRITE_ACTIVE  = 164
local SPRITE_FINISH  = 458
local COLOUR_ACTIVE  = 17   -- orange/gold
local COLOUR_PENDING = 4    -- white
local COLOUR_FINISH  = 2    -- green
local SCALE_ACTIVE   = 1.1
local SCALE_PENDING  = 0.6

-- ── GPS route ──────────────────────────────────────────────────────────────
local GpsActive = false

-- ── Proximity flares ───────────────────────────────────────────────────────
-- Looped particle effects that stay on while the player is within range.
-- Each entry: FlareHandles[cpIndex] = { left=handle, right=handle, scale=number }
local FlareHandles = {}

local PTFX_ASSET      = "core"
local PTFX_EFFECT     = "exp_grd_flare"
local PTFX_SCALE_NEXT = 1.0    -- active / next checkpoint flare size
local PTFX_SCALE_NEAR = 0.45   -- other checkpoints within range

-- ── Helpers ────────────────────────────────────────────────────────────────

local function _finishIdx(total)
    return TrackType == "circuit" and 1 or total
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

-- ── Blips ──────────────────────────────────────────────────────────────────

local function _clearAllBlips()
    for _, blip in ipairs(AllBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    AllBlips = {}

    if RouteBlip and DoesBlipExist(RouteBlip) then
        RemoveBlip(RouteBlip)
        RouteBlip = nil
    end
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
        SetBlipScale(blip, SCALE_PENDING)
        SetBlipAsShortRange(blip, true)

        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(_cpLabel(i, total))
        EndTextCommandSetBlipName(blip)

        AllBlips[i] = blip
    end
end

local function _setActiveBlip(idx)
    local total = #CurrentCheckpoints
    if total == 0 then return end
    local fi = _finishIdx(total)

    for i, blip in ipairs(AllBlips) do
        if not DoesBlipExist(blip) then goto continue end
        local isFinish = (i == fi)
        if i == idx then
            SetBlipSprite(blip,   SPRITE_ACTIVE)
            SetBlipColour(blip,   COLOUR_ACTIVE)
            SetBlipScale(blip,    SCALE_ACTIVE)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip, 10)
        elseif isFinish then
            SetBlipSprite(blip,   SPRITE_FINISH)
            SetBlipColour(blip,   COLOUR_FINISH)
            SetBlipScale(blip,    SCALE_ACTIVE)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip, 9)
        else
            SetBlipSprite(blip,   SPRITE_PENDING)
            SetBlipColour(blip,   COLOUR_PENDING)
            SetBlipScale(blip,    SCALE_PENDING)
            SetBlipAsShortRange(blip, true)
            SetBlipPriority(blip, 1)
        end
        ::continue::
    end

    local cp = CurrentCheckpoints[idx]
    if cp then
        if RouteBlip and DoesBlipExist(RouteBlip) then
            SetBlipCoords(RouteBlip, cp.coords.x, cp.coords.y, cp.coords.z)
        else
            RouteBlip = AddBlipForCoord(cp.coords.x, cp.coords.y, cp.coords.z)
            SetBlipSprite(RouteBlip, 8)
            SetBlipColour(RouteBlip, COLOUR_ACTIVE)
            SetBlipScale(RouteBlip, 0.0)
            SetBlipRoute(RouteBlip, true)
            SetBlipRouteColour(RouteBlip, COLOUR_ACTIVE)
            SetBlipAsShortRange(RouteBlip, false)
        end
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(_cpLabel(idx, #CurrentCheckpoints))
        EndTextCommandSetBlipName(RouteBlip)
    end
end

-- ── GPS multi-route ────────────────────────────────────────────────────────

local function _buildGpsRoute(checkpoints, fromIdx)
    if GpsActive then
        ClearGpsMultiRoute()
    end
    StartGpsMultiRoute((Config and Config.GpsRouteColour) or 51, false, false)
    for i = fromIdx, #checkpoints do
        local cp = checkpoints[i]
        AddPointToGpsMultiRoute(cp.coords.x, cp.coords.y, cp.coords.z or 0.0)
    end
    -- For circuits, loop back to CP1 (start/finish line)
    if TrackType == "circuit" and fromIdx > 1 then
        local finish = checkpoints[1]
        AddPointToGpsMultiRoute(finish.coords.x, finish.coords.y, finish.coords.z or 0.0)
    end
    SetGpsMultiRouteRender(true, 16, 16)
    GpsActive = true
end

local function _clearGpsRoute()
    if GpsActive then
        ClearGpsMultiRoute()
        GpsActive = false
    end
end

-- ── Proximity flares ───────────────────────────────────────────────────────

-- Stop and remove flare handles for a single checkpoint.
local function _stopFlare(cpIndex)
    local h = FlareHandles[cpIndex]
    if not h then return end
    if h.left  and DoesParticleFxLoopedExist(h.left)  then StopParticleFxLooped(h.left,  false) end
    if h.right and DoesParticleFxLoopedExist(h.right) then StopParticleFxLooped(h.right, false) end
    FlareHandles[cpIndex] = nil
end

-- Stop all active flares (called on race end / cleanup).
local function _clearAllFlares()
    for idx in pairs(FlareHandles) do
        _stopFlare(idx)
    end
end

-- Returns true if cpIndex already has a live flare at the expected scale.
local function _flareOk(cpIndex, scale)
    local h = FlareHandles[cpIndex]
    if not h then return false end
    if h.scale ~= scale then return false end  -- scale changed (active CP changed)
    local leftOk  = (h.left  == nil) or DoesParticleFxLoopedExist(h.left)
    local rightOk = (h.right == nil) or DoesParticleFxLoopedExist(h.right)
    return leftOk and rightOk
end

-- Start (or restart) the looped flare at a checkpoint gate.
local function _startFlare(cpIndex, scale)
    _stopFlare(cpIndex)   -- tear down any existing handles first

    if not HasNamedPtfxAssetLoaded(PTFX_ASSET) then
        RequestNamedPtfxAsset(PTFX_ASSET)
        return  -- will retry next proximity tick
    end

    local cp = CurrentCheckpoints[cpIndex]
    if not cp then return end

    local lh, rh

    if cp.left then
        UseParticleFxAssetNextCall(PTFX_ASSET)
        lh = StartParticleFxLoopedAtCoord(PTFX_EFFECT,
            cp.left.x,  cp.left.y,  cp.left.z,
            0.0, 0.0, 0.0, scale, false, false, false, 0)
        if lh == 0 then lh = nil end
    end

    if cp.right then
        UseParticleFxAssetNextCall(PTFX_ASSET)
        rh = StartParticleFxLoopedAtCoord(PTFX_EFFECT,
            cp.right.x, cp.right.y, cp.right.z,
            0.0, 0.0, 0.0, scale, false, false, false, 0)
        if rh == 0 then rh = nil end
    end

    if lh or rh then
        FlareHandles[cpIndex] = { left = lh, right = rh, scale = scale }
    end
end

-- Proximity thread — updates which flares are active every 500 ms.
-- Active states: LIVE, WARMUP, COUNTDOWN, STAGING
Citizen.CreateThread(function()
    while true do
        local active = #CurrentCheckpoints > 0
            and (RaceState == "LIVE"
              or RaceState == "WARMUP"
              or RaceState == "COUNTDOWN"
              or RaceState == "STAGING")

        if active then
            -- Ensure ptfx asset is requested (loads asynchronously)
            if not HasNamedPtfxAssetLoaded(PTFX_ASSET) then
                RequestNamedPtfxAsset(PTFX_ASSET)
            end

            local playerPos = GetEntityCoords(PlayerPedId())
            local range     = (Config and Config.FlareRange) or 130.0
            local range2    = range * range

            for i, cp in ipairs(CurrentCheckpoints) do
                local dx    = playerPos.x - cp.coords.x
                local dy    = playerPos.y - cp.coords.y
                local dist2 = dx*dx + dy*dy

                if dist2 <= range2 then
                    local scale = (i == CurrentCPIndex) and PTFX_SCALE_NEXT or PTFX_SCALE_NEAR
                    if not _flareOk(i, scale) then
                        _startFlare(i, scale)
                    end
                else
                    _stopFlare(i)
                end
            end

            Citizen.Wait(500)
        else
            _clearAllFlares()
            Citizen.Wait(1000)
        end
    end
end)

-- ── Net events ─────────────────────────────────────────────────────────────

-- Full track loaded (server sends this during WARMUP / COUNTDOWN)
RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, startIdx, trackType)
    print(string.format("[Checkpoints] Loading %d checkpoints (type: %s)", #checkpoints, trackType or "circuit"))
    _clearAllFlares()

    TrackType          = trackType or "circuit"
    CurrentCheckpoints = checkpoints
    CurrentCPIndex     = startIdx or 1

    _buildBlips(checkpoints)
    _setActiveBlip(CurrentCPIndex)
    _buildGpsRoute(checkpoints, CurrentCPIndex)

    -- Pre-request ptfx asset so flares start quickly once player is in range
    if not HasNamedPtfxAssetLoaded(PTFX_ASSET) then
        RequestNamedPtfxAsset(PTFX_ASSET)
    end
end)

-- Player hit a checkpoint — advance indicator, rebuild GPS route.
-- No on-hit flare needed: flares are always-on within range.
RegisterNetEvent("SPZ:nextCheckpoint", function(newIndex)
    CurrentCPIndex = newIndex

    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    _setActiveBlip(CurrentCPIndex)
    _buildGpsRoute(CurrentCheckpoints, CurrentCPIndex)

    -- Scale refresh: let proximity thread pick up new active CP on next tick.
    -- Force it by invalidating all current flare scale entries.
    for idx in pairs(FlareHandles) do
        FlareHandles[idx].scale = -1   -- mark stale; _flareOk() will return false
    end
end)

-- Lap complete — GPS route is rebuilt by SPZ:nextCheckpoint that fires right after.
RegisterNetEvent("SPZ:lapComplete", function(lapNum, lapTimeMs)
    PlaySoundFrontend(-1, "CHECKPOINT_UNDER_THE_BRIDGE_STUNT", "HUD_MINI_GAME_SOUNDSET", 1)
end)

-- Race state changed (native statebag)
local function _onRaceStateChange(newState)
    RaceState = newState
    if newState == "IDLE" or newState == "CLEANUP" then
        _clearAllFlares()
        _clearAllBlips()
        _clearGpsRoute()
        CurrentCheckpoints = {}
        CurrentCPIndex     = 1
    end
end

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _onRaceStateChange(value) end
end)

-- Seed from current GlobalState on load
Citizen.CreateThread(function()
    Citizen.Wait(0)
    local s = GlobalState.raceState
    if s then _onRaceStateChange(s) end
end)

-- ── Exports ────────────────────────────────────────────────────────────────

exports("GetCurrentCP", function()
    return CurrentCheckpoints[CurrentCPIndex], CurrentCPIndex
end)

exports("GetRaceState", function()
    return RaceState
end)
