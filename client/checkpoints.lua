-- client/checkpoints.lua

local CurrentCheckpoints = {}
local CurrentCPIndex     = 1
local RaceState          = "IDLE"
local TrackType          = "circuit"   -- "circuit" | "sprint"

-- One blip per checkpoint, indexed 1…N
local AllBlips    = {}
-- Separate dedicated route blip that always points to the ACTIVE checkpoint
local RouteBlip   = nil

-- Blip appearance constants
-- Blip appearance constants
local SPRITE_CP_PENDING  = 1    -- Simple dot for upcoming path
local SPRITE_CP_ACTIVE   = 164  -- Large arrow for the immediate target
local SPRITE_CP_FINISH   = 458  -- Premium checkered flag for the finish line
local COLOUR_ACTIVE      = 17   -- Orange/Gold
local COLOUR_PENDING     = 4    -- White (semi-transparent via short range)
local COLOUR_FINISH      = 2    -- Green
local SCALE_ACTIVE       = 1.1
local SCALE_PENDING      = 0.6

-- ---------------------------------------------------------------------------
-- Internal: index of the finish line checkpoint
--   circuit → CP 1 is both start AND finish
--   sprint  → CP N is the finish
-- ---------------------------------------------------------------------------
local function _finishIdx(total)
    return TrackType == "circuit" and 1 or total
end

-- ---------------------------------------------------------------------------
-- Internal: build the label string shown in the map legend for a blip
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Internal: remove every blip and the route blip
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Internal: create one blip per checkpoint labelled "CP 1", "CP 2" …
-- ---------------------------------------------------------------------------
local function _buildBlips(checkpoints)
    _clearAllBlips()
    local total = #checkpoints
    local fi    = _finishIdx(total)

    for i, cp in ipairs(checkpoints) do
        local blip = AddBlipForCoord(cp.coords.x, cp.coords.y, cp.coords.z)
        local isFinish = (i == fi)

        SetBlipSprite(blip, isFinish and SPRITE_CP_FINISH or SPRITE_CP_PENDING)
        SetBlipColour(blip, isFinish and COLOUR_FINISH or COLOUR_PENDING)
        SetBlipScale(blip, SCALE_PENDING)
        SetBlipAsShortRange(blip, true)  -- Hide distant clutter by default

        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(_cpLabel(i, total))
        EndTextCommandSetBlipName(blip)

        AllBlips[i] = blip
    end
end

-- ---------------------------------------------------------------------------
-- Internal: highlight the active checkpoint and route to it
-- ---------------------------------------------------------------------------
local function _setActiveBlip(idx)
    local total = #CurrentCheckpoints
    if total == 0 then return end
    local fi = _finishIdx(total)

    for i, blip in ipairs(AllBlips) do
        if not DoesBlipExist(blip) then goto continue end

        local isFinish = (i == fi)
        if i == idx then
            -- Active checkpoint — large arrow, always visible on minimap
            SetBlipSprite(blip,   SPRITE_CP_ACTIVE)
            SetBlipColour(blip,   COLOUR_ACTIVE)
            SetBlipScale(blip,    SCALE_ACTIVE)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip, 10)
        elseif isFinish then
            -- Finish line — always visible so players know where they are heading
            SetBlipSprite(blip,   SPRITE_CP_FINISH)
            SetBlipColour(blip,   COLOUR_FINISH)
            SetBlipScale(blip,    SCALE_ACTIVE)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip, 9)
        else
            -- Pending checkpoints — small dots, only visible when close (ShortRange)
            SetBlipSprite(blip,   SPRITE_CP_PENDING)
            SetBlipColour(blip,   COLOUR_PENDING)
            SetBlipScale(blip,    SCALE_PENDING)
            SetBlipAsShortRange(blip, true)
            SetBlipPriority(blip, 1)
        end
        ::continue::
    end

    -- Dedicated route blip — update coords in-place to avoid GPS flicker
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

-- ---------------------------------------------------------------------------
-- 11.2 Checkpoint world markers (drawn every frame while racing)
-- ---------------------------------------------------------------------------
local function DrawRaceMarkers()
    if #CurrentCheckpoints == 0 or RaceState == "IDLE" then return end

    -- Active checkpoint: bright yellow cylinder
    local cp = CurrentCheckpoints[CurrentCPIndex]
    if cp then
        DrawMarker(1,
            cp.coords.x, cp.coords.y, cp.coords.z - 1.0,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            cp.radius * 2.0, cp.radius * 2.0, 2.5,
            255, 200, 0, 120,
            false, true, 2, false, nil, nil, false)
    end

    -- Next checkpoint: dim white
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

-- Marker render thread — tight loop only during active race / staging
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

-- ---------------------------------------------------------------------------
-- Net events
-- ---------------------------------------------------------------------------

-- Full track loaded (sent by server when entering COUNTDOWN or STAGING)
RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, startIdx, trackType)
    print(string.format("[Checkpoints] Loading track with %d checkpoints (type: %s)", #checkpoints, trackType or "circuit"))
    TrackType          = trackType or "circuit"
    CurrentCheckpoints = checkpoints
    CurrentCPIndex     = startIdx or 1
    _buildBlips(checkpoints)
    _setActiveBlip(CurrentCPIndex)
end)

-- Player hit a checkpoint — advance the active indicator
RegisterNetEvent("SPZ:nextCheckpoint", function(newIndex)
    CurrentCPIndex = newIndex
    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    _setActiveBlip(CurrentCPIndex)
end)

-- Race state changed
RegisterNetEvent("spz_race:state_updated", function(newState)
    RaceState = newState
    if newState == "IDLE" or newState == "CLEANUP" then
        _clearAllBlips()
        CurrentCheckpoints = {}
        CurrentCPIndex     = 1
    end
end)

-- ---------------------------------------------------------------------------
-- Exports for other client scripts
-- ---------------------------------------------------------------------------
exports("GetCurrentCP", function()
    return CurrentCheckpoints[CurrentCPIndex], CurrentCPIndex
end)

exports("GetRaceState", function()
    return RaceState
end)
