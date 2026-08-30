-- server/main.lua

RaceSession = {
    state        = SPZ.RaceState.IDLE,
    raceId       = nil,
    raceType     = "circuit",
    track        = nil,
    carClass     = nil,
    carClassId   = nil,
    bucketId     = 0,
    startTime    = 0,
    players      = {},
    cycleCount   = 0,
    intermissionActive = false,
}

-- ── SetRaceState ──────────────────────────────────────────────────────────────
-- Single source of truth. Writes to GlobalState (replicated to all clients) and
-- fires a server-local event for modules that prefer events over statebags.
function SetRaceState(state)
    RaceSession.state = state
    GlobalState:set("raceState", state, true)
    TriggerEvent("SPZ:raceStateChanged", state)
end

exports("SetRaceState", SetRaceState)

-- ── BroadcastToRacers ─────────────────────────────────────────────────────────
-- Race-scoped client events must go to race participants ONLY. A -1 broadcast
-- leaks the race UI (countdown, checkpoints, standings, results) onto every
-- freeroaming player on the server.
function BroadcastToRacers(eventName, ...)
    for src in pairs(RaceSession.players) do
        if GetPlayerName(src) then
            TriggerClientEvent(eventName, src, ...)
        end
    end
end

-- ── ClearRaceState ────────────────────────────────────────────────────────────
-- Every per-player race statebag, cleared in one place. The same block used to
-- be copy-pasted into queue / checkpoints / dnf / cleanup and had already
-- drifted between copies, which is how players ended up stuck with inQueue or
-- inRace set and unable to join anything.
local RACE_STATE_KEYS = {
    "inRace", "inQueue", "queueClass", "queuePosition",
    "raceId", "raceClass", "raceTrack", "raceLap", "raceLaps",
    "personalBest", "allTimeBest", "racePosition", "raceTime",
}

function ClearRaceState(src, keepDnfFlag)
    if not GetPlayerName(src) then return end
    local st = Player(src).state
    for _, key in ipairs(RACE_STATE_KEYS) do
        st:set(key, nil, true)
    end
    st:set("inRace",  false, true)
    st:set("inQueue", false, true)
    if not keepDnfFlag then
        st:set("dnf", nil, true)
    end
end

exports("ClearRaceState", ClearRaceState)

-- ── ResetToIdle ───────────────────────────────────────────────────────────────
-- Abort path for a cycle that never reached the finish (empty queue, dead poll,
-- nobody spawned). This used to drop the players table and nothing else, so an
-- abort after SetupRaceWorld leaked the routing bucket for the server's whole
-- uptime, left raceId/track/bucketId pointing at a dead session, and left every
-- queued player with inQueue still set — permanently unable to rejoin.
function ResetToIdle()
    for src, pData in pairs(RaceSession.players) do
        if GetPlayerName(src) then
            -- Only players who actually made it into the race world need the
            -- world teardown; a cancelled poll leaves everyone in freeroam.
            if RaceSession.bucketId and RaceSession.bucketId ~= 0 then
                if GetResourceState("spz-vehicles") == "started" then
                    pcall(function() exports["spz-vehicles"]:DespawnVehicle(src) end)
                end
                exports["spz-core"]:AssignPlayerToBucket(src, 0)
                if not pData.teleportedToSafeZone then
                    pData.teleportedToSafeZone = true
                    TriggerClientEvent("SPZ:tpToSafeZone", src)
                end
            end
            ClearRaceState(src)
        end
    end

    if RaceSession.bucketId and RaceSession.bucketId ~= 0 then
        exports["spz-core"]:DeleteBucket(RaceSession.bucketId)
        print(string.format("[Race Engine] Aborted session — bucket %s released.", RaceSession.bucketId))
    end

    RaceSession.players            = {}
    RaceSession.raceId             = nil
    RaceSession.track              = nil
    RaceSession.selection          = nil
    RaceSession.carClass           = nil
    RaceSession.carClassId         = nil
    RaceSession.trafficLevel       = nil
    RaceSession.bucketId           = 0
    RaceSession.startTime          = 0
    RaceSession.finishWindowArmed  = false
    RaceSession.intermissionActive = false

    SetRaceState(SPZ.RaceState.IDLE)
    if BroadcastQueueUpdate then BroadcastQueueUpdate() end
end

exports("ResetToIdle", ResetToIdle)

-- ── Player race data factory ──────────────────────────────────────────────────
function CreatePlayerRaceData(src)
    return {
        source          = src,
        name            = GetPlayerName(src),
        identifier      = GetPlayerIdentifierByType(src, 'license'),  -- reconnect matching
        crew_tag        = nil,
        license_tier    = 1,
        current_lap     = 1,
        current_cp      = 1,
        lap_times       = {},
        sector_times    = {},
        finish_time     = nil,
        best_lap        = nil,
        position        = 0,
        finished        = false,
        dnf             = false,
        voted           = false,
        incidents       = {},    -- world impacts reported by the client during LIVE
        race_start_time = nil,
        gridIndex       = 0,
        gridCoords      = nil,   -- set by world.lua after spawn
        gridHeading     = 0.0,
        last_cp_time    = nil,
    }
