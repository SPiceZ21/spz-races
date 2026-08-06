-- client/nui_bridge.lua
-- Adapter between spz-races events and standalone UI resources (spz-poll, spz-raceUI).

-- ── Poll Events ───────────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:pollOpen", function(data)
    if GetResourceState("spz-poll") ~= "started" then
        print("^1[spz-races] WARNING: spz-poll not started^7")
        return
    end
    exports["spz-poll"]:StartPoll({
        phase    = data.phase,
        timer    = data.duration,
        options  = data.options,
        title    = data.title,
        subtitle = data.subtitle,
    })
end)

RegisterNetEvent("SPZ:pollResult", function(data)
    if GetResourceState("spz-poll") ~= "started" then return end
    exports["spz-poll"]:UpdatePoll(data)
    if data.phase == "vehicle" then
        Citizen.SetTimeout(1200, function()
            exports["spz-poll"]:StopPoll()
        end)
    end
end)

-- ── Warmup panel (spz-raceUI tile HUD) ────────────────────────────────────────
RegisterNetEvent("SPZ:warmupPhase", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowWarmup({
        remaining = data.remaining,
        total     = data.total,
        track     = data.track,
        class     = data.class,
        gridPos   = data.gridPos,
    })
end)

RegisterNetEvent("SPZ:warmupEnd", function()
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:HideWarmup()
end)

-- ── Countdown / Staging Events ────────────────────────────────────────────────
-- Staging is a brief silent settle on the grid after the warmup TP-back.
-- It must NOT render the giant countdown box — doing so showed a 10→1 count
-- right before the real 3-2-1-GO (double countdown). Intentionally a no-op;
-- only SPZ:countdown drives the on-screen 3-2-1-GO.
RegisterNetEvent("SPZ:stagingPhase", function() end)

RegisterNetEvent("SPZ:countdown", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowCountdown({
        number  = data.seconds,
        isGo    = false,
        track   = data.track,
        class   = data.class,
        laps    = data.laps,
        gridPos = data.gridPos,
        total   = data.total,
    })
end)

RegisterNetEvent("SPZ:go", function()
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:ShowCountdown({ isGo = true })
    exports["spz-raceUI"]:SetRaceOverlayVisible(true)
    exports["spz-raceUI"]:ResetSectors()
end)

RegisterNetEvent("SPZ:stagingEnd", function() end)

-- ── Race state (native statebag) ──────────────────────────────────────────────
local function _onRaceState(state)
    if state == "IDLE" or state == "CLEANUP" then
        if GetResourceState("spz-raceUI") == "started" then
            exports["spz-raceUI"]:HideAll()
        end
        if GetResourceState("spz-poll") == "started" then
            exports["spz-poll"]:StopPoll()
        end
    elseif state == "WAITING" or state == "COUNTDOWN" or state == "LIVE" then
        if GetResourceState("spz-poll") == "started" then
            exports["spz-poll"]:StopPoll()
        end
        if state ~= "WAITING" and GetResourceState("spz-raceUI") == "started" then
            exports["spz-raceUI"]:HideWarmup()
        end
    end
end

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value then _onRaceState(value) end
end)

Citizen.CreateThread(function()
    Citizen.Wait(0)
    local s = GlobalState.raceState
    if s then _onRaceState(s) end
end)

-- ── Distance to next checkpoint (10 Hz during LIVE) ─────────────────────────
-- Updates the CPDistancePill in spz-raceUI without triggering a full HUD diff.
local _distState = GlobalState.raceState or "IDLE"
AddStateBagChangeHandler("raceState", "global", function(_, _, v)
    if v then _distState = v end
end)

-- Projects the active checkpoint into screen space every frame and feeds the
-- raceUI "Next CP" pill so it renders as a 3D billboard anchored on the CP
-- (with a stem line), instead of a fixed HUD pill.
-- Time Trial drives the same waypoint pill outside the race state machine
local _ttActive = false
RegisterNetEvent("SPZ:tt:Begin", function() _ttActive = true  end)
RegisterNetEvent("SPZ:tt:End",   function() _ttActive = false end)

-- Once *this* player is done (finished or DNF) the pill must go, even though
-- the race stays LIVE for everyone still driving.
local _myRaceOver = false

RegisterNetEvent("SPZ:raceFinished", function()
    _myRaceOver = true
    PlaySoundFrontend(-1, "FIRST_PLACE", "HUD_MINI_GAME_SOUNDSET", true)
end)

RegisterNetEvent("SPZ:playerDNF", function(data)
    if data and data.source == GetPlayerServerId(PlayerId()) then
        _myRaceOver = true
    end
end)

-- Fresh race / TT run → pill is live again
RegisterNetEvent("SPZ:spawnCheckpoints", function() _myRaceOver = false end)
RegisterNetEvent("SPZ:tt:Begin",         function() _myRaceOver = false end)

-- Overtake flourish — a confirmed clean pass, broadcast to the whole race
RegisterNetEvent("SPZ:overtake", function(data)
    if not data then return end
    lib.notify({
        title = "OVERTAKE",
        description = ("%s passed %s"):format(data.over or "?", data.under or "?"),
        type = "inform", duration = 4000, position = "top",
    })
end)

