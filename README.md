# spz-races

> Race engine — queue, poll, countdown, checkpoints, sectors, results · `v1.9.0`

## Overview

`spz-races` runs the race. It owns the lifecycle state machine, the join queue, the track
vote, the grid and countdown, checkpoint and sector validation, live positions, DNF and
reconnect handling, results, and the intermission that loops back into the next race.

The server decides everything. A client may *propose* an event — a checkpoint crossing, an
incident, a rewind — and the server accepts it only if it can check the claim against data
it owns: which gate you were due to cross and where you actually are, what state the race
is in, and hard per-race ceilings. The client owns timing precision, because only it has
the frame; it never owns an outcome.

It also hosts the leaderboard back end (`server/leaderboard/`) — records, standings and
stats — which [spz-leaderboard](../spz-leaderboard/README.md) renders.

## Race flow

1. **Idle** → first player queues, arming a dynamic join window.
2. **Poll** — players vote on track and vehicle class ([spz-poll](../spz-poll/README.md)).
3. **Warmup** (90 s) — world set up, grid spawned, doubles as spawn grace.
4. **Countdown** — grid settle, 3-2-1.
5. **Live** — checkpoints, sectors, positions, overtakes, incidents.
6. **Finish** — first finisher arms a straggler countdown (warned at 60/30/10 s), then
   force-DNF.
7. **Results + intermission** run in parallel; the next join window arms immediately.

Modes: standard race, time trial, and duel.

## Structure

| Side | File | Purpose |
|---|---|---|
| Shared | `config.lua` | Race configuration and tuning |
| Shared | `shared/race_states.lua` | Race state enum |
| Shared | `shared/events.lua` | Race event names, merged into `SPZ.Events` |
| Shared | `shared/points.lua` | Points scoring table |
| Shared | `shared/sectors.lua` | Sector split helpers |
| Server | `data/tracks.lua` | Track definitions (101 tracks: 76 circuit, 25 sprint) |
| Server | `server/main.lua` · `state_machine.lua` | Entry point and race lifecycle |
| Server | `server/queue.lua` · `poll.lua` | Join queue and track vote |
| Server | `server/world.lua` · `countdown.lua` · `lapcount.lua` | World setup, grid, lap count |
| Server | `server/checkpoints.lua` · `sectors.lua` | Checkpoint and sector authority |
| Server | `server/positions.lua` · `overtakes.lua` · `incidents.lua` | Live standings, pass clips, incidents |
| Server | `server/dnf.lua` · `reconnect.lua` | DNF and mid-race rejoin |
| Server | `server/results.lua` · `cleanup.lua` · `intermission.lua` | Results, teardown, next cycle |
| Server | `server/timetrail.lua` · `duel.lua` · `bots.lua` | Alternate modes and AI |
| Server | `server/leaderboard/*.lua` | Records, standings, stats, race archive, callbacks |
| Server | `server/creator.lua` · `dev_heading.lua` | Track creation tooling |
| Client | `client/main.lua` · `nui_bridge.lua` | Race flow and UI delegation |
| Client | `client/checkpoints.lua` · `cp_cross.lua` · `hit_detector.lua` | Checkpoint rendering and detection |
| Client | `client/raceblips.lua` · `trackboard.lua` · `bonus.lua` | Blips, record boards, bonus and overtake flourishes |
| Client | `client/lockin.lua` · `recover.lua` · `incidents.lua` | Grid lock, recovery, incidents |
| Client | `client/rewind.lua` · `showcase.lua` | Time rewind, post-race car showcase |
| Client | `client/timetrail.lua` · `duel.lua` · `bots.lua` | Alternate modes |
| Client | `client/creator.lua` · `editor.lua` · `dev_heading.lua` | Track creation tooling |

## Exports

| Group | Exports |
|---|---|
| State | `GetRaceState` · `SetRaceState` · `ResetToIdle` · `ClearRaceState` |
| Queue | `JoinQueue` · `LeaveQueue` · `IsQueued` · `GetQueueCount` · `GetQueuePlayers` · `BroadcastQueueUpdate` · `FlushPendingToQueue` · `ClearPending` |
| Flow | `StartRacePoll` · `StartWarmupPhase` · `StartCountdownSequence` · `SetupRaceWorld` · `StartIntermission` · `RunRaceCleanup` |
| Checkpoints | `SetActiveCheckpoint` · `GetCurrentCP` · `HandleCheckpointAdvance` · `StartCheckpointVisuals` · `StopCheckpointVisuals` · `IsCheckpointVisualsActive` · `GetRespawnPoint` |
| Sectors | `RecordSectorHit` · `GetSessionBestSectors` |
| Positions | `CalculatePositions` · `UpdatePositions` |
| Results | `CheckAllFinished` · `ProcessRaceResults` · `MarkDNF` · `ProcessDNF` · `HandlePlayerDisconnect` |
| Time trial | `IsInTimeTrial` |
| Track tooling | `SaveTrack` · `AddTrackCheckpoint` · `DeleteLastCheckpoint` · `CancelTrackCreator` |
| Spawn | `ConfirmRaceSpawn` |

## Events

Names live in `shared/events.lua` and are merged into `SPZ.Events`
(`spz-core/shared/events.lua`). Other resources import
`'@spz-core/shared/events.lua'` to see them — each resource has its own Lua state.

| Event | When | Use for |
|---|---|---|
| `SPZ:racerFinished` | Once per **finisher**, on crossing | Feeds, telemetry, showcase. Field still incomplete. |
| `SPZ:raceEnd` | Once per **race**, from `ProcessRaceResults` | Scoring, persistence, payouts. |
| `SPZ:standings` | Every `Config.StandingsBroadcastInterval` | Live race board (spz-spectate), other out-of-race UIs. |
| `SPZ:raceStateChanged` | Every lifecycle transition | Anything that mirrors race phase. |

`SPZ:raceEnd` is fired by `ProcessRaceResults` and nowhere else. Firing it per finisher ran
every listener twice per race — double progression, duplicate result rows, and a Discord
post per finisher.

## Anti-abuse

| Claim | Server check |
|---|---|
| Checkpoint hit | Must be the gate the racer is due to cross, and the ped must be within range of it |
| Incident report | Speed sanity-checked against `Config.Incidents.minImpactSpeed`, capped per race |
| Rewind credit | Clamped per claim (history buffer), per lap (`maxCreditPerLapMs`), and epochs can never pass `now` |

A run that credits any rewind time carries `rewind_ms > 0` into results and is barred from
track records, personal bests and raceline storage. Rewind earns no credit at all inside a
duel.

## Commands

| Command | Effect |
|---|---|
| `/joinrace` · `/leaverace` | Queue in / out |
| `/timetrail` · `/tt_restart` · `/quittt` | Time trial control (leaving the car also ends the run) |
| `/duel` | Challenge a player |
| `/spz_respawn_cp` (F4) · `/spz_flip_car` (X) | Recovery — offered by name when you miss a checkpoint |
| `/trackcreator` · `/trackeditor` · `/trackname` · `/tracktype` · `/fixheadings` · `/checkgateprops` | Track tooling |

## Dependencies

`ox_lib` · `spz-core` · `spz-identity` · `spz-vehicles` · `oxmysql`

## Credits

Checkpoint prop models by **BzZzi** —
[original release](https://forum.cfx.re/t/props-checkpoints/5267670).

---

Part of [SPiceZ-Core](../README.md) · GPL-3.0
