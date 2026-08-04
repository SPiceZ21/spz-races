-- server/timetrail.lua
-- Solo Time Trial: isolated bucket, continuous rolling hotlaps.
--
-- Flow: /timetrail -> pick class -> pick car -> pick track -> car spawns at the
-- LAST checkpoint (the corner before the start/finish line) -> you drive -> the
-- line crossing starts the clock -> full lap -> crossing the line again banks
-- the lap AND immediately starts the next one. No stopping, no ready gate, no
-- countdown: it is a permanent rolling hotlap session.
--
-- Checkpoint numbering (circuits): the start/finish line is the LAST checkpoint
-- of the lap, not the first. Physically the line is checkpoints[1], so a lap
-- runs 2, 3, ... n, 1 — and that final crossing of [1] reads as "CP n/n".
--   logical i  ->  physical (i % total) + 1
-- Sprints keep plain 1..n ordering (finish = n).

local TT          = {}        -- [source] = session
local _nextBucket = 8000      -- high range; race buckets start at 1

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function _notify(src, msg, t)
    SPZ.Notify(src, msg, t or "info")
end

local function _lapLabel(n)
    if n == 0 then return "OUT LAP" end
    return ("LAP %d"):format(n)
end

-- Logical (display / progress) index -> physical checkpoint index.
local function _phys(s, logical)
    local total = #s.track.checkpoints
    if s.track.type == "circuit" then
        return (logical % total) + 1
    end
    return logical
end

-- ── Session teardown ──────────────────────────────────────────────────────────

local function _endSession(src)
    local s = TT[src]
    if not s then return end

    -- A duel that tears down without a settled lap (quit/disconnect/failed start)
    -- refunds the challenger's escrowed stake.
    if s.duel and not s.duel.settled and RefundDuel then
        RefundDuel(s.duel)
    end

    if GetResourceState("spz-vehicles") == "started" then
        pcall(function() exports["spz-vehicles"]:DespawnVehicle(src) end)
    end

    if s.bucketId and s.bucketId ~= 0 then
        if GetResourceState("spz-core") == "started" then
            exports["spz-core"]:AssignPlayerToBucket(src, 0)
            exports["spz-core"]:DeleteBucket(s.bucketId)
        else
            SetPlayerRoutingBucket(src, 0)
        end
    end

    TriggerClientEvent("SPZ:tt:End", src, {
        track     = s.track.name,
        lapTimes  = s.lapTimes,
        bestLap   = s.bestLap,
        totalLaps = #s.lapTimes,
    })

    TT[src] = nil
end

-- ── /timetrail — open the car → track selection chain ────────────────────────