Citizen.CreateThread(function()
    while true do
        if (_distState == "LIVE" or _ttActive)
        and not _myRaceOver
        and GetResourceState("spz-raceUI") == "started" then
            local cp = exports["spz-races"]:GetCurrentCP()
            if cp then
                local pos  = GetEntityCoords(PlayerPedId())
                local dx   = pos.x - cp.coords.x
                local dy   = pos.y - cp.coords.y
                local dist = math.floor(math.sqrt(dx*dx + dy*dy))

                -- Anchor the pill slightly above the checkpoint ground point.
                local onScreen, sx, sy = World3dToScreen2d(
                    cp.coords.x, cp.coords.y, cp.coords.z + 1.0)

                exports["spz-raceUI"]:UpdateCPWaypoint({
                    dist     = dist,
                    onScreen = onScreen and true or false,
                    x        = sx,
                    y        = sy,
                })
                Citizen.Wait(0)
            else
                exports["spz-raceUI"]:UpdateCPWaypoint({ dist = 0, onScreen = false })
                Citizen.Wait(200)
            end
        else
            -- Not driving a route (finished, DNF, idle, cleanup, TT over) →
            -- make sure the pill is gone rather than frozen on screen.
            if GetResourceState("spz-raceUI") == "started" then
                exports["spz-raceUI"]:UpdateCPWaypoint({ dist = 0, onScreen = false })
            end
            Citizen.Wait(500)
        end
    end
end)

-- ── Telemetry ─────────────────────────────────────────────────────────────────
local clientBestLap = nil

RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, currentIdx)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    clientBestLap = LocalPlayer.state.personalBest or 0
    exports["spz-raceUI"]:UpdateRaceOverlay({
        totalCheckpoints = #checkpoints,
        checkpoint       = currentIdx or 1,
        bestLapTime      = clientBestLap,
        allTimeBest      = LocalPlayer.state.allTimeBest or 0
    })
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(cpIndex)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:UpdateRaceOverlay({ checkpoint = cpIndex })
end)

RegisterNetEvent("SPZ:racerDisconnected", function(data)
    lib.notify({
        title = "Race", type = "warning",
        description = ("%s disconnected — slot held for %ds"):format(data.name or "A racer", data.window or 60),
    })
end)

RegisterNetEvent("SPZ:racerReconnected", function(data)
    lib.notify({
        title = "Race", type = "success",
        description = ("%s reconnected and is back in the race"):format(data.name or "A racer"),
    })
end)

RegisterNetEvent("SPZ:sectorComplete", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    exports["spz-raceUI"]:UpdateSector(data)
end)

RegisterNetEvent("SPZ:lapComplete", function(lapNum, lapTime)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    if lapTime and (clientBestLap == nil or clientBestLap == 0 or lapTime < clientBestLap) then
        clientBestLap = lapTime
    end
    exports["spz-raceUI"]:ResetSectors()
    exports["spz-raceUI"]:UpdateRaceOverlay({
        lapNum      = lapNum + 1,
        checkpoint  = 1,
        bestLapTime = clientBestLap or 0
    })
end)

local _lastPosBroadcast = 0
local _lastPosVersion   = 0

RegisterNetEvent("SPZ:positionUpdate", function(payload, version)
    if version and version == 0 then
        _lastPosVersion = 0
    elseif version and version <= _lastPosVersion then
        return
    else
        _lastPosVersion = version or (_lastPosVersion + 1)
    end

    if GetResourceState("spz-raceUI") ~= "started" then return end
    local now = GetGameTimer()
    if now - _lastPosBroadcast < 200 then return end
    _lastPosBroadcast = now

    exports["spz-raceUI"]:UpdateRaceOverlay({
        positions = payload,
        mySource  = GetPlayerServerId(PlayerId()),
    })
end)

-- ── Results & Progression ─────────────────────────────────────────────────────
local _pendingStats = nil

RegisterNetEvent("SPZ:raceEnd", function(results)
    if GetResourceState("spz-raceUI") ~= "started" then return end

    local mySource = GetPlayerServerId(PlayerId())
    local myResult = nil

    for _, finisher in ipairs(results.finishers or {}) do
        if finisher.source == mySource then myResult = finisher; break end
    end

    if not myResult then
        for _, dnf in ipairs(results.dnf or {}) do
            if dnf.source == mySource then
                myResult          = dnf
                myResult.position = "DNF"
                break
            end
        end
    end

    if not myResult then return end

    _pendingStats = {
        trackName  = results.track or "UNKNOWN",
        finishTime = myResult.finish_time
            and string.format("%02d:%05.2f",
                math.floor(myResult.finish_time / 60000),
                (myResult.finish_time % 60000) / 1000)
            or "DNF",
        position   = myResult.position or "DNF",
        bestLap    = myResult.best_lap
            and string.format("%02d:%05.2f",
                math.floor(myResult.best_lap / 60000),
                (myResult.best_lap % 60000) / 1000)
            or "N/A",
        incidents  = myResult.collisions and #myResult.collisions or 0,
        cleanRace  = myResult.cleanRace or false,
    }
end)

