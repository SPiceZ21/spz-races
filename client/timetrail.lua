-- client/timetrail.lua
-- Time Trial client: car selection, head-start teleport, rolling hotlaps.
--
-- Flow: /timetrail -> pick class -> pick car -> pick track -> car spawns at the
-- LAST checkpoint (the corner before the start/finish line) -> you drive -> the
-- line crossing starts the clock -> full lap -> crossing the line again banks
-- the lap AND immediately starts the next one. No stopping, no ready gate, no
-- countdown: it is a permanent rolling hotlap session.
--
-- Sprints differ: the car spawns at the FIRST checkpoint (the start line),
-- crossing it starts the clock, and the finish sends you back to that same
-- spawn for the next attempt.

local TTActive     = false
local TTTrack      = nil
local TTCpIndex    = 1       -- LOGICAL checkpoint index (matches server)
local TTLapNum     = 0
local TTLapLabel   = ""
local TTLapStart   = 0
local TTBestLap    = nil
local TTLapTimes   = {}
local TTReadyAt    = 0       -- grace period: detector sleeps until this time
local TTHeadStart  = nil     -- { coords = vec3, heading = number }

-- Restart state
local TTRestartActive = false
local TTRestartEndsAt = 0
local RESTART_MS      = 3000   -- countdown duration
local TT_RESTART_KEY  = "BACK" -- must match RegisterKeyMapping default below

local CP_Z_THRESH = 8.0
local DEBOUNCE_MS = 500

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function FmtTime(ms)
    if not ms then return "--:--.---" end
    local m = math.floor(ms / 60000)
    local s = math.floor((ms % 60000) / 1000)
    local t = ms % 1000
    return string.format("%02d:%02d.%03d", m, s, t)
end

local function _lapLabel(n)
    if n == 1 then return "OUT LAP"
    elseif n == 2 then return "HOT LAP"
    else return "PRACTICE LAP" end
end

local function UI(action, data)
    exports["spz-raceUI"]:TT_Broadcast(action, data or {})
end

-- ── Checkpoint visuals ────────────────────────────────────────────────────────
-- Time Trial reuses the race checkpoint system (custom gate props + numbered
-- blips + GPS route) via exports from client/checkpoints.lua, so TT and races
-- look identical. Replaces the old cones/barrels + separate blips/GPS route.

local function _startVisuals(checkpoints, startIdx, trackType)
    exports["spz-races"]:StartCheckpointVisuals(checkpoints, startIdx or 1, trackType)
end

local function _setActiveCp(idx)
    exports["spz-races"]:SetActiveCheckpoint(idx)
end

local function _stopVisuals()
    exports["spz-races"]:StopCheckpointVisuals()
end

-- ── Gate-width radius helper ──────────────────────────────────────────────────

local function _gateR2(cp)
    if cp.left then
        local dx = cp.coords.x - cp.left.x
        local dy = cp.coords.y - cp.left.y
        local dz = cp.coords.z - cp.left.z
        local r  = math.sqrt(dx*dx + dy*dy + dz*dz)
        return r * r
    end
    local r = cp.radius or 5.0
    return r * r
end

-- ── Logical → Physical CP index ──────────────────────────────────────────────
-- Server uses logical indexing for circuits: a lap runs 1, 2, ..., n where
-- crossing the start/finish line IS logical CP n. Physical CP 1 is the line.
--   logical i → physical (i % total) + 1   (circuits)
--   logical i → physical i                 (sprints)

-- First logical CP of a run: circuits roll in from the last CP and cross the
-- line (logical n); sprints start ON the line at CP 1.
local function _startIdx()
    if not TTTrack then return 1 end
    if TTTrack.type == "sprint" then return 1 end
    return #TTTrack.checkpoints
end

-- Sprints spawn ON the start line, so "drive to the start" makes no sense.
local function _startLabel()
    if TTTrack and TTTrack.type == "sprint" then return "CROSS THE START LINE" end
    return "DRIVE TO THE START LINE"
end

