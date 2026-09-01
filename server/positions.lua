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

local function _fmtGap(ms)
    if ms < 0 then ms = 0 end
    if ms >= 60000 then
        return ("+%d:%05.2f"):format(math.floor(ms / 60000), (ms % 60000) / 1000)
    end
    return ("+%.2f"):format(ms / 1000)
end

-- Gap string between two entries in the field.
--
-- Real TIME gap, not a checkpoint count. Every entry carries the progress index
-- it has reached (gates cleared since GO) and can answer "what was your elapsed
-- time when you reached index N". The gap is then the plain
-- question a pit wall asks: how long ago was the leader standing where this car
-- is now?
--
--   gap = e.elapsedAt(e.idx) - leader.elapsedAt(e.idx)
--
-- That works unchanged when the two are on different laps, which is exactly the
-- case the old "+2 CP" / "+1 L" text existed to paper over. A lapped car reads
-- as the real time it is down, and the "1 L" fact is kept as a suffix because
-- being lapped is information a time alone does not convey.
local function _mergedGap(leader, e)
    if not leader then return "" end
    if e == leader then return "LEADER" end

    if e.finished and leader.finished then
        return _fmtGap((e.ft or 0) - (leader.ft or 0))
    end

    local lapDiff = (leader.lap or 1) - (e.lap or 1)

    -- Leader's elapsed time when they were at this car's current position.
    local mine = e.elapsedAt and e.elapsedAt(e.idx)
    local his  = leader.elapsedAt and leader.elapsedAt(e.idx)

    if mine and his then
        local gap = _fmtGap(mine - his)
        return lapDiff > 0 and (gap .. " " .. lapDiff .. "L") or gap
    end

    -- No banked crossing for one of them yet (first gate of the race, or a
    -- racer restored mid-race with no history). Fall back to the old text
    -- rather than printing a time that is not measured.
    if lapDiff > 0 then return ("+%d L"):format(lapDiff) end
    local cpDiff = (leader.cp or 1) - (e.cp or 1)
    if cpDiff > 0 then return ("+%d CP"):format(cpDiff) end
    if leader.lct and e.lct then
        local d = e.lct - leader.lct
        if d > 0 then return _fmtGap(d) end
    end
    return "+0.00"
end

-- 13.2 Periodic Broadcast
local _posVersion = 0
local _lastStandingsAt = 0

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(Config.PositionBroadcastInterval or 1000)

        if RaceSession.state == SPZ.RaceState.LIVE then
            local now = GetGameTimer()

            -- CalculatePositions sets pData.position — the scoring truth
            -- results.lua reads. The list built below is the DISPLAY order sent
            -- to the tower; it used to merge replayed ghost-bots into the field,
            -- which is gone, so the two now describe the same set of racers.
            CalculatePositions()

            local merged = {}
            for src, pData in pairs(RaceSession.players) do
                if not pData.dnf then
                    local st = Player(src).state
                    merged[#merged + 1] = {
                        source = src, name = pData.name,
                        crew_tag = pData.crew_tag,
                        nation = st and st['spz:nation'] or nil,
                        raceNumber = st and st['spz:raceNumber'] or nil,
                        lap = pData.current_lap, cp = pData.current_cp,
                        finished = pData.finished, ft = pData.finish_time or 0,
                        lct = pData.last_cp_time or 0,
                        -- Held slot: dropped mid-race, inside the reconnect
                        -- window. They keep their place in the tower, but the
                        -- UI should say why they are not moving.
                        dc = pData.disconnected and true or false,
                        -- Gates cleared, and the banked elapsed time at any of
                        -- them — the two facts a real time gap needs.
                        idx = pData.progress_idx or 0,
                        elapsedAt = function(i) return CPProgressAt(pData, i) end,
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
                    source     = e.source,
                    name       = e.name,
                    crew_tag   = e.crew_tag,
                    nation     = e.nation,
                    raceNumber = e.raceNumber,
                    position   = i,
                    lap        = e.lap,
                    finished   = e.finished,
                    dc         = e.dc or false,
                    gap        = _mergedGap(leader, e),
                    -- Gap to the car directly ahead. Same measurement, different
                    -- reference — a tower usually wants both: `gap` says where
                    -- you are in the race, `interval` says whether you are
                    -- catching the car you can actually see.
                    interval   = (i > 1) and _mergedGap(merged[i - 1], e) or "LEADER",
                }
            end

            _posVersion = _posVersion + 1
            -- Clients reject packets whose version is not strictly greater than their last
            BroadcastToRacers("SPZ:positionUpdate", payload, _posVersion)

            -- Server-side standings feed for out-of-race modules (the live
            -- race board in spz-spectate):
            -- BroadcastToRacers only reaches racers, so freeroamers/spectators and
            -- other resources get the live order here. Same payload.
            --
            -- Throttled independently of the racer HUD feed. Racers need 1 Hz to
            -- keep the gap tower honest; a passive freeroam board does not, and
            -- every emit here fans out to everyone not in the race.
            local standingsEvery = Config.StandingsBroadcastInterval or 2500
            if (now - _lastStandingsAt) >= standingsEvery then
                _lastStandingsAt = now
                TriggerEvent(SPZ.Events.STANDINGS, payload, _posVersion)
            end

            -- Statebags for reactive UI: each racer gets their DISPLAY position.
            for i, e in ipairs(merged) do
                local src   = e.source
                local pData = RaceSession.players[src]
                -- Finished racers stay in `merged` so the standings board keeps
                -- showing them, but their statebags were already cleared by
                -- HandleFinish and they have been teleported to the safe zone.
                -- Writing here resurrected the race HUD on a player who is no
                -- longer racing.
                if pData and not pData.finished and not pData.dnf then
                    Player(src).state:set("racePosition", i, true)
                    Player(src).state:set("raceLap", pData.current_lap, true)
                    -- Per-racer epoch: a rewind shifts race_start_time forward,
                    -- so this clock winds back with the car.
                    Player(src).state:set("raceTime",
                        now - (pData.race_start_time or RaceSession.startTime or 0), true)
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
