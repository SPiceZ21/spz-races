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
local LastCaughtIdx      = nil   -- last checkpoint actually crossed (for /respawn)
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

-- Lookahead gates fade with distance ahead, so the order reads at a glance.
local ALPHA_NEAR    = 225
local ALPHA_AHEAD   = 170

-- How many gates are shown as waypoints at once, counting the one you are
-- driving at.
--
-- ONE by default: the minimap behaves like a satnav, showing the gate you are
-- going to and the route line to it, then the next one, then the next. Showing
-- the two after it as well put three markers and one route line on the same
-- stretch of minimap, and at racing speed that reads as clutter around the
-- line rather than as a preview of it.
--
-- Raise it (Config.CpBlips.lookahead = 3) to get the old preview back.
local CPB           = (Config and Config.CpBlips) or {}
local LOOKAHEAD     = CPB.lookahead or 1

-- Gates outside the lookahead are hidden rather than drawn small and dark, so
-- the track does not sit on the map as a dotted outline of where you are about
-- to go. The FINISH is the exception — it is the destination, not a waypoint,
-- and knowing where the race ends is never clutter.
local HIDE_FAR      = CPB.hideFar ~= false

local SCALE_ACTIVE  = 1.1
local SCALE_NEAR    = 0.85
local SCALE_AHEAD   = 0.72   -- two gates ahead
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
-- Each gate has two variants: "_a" while the checkpoint is still ahead of you,
-- "_b" once you have crossed it. Swapping the prop is the visual confirmation
-- that the checkpoint registered.
local PROP_START      = { pending = 'bzzz_start_a',      cleared = 'bzzz_start_b'      }
local PROP_FINISH     = { pending = 'bzzz_finish_a',     cleared = 'bzzz_finish_b'     }
local PROP_CHECKPOINT = { pending = 'bzzz_checkpoint_a', cleared = 'bzzz_checkpoint_b' }

local GateProps = {}   -- [cpIndex] = { left = handle, right = handle, cleared = bool }

local function _gateModelFor(idx, total, cleared)
    -- Circuit: CP1 is the shared start/finish line → start post.
    -- Sprint: CP1 = start, last CP = finish, everything else = checkpoint.
    local set
    if idx == 1 then set = PROP_START
    elseif idx == _finishIdx(total) then set = PROP_FINISH
    else set = PROP_CHECKPOINT end
    return cleared and set.cleared or set.pending
end

