-- server/positions.lua

-- 13.1 Position Calculation
local function GetDistToNextCP(source, pData)
    if not RaceSession.track or not RaceSession.track.checkpoints then return 9999.0 end
    
    local cpIndex = pData.current_cp
    local cp = RaceSession.track.checkpoints[cpIndex]
    if not cp then return 9999.0 end

    local ped = GetPlayerPed(source)
    if not DoesEntityExist(ped) then return 9999.0 end

    local playerPos = GetEntityCoords(ped)
    local cpPos = vector3(cp.coords.x, cp.coords.y, cp.coords.z)
    return #(playerPos - cpPos)
end

function CalculatePositions()
    local ranked = {}

    for source, pData in pairs(RaceSession.players) do
        if not pData.dnf then
            table.insert(ranked, {
                source    = source,
                finished  = pData.finished,
                lap       = pData.current_lap,
                cp        = pData.current_cp,
                finish_time = pData.finish_time or 0,
                -- Distance to next checkpoint (tiebreak)
                dist      = GetDistToNextCP(source, pData),
            })
        end
    end

    -- Sort logic: 
    -- 1. Finished players first (by finish_time asc)
    -- 2. Then by lap descending
    -- 3. Then by cp descending
    -- 4. Finally by distance to next CP ascending (closer is better)
    table.sort(ranked, function(a, b)
        if a.finished ~= b.finished then return a.finished end
        if a.finished and b.finished then return a.finish_time < b.finish_time end
        
        if a.lap ~= b.lap then return a.lap > b.lap end
        if a.cp  ~= b.cp  then return a.cp  > b.cp  end
        return a.dist < b.dist
    end)

    -- Update the actual player data objects
    for i, entry in ipairs(ranked) do
        RaceSession.players[entry.source].position = i
    end

    return ranked
end

-- Human-readable gap to the leader. We don't have per-CP timestamps for every
-- racer, so time gaps are only exact when two racers are on the same lap AND
-- checkpoint (compare their last-CP crossing times). Otherwise fall back to a
-- lap/checkpoint delta, which is honest and still useful.
function _gapToLeader(leader, pData, entry, leadEntry)
    if not leader or not leadEntry then return "" end
    if entry.source == leadEntry.source then return "LEADER" end
    if pData.finished then
        local d = (pData.finish_time or 0) - (leader.finish_time or 0)
        return d > 0 and ("+" .. string.format("%.2f", d / 1000)) or "+0.00"
    end

    local lapDiff = (leadEntry.lap or 1) - (entry.lap or 1)
    if lapDiff > 0 then
        return ("+%d L"):format(lapDiff)
    end

    local cpDiff = (leadEntry.cp or 1) - (entry.cp or 1)
    if cpDiff > 0 then
        return ("+%d CP"):format(cpDiff)
    end

    -- Same lap and CP: compare when each last crossed a checkpoint.
    if leader.last_cp_time and pData.last_cp_time then
        local d = pData.last_cp_time - leader.last_cp_time
        if d > 0 then return "+" .. string.format("%.2f", d / 1000) end
    end
    return "+0.00"
end

-- Unified gap string over the MERGED (human + bot) field. Both kinds carry
-- lap/cp/last_cp_time, so the same lap→cp→last-crossing fallback applies.
local function _mergedGap(leader, e)
    if not leader then return "" end
    if e == leader then return "LEADER" end
    if e.finished and leader.finished then
        local d = (e.ft or 0) - (leader.ft or 0)
        return d > 0 and ("+" .. string.format("%.2f", d / 1000)) or "+0.00"
    end
    local lapDiff = (leader.lap or 1) - (e.lap or 1)
    if lapDiff > 0 then return ("+%d L"):format(lapDiff) end
    local cpDiff = (leader.cp or 1) - (e.cp or 1)
    if cpDiff > 0 then return ("+%d CP"):format(cpDiff) end
    if leader.lct and e.lct then
        local d = e.lct - leader.lct
        if d > 0 then return "+" .. string.format("%.2f", d / 1000) end
    end
    return "+0.00"
end

-- 13.2 Periodic Broadcast
local _posVersion = 0

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(Config.PositionBroadcastInterval or 1000)

        if RaceSession.state == SPZ.RaceState.LIVE then
            local now = GetGameTimer()

            -- CalculatePositions ranks HUMANS only and sets pData.position — that
            -- stays the scoring truth (results.lua uses it). Bots are merged in
            -- below for DISPLAY only, so they never touch human scoring.
            CalculatePositions()

            local merged = {}
            for src, pData in pairs(RaceSession.players) do
                if not pData.dnf then
                    merged[#merged + 1] = {
                        bot = false, source = src, name = pData.name,
                        crew_tag = pData.crew_tag,
                        lap = pData.current_lap, cp = pData.current_cp,
                        finished = pData.finished, ft = pData.finish_time or 0,
                        lct = pData.last_cp_time or 0,
                    }
                end
            end
            if GetBotStandings then
                for _, br in ipairs(GetBotStandings(now)) do
                    merged[#merged + 1] = {
                        bot = true, source = br.id, name = br.name,
                        lap = br.lap, cp = br.cp, finished = br.finished,
                        ft = br.finish_time or 0, lct = br.last_cp_time or 0,
                    }
                end
            end

            table.sort(merged, function(a, b)
                if a.finished ~= b.finished then return a.finished end
                if a.finished and b.finished then return a.ft < b.ft end
                if a.lap ~= b.lap then return a.lap > b.lap end
                if a.cp  ~= b.cp  then return a.cp  > b.cp  end
                return (a.lct or 0) < (b.lct or 0)
            end)

            local leader = merged[1]
            local payload = {}
            for i, e in ipairs(merged) do
                payload[i] = {
                    source   = e.source,   -- number for humans, "bot_N" for bots
                    bot      = e.bot,
                    name     = e.name,
                    crew_tag = e.crew_tag,
                    position = i,
                    lap      = e.lap,
                    finished = e.finished,
                    gap      = _mergedGap(leader, e),
                }
            end

            _posVersion = _posVersion + 1
            -- Clients reject packets whose version is not strictly greater than their last
            BroadcastToRacers("SPZ:positionUpdate", payload, _posVersion)

            -- Statebags for reactive UI: humans get their DISPLAY position within
            -- the merged field (so "P2/6" counts the bots ahead).
            for i, e in ipairs(merged) do
                if not e.bot then
                    local src = e.source
                    local pData = RaceSession.players[src]
                    if pData then
                        Player(src).state:set("racePosition", i, true)
                        Player(src).state:set("raceLap", pData.current_lap, true)
                        Player(src).state:set("raceTime", now - (RaceSession.startTime or 0), true)
                    end
                end
            end
        end
    end
end)

-- Manual update trigger (e.g. immediately after a CP hit or finish)
function UpdateAllPositions()
    CalculatePositions()
    -- We can optionally force a broadcast here too if we want immediate HUD updates
end

-- Export for external systems
exports("UpdatePositions", UpdateAllPositions)
exports("CalculatePositions", CalculatePositions)