end

-- ── Queue join / leave net events ─────────────────────────────────────────────
RegisterNetEvent("SPZ:joinQueue", function()
    JoinQueue(source)
end)

RegisterNetEvent("SPZ:leaveQueue", function()
    LeaveQueue(source)
end)

RegisterCommand("joinrace",  function(src) JoinQueue(src)  end, false)
RegisterCommand("leaverace", function(src) LeaveQueue(src) end, false)

-- ── BroadcastQueueUpdate ──────────────────────────────────────────────────────
-- Writes to GlobalState so any client can read queue info without polling.
function BroadcastQueueUpdate()
    local count = GetQueueCount()
    GlobalState:set("queueCount", count,                          true)
    GlobalState:set("raceType",   RaceSession.raceType or "circuit", true)
    TriggerClientEvent("SPZ:queueUpdated", -1, {
        count     = count,
        raceType  = RaceSession.raceType or "circuit",
        raceState = RaceSession.state,
    })
end

exports("BroadcastQueueUpdate", BroadcastQueueUpdate)

-- ── Resync handler ────────────────────────────────────────────────────────────
RegisterNetEvent("SPZ:requestResync", function()
    local src   = source
    local pData = RaceSession and RaceSession.players and RaceSession.players[src]
    if not pData then return end

    TriggerClientEvent("SPZ:nextCheckpoint", src, pData.current_cp)
    -- Do NOT re-write GlobalState.raceState here. It is already replicated to
    -- every client, and the server's own AddStateBagChangeHandler fires on any
    -- set — re-asserting the current value re-ran the lifecycle branch for that
    -- state (a resync landing on ENDED replayed ProcessRaceResults).

    if RaceSession.state == SPZ.RaceState.LIVE then
        local ranked  = CalculatePositions()
        local payload = {}
        for i, entry in ipairs(ranked) do
            local pd = RaceSession.players[entry.source]
            table.insert(payload, {
                source   = entry.source,
                name     = pd.name,
                crew_tag = pd.crew_tag,
                position = i,
                lap      = pd.current_lap,
                finished = pd.finished,
            })
        end
        TriggerClientEvent("SPZ:positionUpdate", src, payload, 0)
    end
end)

-- ── Disconnect export ─────────────────────────────────────────────────────────
exports("HandlePlayerDisconnect", function(src)
    if ClearPending then ClearPending(src) end
    local pData = RaceSession and RaceSession.players and RaceSession.players[src]
    if not pData then return end
    local activePhases = {
        [SPZ.RaceState.WAITING]   = true,
        [SPZ.RaceState.WARMUP]    = true,
        [SPZ.RaceState.COUNTDOWN] = true,
        [SPZ.RaceState.LIVE]      = true,
    }
    if activePhases[RaceSession.state] then
        if MarkDNF then MarkDNF(src, "disconnect") end
    else
        RaceSession.players[src] = nil
    end
end)

function CountPlayers()
    local n = 0
    for _ in pairs(RaceSession.players) do n = n + 1 end
    return n
end

-- ── Current race meta (read-only snapshot for external modules, e.g. spz-discord) ─
exports("GetRaceInfo", function()
    local t = RaceSession.track
    return {
        raceId   = RaceSession.raceId,
        state    = RaceSession.state,
        track    = t and t.name,
        trackId  = t and (t.id or t.name),
        type     = (t and t.type) or RaceSession.raceType,
        laps     = t and t.laps,
        carClass = RaceSession.carClassId,
        players  = CountPlayers(),
        startTime = RaceSession.startTime,
    }
end)

-- ── playerDropped ─────────────────────────────────────────────────────────────
AddEventHandler("playerDropped", function()
    local src   = source
    if ClearPending then ClearPending(src) end
    local pData = RaceSession.players[src]
    if not pData then return end

    local activePhases = {
        [SPZ.RaceState.WAITING]   = true,
        [SPZ.RaceState.WARMUP]    = true,
        [SPZ.RaceState.COUNTDOWN] = true,
        [SPZ.RaceState.LIVE]      = true,
    }

    if RaceSession.state == SPZ.RaceState.LIVE
    and HoldForReconnect and HoldForReconnect(src, pData) then
        -- Slot held: the reconnect window in server/reconnect.lua either
        -- restores them or DNFs them when it expires.
        return
    end

    if activePhases[RaceSession.state] then
        MarkDNF(src, "disconnect")
    else
        local name = pData.name
        RaceSession.players[src] = nil
        print(string.format("[Race Engine] Player %s left the queue.", name))

        if RaceSession.state == SPZ.RaceState.POLLING
        and GetQueueCount() < (Config.MinPlayersToStart or 1) then
            ResetToIdle()
        end
    end
end)
