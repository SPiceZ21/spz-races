-- server/reconnect.lua
-- Mid-race reconnect. A drop during LIVE holds the racer's slot for
-- Config.ReconnectWindowMs instead of instant DNF. Rejoining inside the window
-- restores their lap, checkpoint and race clock, respawns their car at the
-- last crossed checkpoint, and puts them back in the race bucket. Expiry falls
-- through to the normal disconnect DNF.
--
-- The held pData stays in RaceSession.players under the old source id (flagged
-- .disconnected) so CheckAllFinished keeps the race alive while they return.

local Held = {}   -- identifier -> { oldSrc, raceId, expiresAt }

-- ── Hold (called from playerDropped in main.lua) ─────────────────────────────

function HoldForReconnect(oldSrc, pData)
    if not pData.identifier then return false end          -- can't match a return
    if pData.finished or pData.dnf then return false end

    local raceId = RaceSession.raceId
    local window = Config.ReconnectWindowMs or 60000

    pData.disconnected = true
    Held[pData.identifier] = {
        oldSrc    = oldSrc,
        raceId    = raceId,
        expiresAt = GetGameTimer() + window,
    }

    print(("[Reconnect] Holding slot for %s (%ds window)"):format(pData.name, window / 1000))
    BroadcastToRacers("SPZ:racerDisconnected", { name = pData.name, window = window / 1000 })

    CreateThread(function()
        Wait(window)
        local h = Held[pData.identifier]
        -- Already restored, or a different race by now: stand down
        if not h or h.raceId ~= RaceSession.raceId then return end
        Held[pData.identifier] = nil

        if pData.dnf or pData.finished then return end
        print(("[Reconnect] Window expired for %s — DNF"):format(pData.name))
        -- MarkDNF touches statebags/buckets of a gone player; harmless no-ops,
        -- but guard anyway so an engine change can never wedge the race end.
        pcall(MarkDNF, h.oldSrc, "disconnect")
    end)

    return true
end

-- ── Restore (identity fires SPZ:playerReady once the profile is loaded) ──────

local function LastCrossedCoords(pData)
    local cps = RaceSession.track and RaceSession.track.checkpoints
    if not cps then return nil end

    local idx = (pData.current_cp or 1) - 1
    if idx < 1 then
        -- Lap boundary (next expected is CP1): they crossed the final CP.
        -- Fresh race start edge case (lap 1, nothing crossed): CP1 itself.
        idx = (pData.current_lap or 1) > 1 and #cps or 1
    end

    local at  = cps[idx]
    local nxt = cps[pData.current_cp] or cps[1]
    local heading = 0.0
    if at and nxt and nxt ~= at then
        heading = math.deg(math.atan(-(nxt.coords.x - at.coords.x), nxt.coords.y - at.coords.y)) % 360
    end
    return at and at.coords or nil, heading
end

AddEventHandler("SPZ:playerReady", function(newSrc, profile)
    local identifier = GetPlayerIdentifierByType(newSrc, 'license')
    if not identifier then return end

    local h = Held[identifier]
    if not h then return end
    Held[identifier] = nil

    -- Race must still be the same one, and still running
    if h.raceId ~= RaceSession.raceId or RaceSession.state ~= SPZ.RaceState.LIVE then return end

    local pData = RaceSession.players[h.oldSrc]
    if not pData or pData.dnf or pData.finished then return end

    -- Re-key the session entry to the new source id
    RaceSession.players[h.oldSrc] = nil
    RaceSession.players[newSrc]   = pData
    pData.source       = newSrc
    pData.disconnected = nil
    pData.last_cp_time = GetGameTimer()   -- reset the idle-kick clock

    print(("[Reconnect] %s restored (lap %d, CP %d)"):format(pData.name, pData.current_lap, pData.current_cp))

    -- World: race bucket + statebags (mirrors world.lua's spawn block)
    exports["spz-core"]:AssignPlayerToBucket(newSrc, RaceSession.bucketId)
    local st = Player(newSrc).state
    st:set("inRace",       true,                       true)
    st:set("raceId",       RaceSession.raceId,         true)
    st:set("raceClass",    RaceSession.carClassId,     true)
    st:set("raceTrack",    RaceSession.track.name,     true)
    st:set("raceLap",      pData.current_lap or 1,     true)
    st:set("raceLaps",     RaceSession.track.laps or 1, true)
    st:set("racePosition", pData.position or 0,        true)

    -- Vehicle at the last crossed checkpoint, pointed at the next one
    local coords, heading = LastCrossedCoords(pData)
    if coords then
        local model = (type(RaceSession.carClass) == "table" and RaceSession.carClass.model) or "sultan"
        local ok, err = pcall(function()
            exports["spz-vehicles"]:SpawnRaceVehicle(newSrc, model, coords, heading, true)
            exports["spz-vehicles"]:UnlockRaceVehicle(newSrc)
        end)
        if not ok then
            print(("[Reconnect] Vehicle respawn failed for %s: %s"):format(pData.name, tostring(err)))
        end
    end

    -- Client: rebuild race state — checkpoints/blips, active CP, HUD threads
    local track = RaceSession.track
    TriggerClientEvent("SPZ:spawnCheckpoints", newSrc, track.checkpoints, pData.current_cp, track.type or "circuit")
    TriggerClientEvent("SPZ:nextCheckpoint",   newSrc, pData.current_cp)
    TriggerClientEvent("SPZ:go",               newSrc)   -- re-arms overlay, ghosting, incident watch

    TriggerClientEvent("ox_lib:notify", newSrc, {
        title = "Race", type = "success",
        description = ("Reconnected — lap %d, checkpoint %d. Go!"):format(pData.current_lap, pData.current_cp),
    })
    BroadcastToRacers("SPZ:racerReconnected", { name = pData.name })
end)

-- No explicit cleanup hook needed: every Held entry pins the raceId it belongs
-- to, and both the expiry thread and the restore path drop entries whose race
-- is no longer the current one.
