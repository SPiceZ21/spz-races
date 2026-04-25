-- server/timetrail.lua
-- Solo Time Trial: isolated bucket, unlimited laps, OUT/HOT/PRACTICE labels.

local TT          = {}        -- [source] = session
local _nextBucket = 8000      -- high range; race buckets start at 1

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function _notify(src, msg, t)
    TriggerClientEvent("spz-lib:notify", src, msg, t or "info")
end

local function _lapLabel(n)
    if n == 1 then return "OUT LAP"
    elseif n == 2 then return "HOT LAP"
    else return "PRACTICE LAP" end
end

-- ── Session teardown (forward-declared so AddEventHandler can reference it) ──

local function _endSession(src)
    local s = TT[src]
    if not s then return end

    SetPlayerRoutingBucket(src, 0)

    TriggerClientEvent("SPZ:tt:End", src, {
        track     = s.track.name,
        lapTimes  = s.lapTimes,
        bestLap   = s.bestLap,
        totalLaps = #s.lapTimes,
    })

    TT[src] = nil
end

-- ── /timetrail — open track selection menu ────────────────────────────────────

RegisterCommand("timetrail", function(source)
    local src = source
    if TT[src] then
        _notify(src, "Already in Time Trial — use /quittt to exit.", "error")
        return
    end
    local list = {}
    for i, t in ipairs(SPZ.Tracks) do
        list[#list + 1] = { index = i, name = t.name, type = t.type, laps = t.laps }
    end
    TriggerClientEvent("SPZ:tt:OpenMenu", src, list)
end, false)

-- ── Net: player picked a track ────────────────────────────────────────────────

RegisterNetEvent("SPZ:tt:SelectTrack", function(trackIndex)
    local src   = source
    local track = SPZ.Tracks[trackIndex]
    if not track or TT[src] then return end

    local bid    = _nextBucket
    _nextBucket  = _nextBucket + 1
    SetPlayerRoutingBucket(src, bid)

    TT[src] = {
        source     = src,
        track      = track,
        bucketId   = bid,
        phase      = "PRE_START",  -- PRE_START → ACTIVE → BETWEEN_LAPS → ACTIVE …
        currentLap = 0,
        currentCp  = 1,
        lapStart   = nil,
        lapTimes   = {},
        bestLap    = nil,
        lastCpTime = GetGameTimer(),
    }

    TriggerClientEvent("SPZ:tt:Begin", src, {
        track      = track,
        trackIndex = trackIndex,
    })
end)

-- ── Net: checkpoint hit ───────────────────────────────────────────────────────

RegisterNetEvent("SPZ:tt:cpHit", function(cpIndex)
    local src = source
    local s   = TT[src]
    if not s then return end
    if cpIndex ~= s.currentCp then return end  -- order validation

    local track    = s.track
    local totalCPs = #track.checkpoints
    local now      = GetGameTimer()
    s.lastCpTime   = now

    -- ── CP[1] crossing: begins a new lap (PRE_START or BETWEEN_LAPS) ──────────
    if cpIndex == 1 and (s.phase == "PRE_START" or s.phase == "BETWEEN_LAPS") then
        s.currentLap = s.currentLap + 1
        s.lapStart   = now
        s.currentCp  = totalCPs > 1 and 2 or 1  -- single-CP edge-case guard
        s.phase      = "ACTIVE"

        local label = _lapLabel(s.currentLap)
        TriggerClientEvent("SPZ:tt:LapStarted", src, { lap = s.currentLap, label = label })
        TriggerClientEvent("SPZ:tt:NextCp",     src, s.currentCp)
        return
    end

    -- ── Ignore CP[1] while already in an active lap (haven't finished yet) ────
    if cpIndex == 1 and s.phase == "ACTIVE" then
        -- player is going the wrong way or shortcutting — silently ignore
        return
    end

    -- ── Intermediate / final CP advance ──────────────────────────────────────
    local nextCp = cpIndex + 1

    if nextCp > totalCPs then
        -- ── Lap complete ─────────────────────────────────────────────────────
        local lapTime    = now - s.lapStart
        local completedN = s.currentLap

        table.insert(s.lapTimes, lapTime)
        if not s.bestLap or lapTime < s.bestLap then s.bestLap = lapTime end

        TriggerClientEvent("SPZ:tt:LapComplete", src, {
            lapNum    = completedN,
            label     = _lapLabel(completedN),
            lapTime   = lapTime,
            bestLap   = s.bestLap,
            times     = s.lapTimes,
            isNewBest = (lapTime == s.bestLap),
        })

        if track.type == "sprint" then
            -- Sprint: reset back to start for next attempt
            s.currentCp = 1
            s.phase     = "PRE_START"
            TriggerClientEvent("SPZ:tt:SprintReset", src, {
                lap   = s.currentLap + 1,
                label = _lapLabel(s.currentLap + 1),
            })
            TriggerClientEvent("SPZ:tt:NextCp", src, 1)
        else
            -- Circuit: wait for CP[1] crossing to start next lap
            s.currentCp = 1
            s.phase     = "BETWEEN_LAPS"
            TriggerClientEvent("SPZ:tt:NextCp", src, 1)
        end
    else
        -- Normal intermediate checkpoint
        s.currentCp = nextCp
        TriggerClientEvent("SPZ:tt:NextCp", src, nextCp)
    end
end)

-- ── Net: player requested restart to start ───────────────────────────────────

RegisterNetEvent("SPZ:tt:Restart", function()
    local src = source
    local s   = TT[src]
    if not s then return end

    -- Abandon current in-progress lap, reset to pre-start
    s.phase     = "PRE_START"
    s.currentCp = 1
    s.lapStart  = nil

    TriggerClientEvent("SPZ:tt:Restarted", src, {
        lapsDone = #s.lapTimes,
        bestLap  = s.bestLap,
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

-- ── Export ────────────────────────────────────────────────────────────────────

exports("IsInTimeTrial", function(src) return TT[src] ~= nil end)
