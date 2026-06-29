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
    pollVotes    = {},
    pollOptions  = {},
    pollPhase    = 1,
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

-- ── ResetToIdle ───────────────────────────────────────────────────────────────
function ResetToIdle()
    SetRaceState(SPZ.RaceState.IDLE)
    RaceSession.players            = {}
    RaceSession.pollPhase          = 1
    RaceSession.intermissionActive = false
end

exports("ResetToIdle", ResetToIdle)

-- ── Player race data factory ──────────────────────────────────────────────────
function CreatePlayerRaceData(src)
    return {
        source          = src,
        name            = GetPlayerName(src),
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
    GlobalState:set("raceState", RaceSession.state, true)

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
