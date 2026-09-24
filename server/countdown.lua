-- server/countdown.lua

-- ── Race intro helpers ───────────────────────────────────────────────────────
--
-- The cover/sweep/card sequence that wraps the warmup→grid handover. See
-- Config.RaceIntro, spz-races/client/nui_bridge.lua and spz-raceUI.

local function introCfg()
    return (Config and Config.RaceIntro) or {}
end

local function introEnabled()
    return introCfg().Enabled ~= false
end

--- Everything the card names, read from the session the poll decided.
local function introDetails()
    local track = RaceSession.track or {}
    local class = RaceSession.carClass

    -- The car's own label if the poll picked a specific model, otherwise the
    -- class name. A card that says "Sports" when the field is all in one model
    -- is worse than no card, and the reverse — naming a model in an open-class
    -- race — would be a lie.
    local vehicle
    if type(class) == "table" then
        vehicle = class.category or class.name
    elseif class then
        vehicle = tostring(class)
    end

    local out = {
        track   = track.name,
        type    = track.type,
        laps    = track.laps,
        length  = track.length,
        vehicle = vehicle,
        -- The model itself, for two reasons: client/nui_bridge.lua resolves
        -- the real manufacturer and display name from it, and the briefing
        -- prints it as the spawn code.
        model   = type(class) == "table" and class.model or nil,
        class   = type(class) == "table" and class.name or nil,
        cops    = RaceSession.copChase and true or false,
        traffic = RaceSession.trafficLevel or "none",
    }

    -- Real numbers for the machine slide, from the same registry the poll card
    -- reads. Left out entirely when the model has not been classified yet
    -- (a freshly discovered add-on): the slide drops the stat row rather than
    -- showing the placeholder 180/70/70 every unprobed car carries.
    local model = type(class) == "table" and class.model or nil
    if model and GetResourceState("spz-vehicles") == "started" then
        local ok, data = pcall(function()
            return exports["spz-vehicles"]:GetVehicleData(model)
        end)
        if ok and type(data) == "table" and not data.racePending then
            out.topSpeed = data.top_speed
            out.accel    = data.accel
            out.handling = data.handling
        end
    end

    return out
end

local function sendIntro(payload)
    if not introEnabled() then return end
    for src in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:raceIntro", src, payload)
    end
end

-- ── 9. Warmup Phase ──────────────────────────────────────────────────────────
--
-- Entered from WARMUP state.  Players are unfrozen at their grid positions;
-- they may drive around the whole track to scout it or inspect their vehicle.
-- After WarmupTimeSeconds the server re-teleports everyone to their grid slot,
-- freezes them, then transitions to COUNTDOWN for the normal 3-2-1.

function StartWarmupPhase()
    if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

    local warmupTotal = Config.WarmupTimeSeconds or 60
    print(string.format("[Warmup] Free-drive phase started: %d seconds", warmupTotal))

    -- Unfreeze — let players drive
    for src, _ in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:freezeRacer", src, false)
    end

    Citizen.CreateThread(function()
        local remaining = warmupTotal

        while remaining > 0 do
            -- Abort early if state changed externally (e.g. not-enough-players cancel)
            if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

            for src, data in pairs(RaceSession.players) do
                TriggerClientEvent("SPZ:warmupPhase", src, {
                    remaining   = remaining,
                    total       = warmupTotal,
                    track       = RaceSession.track.name,
                    class       = type(RaceSession.carClass) == "table"
                                    and RaceSession.carClass.name
                                    or  tostring(RaceSession.carClass),
                    laps        = RaceSession.track.laps,
                    gridPos     = data.gridIndex or 0,
                })
            end

            Citizen.Wait(1000)
            remaining = remaining - 1
        end

        if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

        -- Warmup was the spawn grace window — anyone whose vehicle still
        -- hasn't confirmed is cut now, before staging.
        if ReconcileUnconfirmed then ReconcileUnconfirmed() end
        if RaceSession.state ~= SPZ.RaceState.WARMUP then return end

        -- Late confirmers weren't in the initial ghosting pass

        -- Signal clients warmup is over so HUD can clear the timer
        BroadcastToRacers("SPZ:warmupEnd")
        print("[Warmup] Phase complete — re-staging players on grid")

        -- Cover BEFORE the teleport, not after: the whole point is that nobody
        -- sees the jump or the collision streaming back in around them. The
        -- lead is short — one NUI frame is enough for the page to paint — and
        -- the cover stays up by itself until the grid is formed.
        if introEnabled() then
            sendIntro({ phase = "cover" })
            Citizen.Wait(tonumber(introCfg().CoverLeadMs) or 700)
            if RaceSession.state ~= SPZ.RaceState.WARMUP then
                -- Cancelled inside the lead. Take the cover back down here
                -- rather than leaving it to the client's deadline.
                sendIntro({ phase = "end" })
                return
            end
        end

        -- Freeze FIRST: freezing only after the TP left a ~2s window where
        -- players could drive off the grid before the countdown started.
        for src, _ in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:freezeRacer", src, true)
        end

        -- Re-teleport each player onto their RACE start slot (still frozen).
        --
        -- Deliberately not the warmup grid slot they spawned on: that is a
        -- staggered grid, and starting a race from it hands row 1 roughly 56
        -- metres over row 8 on a full field — places decided before the lights.
        -- The race placement collapses the field onto a ring at the start point
        -- so every car covers the same distance (Config.RaceStartMode).
        --
        -- Falls back to the warmup slot for a session staged before this
        -- existed, so an in-flight race can never be left with nowhere to go.
        for src, data in pairs(RaceSession.players) do
            local coords  = data.raceCoords  or data.gridCoords
            local heading = data.raceHeading or data.gridHeading or 0.0
            if coords then
                TriggerClientEvent("SPZ:tpToGrid", src, {
                    coords  = coords,
                    heading = heading,
                })
            end
        end

        -- Wait for the client-side TP to settle, then re-assert the freeze
        -- (the teleport can knock the vehicle loose on some clients)
        Citizen.Wait(1500)
        for src, _ in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:freezeRacer", src, true)
        end

        -- Brief pause, then hand off to COUNTDOWN (staging → 3-2-1)
        Citizen.Wait(500)

        SetRaceState(SPZ.RaceState.COUNTDOWN)
    end)