-- A checkpoint is "cleared" once the active index has moved past it. On
-- circuits CurrentCPIndex resets to 1 each lap, so every gate flips back to
-- its pending variant for the new lap automatically.
local function _isCleared(idx)
    return idx < CurrentCPIndex
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
    local cleared  = _isCleared(idx)
    local existing = GateProps[idx]

    -- Already spawned in the correct variant? Nothing to do.
    if existing and existing.cleared == cleared then return end

    local cp = CurrentCheckpoints[idx]
    if not cp then return end

    local model = _gateModelFor(idx, #CurrentCheckpoints, cleared)

    -- Validate BEFORE tearing down the old prop. If the requested variant is
    -- missing from the .ytyp (e.g. the "_b" archetypes were never declared),
    -- keep whatever is standing rather than leaving an empty gate.
    if not IsModelInCdimage(model) then
        if cleared and existing then
            existing.cleared = true   -- stop retrying every tick
            print(("[Checkpoints] Gate variant missing from .ytyp: %s — keeping current prop"):format(model))
        end
        return
    end

    if not HasModelLoaded(model) then
        RequestModel(model)
        return   -- retry next proximity tick
    end

    -- Model is confirmed available: safe to swap now.
    if existing then _removeGate(idx) end

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
        GateProps[idx] = { left = left, right = right, cleared = cleared }
    end
end

-- Re-evaluate every spawned gate against the active checkpoint index. Called
-- the moment the index changes so the prop swaps immediately behind the player
-- instead of waiting for the next 500 ms proximity tick.
local function _refreshGates()
    -- Collect first: _spawnGate removes and re-adds the key, and adding keys
    -- during a pairs() traversal is undefined in Lua.
    local stale = {}
    for idx, g in pairs(GateProps) do
        if g.cleared ~= _isCleared(idx) then stale[#stale + 1] = idx end
    end
    for _, idx in ipairs(stale) do _spawnGate(idx) end
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

--- How far ahead of `idx` a checkpoint sits, or nil if it is behind.
---
--- Wraps on circuits, where the checkpoint two ahead of the last gate is gate
--- two of the next lap. Only ever looks LOOKAHEAD gates forward, so this stays
--- O(LOOKAHEAD) rather than scanning the whole track.
local function _aheadRank(i, idx, total)
    for n = 0, LOOKAHEAD - 1 do
        local at = idx + n
        if at > total then
            if TrackType ~= "circuit" then break end
            at = ((at - 1) % total) + 1
        end
        if at == i then return n end
    end
    return nil
end

local function _styleBlips(idx)
    local total = #CurrentCheckpoints
    if total == 0 then return end
    local fi = _finishIdx(total)

    for i, blip in ipairs(AllBlips) do
        if not DoesBlipExist(blip) then goto continue end

        local isFinish = (i == fi)
        local isActive = (i == idx)

        -- Rank 0 is the gate you are driving at; 1 and 2 are the two after it.
        local rank   = _aheadRank(i, idx, total)
        local isNear = (rank ~= nil) and rank > 0 and not isFinish

        if isActive then
            -- Active (next) CP — orange diamond, GPS route line ON, orange route
            SetBlipSprite(blip,       SPRITE_ACTIVE)
            SetBlipColour(blip,       COLOUR_ACTIVE)
            SetBlipScale(blip,        SCALE_ACTIVE)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip,     10)
            SetBlipAlpha(blip,        255)
            SetBlipRoute(blip,        true)
            SetBlipRouteColour(blip,  COLOUR_ACTIVE)

        elseif isNear then
            -- The next two after the active one.
            --
            -- Only the active gate carries a GPS route: the game draws one line
            -- per routed blip and they overlap into an unreadable tangle, so the
            -- lookahead is communicated by making the gates themselves visible
            -- at range instead. They stay numbered and fade with distance ahead,
            -- which is enough to read the shape of the next two corners without
            -- competing with the line you are actually following.
            SetBlipSprite(blip,       SPRITE_PENDING)
            SetBlipColour(blip,       COLOUR_NEAR)
            SetBlipScale(blip,        rank == 1 and SCALE_NEAR or SCALE_AHEAD)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip,     rank == 1 and 6 or 5)
            SetBlipAlpha(blip,        rank == 1 and ALPHA_NEAR or ALPHA_AHEAD)
            SetBlipRoute(blip,        false)

        elseif isFinish then
            -- Finish — green big circle, no route (unless it's also active)
            SetBlipSprite(blip,       SPRITE_FINISH)
            SetBlipColour(blip,       COLOUR_FINISH)
            SetBlipScale(blip,        SCALE_FINISH)
            SetBlipAsShortRange(blip, false)
            SetBlipPriority(blip,     9)
            SetBlipAlpha(blip,        255)
            SetBlipRoute(blip,        false)

        else
            -- Far CPs — hidden entirely by default (alpha 0 keeps the blip alive
            -- so it can simply be turned back up when it becomes the next gate,
            -- rather than being destroyed and rebuilt every crossing).
            SetBlipSprite(blip,       SPRITE_PENDING)
            SetBlipColour(blip,       COLOUR_PENDING)
            SetBlipScale(blip,        SCALE_PENDING)
            SetBlipAsShortRange(blip, true)
            SetBlipPriority(blip,     1)
            SetBlipAlpha(blip,        HIDE_FAR and 0 or 255)
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

-- Camera collision — gate posts have physics collision off (you drive through
-- them), but the game camera still collides with their bounds, so passing a
-- gate slams the chase cam into the car. DisableCamCollisionForObject only
-- holds for one frame, so it has to be re-asserted every frame while gates are
-- standing; it is cheap and only runs when props actually exist nearby.
Citizen.CreateThread(function()
    while true do
        local any = false
        for _, g in pairs(GateProps) do
            if g.left  and DoesEntityExist(g.left)  then
                DisableCamCollisionForObject(g.left);  any = true
            end
            if g.right and DoesEntityExist(g.right) then
                DisableCamCollisionForObject(g.right); any = true
            end
        end
        Citizen.Wait(any and 0 or 500)
    end
end)

-- ── Apply active CP state ──────────────────────────────────────────────────

local function _applyActive(idx)
    _styleBlips(idx)
    _refreshGates()   -- swap crossed gates to their "_b" (cleared) variant
end

-- ── Net events ─────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, startIdx, trackType)
    print(string.format("[Checkpoints] Loading %d checkpoints (type: %s)", #checkpoints, trackType or "circuit"))
    _clearAllGates()   -- drop the previous track's gate props

    TrackType          = trackType or "circuit"
    CurrentCheckpoints = checkpoints
    CurrentCPIndex     = startIdx or 1
    LastCaughtIdx      = nil

    _buildBlips(checkpoints)
    _applyActive(CurrentCPIndex)
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(newIndex)
    -- Periodic resyncs re-send the CURRENT index — only chime and restyle
    -- when the checkpoint actually advanced.
    if newIndex == CurrentCPIndex then return end
    -- The CP we just crossed was the old target — remember it as the respawn point.
    LastCaughtIdx  = CurrentCPIndex
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
        LastCaughtIdx      = nil
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

--- The checkpoint at a given index, wrapping on circuits.
---
--- Used by the turn guide, which needs the gate AFTER the one you are driving
--- at in order to work out which way the road turns there. On a circuit the
--- checkpoint after the last one is the first one of the next lap; on a sprint
--- there is nothing after the finish, so this returns nil and the caller falls
--- back to the gate's own heading.
exports("GetCheckpointAt", function(idx)
    local total = #CurrentCheckpoints
    if total == 0 or not idx then return nil end

    if idx > total then
        if TrackType ~= "circuit" then return nil end
        idx = ((idx - 1) % total) + 1
    elseif idx < 1 then
        return nil
    end

    return CurrentCheckpoints[idx], idx
end)

-- Respawn point for the "back to last checkpoint" key: the coords of the last
-- checkpoint actually crossed (fallback: the first checkpoint / start), with a
-- heading that faces the NEXT target so you resume pointing the right way.
exports("GetRespawnPoint", function()
    if #CurrentCheckpoints == 0 then return nil end

    local fromCp = CurrentCheckpoints[LastCaughtIdx or 1]
    if not fromCp then return nil end

    local nextCp  = CurrentCheckpoints[CurrentCPIndex]
    local heading = fromCp.heading
    if nextCp then
        heading = math.deg(math.atan(
            -(nextCp.coords.x - fromCp.coords.x),
            nextCp.coords.y - fromCp.coords.y)) % 360
    end

    return { coords = fromCp.coords, heading = heading or 0.0 }
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

-- ── Diagnostics ────────────────────────────────────────────────────────────
-- Verifies every gate archetype resolves. If a "_b" variant reports MISSING,
-- it is not declared in stream/bzzz_checkpoint_package.ytyp and the gate will
-- stay on its "_a" prop after being crossed.
RegisterCommand("checkgateprops", function()
    local models = {
        "bzzz_start_a",      "bzzz_start_b",
        "bzzz_finish_a",     "bzzz_finish_b",
        "bzzz_checkpoint_a", "bzzz_checkpoint_b",
    }
    print("[Checkpoints] Gate prop availability:")
    for _, name in ipairs(models) do
        local hash = GetHashKey(name)
        print(("  %-20s %s"):format(name,
            IsModelInCdimage(hash) and "^2OK^7" or "^1MISSING from .ytyp^7"))
    end
end, false)