local function _physIdx(logical)
    if not TTTrack then return logical end
    local total = #TTTrack.checkpoints
    if TTTrack.type == "circuit" then
        return (logical % total) + 1
    end
    return logical
end

-- ── Teleport to head start ───────────────────────────────────────────────────
-- Head start = last physical checkpoint (the corner before the start/finish
-- line). Player arrives at the line already at speed.

local function _tpToHeadStart(gracePeriodMs)
    if not TTHeadStart then return end
    exports["spz-core"]:FadeTransition(function()
        local ped     = PlayerPedId()
        local veh     = GetVehiclePedIsIn(ped)
        local sp      = TTHeadStart.coords
        local heading = TTHeadStart.heading or 0.0
        if veh ~= 0 then
            SetEntityCoords(veh, sp.x, sp.y, sp.z, false, false, false, true)
            SetEntityHeading(veh, heading)
            SetVehicleEngineOn(veh, true, true, false)
        else
            SetEntityCoords(ped, sp.x, sp.y, sp.z, false, false, false, true)
            SetEntityHeading(ped, heading)
        end
    end, 400, 300, 600)
    TTReadyAt = GetGameTimer() + (gracePeriodMs or 1500)
end

-- ── Restart logic ─────────────────────────────────────────────────────────────

local function _cancelRestart()
    if not TTRestartActive then return end
    TTRestartActive = false
    UI("tt_restart_cancel", {})
end

