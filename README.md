# spz-races

> The race engine: queue, vote, grid, warmup, checkpoints, timing and results.

![version](https://img.shields.io/badge/version-1.45.0-ff6200) ![SPiceZ-Core](https://img.shields.io/badge/SPiceZ--Core-beta-18181b)

## Overview

Runs the whole race loop on the server. Players queue, vote on track and car class (spz-poll), spawn on a grid in a private bucket, free-drive a warmup, then race. Lap, sector and finish times are measured server-side. Also includes Time Trials, duels and **Track Studio** for building tracks in the world.

## Features

- Queue → vote → warmup → countdown → race → results cycle
- Late join during warmup
- Server-side lap / sector / finish timing
- Road-following GPS route and 3D distance pills over the next gates
- Rewind, flip and back-to-checkpoint recovery
- Time Trials and 1v1 duels
- Track Studio: drive the route and drop gates (`custom_tracks.json`)
- Flag girl race start

## Requirements

| Resource | Type |
|---|---|
| `ox_lib` | third-party |
| `spz-core` | SPiceZ module |
| `spz-identity` | SPiceZ module |
| `spz-vehicles` | SPiceZ module |
| `oxmysql` | third-party |

## Installation

Included in the [txAdmin recipe](https://github.com/SPiceZ21/spz-txrecipe). Manual install:

1. Download `spz-races` from GitHub (latest release, or the repository) into your `resources` folder.
2. Add to `server.cfg`, after its requirements:

```cfg
ensure spz-races
```

## Configuration

- `config.lua`
- `server/leaderboard/config.lua`

See the file for every option.

## Commands

| Command | Who | Description |
|---|---|---|
| `/duel` | player | `/duel <player> <track> <stake>` — challenge a player |
| `/joinrace` | player | Join the race queue (also `E` in freeroam) |
| `/leaverace` | player | Leave the queue / race |
| `/quittt` | player | Quit the time trial |
| `/srace` | player | Start a quick solo race |
| `/timetrail` | player | Start a time trial |
| `/clearstart` | admin | Remove a surveyed start line |
| `/racehud` | admin | Re-read race HUD convars |
| `/setstart` | admin | Survey a start line for a track |
| `/startlines` | admin | List surveyed start lines |
| `/checkgateprops` | dev | Check gate prop models resolve |
| `/copdebug` | dev | Cop-chase debug overlay |
| `/cpdebug` | dev | Draw checkpoint gates in 3D |
| `/fixheadings` | dev | Recompute gate headings |
| `/flagdrop` | dev | Preview the flag girl animation |
| `/racesoundtest` | dev | Play the grid sounds |
| `/wantedtest` | dev | Preview the wanted HUD |

## Key binds

Rebindable in **Settings → Key Bindings → FiveM**.

| Action | Default |
|---|---|
| Race: tune car during warmup | `Y` |
| Race: back to last checkpoint | `F4` |
| Race: flip car upright | `K` |
| Race: Rewind Time | `B` |
| Time Trial — Restart to Start | `BACK` |

## Exports

| Export | Side |
|---|---|
| `ConfirmRaceSpawn` | server |
| `GetCheckpointDebug` | client |
| `GetCurrentCP` | client |
| `GetQueueCount` | server |
| `GetRaceInfo` | server |
| `GetRespawnPoint` | client |
| `GetRewindCreditMs` | client |
| `GetTTCpIndex` | client |
| `HandlePlayerDisconnect` | server |
| `IsInTimeTrial` | server |
| `IsQueued` | server |
| `IsRewinding` | client |
| `IsTrackCreatorActive` | client |
| `IsTrackEditorActive` | client |
| `IsTrackStudioActive` | client |
| `JoinQueue` | server |
| `LeaveQueue` | server |
| `MarkDNF` | server |
| `SetActiveCheckpoint` | client |
| `SetRaceState` | server |
| `StartCheckpointVisuals` | client |
| `StopCheckpointVisuals` | client |

```lua
exports["spz-races"]:ConfirmRaceSpawn(...)
```

## Notes

- Tracks built in Track Studio are stored in `data/custom_tracks.json`, not the database — back that file up.

---

Part of **SPiceZ-Core** — [documentation](https://github.com/SPiceZ21/Docs) · [all modules](https://github.com/SPiceZ21/Docs/blob/main/modules/README.md)