end

exports("StartWarmupPhase", StartWarmupPhase)

-- ── 10. Staging + Countdown Sequence ─────────────────────────────────────
--
-- Flow:
--   COUNTDOWN state entered
--     → Freeze all players on grid
--     → Send checkpoints so map blips appear (spawnCheckpoints already sent by
--       state_machine.lua when entering COUNTDOWN, so clients already have them)
--     → STAGING PHASE: Config.StagingTimeSeconds (default 60) — players sit
--       frozen, can see the full track on the map and inspect their car
--     → 3-2-1 COUNTDOWN: Config.CountdownSeconds (default 3)
--     → GO — unfreeze, unlock vehicles, transition to LIVE

local function _broadcastStagingTick(remaining, total)
    local totalPlayers = 0
    for _ in pairs(RaceSession.players) do totalPlayers = totalPlayers + 1 end

    for source, data in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:stagingPhase", source, {
            remaining   = remaining,
            total       = total,
            track       = RaceSession.track.name,
            class       = type(RaceSession.carClass) == "table" and RaceSession.carClass.name or tostring(RaceSession.carClass),
            laps        = RaceSession.track.laps,
            gridPos     = data.gridIndex or 0,
            totalRacers = totalPlayers,
        })
    end
end

local function _runThreeTwoOne()
    local remaining = Config.CountdownSeconds or 3
    local totalPlayers = 0
    for _ in pairs(RaceSession.players) do totalPlayers = totalPlayers + 1 end

    while remaining > 0 do
        for source, data in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:countdown", source, {
                seconds = remaining,
                -- Length of the whole count, so the HUD can draw a staging
                -- tree with one lamp per second instead of assuming three.
                totalSeconds = Config.CountdownSeconds or 5,
                track   = RaceSession.track.name,
                class   = type(RaceSession.carClass) == "table" and RaceSession.carClass.name or tostring(RaceSession.carClass),
                laps    = RaceSession.track.laps,
                -- 'circuit' | 'sprint': the HUD only counts laps on a circuit.
                raceType = RaceSession.track.type or RaceSession.raceType,
                gridPos = data.gridIndex or 0,
                total   = totalPlayers,
            })
        end
        print(string.format("[Countdown] T-minus %d", remaining))
        Citizen.Wait(1000)
        remaining = remaining - 1
    end
end


-- Flag girl selection, shared across the lobby. See the call site below.
local FLAG_GIRL_COUNT = 6      -- #PED_MODELS in client/gridgirl.lua
local flagGirlBag = {}

local function nextFlagGirl()
    if #flagGirlBag == 0 then
        for i = 1, FLAG_GIRL_COUNT do flagGirlBag[i] = i end
        for i = #flagGirlBag, 2, -1 do
            local j = math.random(i)
            flagGirlBag[i], flagGirlBag[j] = flagGirlBag[j], flagGirlBag[i]
        end
    end
    return table.remove(flagGirlBag)
end