local function _executeRestart()
    TTRestartActive = false
    TTCpIndex       = _startIdx()   -- circuit: line crossing · sprint: CP 1
    TTLapStart      = 0

    _tpToHeadStart(1500)
    if TTTrack then
        _startVisuals(TTTrack.checkpoints, _physIdx(TTCpIndex), TTTrack.type)
    end

    TriggerServerEvent("SPZ:tt:Restart")
    UI("tt_restart_done", {
        lapLabel = _startLabel(),
        bestLap  = FmtTime(TTBestLap),
    })
    PlaySoundFrontend(-1, "BACK", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
end

-- ── Restart command ───────────────────────────────────────────────────────────

RegisterCommand("tt_restart", function()
    if not TTActive then return end
    if TTRestartActive then
        _cancelRestart()
        return
    end
    TTRestartActive = true
    TTRestartEndsAt = GetGameTimer() + RESTART_MS
    UI("tt_restart_start", { totalMs = RESTART_MS })
    PlaySoundFrontend(-1, "WAYPOINT_SET", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
end, false)

RegisterKeyMapping("tt_restart", "Time Trial — Restart to Start", "keyboard", TT_RESTART_KEY)

-- ── Restart countdown thread ──────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        if TTRestartActive then
            local remaining = TTRestartEndsAt - GetGameTimer()
            if remaining <= 0 then
                _executeRestart()
            else
                UI("tt_restart_tick", {
                    remaining = remaining,
                    totalMs   = RESTART_MS,
                    seconds   = math.ceil(remaining / 1000),
                })
            end
            Citizen.Wait(50)
        else
            Citizen.Wait(200)
        end
    end
end)

-- ── Hit detection thread ──────────────────────────────────────────────────────
-- Uses the PHYSICAL CP index for proximity checks but sends the LOGICAL
-- index to the server (the server validates order against its logical counter).

local _ttSide, _ttSideIdx = nil, nil   -- crossing-side state for the active CP

Citizen.CreateThread(function()
    while true do
        if TTActive and TTTrack and not TTRestartActive
        and GetGameTimer() >= TTReadyAt
        and not exports["spz-races"]:IsRewinding() then
            local physCp = TTTrack.checkpoints[_physIdx(TTCpIndex)]
            if physCp then
                -- Reset crossing state when the active CP changes.
                if TTCpIndex ~= _ttSideIdx then
                    _ttSideIdx, _ttSide = TTCpIndex, nil
                end

                local pos = GetEntityCoords(PlayerPedId())
                local crossed, side = SPZ_GateCross(physCp, pos, _ttSide)
                _ttSide = side

                if crossed then
                    TriggerServerEvent("SPZ:tt:cpHit", TTCpIndex)  -- logical
                    Citizen.Wait(DEBOUNCE_MS)
                else
                    local dx, dy = pos.x - physCp.coords.x, pos.y - physCp.coords.y
                    local d = math.sqrt(dx*dx + dy*dy)
                    Citizen.Wait(d > 80 and 100 or d > 30 and 20 or 0)
                end
            else
                Citizen.Wait(100)
            end
        else
            _ttSideIdx, _ttSide = nil, nil
            Citizen.Wait(200)
        end
    end
end)

-- ── Timer HUD thread ──────────────────────────────────────────────────────────
-- The lap clock rewinds with the car: while a scrub is in progress the live
-- credit is subtracted so the timer visibly runs backward, and on release the
-- committed credit is folded into TTLapStart (below) so the displayed time and
-- the server's banked lap time agree from that frame on.

Citizen.CreateThread(function()
    while true do
        if TTActive and TTLapStart > 0 then
            local elapsed = GetGameTimer() - TTLapStart
                          - exports["spz-races"]:GetRewindCreditMs()
            UI("tt_timer", { formatted = FmtTime(math.max(0, math.floor(elapsed))) })
            Citizen.Wait(50)
        else
            Citizen.Wait(200)
        end
    end
end)

-- Rewind committed: shift the lap clock forward by the credited amount, which
-- is the same as winding the elapsed time back. Clamped so a long scrub through
-- the start of a lap can never produce a start time in the future.
AddEventHandler("SPZ:rewind:applied", function(ms)
    if not TTActive or TTLapStart <= 0 then return end
    ms = tonumber(ms) or 0
    if ms <= 0 then return end
    TTLapStart = math.min(TTLapStart + ms, GetGameTimer())
end)

-- ── Full cleanup ──────────────────────────────────────────────────────────────

local function _cleanup()
    TTActive        = false
    _G.SPZ_InTimeTrial = false
    TTTrack         = nil
    TTCpIndex       = 1
    TTLapNum        = 0
    TTLapLabel      = ""
    TTLapStart      = 0
    TTBestLap       = nil
    TTLapTimes      = {}
    TTHeadStart     = nil
    TTRestartActive = false
    _stopVisuals()
end

-- ── Net events ────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:tt:OpenMenu", function(payload)
    -- payload = { tracks = {...}, classes = {...} }
    -- Backwards-compat: if server sends a flat array, treat it as tracks-only
    local trackList = payload.tracks or payload
    local classes   = payload.classes or {}

    print("[TimeTrial] Received OpenMenu — " .. #trackList .. " tracks, " .. #classes .. " classes")

    -- ── Build track submenus (re-registered each time a car is picked) ──────
    local _selectedModel = nil

    local function _buildTrackMenus(backMenu)
        local circuit, sprint = {}, {}
        for _, t in ipairs(trackList) do
            local ttype = t.type or "circuit"
            local lapTxt = t.laps and (" · " .. t.laps .. " lap" .. (t.laps > 1 and "s" or "")) or ""
            local opt = {
                title       = t.name,
                description = ttype:gsub("^%l", string.upper) .. lapTxt,
                icon        = ttype == "sprint" and "route" or "flag-checkered",
                onSelect    = function()
                    TriggerServerEvent("SPZ:tt:SelectTrack", t.index, _selectedModel)
                end,
            }
            if ttype == "sprint" then sprint[#sprint + 1] = opt else circuit[#circuit + 1] = opt end
        end

        lib.registerContext({ id = "tt_circuit", title = "Circuit Tracks", menu = "tt_tracktype", options = circuit })
        lib.registerContext({ id = "tt_sprint",  title = "Sprint Tracks",  menu = "tt_tracktype", options = sprint })

        local typeOpts = {}
        if #circuit > 0 then
            typeOpts[#typeOpts + 1] = { title = "Circuit", description = #circuit .. " tracks", icon = "flag-checkered", arrow = true, menu = "tt_circuit" }
        end
        if #sprint > 0 then
            typeOpts[#typeOpts + 1] = { title = "Sprint", description = #sprint .. " tracks", icon = "route", arrow = true, menu = "tt_sprint" }
        end

        lib.registerContext({ id = "tt_tracktype", title = "Select Track Type", menu = backMenu or "tt_main", options = typeOpts })
    end

    -- ── Car selection menus ──────────────────────────────────────────────────
    if #classes > 0 then
        local main = {}
        for _, cls in ipairs(classes) do
            local classId  = cls.class
            local vehicles = cls.vehicles or {}
            local menuId   = "tt_class_" .. classId

            local carOpts = {}
            for _, car in ipairs(vehicles) do
                carOpts[#carOpts + 1] = {
                    title  = car.label,
                    icon   = "car",
                    onSelect = function()
                        _selectedModel = car.model
                        _buildTrackMenus(menuId)
                        lib.showContext("tt_tracktype")
                    end,
                }
            end
            lib.registerContext({
                id      = menuId,
                title   = "Class " .. classId .. " — Select Car",
                menu    = "tt_main",
                options = carOpts,
            })

            main[#main + 1] = {
                title       = "Class " .. classId,
                description = #vehicles .. " car" .. (#vehicles > 1 and "s" or ""),
                icon        = "car",
                arrow       = true,
                menu        = menuId,
            }
        end

        lib.registerContext({ id = "tt_main", title = "Time Trial — Select Car", options = main })
    else
        -- No car classes available — skip straight to track selection
        _selectedModel = nil
        _buildTrackMenus("tt_main")

        local typeOpts = {}
        local circuit, sprint = {}, {}
        for _, t in ipairs(trackList) do
            if (t.type or "circuit") == "sprint" then sprint[#sprint + 1] = t
            else circuit[#circuit + 1] = t end
        end
        if #circuit > 0 then
            typeOpts[#typeOpts + 1] = { title = "Circuit", description = #circuit .. " tracks", icon = "flag-checkered", arrow = true, menu = "tt_circuit" }
        end
        if #sprint > 0 then
            typeOpts[#typeOpts + 1] = { title = "Sprint", description = #sprint .. " tracks", icon = "route", arrow = true, menu = "tt_sprint" }
        end

        lib.registerContext({ id = "tt_main", title = "Time Trial — Select Track", options = typeOpts })
    end

    lib.showContext("tt_main")
end)

RegisterNetEvent("SPZ:tt:Begin", function(payload)
    local track = payload.track
    local total = #track.checkpoints
    TTTrack     = track
    TTCpIndex   = _startIdx()  -- circuit: last CP (line) · sprint: CP 1
    TTLapNum    = 0
    TTBestLap   = nil
    TTLapStart  = 0            -- timer starts on first line crossing
    TTLapTimes  = {}
    TTActive    = true
    _G.SPZ_InTimeTrial = true  -- suppress the race lobby pill + E-to-join

    -- Store head start for restarts
    TTHeadStart = payload.headStart

    -- TP to head start (last physical CP, corner before the start/finish line)
    _tpToHeadStart(2500)

    -- Visuals: highlight the start/finish line as the next CP to drive through
    _startVisuals(track.checkpoints, _physIdx(TTCpIndex), track.type)

    UI("tt_hud_show", {
        track      = track.name,
        trackType  = track.type,
        lapLabel   = _startLabel(),
        bestLap    = nil,
        cpIndex    = TTCpIndex,
        cpTotal    = total,
        restartKey = TT_RESTART_KEY,
    })

    lib.notify({ description = "Time Trial — " .. track.name .. " | " .. _startLabel():lower(), type = "info" })
end)

RegisterNetEvent("SPZ:tt:LapStarted", function(data)
    TTLapNum   = data.lap
    TTLapLabel = data.label
    TTLapStart = GetGameTimer()

    UI("tt_lap_started", {
        lap      = data.lap,
        lapLabel = data.label,
        bestLap  = FmtTime(TTBestLap),
    })
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:ResetSectors()
    end
    PlaySoundFrontend(-1, "CHECKPOINT_UNDER_THE_BRIDGE_STUNT", "HUD_MINI_GAME_SOUNDSET", 1)
end)

-- Split delta tower — server sends this on every CP crossing with the delta
-- vs your best lap at that same checkpoint.
RegisterNetEvent("SPZ:tt:split", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowSplitDelta(data)
end)

RegisterNetEvent("SPZ:tt:NextCp", function(logicalIdx, physIdx)
    TTCpIndex = logicalIdx

    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    if TTTrack then
        _setActiveCp(physIdx or _physIdx(logicalIdx))
    end
    UI("tt_next_cp", {
        cpIndex = logicalIdx,
        total   = TTTrack and #TTTrack.checkpoints or 0,
    })
end)

RegisterNetEvent("SPZ:tt:LapComplete", function(data)
    if data.lapTime < (TTBestLap or math.huge) then TTBestLap = data.lapTime end
    TTLapTimes[#TTLapTimes + 1] = data.lapTime

    local formatted = {}
    for i, t in ipairs(TTLapTimes) do
        formatted[i] = { lapNum = i, label = _lapLabel(i), time = FmtTime(t), isBest = (t == TTBestLap) }
    end

    UI("tt_lap_complete", {
        lapNum    = data.lapNum,
        lapLabel  = data.label,
        lapTime   = FmtTime(data.lapTime),
        bestLap   = FmtTime(TTBestLap),
        allLaps   = formatted,
        isNewBest = data.isNewBest,
    })
    PlaySoundFrontend(-1, "CHECKPOINT_UNDER_THE_BRIDGE_STUNT", "HUD_MINI_GAME_SOUNDSET", 1)
end)

-- Server confirmed the restart reset
RegisterNetEvent("SPZ:tt:Restarted", function(data)
    TTLapStart = 0
    if not TTTrack then return end

    -- Back to the head-start point (corner before the line) and roll again
    if data and data.headStart then TTHeadStart = data.headStart end
    TTCpIndex = _startIdx()                   -- next target is the line
    _tpToHeadStart(1500)
    _startVisuals(TTTrack.checkpoints, _physIdx(TTCpIndex), TTTrack.type)

    UI("tt_lap_started", {
        lap      = (data.lapsDone or 0),
        lapLabel = _startLabel(),
        bestLap  = FmtTime(TTBestLap),
    })
end)

RegisterNetEvent("SPZ:tt:End", function(data)
    -- Fully tear down the TT HUD/overlay (raceUI shows nothing for TT anymore)
    exports["spz-raceUI"]:TT_Hide()
    exports["spz-raceUI"]:SetRaceOverlayVisible(false)
    SetNuiFocus(false, false)
    _cleanup()

    local best = (data.bestLap and data.bestLap > 0) and FmtTime(data.bestLap) or "—"
    lib.notify({
        description = ("Time Trial ended · Best lap: %s"):format(best),
        type = "info",
    })
end)

-- ── NUI callbacks ─────────────────────────────────────────────────────────────

-- ── Relay events from spz-raceUI ──────────────────────────────────────────────
-- (track selection now uses ox_lib → SPZ:tt:SelectTrack directly; the NUI
--  select/close relays were removed)

AddEventHandler("SPZ:tt:nuiDismissResults", function()
    UI("tt_hide", {})
end)

AddEventHandler("SPZ:tt:nuiRestartBtn", function()
    if TTActive then
        if TTRestartActive then
            _cancelRestart()
        else
            TTRestartActive = true
            TTRestartEndsAt = GetGameTimer() + RESTART_MS
            UI("tt_restart_start", { totalMs = RESTART_MS })
            PlaySoundFrontend(-1, "WAYPOINT_SET", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
        end
    end
end)

-- ── Export ────────────────────────────────────────────────────────────────────
-- Lets client/rewind.lua snapshot the logical CP index per recorded frame.
exports("GetTTCpIndex", function() return TTActive and TTCpIndex or nil end)