RegisterNetEvent("SPZ:progressionUpdate", function(data)
    if GetResourceState("spz-raceUI") ~= "started" then return end
    if not _pendingStats then return end

    exports["spz-raceUI"]:ShowPostRaceStats({
        trackName           = _pendingStats.trackName,
        finishTime          = _pendingStats.finishTime,
        position            = _pendingStats.position,
        bestLap             = _pendingStats.bestLap,
        xpGained            = data.xpGain or 0,
        xpNewProgress       = data.xpProgress or 0.0,
        classPointsGained   = data.pointsGain or 0,
        cpNewProgress       = data.cpProgress or 0.0,
        iRatingDelta        = data.irDelta or 0,
        safetyRatingDelta   = data.srDelta or 0,
        level               = data.level or 1,
        levelUp             = data.levelUp or false,
        incidents           = _pendingStats.incidents,
        cleanRace           = _pendingStats.cleanRace,
    })
    _pendingStats = nil
end)

-- ── Lobby pill + [E] join ─────────────────────────────────────────────────────
-- Small persistent HUD: "[E] JOIN RACE" while freeroaming, "IN QUEUE" once
-- joined, "NEXT RACE IN Ns" during intermission. Every race requires an
-- explicit join — no auto re-queue loop.

local _lobbyRaceState  = GlobalState.raceState or "IDLE"
local _intermissionEnd = 0   -- GetGameTimer() timestamp when break ends
local _lastLobbySig    = ""

AddStateBagChangeHandler("raceState", "global", function(_, _, v)
    if v then _lobbyRaceState = v end
end)

RegisterNetEvent("SPZ:intermissionStart", function(data)
    local secs = (data and data.seconds) or 60
    _intermissionEnd = GetGameTimer() + secs * 1000
end)

-- Join window: armed by the first joiner, counts down for everyone
local _joinWindowEnd = 0

RegisterNetEvent("SPZ:joinWindow", function(data)
    local secs = (data and data.seconds) or 0
    _joinWindowEnd = secs > 0 and (GetGameTimer() + secs * 1000) or 0
end)

-- Poll opening means the break / join window is over
RegisterNetEvent("SPZ:pollOpen", function()
    _intermissionEnd = 0
    _joinWindowEnd   = 0
end)

local function _isSpectating()
    return GetResourceState("spz-spectate") == "started"
        and exports["spz-spectate"]:IsSpectating() == true
end

local function _lobbyMode()
    if LocalPlayer.state.inRace then return { mode = "hidden" } end
    if _G.SPZ_InTimeTrial then return { mode = "hidden" } end  -- no join UI in TT
    if _isSpectating() then return { mode = "hidden" } end      -- no join UI while spectating
    if IsNuiFocused() then return { mode = "hidden" } end       -- spawn menu / any focused NUI open

    local qCount = GlobalState.queueCount or 0

    -- seconds until the armed race starts (nil when no window is running)
    local winMs   = _joinWindowEnd - GetGameTimer()
    local winSecs = winMs > 0 and math.ceil(winMs / 1000) or nil

    if LocalPlayer.state.inQueue or LocalPlayer.state.pendingRace then
        return {
            mode       = "queued",
            queuePos   = LocalPlayer.state.queuePosition or 1,
            queueCount = math.max(qCount, 1),
            seconds    = winSecs,
        }
    end

    local remainMs = _intermissionEnd - GetGameTimer()
    if remainMs > 0 then
        return {
            mode    = "intermission",
            seconds = math.ceil(remainMs / 1000),
        }
    end

    return { mode = "join", queueCount = qCount, seconds = winSecs }
end

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)
        if GetResourceState("spz-raceUI") == "started" then
            local lb  = _lobbyMode()
            local sig = ("%s|%s|%s|%s"):format(lb.mode, lb.queueCount or "", lb.queuePos or "", lb.seconds or "")
            if sig ~= _lastLobbySig then
                _lastLobbySig = sig
                exports["spz-raceUI"]:UpdateLobby(lb)
            end
        end
    end
end)

-- [E] toggles queue: join when free, leave when queued/pending.
-- Disabled once actually racing (inRace) — no bailing mid-grid via E.
Citizen.CreateThread(function()
    while true do
        if not LocalPlayer.state.inRace and not _G.SPZ_InTimeTrial
        and not IsPauseMenuActive() and not IsNuiFocused() and not _isSpectating() then
            if IsControlJustPressed(0, 51) then   -- INPUT_CONTEXT (E)
                if LocalPlayer.state.inQueue or LocalPlayer.state.pendingRace then
                    TriggerServerEvent("SPZ:leaveQueue")
                else
                    TriggerServerEvent("SPZ:joinQueue")
                end
                Citizen.Wait(500)                 -- debounce
            end
            Citizen.Wait(0)
        else
            Citizen.Wait(400)
        end
    end
end)
