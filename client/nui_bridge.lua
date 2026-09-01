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
        -- `timer` is what spz-poll's own API documents, but its UI reads
        -- `duration` — sending only timer left the countdown bar permanently on
        -- its 30s default. Send both so the bar matches the real window.
        timer    = data.duration,
        duration = data.duration,
        options  = data.options,
        title    = data.title,
        subtitle = data.subtitle,
        -- Position in this player's own run of the ballot, and any switch the
        -- phase carries (traffic votes NPC cops on/off this way).
        step     = data.step,
        steps    = data.steps,
        toggle   = data.toggle,
    })
end)

-- Voting is per player now: the moment YOUR three picks are in, your menu shuts
-- and you are free until the grid forms — no waiting on the slowest voter.
RegisterNetEvent("SPZ:pollClosed", function()
    if GetResourceState("spz-poll") ~= "started" then return end
    exports["spz-poll"]:StopPoll()
end)

RegisterNetEvent("SPZ:pollResult", function(data)
    if GetResourceState("spz-poll") ~= "started" then return end
    exports["spz-poll"]:UpdatePoll(data)
    -- "final" is the decided race, broadcast once everyone has voted. Any ballot
    -- still open at that point is closed here.
    if data.phase == "final" then
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

-- Overtake flourish moved to client/bonus.lua — it is race feedback (toast,
-- sound, nitrous effect on the overtaker's car), not a bridge to a UI resource,
-- and splitting one event across two files hid half of it.

-- ── Turn guide ────────────────────────────────────────────────────────────────
--
-- The corner-call HUD: which way the next gate turns, how far away it is, and
-- how fast you are going, anchored in world space just ahead of the car so it
-- travels with you instead of sitting in a fixed corner of the screen.
--
-- The turn being announced is the one you make AT the next checkpoint, not the
-- direction of the checkpoint itself. Those are different things and only the
-- first is useful: pointing at a gate tells you where it is, which the blips
-- already do. What a driver needs at speed is what the road does once they get
-- there, which is the angle between the leg they are on and the leg after it.

local TURN_ANCHOR_FWD  = 8.0    -- metres ahead of the car
local TURN_ANCHOR_UP   = 2.0    -- metres above it

-- ...and metres to the SIDE of it. Anchored dead ahead, the call sat on the
-- piece of road the driver is about to drive through — the one part of the
-- screen that must stay clear. It now rides the shoulder of the road INSTEAD,
-- on the side the corner goes: a left-hander puts it left, a right-hander puts
-- it right, so the readout is also pointing at where the car is going.
local TURN_ANCHOR_SIDE = 4.5

-- Straight, u-turn and anything doubling back have no side to be on: a
-- "STRAIGHT" call that snaps the element back to centre would put it right back
-- in front of the driver, and a u-turn's sign is meaningless (180° left and
-- 180° right are the same corner, and the sign flips on tiny jitter). Those
-- keep whatever side was last committed.
--
-- `_guideSide` is that commitment; `_guideSideCur` is where the element
-- actually is, eased toward it, so a change of side slides across the road
-- instead of teleporting.
local _guideSide    = 1.0   -- -1 = left, +1 = right
local _guideSideCur = 1.0

-- Which readouts the server wants drawn. GlobalState is authoritative and
-- replicated, so an admin flipping the convar and running /racehud changes this
-- live — read it per frame rather than caching, because a cached copy would go
-- stale exactly when someone is trying to toggle it and see the result.
--
-- Config is the fallback for the window before GlobalState has replicated, and
-- for a client whose spz-races server half is not answering.
local function _hudGuide()
    local v = GlobalState.hudTurnGuide
    if v == nil then return not (Config and Config.Hud and Config.Hud.TurnGuide == false) end
    return v == true
end

local function _hudPill()
    local v = GlobalState.hudCpPill
    if v == nil then return (Config and Config.Hud and Config.Hud.CpDistancePill) == true end
    return v == true
end

--- Signed angle in degrees from vector A to vector B, -180..180.
--- Positive is a right-hand turn.
local function _signedAngle(ax, ay, bx, by)
    local dot   = ax * bx + ay * by
    local cross = ax * by - ay * bx
    return math.deg(math.atan(cross, dot))
end

--- Turn severity from the signed angle. The bands are deliberately wide at the
--- top: below 12° a road is straight as far as the driver is concerned, and
--- calling every gentle kink a turn trains people to ignore the readout.
local function _turnLabel(angle)
    local a = math.abs(angle)
    local side = angle < 0 and "LEFT" or "RIGHT"

    if a < 12 then return "STRAIGHT", "straight"
    elseif a < 40 then return "SLIGHT " .. side, "slight"
    elseif a < 100 then return side, "normal"
    elseif a < 150 then return "HARD " .. side, "hard"
    end
    return "U-TURN", "uturn"
end

Citizen.CreateThread(function()
    while true do
        if (_distState == "LIVE" or _ttActive)
        and not _myRaceOver
        and GetResourceState("spz-raceUI") == "started" then
            local cp, cpIndex = exports["spz-races"]:GetCurrentCP()
            if cp then
                local ped  = PlayerPedId()
                local veh  = GetVehiclePedIsIn(ped, false)
                local ent  = veh ~= 0 and veh or ped
                local pos  = GetEntityCoords(ped)
                local dx   = pos.x - cp.coords.x
                local dy   = pos.y - cp.coords.y
                local dist = math.floor(math.sqrt(dx*dx + dy*dy))

                -- The leg you are driving now: car → next checkpoint.
                local legX, legY = cp.coords.x - pos.x, cp.coords.y - pos.y
                local legLen = math.sqrt(legX*legX + legY*legY)

                -- The leg after it: next checkpoint → the one beyond. Falls back
                -- to the gate's own heading when there is no gate beyond it (the
                -- finish), so the last call is still a real direction rather
                -- than a shrug.
                local angle = 0.0
                local after = exports["spz-races"]:GetCheckpointAt((cpIndex or 0) + 1)

                if legLen > 0.5 then
                    local nx, ny = legX / legLen, legY / legLen
                    if after then
                        local ax, ay = after.coords.x - cp.coords.x, after.coords.y - cp.coords.y
                        local aLen = math.sqrt(ax*ax + ay*ay)
                        if aLen > 0.5 then
                            angle = _signedAngle(nx, ny, ax / aLen, ay / aLen)
                        end
                    elseif cp.heading then
                        local rad = math.rad(cp.heading)
                        angle = _signedAngle(nx, ny, -math.sin(rad), math.cos(rad))
                    end
                end

                local label, severity = _turnLabel(angle)

                -- The two readouts have DIFFERENT anchors, which is the whole
                -- reason they are separate elements rather than one panel.
                local payload = { dist = dist }

                if _hudGuide() then
                    -- Which side of the road the call sits on. Only a real,
                    -- signed corner moves it: the same 12° band that stops
                    -- gentle kinks being called a turn, capped below the u-turn
                    -- band where the sign stops meaning anything.
                    local absAngle = math.abs(angle)
                    if absAngle >= 12 and absAngle < 150 then
                        _guideSide = angle < 0 and -1.0 or 1.0
                    end

                    -- Ease toward it in WALL time, not per frame: a fixed
                    -- per-frame step crosses the road at whatever rate the
                    -- client's framerate happens to be.
                    local k = math.min(1.0, GetFrameTime() * 4.0)
                    _guideSideCur = _guideSideCur + (_guideSide - _guideSideCur) * k

                    -- Anchored to the CAR: the corner call rides with you down
                    -- the road. Offset forward, up and sideways so it sits over
                    -- the shoulder ahead rather than through the roof or over
                    -- the racing line.
                    local fwd = GetEntityForwardVector(ent)
                    -- Right vector, derived from forward rather than read out of
                    -- the entity matrix: forward is (-sin h, cos h), so right is
                    -- (cos h, sin h) — which is exactly (fwd.y, -fwd.x). No
                    -- ambiguity about what order GetEntityMatrix returns.
                    local rx, ry = fwd.y, -fwd.x
                    local side = _guideSideCur * TURN_ANCHOR_SIDE

                    local gOn, gx, gy = World3dToScreen2d(
                        pos.x + fwd.x * TURN_ANCHOR_FWD + rx * side,
                        pos.y + fwd.y * TURN_ANCHOR_FWD + ry * side,
                        pos.z + TURN_ANCHOR_UP)

                    payload.guide = {
                        onScreen = gOn and true or false,
                        x        = gx,
                        y        = gy,
                        turn     = label,
                        severity = severity,
                        angle    = math.floor(angle + 0.5),
                        -- 2.236936 m/s → mph. The reference HUD reads in mph and
                        -- the speedometer does too, so this matches rather than
                        -- inventing a second unit on the same screen.
                        speed    = math.floor(GetEntitySpeed(ent) * 2.236936 + 0.5),
                    }
                end

                if _hudPill() then
                    -- Anchored to the CHECKPOINT, slightly above the ground
                    -- point, with a stem drawn down to it: this one answers
                    -- "where is the gate", including when it is behind geometry.
                    local pOn, px, py = World3dToScreen2d(
                        cp.coords.x, cp.coords.y, cp.coords.z + 1.0)

                    payload.pill = {
                        onScreen = pOn and true or false,
                        x        = px,
                        y        = py,
                    }
                end

                exports["spz-raceUI"]:UpdateCPWaypoint(payload)
                Citizen.Wait(0)
            else
                exports["spz-raceUI"]:UpdateCPWaypoint({ dist = 0 })
                Citizen.Wait(200)
            end
        else
            -- Not driving a route (finished, DNF, idle, cleanup, TT over) →
            -- make sure both readouts are gone rather than frozen on screen.
            if GetResourceState("spz-raceUI") == "started" then
                exports["spz-raceUI"]:UpdateCPWaypoint({ dist = 0 })
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

    -- The stats card is about YOUR race. The full classification — who finished
    -- where, gaps, DNFs — lives on the results board, so say how to reach it
    -- rather than leaving the field's result undiscoverable.
    if GetResourceState("spz-leaderboard") == "started" then
        local key = "F6"   -- spz-leaderboard's default binding for /leaderboard
        SetTimeout(2500, function()
            lib.notify({
                title       = "Race results",
                description = ("Press %s for the full classification"):format(key),
                type        = "inform",
                duration    = 7000,
                position    = "top",
            })
        end)
    end
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
