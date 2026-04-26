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

-- ── Blips ─────────────────────────────────────────────────────────────────────

local _blips     = {}
local _routeBlip = nil

local function _clearBlips()
    for _, b in ipairs(_blips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    _blips = {}
    if _routeBlip and DoesBlipExist(_routeBlip) then
        RemoveBlip(_routeBlip)
        _routeBlip = nil
    end
end

local function _isFinish(i, total, trackType)
    return (trackType == "circuit" and i == 1) or (trackType == "sprint" and i == total)
end

local function _buildBlips(checkpoints, activeIdx, trackType)
    _clearBlips()
    local total = #checkpoints
    for i, cp in ipairs(checkpoints) do
        local isFin = _isFinish(i, total, trackType)
        local isAct = (i == activeIdx)
        local b     = AddBlipForCoord(cp.coords.x, cp.coords.y, cp.coords.z)
        SetBlipSprite(b, isAct and 164 or isFin and 458 or 1)
        SetBlipColour(b, isAct and 17 or isFin and 2 or 4)
        SetBlipScale(b,  isAct and 1.1 or 0.6)
        SetBlipAsShortRange(b, not isAct)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(
            i == 1 and (trackType == "circuit" and "Start / Finish" or "Start")
            or i == total and "Finish"
            or ("CP " .. i)
        )
        EndTextCommandSetBlipName(b)
        _blips[i] = b
    end
    local cp = checkpoints[activeIdx]
    if cp then
        _routeBlip = AddBlipForCoord(cp.coords.x, cp.coords.y, cp.coords.z)
        SetBlipSprite(_routeBlip, 8)
        SetBlipColour(_routeBlip, 17)
        SetBlipScale(_routeBlip, 0.0)
        SetBlipRoute(_routeBlip, true)
        SetBlipRouteColour(_routeBlip, 17)
    end
end

local function _updateBlip(newIdx, trackType)
    local total = TTTrack and #TTTrack.checkpoints or 0
    for i, b in ipairs(_blips) do
        if not DoesBlipExist(b) then goto continue end
        local isFin = _isFinish(i, total, trackType)
        local isAct = (i == newIdx)
        SetBlipSprite(b, isAct and 164 or isFin and 458 or 1)
        SetBlipColour(b, isAct and 17 or isFin and 2 or 4)
        SetBlipScale(b,  isAct and 1.1 or 0.6)
        SetBlipAsShortRange(b, not isAct)
        ::continue::
    end
    if _routeBlip and DoesBlipExist(_routeBlip) and TTTrack then
        local cp = TTTrack.checkpoints[newIdx]
        if cp then SetBlipCoords(_routeBlip, cp.coords.x, cp.coords.y, cp.coords.z) end
    end
end

-- ── Gate props ────────────────────────────────────────────────────────────────

local _gates = {}
local CONE   = joaat("prop_roadcone02a")
local BARREL = joaat("prop_mp_barrier_02b")

local function _awaitModel(model)
    while not HasModelLoaded(model) do RequestModel(model) Citizen.Wait(0) end
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
    for i, cp in ipairs(checkpoints) do
        if cp.left and cp.right then
            local m = (i == 1 or i == total) and BARREL or CONE
            _gates[#_gates + 1] = _placeProp(m, cp.left)
            _gates[#_gates + 1] = _placeProp(m, cp.right)
        end
    end
end

local function _clearGates()
    for _, obj in ipairs(_gates) do
        if DoesEntityExist(obj) then
            SetEntityAsMissionEntity(obj, false, true)
            DeleteObject(obj)
        end
    end
    _gates = {}
end

-- ── GPS route ─────────────────────────────────────────────────────────────────

local _gpsOn = false

local function _buildGPS(checkpoints, fromIdx, trackType)
    if _gpsOn then ClearGpsMultiRoute() end
    StartGpsMultiRoute((Config and Config.GpsRouteColour) or 51, false, false)
    for i = fromIdx, #checkpoints do
        local c = checkpoints[i]
        AddPointToGpsMultiRoute(c.coords.x, c.coords.y, c.coords.z or 0.0)
    end
    if trackType == "circuit" and fromIdx > 1 then
        local f = checkpoints[1]
        AddPointToGpsMultiRoute(f.coords.x, f.coords.y, f.coords.z or 0.0)
    end
    SetGpsMultiRouteRender(true, 16, 16)
    _gpsOn = true
end

local function _clearGPS()
    if _gpsOn then ClearGpsMultiRoute() _gpsOn = false end
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

-- ── Flare ─────────────────────────────────────────────────────────────────────

local PTFX_ASSET  = "core"
local PTFX_EFFECT = "exp_grd_flare"

local function _fireFlare(cpIndex)
    if not TTTrack then return end
    local cp = TTTrack.checkpoints[cpIndex]
    if not cp or not cp.left or not cp.right then return end
    while not HasNamedPtfxAssetLoaded(PTFX_ASSET) do
        RequestNamedPtfxAsset(PTFX_ASSET) Citizen.Wait(0)
    end
    UseParticleFxAssetNextCall(PTFX_ASSET)
    local lh = StartParticleFxLoopedAtCoord(PTFX_EFFECT,
        cp.left.x,  cp.left.y,  cp.left.z,  0,0,0, 0.9, false, false, false, 0)
    UseParticleFxAssetNextCall(PTFX_ASSET)
    local rh = StartParticleFxLoopedAtCoord(PTFX_EFFECT,
        cp.right.x, cp.right.y, cp.right.z, 0,0,0, 0.9, false, false, false, 0)
    SetTimeout(3000, function()
        StopParticleFxLooped(lh, false) StopParticleFxLooped(rh, false)
    end)
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
    _buildBlips(TTTrack.checkpoints, 1, TTTrack.type)
    _buildGPS(TTTrack.checkpoints, 1, TTTrack.type)

    TriggerServerEvent("SPZ:tt:Restart")
    UI("tt_restart_done", {
        lapLabel = "DRIVE TO THE START LINE",
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

-- ── Marker render thread ──────────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        if TTActive and TTTrack then
            local cps = TTTrack.checkpoints
            local cp  = cps[TTCpIndex]
            if cp then
                local pPos = GetEntityCoords(PlayerPedId())
                local dist = #(pPos - vector3(cp.coords.x, cp.coords.y, cp.coords.z))
                local pilH = math.min(80.0, math.max(2.0, dist * 0.35))

                DrawMarker(1,
                    cp.coords.x, cp.coords.y, cp.coords.z - 1.0,
                    0,0,0, 0,0,0,
                    cp.radius * 2.0, cp.radius * 2.0, 2.5,
                    255, 200, 0, 120, false, true, 2, false, nil, nil, false)
                DrawMarker(1,
                    cp.coords.x, cp.coords.y, cp.coords.z,
                    0,0,0, 0,0,0,
                    0.4, 0.4, pilH,
                    255, 200, 0, 180, false, true, 2, false, nil, nil, false)

                if dist < 200.0 then
                    local ok, sx, sy = World3dToScreen2d(
                        cp.coords.x, cp.coords.y, cp.coords.z + pilH + 1.2)
                    if ok then
                        SetTextScale(0.28, 0.28) SetTextFont(4) SetTextProportional(1)
                        SetTextColour(255, 200, 0, 240) SetTextCentre(1)
                        SetTextEntry("STRING")
                        AddTextComponentString(("CP %d\n%.0fm"):format(TTCpIndex, dist))
                        DrawText(sx, sy)
                    end
                end

                local ncp = cps[TTCpIndex + 1]
                if ncp then
                    DrawMarker(1,
                        ncp.coords.x, ncp.coords.y, ncp.coords.z - 1.0,
                        0,0,0, 0,0,0,
                        ncp.radius * 2.0, ncp.radius * 2.0, 2.0,
                        255, 255, 255, 40, false, true, 2, false, nil, nil, false)
                end
            end
            Citizen.Wait(0)
        else
            Citizen.Wait(500)
        end
    end
end)

-- ── Hit detection thread ──────────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        if TTActive and TTTrack and not TTRestartActive and GetGameTimer() >= TTReadyAt then
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
    TTActive        = false
    TTTrack         = nil
    TTCpIndex       = 1
    TTLapNum        = 0
    TTLapLabel      = ""
    TTLapStart      = 0
    TTBestLap       = nil
    TTLapTimes      = {}
    TTRestartActive = false
    _clearBlips()
    _clearGates()
    _clearGPS()
end

-- ── Net events ────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:tt:OpenMenu", function(trackList)
    print("[TimeTrial] Received OpenMenu event from server with " .. #trackList .. " tracks")
    exports["spz-raceUI"]:TT_ShowMenu(trackList)
end)

RegisterNetEvent("SPZ:tt:Begin", function(payload)
    local track = payload.track
    TTTrack     = track
    TTCpIndex   = 1
    TTLapNum    = 0
    TTBestLap   = nil
    TTLapStart  = 0
    TTLapTimes  = {}
    TTActive    = true

    _tpToStart(2500)
    _buildBlips(track.checkpoints, 1, track.type)
    _buildGPS(track.checkpoints, 1, track.type)
    Citizen.CreateThread(function() _spawnGates(track.checkpoints) end)

    UI("tt_hud_show", {
        track      = track.name,
        trackType  = track.type,
        lapLabel   = "DRIVE TO THE START LINE",
        bestLap    = nil,
        cpIndex    = 1,
        cpTotal    = #track.checkpoints,
        restartKey = TT_RESTART_KEY,
    })

    exports["spz-lib"]:Notify("Time Trial — " .. track.name .. " | Drive through the start gate!", "info")
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
    PlaySoundFrontend(-1, "CHECKPOINT_UNDER_THE_BRIDGE_STUNT", "HUD_MINI_GAME_SOUNDSET", 1)
end)

RegisterNetEvent("SPZ:tt:NextCp", function(newIdx)
    local prevIdx = TTCpIndex
    TTCpIndex     = newIdx

    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    if TTTrack then
        _updateBlip(newIdx, TTTrack.type)
        _buildGPS(TTTrack.checkpoints, newIdx, TTTrack.type)
        Citizen.CreateThread(function() _fireFlare(prevIdx) end)
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
    _buildBlips(TTTrack.checkpoints, 1, TTTrack.type)
    _buildGPS(TTTrack.checkpoints, 1, TTTrack.type)
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
    local formatted = {}
    for i, t in ipairs(data.lapTimes or {}) do
        formatted[i] = { lapNum = i, label = _lapLabel(i), time = FmtTime(t), isBest = (t == data.bestLap) }
    end

    UI("tt_end", {
        track     = data.track,
        bestLap   = FmtTime(data.bestLap),
        allLaps   = formatted,
        totalLaps = data.totalLaps or 0,
    })
    SetNuiFocus(true, true)
    _cleanup()

    exports["spz-lib"]:Notify("Time Trial ended — Best lap: " .. FmtTime(data.bestLap), "info")
end)

-- ── NUI callbacks ─────────────────────────────────────────────────────────────

-- ── Relay events from spz-raceUI ──────────────────────────────────────────────

AddEventHandler("SPZ:tt:nuiSelectTrack", function(index)
    TriggerServerEvent("SPZ:tt:SelectTrack", index)
end)

AddEventHandler("SPZ:tt:nuiCloseMenu", function()
    -- handled locally in raceUI for focus
end)

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
