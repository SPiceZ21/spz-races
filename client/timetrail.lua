-- client/timetrail.lua
-- Time Trial client: visuals, hit detection, restart, NUI bridge.

local TTActive     = false
local TTTrack      = nil
local TTCpIndex    = 1
local TTLapNum     = 0
local TTLapLabel   = ""
local TTLapStart   = 0
local TTBestLap    = nil
local TTLapTimes   = {}
local TTReadyAt    = 0        -- grace period: detector sleeps until this time

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

-- ── Teleport to start (shared by Begin, SprintReset, and Restart) ─────────────

local function _tpToStart(gracePeriodMs)
    if not TTTrack then return end
    local ped     = PlayerPedId()
    local veh     = GetVehiclePedIsIn(ped)
    local sp      = TTTrack.start_coords
    local heading = TTTrack.start_heading or 0.0
    if veh ~= 0 then
        SetEntityCoords(veh, sp.x, sp.y, sp.z, false, false, false, true)
        SetEntityHeading(veh, heading)
        SetVehicleEngineOn(veh, true, true, false)
    else
        SetEntityCoords(ped, sp.x, sp.y, sp.z, false, false, false, true)
        SetEntityHeading(ped, heading)
    end
    TTReadyAt = GetGameTimer() + (gracePeriodMs or 1500)
end

-- ── Ready gate ────────────────────────────────────────────────────────────────
-- The TP lands inside CP1's radius, so runs must not arm until the player says
-- so: freeze at the line, wait for E, then a 3-2-1 standing start.

local TTAwaitReady = false
local TTGateGen    = 0     -- invalidates stale gate threads on re-entry

local function _setFrozen(on)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped)
    FreezeEntityPosition(veh ~= 0 and veh or ped, on)
    if not on and veh ~= 0 then
        SetVehicleEngineOn(veh, true, true, false)
    end
end

local function _enterReadyGate()
    TTAwaitReady = true
    TTGateGen    = TTGateGen + 1
    local gen    = TTGateGen

    _setFrozen(true)
    UI("tt_lap_started", {
        lap      = TTLapNum,
        lapLabel = "PRESS [E] WHEN READY",
        bestLap  = FmtTime(TTBestLap),
    })

    CreateThread(function()
        while TTAwaitReady and TTActive and gen == TTGateGen do
            if IsControlJustPressed(0, 38) then   -- E
                TTAwaitReady = false
                TriggerServerEvent("SPZ:tt:Ready")
                break
            end
            Wait(0)
        end
    end)
end

local function _leaveReadyGate()
    TTAwaitReady = false
    TTGateGen    = TTGateGen + 1
    _setFrozen(false)
end

-- Server armed the run: 3-2-1, then release. Standing on the line means CP1
-- registers the moment the car moves — a proper standing start.
RegisterNetEvent("SPZ:tt:Armed", function()
    CreateThread(function()
        for i = 3, 1, -1 do
            UI("tt_lap_started", {
                lap      = TTLapNum,
                lapLabel = tostring(i),
                bestLap  = FmtTime(TTBestLap),
            })
            PlaySoundFrontend(-1, "3_2_1", "HUD_MINI_GAME_SOUNDSET", 1)
            Wait(1000)
        end
        UI("tt_lap_started", {
            lap      = TTLapNum,
            lapLabel = "GO!",
            bestLap  = FmtTime(TTBestLap),
        })
        PlaySoundFrontend(-1, "GO", "HUD_MINI_GAME_SOUNDSET", 1)
        _setFrozen(false)
    end)
end)

-- ── Restart logic ─────────────────────────────────────────────────────────────

local function _cancelRestart()
    if not TTRestartActive then return end
    TTRestartActive = false
    UI("tt_restart_cancel", {})
end

local function _executeRestart()
    TTRestartActive = false
    TTCpIndex       = 1
    TTLapStart      = 0

    _tpToStart(1500)
    _startVisuals(TTTrack.checkpoints, 1, TTTrack.type)

    TriggerServerEvent("SPZ:tt:Restart")
    UI("tt_restart_done", {
        lapLabel = "PRESS [E] WHEN READY",
        bestLap  = FmtTime(TTBestLap),
    })
    SetTimeout(600, _enterReadyGate)
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

Citizen.CreateThread(function()
    while true do
        if TTActive and TTTrack and not TTRestartActive and not TTAwaitReady
        and GetGameTimer() >= TTReadyAt then
            local cp = TTTrack.checkpoints[TTCpIndex]
            if cp then
                local pos   = GetEntityCoords(PlayerPedId())
                local dx    = pos.x - cp.coords.x
                local dy    = pos.y - cp.coords.y
                local dist2 = dx*dx + dy*dy

                if dist2 < _gateR2(cp) and math.abs(pos.z - cp.coords.z) < CP_Z_THRESH then
                    TriggerServerEvent("SPZ:tt:cpHit", TTCpIndex)
                    Citizen.Wait(DEBOUNCE_MS)
                else
                    local d = math.sqrt(dist2)
                    Citizen.Wait(d > 80 and 100 or d > 30 and 50 or 0)
                end
            else
                Citizen.Wait(100)
            end
        else
            Citizen.Wait(200)
        end
    end
end)

