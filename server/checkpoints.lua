-- server/checkpoints.lua

-- ── 12.1 Finish handler ─────────────────────────────────────────────────────
local function HandleFinish(source, pData)
    if pData.finished or pData.dnf then return end

    pData.finished    = true
    pData.finish_time = GetGameTimer() - (pData.race_start_time or RaceSession.startTime)

    local track    = RaceSession.track
    local carClass = RaceSession.carClassId

    if GetResourceState("spz-leaderboard") == "started" then
        local prevBest        = exports["spz-leaderboard"]:GetPersonalBest(source, track.name, carClass)
        pData.personal_best   = (prevBest == nil) or (pData.finish_time < prevBest)
        if pData.personal_best then
            print(string.format("[Timing] New PB for %s on %s: %d ms", pData.name, track.name, pData.finish_time))
        end
    else
        pData.personal_best = false
    end

    print(string.format("[Race] %s (%d) finished in %d ms (PB: %s)",
        pData.name, source, pData.finish_time, tostring(pData.personal_best)))

    TriggerClientEvent("SPZ:raceFinished", source, pData.finish_time, pData.personal_best)

    if UpdateAllPositions then UpdateAllPositions() end
    CheckAllFinished()
end

-- ── 12.2 Checkpoint advance handler ────────────────────────────────────────
local function HandleCheckpointAdvance(source, pData)
    local track    = RaceSession.track
    local totalCPs = #track.checkpoints

    if pData.current_cp > totalCPs then
        if track.type == "circuit" then
            -- Lap completed
            local now          = GetGameTimer()
            local lapStartTime = pData.lap_start_time or RaceSession.startTime
            local lapTime      = now - lapStartTime

            pData.current_cp      = 1
            pData.current_lap     = pData.current_lap + 1
            pData.lap_start_time  = now

            table.insert(pData.lap_times, lapTime)
            if not pData.best_lap or lapTime < pData.best_lap then
                pData.best_lap = lapTime
            end

            print(string.format("[Race] %s lap %d done in %d ms", pData.name, pData.current_lap - 1, lapTime))
            TriggerClientEvent("SPZ:lapComplete", source, pData.current_lap - 1, lapTime)

            if pData.current_lap > track.laps then
                -- All laps done — wait for the start/finish cross
                pData.awaitingFinish = true
                TriggerClientEvent("SPZ:nextCheckpoint", source, 1)
            else
                TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
            end
        else
            -- Sprint: reaching end of CPs = instant finish
            HandleFinish(source, pData)
        end
    else
        TriggerClientEvent("SPZ:nextCheckpoint", source, pData.current_cp)
    end

    if UpdateAllPositions then UpdateAllPositions() end
end

-- ── 11.4 Hit validation ─────────────────────────────────────────────────────
RegisterNetEvent("SPZ:checkpointHit", function(cpIndex)
    local src   = source
    local pData = RaceSession.players[src]

    if not pData                                      then return end
    if pData.finished or pData.dnf                    then return end
    if RaceSession.state ~= SPZ.RaceState.LIVE        then return end
    if cpIndex ~= pData.current_cp                    then
        print(string.format("[Security] CP skip by %s: expected %d, got %d",
            pData.name, pData.current_cp, cpIndex))
        return
    end

    -- Circuit finish: player cleared all laps and crosses CP1 to stop the clock
    if pData.awaitingFinish and cpIndex == 1 then
        HandleFinish(src, pData)
        return
    end

    -- Record the time this CP was hit (used by the idle-kick watchdog below)
    pData.last_cp_time = GetGameTimer()

    pData.current_cp = pData.current_cp + 1
    HandleCheckpointAdvance(src, pData)
end)

-- ── Idle-kick watchdog ──────────────────────────────────────────────────────
-- If a racer has not crossed a single checkpoint within Config.IdleKickMs during
-- a live race they are assumed to have given up / gone AFK and are DNF'd.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(10000)  -- check every 10 s (low overhead)

        if RaceSession and RaceSession.state == SPZ.RaceState.LIVE then
            local cutoff = GetGameTimer() - (Config.IdleKickMs or 120000)

            for src, pData in pairs(RaceSession.players) do
                if not pData.finished and not pData.dnf then
                    local lastHit = pData.last_cp_time or RaceSession.startTime or 0
                    if lastHit < cutoff then
                        print(string.format("[Idle-Kick] %s (%d) timed out — no CP in %d s",
                            pData.name, src, (Config.IdleKickMs or 120000) / 1000))
                        MarkDNF(src, "idle")
                    end
                end
            end
        end
    end
end)

exports("HandleCheckpointAdvance", HandleCheckpointAdvance)