function StartCountdownSequence()
    if RaceSession.state ~= SPZ.RaceState.COUNTDOWN then return end

    print("[Countdown] Initiating race start sequence.")

    -- Freeze all players at their grid positions
    for source, _ in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:freezeRacer", source, true)
    end

    -- The grid is formed and nobody can move: hand the clients the centre line
    -- so the flag girl can walk out to it and the start camera can frame it.
    --
    -- Sent once, here, rather than on every countdown tick — it is a property
    -- of the grid, not of the clock, and the walk-in has to start well before
    -- the last three seconds to land on time.
    local startCoords  = RaceSession.track.start_coords
    local startHeading = RaceSession.startHeading or RaceSession.track.start_heading or 0.0

    -- How long until the lights go out, from THIS moment. Everything in the
    -- start sequence is timed backwards off this single number rather than
    -- each piece guessing its own duration: the camera push lands on GO, and
    -- the flag girl's walk and swing are fitted into what is left. Change the
    -- two config values and the whole sequence re-times itself.
    local goInMs = ((Config.StagingTimeSeconds or 9) + (Config.CountdownSeconds or 5)) * 1000

    -- Which flag girl, decided ONCE and sent to everybody. She is a local ped
    -- created separately on every client, so left to choose for themselves two
    -- drivers in the same race would be waved off by two different women.
    --
    -- Drawn from a shuffled bag rather than at random, so all six appear before
    -- any of them repeats. The count is the length of PED_MODELS in
    -- client/gridgirl.lua — the client wraps whatever arrives, so the two going
    -- out of step costs variety, never a missing ped.
    local flagGirl = nextFlagGirl()

    for source, data in pairs(RaceSession.players) do
        TriggerClientEvent("SPZ:gridFormed", source, {
            coords    = startCoords,
            heading   = startHeading,
            goInMs    = goInMs,
            staging   = Config.StagingTimeSeconds or 9,
            countdown = Config.CountdownSeconds or 5,
            gridPos   = data.gridIndex or 0,
            flagGirl  = flagGirl,
        })
    end

    -- The grid is formed and the start camera is being built on every client
    -- from the event above. NOW open the cover: the panels sweep off a frame
    -- that is already moving, and the card they uncover names the race the
    -- driver is about to run.
    --
    -- Sent after gridFormed on purpose. Reveal first and the sweep opens onto
    -- a static bumper for a frame before the camera cuts in, which is the one
    -- thing the cover existed to avoid.
    if introEnabled() then
        local staging = (Config.StagingTimeSeconds or 9) * 1000
        local hold    = tonumber(introCfg().CardHoldMs)
                     or (staging - (tonumber(introCfg().CardGapMs) or 1500))
        if hold < 2000 then hold = 2000 end
        if hold > staging then hold = staging end

        local payload = introDetails()
        payload.phase  = "reveal"
        payload.holdMs = hold
        sendIntro(payload)

        -- Card down before the lights. spz-raceUI also clears it on the first
        -- countdown tick, so a lost timer cannot leave it over the 3-2-1 —
        -- this is the one that makes it leave on its own, unhurried.
        Citizen.SetTimeout(hold, function()
            if RaceSession.state ~= SPZ.RaceState.COUNTDOWN then return end
            sendIntro({ phase = "end" })
        end)
    end

    Citizen.CreateThread(function()

        -- ── STAGING PHASE ──────────────────────────────────────────────
        -- Players are frozen on grid; they can see the full track, look around,
        -- and prepare. Car customisation menus (if any) may open here.
        local stagingTotal   = Config.StagingTimeSeconds or 60
        local stagingRemain  = stagingTotal

        print(string.format("[Countdown] Staging phase: %d seconds", stagingTotal))

        while stagingRemain > 0 do
            _broadcastStagingTick(stagingRemain, stagingTotal)
            Citizen.Wait(1000)
            stagingRemain = stagingRemain - 1
        end

        -- Signal clients that staging ended (HUD can clear the staging timer)
        BroadcastToRacers("SPZ:stagingEnd")
        print("[Countdown] Staging complete — starting 3-2-1")

        -- ── 3-2-1 COUNTDOWN ────────────────────────────────────────────
        _runThreeTwoOne()

        -- ── GO ─────────────────────────────────────────────────────────
        RaceSession.startTime = GetGameTimer()

        -- Sector clocks start with the race clock, not on the first CP hit.
        ResetSessionSectors()
        for source, pData in pairs(RaceSession.players) do
            InitPlayerSectors(source, pData, RaceSession.track.name, RaceSession.carClassId)
            StartSectorClock(pData, RaceSession.startTime)
        end

        BroadcastToRacers("SPZ:go")
        print("[Countdown] RACE LIVE")

        -- Start timeout watchdog
        StartRaceTimeoutWatchdog()

        -- Unfreeze and unlock vehicles
        for source, _ in pairs(RaceSession.players) do
            TriggerClientEvent("SPZ:freezeRacer", source, false)
            if GetResourceState("spz-vehicles") == "started" then
                exports["spz-vehicles"]:UnlockRaceVehicle(source)
            end
        end

        -- Advance state machine
        exports["spz-races"]:SetRaceState(SPZ.RaceState.LIVE)
    end)
end

-- ── Race timeout watchdog ─────────────────────────────────────────────────
function StartRaceTimeoutWatchdog()
    Citizen.CreateThread(function()
        local maxTimeMs = Config.RaceTimeout or 3600000
        local startTime = GetGameTimer()

        while (GetGameTimer() - startTime) < maxTimeMs do
            Citizen.Wait(5000)
            if RaceSession.state ~= SPZ.RaceState.LIVE then return end
        end

        if RaceSession.state == SPZ.RaceState.LIVE then
            print("[Race Engine] Race timeout reached — forcing DNF for remaining players.")
            for source, data in pairs(RaceSession.players) do
                if not data.finished and not data.dnf then
                    ProcessDNF(source, "timeout")
                end
            end
        end
    end)
end

exports("StartCountdownSequence", StartCountdownSequence)