-- ── Timer HUD thread ──────────────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        if TTActive and TTLapStart > 0 then
            UI("tt_timer", { formatted = FmtTime(GetGameTimer() - TTLapStart) })
            Citizen.Wait(50)
        else
            Citizen.Wait(200)
        end
    end
end)

-- ── Full cleanup ──────────────────────────────────────────────────────────────

local function _cleanup()
    _leaveReadyGate()   -- unfreeze + kill any pending gate thread
    TTActive        = false
    TTTrack         = nil
    TTCpIndex       = 1
    TTLapNum        = 0
    TTLapLabel      = ""
    TTLapStart      = 0
    TTBestLap       = nil
    TTLapTimes      = {}
    TTRestartActive = false
    _stopVisuals()
end

-- ── Net events ────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:tt:OpenMenu", function(trackList)
    print("[TimeTrial] Received OpenMenu event from server with " .. #trackList .. " tracks")

    -- Split by type into ox_lib context submenus
    local circuit, sprint = {}, {}
    for _, t in ipairs(trackList) do
        local ttype = t.type or "circuit"
        local lapTxt = t.laps and (" · " .. t.laps .. " lap" .. (t.laps > 1 and "s" or "")) or ""
        local opt = {
            title       = t.name,
            description = ttype:gsub("^%l", string.upper) .. lapTxt,
            icon        = ttype == "sprint" and "route" or "flag-checkered",
            onSelect    = function()
                TriggerServerEvent("SPZ:tt:SelectTrack", t.index)
            end,
        }
        if ttype == "sprint" then sprint[#sprint + 1] = opt else circuit[#circuit + 1] = opt end
    end

    lib.registerContext({ id = "tt_circuit", title = "Circuit Tracks", menu = "tt_main", options = circuit })
    lib.registerContext({ id = "tt_sprint",  title = "Sprint Tracks",  menu = "tt_main", options = sprint })

    local main = {}
    if #circuit > 0 then
        main[#main + 1] = { title = "Circuit", description = #circuit .. " tracks", icon = "flag-checkered", arrow = true, menu = "tt_circuit" }
    end
    if #sprint > 0 then
        main[#main + 1] = { title = "Sprint", description = #sprint .. " tracks", icon = "route", arrow = true, menu = "tt_sprint" }
    end

    lib.registerContext({ id = "tt_main", title = "Time Trial — Select Track", options = main })
    lib.showContext("tt_main")
end)

RegisterNetEvent("SPZ:tt:Begin", function(payload)
    local track = payload.track
    TTTrack     = track
    TTCpIndex   = 1
    TTLapNum    = 0
    TTBestLap   = nil
    TTLapStart  = GetGameTimer() -- Start timer immediately for Out Lap progress
    TTLapTimes  = {}
    TTActive    = true

    _tpToStart(2500)
    _startVisuals(track.checkpoints, 1, track.type)

    UI("tt_hud_show", {
        track      = track.name,
        trackType  = track.type,
        lapLabel   = "PRESS [E] WHEN READY",
        bestLap    = nil,
        cpIndex    = 1,
        cpTotal    = #track.checkpoints,
        restartKey = TT_RESTART_KEY,
    })

    -- Let the TP settle before freezing at the line
    SetTimeout(600, _enterReadyGate)

    lib.notify({ description = "Time Trial — " .. track.name .. " | Press E to start", type = "info" })
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

RegisterNetEvent("SPZ:tt:NextCp", function(newIdx)
    TTCpIndex = newIdx

    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    if TTTrack then
        _setActiveCp(newIdx)
    end
    UI("tt_next_cp", {
        cpIndex = newIdx,
        total   = TTTrack and #TTTrack.checkpoints or 0,
    })
end)

RegisterNetEvent("SPZ:tt:LapComplete", function(data)
    if data.lapTime < (TTBestLap or math.huge) then TTBestLap = data.lapTime end
    TTLapTimes[#TTLapTimes + 1] = data.lapTime
    TTLapStart = 0

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

RegisterNetEvent("SPZ:tt:SprintReset", function()
    if not TTActive or not TTTrack then return end
    Citizen.Wait(2500)
    _tpToStart(1500)
    _startVisuals(TTTrack.checkpoints, 1, TTTrack.type)
    SetTimeout(600, _enterReadyGate)
end)

-- Server confirmed the restart reset
RegisterNetEvent("SPZ:tt:Restarted", function(data)
    TTLapStart = 0
    UI("tt_lap_started", {
        lap      = (data.lapsDone or 0),
        lapLabel = "DRIVE TO THE START LINE",
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
