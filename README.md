# spz-races

> Race engine — queue, poll, countdown, checkpoints, sectors, results · `v1.9.0`

## Overview

`spz-races` runs the race. It owns the lifecycle state machine, the join queue, the track
vote, the grid and countdown, checkpoint and sector validation, live positions, DNF and
reconnect handling, results, and the intermission that loops back into the next race. The
server decides everything; clients only report checkpoint hits.

It also hosts the leaderboard back end (`server/leaderboard/`) — records, standings and
stats — which [spz-leaderboard](../spz-leaderboard/README.md) renders.

## Race flow

1. **Idle** → first player queues, arming a dynamic join window.
2. **Poll** — players vote on track and vehicle class ([spz-poll](../spz-poll/README.md)).
3. **Warmup** (60 s) — world set up, grid spawned, doubles as spawn grace.
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
| Shared | `shared/events.lua` | Event name constants |
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
| Server | `server/leaderboard/*.lua` | Records, standings, stats, callbacks |
| Server | `server/creator.lua` · `dev_heading.lua` | Track creation tooling |
| Client | `client/main.lua` · `nui_bridge.lua` | Race flow and UI delegation |
| Client | `client/checkpoints.lua` · `cp_cross.lua` · `hit_detector.lua` | Checkpoint rendering and detection |
| Client | `client/raceblips.lua` · `trackboard.lua` · `bonus.lua` | Blips, record boards, bonuses |
| Client | `client/lockin.lua` · `recover.lua` · `incidents.lua` | Grid lock, recovery, incidents |
| Client | `client/timetrail.lua` · `duel.lua` · `bots.lua` | Alternate modes |
| Client | `client/creator.lua` · `editor.lua` · `dev_heading.lua` | Track creation tooling |

## Exports

| Group | Exports |
|---|---|
| State | `GetRaceState` · `SetRaceState` · `ResetToIdle` |
| Queue | `JoinQueue` · `LeaveQueue` · `IsQueued` · `GetQueueCount` · `GetQueuePlayers` · `BroadcastQueueUpdate` · `FlushPendingToQueue` · `ClearPending` |
| Flow | `StartRacePoll` · `StartWarmupPhase` · `StartCountdownSequence` · `SetupRaceWorld` · `StartIntermission` · `RunRaceCleanup` |
| Checkpoints | `SetActiveCheckpoint` · `GetCurrentCP` · `HandleCheckpointAdvance` · `StartCheckpointVisuals` · `StopCheckpointVisuals` · `IsCheckpointVisualsActive` · `GetRespawnPoint` |
| Sectors | `RecordSectorHit` · `GetSessionBestSectors` |
| Positions | `CalculatePositions` · `UpdatePositions` |
| Results | `CheckAllFinished` · `ProcessRaceResults` · `MarkDNF` · `ProcessDNF` · `HandlePlayerDisconnect` |
| Time trial | `IsInTimeTrial` |
| Track tooling | `SaveTrack` · `AddTrackCheckpoint` · `DeleteLastCheckpoint` · `CancelTrackCreator` |
| Spawn | `ConfirmRaceSpawn` |

## Commands

| Command | Effect |
|---|---|
| `/joinrace` · `/leaverace` | Queue in / out |
| `/timetrail` · `/tt_restart` · `/quittt` | Time trial control |
| `/duel` | Challenge a player |
| `/spz_respawn_cp` · `/spz_flip_car` | Recovery |
| `/trackcreator` · `/trackeditor` · `/trackname` · `/tracktype` · `/fixheadings` · `/checkgateprops` | Track tooling |

## Dependencies

`ox_lib` · `spz-core` · `spz-identity` · `spz-vehicles` · `oxmysql`

## Credits

Checkpoint prop models by **BzZzi** —
[original release](https://forum.cfx.re/t/props-checkpoints/5267670).

---

Part of [SPiceZ-Core](../README.md) · GPL-3.0