RegisterCommand("timetrail", function(source)
    local src = source
    if TT[src] then
        _notify(src, "Already in Time Trial — use /quittt to exit.", "error")
        return
    end

    -- Car catalogue, grouped by class, so the client can build the menu.
    local classes = {}
    if GetResourceState("spz-vehicles") == "started" then
        local ok, list = pcall(function() return exports["spz-vehicles"]:GetRaceClasses() end)
        if ok and list then
            for _, cls in ipairs(list) do
                local cars = exports["spz-vehicles"]:GetAllPollOptions(cls)
                if cars and #cars > 0 then
                    table.sort(cars, function(a, b) return (a.label or "") < (b.label or "") end)
                    classes[#classes + 1] = { class = cls, vehicles = cars }
                end
            end
            table.sort(classes, function(a, b) return a.class < b.class end)
        end
    end

    local tracks = {}
    for id, t in pairs(SPZ.Tracks) do
        tracks[#tracks + 1] = { index = id, name = t.name, type = t.type, laps = t.laps }
    end
    table.sort(tracks, function(a, b) return a.name < b.name end)

    TriggerClientEvent("SPZ:tt:OpenMenu", src, { tracks = tracks, classes = classes })
end, false)

-- ── Net: player picked a track + car ──────────────────────────────────────────

RegisterNetEvent("SPZ:tt:SelectTrack", function(trackIndex, model)
    local src   = source
    local track = SPZ.Tracks[trackIndex]
    if not track or TT[src] then return end

    local total = #track.checkpoints
    if total < 2 then
        _notify(src, "That track has too few checkpoints for a time trial.", "error")
        return
    end

    local bid = 0
    if GetResourceState("spz-core") == "started" then
        bid = exports["spz-core"]:CreateBucket(string.format("tt_%d", src))
        exports["spz-core"]:AssignPlayerToBucket(src, bid)
    else
        bid = _nextBucket
        _nextBucket = _nextBucket + 1
        SetPlayerRoutingBucket(src, bid)
    end

    TT[src] = {
        source     = src,
        track      = track,
        bucketId   = bid,
        model      = model,
        -- OUT_LAP: driving from the head-start point to the line (untimed).
        -- ACTIVE : a lap is being timed. There is no other phase.
        phase      = "OUT_LAP",
        currentLap = 0,
        currentCp  = total,   -- logical: the line closes the lap, so it IS CP n
        lapStart   = nil,
        lapTimes   = {},
        bestLap    = nil,
        lastCpTime = GetGameTimer(),
    }

    TT_InitSectors(src, TT[src])

    -- Head start: last physical checkpoint (the corner before the line) so the
    -- player arrives at the start/finish already at speed.
    local headStart = track.checkpoints[total]
    local heading   = headStart.heading
    if not heading then
        -- Fallback: aim from headstart toward the start/finish line
        local target = track.checkpoints[1]
        heading = math.deg(math.atan(
            -(target.coords.x - headStart.coords.x),
            target.coords.y - headStart.coords.y
        )) % 360
    end

    -- Spawn the selected car at the head-start position
    if model and GetResourceState("spz-vehicles") == "started" then
        exports["spz-vehicles"]:SpawnRaceVehicle(src, model, headStart.coords, heading, true)
    end

    TriggerClientEvent("SPZ:tt:Begin", src, {
        track      = track,
        trackIndex = trackIndex,
        model      = model,
        headStart  = { coords = headStart.coords, heading = heading },
    })
end)

-- ── Net: checkpoint hit (client sends the LOGICAL index) ─────────────────────

RegisterNetEvent("SPZ:tt:cpHit", function(logicalIdx)
    local src = source
    local s   = TT[src]
    if not s then return end
    if logicalIdx ~= s.currentCp then return end   -- order validation

    local track = s.track
    local total = #track.checkpoints
    local now   = GetGameTimer()
    s.lastCpTime = now

    -- ── Split delta vs your best lap at THIS checkpoint ──────────────────────
    -- s.cpTimes[i] = ms into the current lap when CP i was crossed.
    -- s.bestSplits[i] = the same, from your fastest lap. Delta = now - best.
    if s.phase == "ACTIVE" and s.lapStart then
        s.cpTimes = s.cpTimes or {}
        local splitNow = now - s.lapStart
        s.cpTimes[logicalIdx] = splitNow

        local ref = s.bestSplits and s.bestSplits[logicalIdx]
        TriggerClientEvent("SPZ:tt:split", src, {
            cp    = logicalIdx,
            total = total,
            split = splitNow,
            delta = ref and (splitNow - ref) or nil,   -- nil = no best yet
        })
    end

    -- ── Crossing the start/finish line (always the LAST logical CP) ──────────
    if logicalIdx == total then
        if s.phase == "ACTIVE" then
            -- Bank the completed lap
            local lapTime = now - s.lapStart
            table.insert(s.lapTimes, lapTime)

            -- New best → freeze this lap's CP splits as the reference tower
            if not s.bestLap or lapTime < s.bestLap then
                s.bestLap    = lapTime
                s.bestSplits = s.cpTimes or {}
            end
            s.cpTimes = {}   -- reset for the lap about to start

            if GetResourceState("spz-raceline") == "started" then
                TriggerEvent("spz-raceline:lapCompleted", src, track.name, lapTime)
            end

            TriggerClientEvent("SPZ:tt:LapComplete", src, {
                lapNum    = s.currentLap,
                label     = _lapLabel(s.currentLap),
                lapTime   = lapTime,
                bestLap   = s.bestLap,
                times     = s.lapTimes,
                isNewBest = (lapTime == s.bestLap),
            })

            -- Ghost duel: the first completed timed lap IS the attempt. Settle
            -- against the opponent's stored time and tear the session down. The
            -- server owns the comparison — the client never reports the outcome.
            if s.duel and not s.duel.settled then
                s.duel.settled = true
                if OnDuelLap then OnDuelLap(src, s, lapTime) end
                return
            end
        end

        -- ...and immediately roll into the next one. Continuous, no reset.
        s.currentLap = s.currentLap + 1
        s.lapStart   = now
        s.phase      = "ACTIVE"
        s.currentCp  = 1
        TT_StartSectorClock(s, now)

        TriggerClientEvent("SPZ:tt:LapStarted", src, {
            lap   = s.currentLap,
            label = _lapLabel(s.currentLap),
        })
        TriggerClientEvent("SPZ:tt:NextCp", src, 1, _phys(s, 1))
        return
    end

    -- ── Mid-lap checkpoint ───────────────────────────────────────────────────
    if s.phase == "ACTIVE" then
        TT_RecordSectorHit(src, s, logicalIdx, now)
    end

    s.currentCp = logicalIdx + 1
    TriggerClientEvent("SPZ:tt:NextCp", src, s.currentCp, _phys(s, s.currentCp))
end)

-- ── Net: restart — head-start teleport again, out lap ────────────────────────

RegisterNetEvent("SPZ:tt:Restart", function()
    local src = source
    local s   = TT[src]
    if not s then return end

    local total = #s.track.checkpoints
    s.phase     = "OUT_LAP"
    s.currentCp = total
    s.lapStart  = nil

    local headStart = s.track.checkpoints[total]
    TriggerClientEvent("SPZ:tt:Restarted", src, {
        lapsDone  = #s.lapTimes,
        bestLap   = s.bestLap,
        headStart = { coords = headStart.coords, heading = headStart.heading },
    })
end)

-- ── /quittt ───────────────────────────────────────────────────────────────────

RegisterCommand("quittt", function(source)
    local src = source
    if not TT[src] then
        _notify(src, "You are not in Time Trial mode.", "error")
        return
    end
    _endSession(src)
end, false)

-- ── Disconnect cleanup ────────────────────────────────────────────────────────

AddEventHandler("playerDropped", function()
    if TT[source] then _endSession(source) end
end)

-- ── Ghost-duel entry points (called from server/duel.lua) ────────────────────
-- A duel reuses the entire TT harness (bucket, CP timing, sectors, ghost) but
-- runs a SINGLE timed lap against a target time. duel.lua handles the wager,
-- validation and settlement; here we just start/stop the session.

-- d = { track, trackIndex, oppLine = {model, points}, targetMs, oppName,
--       oppPid, challengerPid, stake, duelId }
function StartDuelSession(src, d)
    if TT[src] then return false end
    local track = d.track
    local total = #track.checkpoints
    if total < 2 then return false end

    local bid = 0
    if GetResourceState("spz-core") == "started" then
        bid = exports["spz-core"]:CreateBucket(("duel_%d"):format(src))
        exports["spz-core"]:AssignPlayerToBucket(src, bid)
    else
        bid = _nextBucket; _nextBucket = _nextBucket + 1
        SetPlayerRoutingBucket(src, bid)
    end

    TT[src] = {
        source = src, track = track, bucketId = bid, model = d.oppLine.model,
        phase = "OUT_LAP", currentLap = 0, currentCp = total, lapStart = nil,
        lapTimes = {}, bestLap = nil, lastCpTime = GetGameTimer(),
        duel = {
            targetMs = d.targetMs, stake = d.stake, oppName = d.oppName,
            oppPid = d.oppPid, challengerPid = d.challengerPid,
            duelId = d.duelId, settled = false,
        },
    }
    TT_InitSectors(src, TT[src])

    local headStart = track.checkpoints[total]
    local heading   = headStart.heading
    if not heading then
        local target = track.checkpoints[1]
        heading = math.deg(math.atan(
            -(target.coords.x - headStart.coords.x),
            target.coords.y - headStart.coords.y)) % 360
    end

    -- Challenger drives the SAME model as the opponent's stored line — fair, and
    -- it skips the car-select step. The line stores a model HASH; SpawnVehicle
    -- needs a registered spawn NAME, so resolve it (fall back to a safe default
    -- if that model isn't in the race registry).
    local spawnName
    if GetResourceState("spz-vehicles") == "started" then
        local h = d.oppLine.model
        if type(h) == "number" then
            local ok, nm = pcall(function() return GetDisplayNameFromVehicleModel(h) end)
            if ok and nm and nm ~= "" and nm ~= "NULL" then spawnName = nm:lower() end
        elseif type(h) == "string" then
            spawnName = h:lower()
        end
        if not (spawnName and exports["spz-vehicles"]:GetVehicleData(spawnName)) then
            spawnName = (Config.Duel and Config.Duel.FallbackModel) or "sultan"
        end
        exports["spz-vehicles"]:SpawnRaceVehicle(src, spawnName, headStart.coords, heading, true)
    end

    TriggerClientEvent("SPZ:tt:Begin", src, {
        track = track, trackIndex = d.trackIndex, model = spawnName,
        headStart = { coords = headStart.coords, heading = heading },
    })
    TriggerClientEvent("SPZ:duel:Begin", src, {
        line     = { model = d.oppLine.model, points = d.oppLine.points },
        targetMs = d.targetMs, oppName = d.oppName, stake = d.stake,
    })
    return true
end

function EndDuelSession(src)
    _endSession(src)
end

function IsBusyInTT(src) return TT[src] ~= nil end

-- ── Export ────────────────────────────────────────────────────────────────────

exports("IsInTimeTrial", function(src) return TT[src] ~= nil end)
