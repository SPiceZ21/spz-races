-- client/checkpoints.lua

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

-- ── Gate props ─────────────────────────────────────────────────────────────
-- Physical objects spawned at the left/right lane-marker coords of every checkpoint.
-- We use a traffic cone by default; START and FINISH gates get a barrel instead.
local GATE_PROP_DEFAULT = joaat("prop_roadcone02a")
local GATE_PROP_FINISH  = joaat("prop_mp_barrier_02b")

local GateObjects = {}   -- flat list of entity handles

-- ── GPS route ──────────────────────────────────────────────────────────────
local GpsActive = false

-- ── Particle asset ─────────────────────────────────────────────────────────
local PTFX_ASSET  = "core"
local PTFX_EFFECT = "exp_grd_flare"
local PTFX_SCALE  = 0.9

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
        local blip    = AddBlipForCoord(cp.coords.x, cp.coords.y, cp.coords.z)
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

-- ── Gate props ─────────────────────────────────────────────────────────────

local function _awaitModel(model)
    while not HasModelLoaded(model) do
        RequestModel(model)
        Citizen.Wait(0)
    end
end

local function _placeProp(model, pos)
    _awaitModel(model)
    local obj = CreateObject(model, pos.x, pos.y, pos.z, false, false, false)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, true)
    SetEntityInvincible(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    return obj
end

local function _spawnGates(checkpoints)
    local total = #checkpoints
    local fi    = _finishIdx(total)

    for i, cp in ipairs(checkpoints) do
        if cp.left and cp.right then
            local model = (i == 1 or i == fi) and GATE_PROP_FINISH or GATE_PROP_DEFAULT
            GateObjects[#GateObjects + 1] = _placeProp(model, cp.left)
            GateObjects[#GateObjects + 1] = _placeProp(model, cp.right)
        end
    end
end

local function _clearGates()
    for _, obj in ipairs(GateObjects) do
        if DoesEntityExist(obj) then
            SetEntityAsMissionEntity(obj, false, true)
            DeleteObject(obj)
        end
    end
    GateObjects = {}
end

-- ── Particle flares ────────────────────────────────────────────────────────

local function _fireGateFlare(cpIndex)
    local cp = CurrentCheckpoints[cpIndex]
    if not cp or not cp.left or not cp.right then return end

    while not HasNamedPtfxAssetLoaded(PTFX_ASSET) do
        RequestNamedPtfxAsset(PTFX_ASSET)
        Citizen.Wait(0)
    end

    UseParticleFxAssetNextCall(PTFX_ASSET)
    local lh = StartParticleFxLoopedAtCoord(PTFX_EFFECT,
        cp.left.x, cp.left.y, cp.left.z,
        0.0, 0.0, 0.0, PTFX_SCALE, false, false, false, 0)

    UseParticleFxAssetNextCall(PTFX_ASSET)
    local rh = StartParticleFxLoopedAtCoord(PTFX_EFFECT,
        cp.right.x, cp.right.y, cp.right.z,
        0.0, 0.0, 0.0, PTFX_SCALE, false, false, false, 0)

    SetTimeout((Config and Config.FlareDisplayMs) or 3000, function()
        StopParticleFxLooped(lh, false)
        StopParticleFxLooped(rh, false)
    end)
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

-- ── World markers + 3D distance text ───────────────────────────────────────

local function _drawDistanceLabel(cp, idx, total)
    local playerPos = GetEntityCoords(PlayerPedId())
    local cpPos     = vector3(cp.coords.x, cp.coords.y, cp.coords.z)
    local dist      = #(playerPos - cpPos)

    -- Vertical pillar above the checkpoint — height scales with distance (looks cool from afar)
    local pillarH = math.min(80.0, math.max(2.0, dist * 0.35))

    DrawMarker(1,                                       -- vertical cylinder
        cp.coords.x, cp.coords.y, cp.coords.z,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        0.4, 0.4, pillarH,
        255, 200, 0, 180,
        false, true, 2, false, nil, nil, false)

    -- 2D screen text: label + distance (only render when player is close enough)
    if dist < 200.0 then
        local onScreen, sx, sy = World3dToScreen2d(
            cp.coords.x, cp.coords.y, cp.coords.z + pillarH + 1.2)
        if onScreen then
            local label = _cpLabel(idx, total)
            local distStr = string.format("%.0fm", dist)
            SetTextScale(0.28, 0.28)
            SetTextFont(4)
            SetTextProportional(1)
            SetTextColour(255, 200, 0, 240)
            SetTextCentre(1)
            SetTextEntry("STRING")
            AddTextComponentString(label .. "\n" .. distStr)
            DrawText(sx, sy)
        end
    end
end

local function DrawRaceMarkers()
    if #CurrentCheckpoints == 0 or RaceState == "IDLE" then return end
    local total = #CurrentCheckpoints

    -- Active CP — bright yellow cylinder + distance label
    local cp = CurrentCheckpoints[CurrentCPIndex]
    if cp then
        DrawMarker(1,
            cp.coords.x, cp.coords.y, cp.coords.z - 1.0,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            cp.radius * 2.0, cp.radius * 2.0, 2.5,
            255, 200, 0, 120,
            false, true, 2, false, nil, nil, false)
        _drawDistanceLabel(cp, CurrentCPIndex, total)
    end

    -- Next CP — dim white preview
    local nextCp = CurrentCheckpoints[CurrentCPIndex + 1]
    if nextCp then
        DrawMarker(1,
            nextCp.coords.x, nextCp.coords.y, nextCp.coords.z - 1.0,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            nextCp.radius * 2.0, nextCp.radius * 2.0, 2.0,
            255, 255, 255, 40,
            false, true, 2, false, nil, nil, false)
    end
end

-- Marker render thread
Citizen.CreateThread(function()
    while true do
        if #CurrentCheckpoints > 0
        and (RaceState == "LIVE" or RaceState == "COUNTDOWN" or RaceState == "STAGING") then
            DrawRaceMarkers()
            Citizen.Wait(0)
        else
            Citizen.Wait(500)
        end
    end
end)

-- ── Net events ─────────────────────────────────────────────────────────────

-- Full track loaded (server sends this during COUNTDOWN / STAGING)
RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, startIdx, trackType)
    print(string.format("[Checkpoints] Loading %d checkpoints (type: %s)", #checkpoints, trackType or "circuit"))
    TrackType          = trackType or "circuit"
    CurrentCheckpoints = checkpoints
    CurrentCPIndex     = startIdx or 1

    _buildBlips(checkpoints)
    _setActiveBlip(CurrentCPIndex)
    _buildGpsRoute(checkpoints, CurrentCPIndex)

    -- Spawn gate props in a thread so we don't block the net event handler
    Citizen.CreateThread(function()
        _spawnGates(checkpoints)
    end)
end)

-- Player hit a checkpoint — advance indicator, fire flare at the one just cleared
RegisterNetEvent("SPZ:nextCheckpoint", function(newIndex)
    local prevIndex    = CurrentCPIndex
    CurrentCPIndex     = newIndex

    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    _setActiveBlip(CurrentCPIndex)
    _buildGpsRoute(CurrentCheckpoints, CurrentCPIndex)

    -- Fire flare at the checkpoint the player just cleared
    Citizen.CreateThread(function()
        _fireGateFlare(prevIndex)
    end)
end)

-- Lap complete — route loops back from CP 1
RegisterNetEvent("SPZ:lapComplete", function(lapNum, lapTimeMs)
    -- GPS route is rebuilt by SPZ:nextCheckpoint (which fires right after lap complete)
    PlaySoundFrontend(-1, "CHECKPOINT_UNDER_THE_BRIDGE_STUNT", "HUD_MINI_GAME_SOUNDSET", 1)
end)

-- Race state changed
RegisterNetEvent("spz_race:state_updated", function(newState)
    RaceState = newState
    if newState == "IDLE" or newState == "CLEANUP" then
        _clearAllBlips()
        _clearGates()
        _clearGpsRoute()
        CurrentCheckpoints = {}
        CurrentCPIndex     = 1
    end
end)

-- ── Exports ────────────────────────────────────────────────────────────────

exports("GetCurrentCP", function()
    return CurrentCheckpoints[CurrentCPIndex], CurrentCPIndex
end)

exports("GetRaceState", function()
    return RaceState
end)
