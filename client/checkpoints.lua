-- client/checkpoints.lua
-- SPZ-Races checkpoint visualizer.
--
-- Visuals:
--   • Particle FLARES at every gate (left+right) when player in range
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

-- ── Proximity flares ───────────────────────────────────────────────────────
local FlareHandles = {}   -- [cpIndex] = { left=handle, right=handle, scale=number }

local PTFX_ASSET      = "core"
local PTFX_EFFECT     = "exp_grd_flare"
local PTFX_SCALE_NEXT = 1.0    -- flare scale at active CP
local PTFX_SCALE_NEAR = 0.45   -- flare scale at all other in-range CPs

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

local function _isRaceActive()
    return RaceState == "LIVE"
        or RaceState == "WARMUP"
        or RaceState == "COUNTDOWN"
        or RaceState == "STAGING"
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

-- ── Particle flares (per-gate looped ptfx) ─────────────────────────────────

local function _stopFlare(cpIndex)
    local h = FlareHandles[cpIndex]
    if not h then return end
    if h.left  and DoesParticleFxLoopedExist(h.left)  then StopParticleFxLooped(h.left,  false) end
    if h.right and DoesParticleFxLoopedExist(h.right) then StopParticleFxLooped(h.right, false) end
    FlareHandles[cpIndex] = nil
end

local function _clearAllFlares()
    for idx in pairs(FlareHandles) do
        _stopFlare(idx)
    end
end

local function _flareOk(cpIndex, scale)
    local h = FlareHandles[cpIndex]
    if not h then return false end
    if h.scale ~= scale then return false end
    local leftOk  = (h.left  == nil) or DoesParticleFxLoopedExist(h.left)
    local rightOk = (h.right == nil) or DoesParticleFxLoopedExist(h.right)
    return leftOk and rightOk
end

local function _startFlare(cpIndex, scale)
    _stopFlare(cpIndex)

    if not HasNamedPtfxAssetLoaded(PTFX_ASSET) then
        RequestNamedPtfxAsset(PTFX_ASSET)
        return   -- retry next proximity tick
    end

    local cp = CurrentCheckpoints[cpIndex]
    if not cp then return end

    local lh, rh

    if cp.left then
        UseParticleFxAssetNextCall(PTFX_ASSET)
        lh = StartParticleFxLoopedAtCoord(PTFX_EFFECT,
            cp.left.x, cp.left.y, cp.left.z,
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

-- Proximity thread — every 500 ms, ensure flares are lit at every CP within
-- Config.FlareRange, with the active CP at full scale and others at near scale.
Citizen.CreateThread(function()
    while true do
        if _isRaceActive() and #CurrentCheckpoints > 0 then
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

-- ── Apply active CP state ──────────────────────────────────────────────────

local function _applyActive(idx)
    _styleBlips(idx)
    -- Invalidate flare scales so proximity thread rebuilds at new active CP
    for k in pairs(FlareHandles) do
        FlareHandles[k].scale = -1
    end
end

-- ── Net events ─────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, startIdx, trackType)
    print(string.format("[Checkpoints] Loading %d checkpoints (type: %s)", #checkpoints, trackType or "circuit"))
    _clearAllFlares()

    TrackType          = trackType or "circuit"
    CurrentCheckpoints = checkpoints
    CurrentCPIndex     = startIdx or 1

    _buildBlips(checkpoints)
    _applyActive(CurrentCPIndex)

    if not HasNamedPtfxAssetLoaded(PTFX_ASSET) then
        RequestNamedPtfxAsset(PTFX_ASSET)
    end
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(newIndex)
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
        _clearAllFlares()
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
        _clearAllFlares()
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
