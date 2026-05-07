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

    elseif value == SPZ.RaceState.COUNTDOWN then
        -- World ready — push checkpoint data to all clients then start 3-2-1.
        Citizen.SetTimeout(0, function()
            local track = RaceSession.track
            if track and track.checkpoints then
                TriggerClientEvent("SPZ:spawnCheckpoints", -1,
                    track.checkpoints,
                    1,
                    track.type or "circuit")
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

-- ── Idle poll loop ─────────────────────────────────────────────────────────────
-- Fires every 5 s. Starts a new poll cycle when:
--   · state is IDLE
--   · intermission has expired
--   · queue has reached minimum player threshold
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(5000)
        if  RaceSession.state == SPZ.RaceState.IDLE
        and not RaceSession.intermissionActive
        and GetQueueCount() >= (Config.MinPlayersToStart or 1) then
            StartRacePoll()
        end
    end
end)
