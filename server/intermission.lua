-- server/intermission.lua

-- 17. Intermission logic
-- Runs OVERLAPPED with the post-race results screen: StartIntermission is
-- called by the ENDED handler the moment results are broadcast, so the
-- between-races countdown ticks while finishers are still reading their stats.
-- Cleanup (TP back, bucket teardown) happens mid-intermission at the
-- ResultsDisplayTime mark — see state_machine.lua.
function StartIntermission(results)
    local lastResults = {}
    if results and results.finishers then
        for i, racer in ipairs(results.finishers) do
            table.insert(lastResults, {
                name     = racer.name,
                position = racer.position,
                time     = racer.finish_time and string.format("%.2fs", racer.finish_time / 1000) or "DNF",
            })
            if i >= 3 then break end
        end
    end

    -- Cleanup hasn't bumped the cycle counter yet — announce the next type
    -- from the upcoming count so the HUD matches what cleanup will pick.
    local nextType = NextCycleType and NextCycleType((RaceSession.cycleCount or 0) + 1) or "circuit"

    -- Block the idle polling loop for the whole window. Cleanup re-asserts
    -- this after it resets RaceSession; the end of the timer clears it.
    RaceSession.intermissionActive = true

    local playersInQueue = exports["spz-races"]:GetQueueCount()

    -- The countdown must outlive the results screen, or the end-callback would
    -- unblock the idle loop before cleanup re-blocks it and wedge the engine.
    local seconds = math.max(
        Config.IntermissionTime or 30,
        math.ceil((Config.ResultsDisplayTime or 12000) / 1000) + 5
    )

    print(string.format("[Race Engine] Starting %ds intermission (overlapped with results). Next race type: %s",
        seconds, nextType))

    -- 17.1 Broadcast start event to all clients for HUD countdowns
    TriggerClientEvent("SPZ:intermissionStart", -1, {
        seconds        = seconds,
        nextType       = nextType,
        lastResults    = lastResults,
        playersInQueue = playersInQueue
    })

    -- 17.2 When the window ends, reopen the queue and arm the join window
    -- immediately — no waiting for the 5s idle-loop watchdog.
    Citizen.SetTimeout(seconds * 1000, function()
        print("[Race Engine] Intermission over. Queue is open.")
        RaceSession.intermissionActive = false

        -- NO auto re-queue of last race's participants: every race requires an
        -- explicit [E] join. Only players who pressed E during the race
        -- (pending) are enrolled automatically — that WAS their explicit join.
        if FlushPendingToQueue then FlushPendingToQueue() end

        BroadcastQueueUpdate()

        if GetQueueCount() >= 1 then
            ArmJoinWindow()
        end
    end)
end

-- Called by the ENDED handler in state_machine.lua (overlapped with results)
exports("StartIntermission", StartIntermission)
