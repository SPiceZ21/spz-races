-- server/state_machine.lua
-- Native FiveM statebag-driven race lifecycle orchestration.
-- Reacts to GlobalState.raceState changes; no custom events needed.

-- ── Seed GlobalState on resource start ───────────────────────────────────────
GlobalState:set("raceState",  SPZ.RaceState.IDLE, true)
GlobalState:set("queueCount", 0,                  true)
GlobalState:set("raceType",   "circuit",           true)

-- ── State transition handler ──────────────────────────────────────────────────
AddStateBagChangeHandler("raceState", "global", function(bagName, key, value)
    if not value then return end

    if value == SPZ.RaceState.WAITING then
        -- Poll finished — vehicle + track selected; spin up race world.
        Citizen.SetTimeout(0, function()
            SetupRaceWorld()
        end)

    elseif value == SPZ.RaceState.WARMUP then
        -- Spawn just finished → push checkpoint blips/GPS so players can scout the track,
        -- then start the free-drive warmup timer.
        Citizen.SetTimeout(0, function()
            local track = RaceSession.track
            if track and track.checkpoints then
                BroadcastToRacers("SPZ:spawnCheckpoints",
                    track.checkpoints,
                    1,
                    track.type or "circuit")
            end
            StartWarmupPhase()
        end)

    elseif value == SPZ.RaceState.COUNTDOWN then
        -- Checkpoints already pushed during WARMUP.  If warmup was skipped, push now.
        Citizen.SetTimeout(0, function()
            if (Config.WarmupTimeSeconds or 0) == 0 then
                local track = RaceSession.track
                if track and track.checkpoints then
                    BroadcastToRacers("SPZ:spawnCheckpoints",
                        track.checkpoints,
                        1,
                        track.type or "circuit")
                end
            end
            StartCountdownSequence()
        end)

    elseif value == SPZ.RaceState.ENDED then
        -- All racers finished or DNF → process results, show screen, then clean up.
        Citizen.CreateThread(function()
            local results = ProcessRaceResults()
            Citizen.Wait(Config.ResultsDisplayTime or 15000)
            RunRaceCleanup(results)
        end)
    end
end)

-- ── Idle watchdog ──────────────────────────────────────────────────────────────
-- Fires every 5 s. If anyone is queued while the engine idles (e.g. players
-- flushed in after intermission), (re)arm the join-window countdown — the
-- window itself starts the poll when it expires. No minimum player count.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(5000)
        if  RaceSession.state == SPZ.RaceState.IDLE
        and not RaceSession.intermissionActive
        and GetQueueCount() >= 1 then
            ArmJoinWindow()
        end
    end
end)
