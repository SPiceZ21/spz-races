<div align="center">

<img src="https://github.com/SPiceZ21/spz-core-media-kit/raw/main/Banner/Banner%232.png" alt="SPiceZ-Core Banner" width="100%"/>

<br/>

# spz-races

### Race Engine

*The largest and most critical module in the framework. Owns the complete race lifecycle — from the moment a player joins the queue to the moment they are teleported back to the safe zone.*

<br/>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-orange.svg?style=flat-square)](https://www.gnu.org/licenses/gpl-3.0)
[![FiveM](https://img.shields.io/badge/FiveM-Compatible-orange?style=flat-square)](https://fivem.net)
[![Lua](https://img.shields.io/badge/Lua-5.4-blue?style=flat-square&logo=lua)](https://lua.org)
[![Status](https://img.shields.io/badge/Status-Designing-blue?style=flat-square)]()

</div>

---

## Overview

`spz-races` is the heart of SPiceZ-Core. It drives a continuous race loop: queue fills → community votes on track and class → isolated race world is built → countdown fires → race runs → results broadcast → cleanup → repeat.

Every state transition, checkpoint validation, timing calculation, and position update is authoritative on the server. The client is never trusted for anything that affects race integrity.

**Owns:**
- Race state machine (`IDLE → POLLING → WAITING → COUNTDOWN → LIVE → ENDED → CLEANUP`)
- Lobby queue, pre-poll countdown, and vote system
- Routing bucket allocation and race world teardown
- Ghost car (no-collision) setup between all racers
- Server-authoritative countdown — clients cannot move until `SPZ:go`
- Checkpoint spawning and server-side hit validation — no checkpoint skipping
- Lap counter, timing engine, sector splits, and personal best detection
- Live position broadcast (P1–PN) every second
- DNF handling for disconnects, timeouts, and disqualifications
- Results object construction and broadcast to downstream modules
- Race cleanup, player TP back to safe zone, and intermission

**Does not own:**
- XP, points, SR, iRating → `spz-progression`
- Prize pool distribution → `spz-economy`
- Writing results to DB → `spz-leaderboard`
- Rendering HUD, countdown, poll UI → `spz-hud`
- Spawning vehicles → `spz-vehicles`
- Routing bucket management → `spz-core`

---

## Race Types

### Circuit
Multi-lap loop. The track wraps — last checkpoint leads back to first. Timing tracks per-lap splits and a total race time.
```
CP[1] → CP[2] → ... → CP[N] → CP[1] (lap 2) → ... → finish
```

### Sprint
Point-to-point. No laps. The final checkpoint is the finish line. Timing records a single run time only.
```
CP[1] → CP[2] → ... → CP[N] → finish
```

Cycle type alternates `circuit → sprint → circuit → sprint` automatically (configurable via `Config.CycleOrder`).

---

## Race State Machine

```
IDLE → POLLING → WAITING → COUNTDOWN → LIVE → ENDED → CLEANUP → IDLE
```

| State | What is happening |
|---|---|
| `IDLE` | No race active — intermission timer running, queue accepting players |
| `POLLING` | Track + car class vote open for `Config.PollDuration` seconds |
| `WAITING` | Votes closed — players being TP'd to grid, vehicles being spawned |
| `COUNTDOWN` | 3-2-1-GO — all racers frozen on grid, server-synced |
| `LIVE` | Race in progress — timing, checkpoints, and positions active |
| `ENDED` | All players finished or timed out — results calculated |
| `CLEANUP` | Bucket deleted, players TP'd back, intermission begins |

---

## Dependencies

| Resource | Type | Role |
|---|---|---|
| `spz-lib` | Required | Timers, math (GridPositions, FormatTime), notify |
| `spz-core` | Required | State machine, routing buckets, sessions, event bus |
| `spz-identity` | Required | License gate on queue join, crew tags in results |
| `spz-vehicles` | Required | Race spawn, despawn, door lock/unlock |

```cfg
ensure spz-lib
ensure spz-core
ensure spz-identity
ensure spz-vehicles
ensure spz-races
```

---

## Player Commands

```
/joinrace    -- Enter the global race queue
/leaverace   -- Exit the queue (only available during IDLE or POLLING states)
```

---

## The Race Loop

1. **Queue** — Players join via `/joinrace`. Poll opens once `Config.MinPlayersToStart` is reached.
2. **Poll** — Community votes on two track options and two car class options. Tie-break is random. Non-voters get the winner applied.
3. **Setup** — Server allocates a routing bucket, calculates the start grid, spawns race-tuned vehicles, applies ghost-car no-collision between all pairs.
4. **Countdown** — 3-2-1-GO. Players are frozen until the server fires `SPZ:go`.
5. **Race** — Checkpoints must be hit in order. The server validates every hit — skipping is impossible. Lap times recorded per-lap (circuit) or single run (sprint).
6. **Results** — Finish order, times, and F1 points calculated. `SPZ:raceEnd` fires — `spz-progression`, `spz-economy`, and `spz-leaderboard` listen here.
7. **Cleanup** — Vehicles despawned, bucket deleted, players TP'd to safe zone. Intermission countdown starts.

---

## Poll System

Two simultaneous polls — track vote and car class vote. Both use 2 options.

- Class options offered are limited to tiers **every queued player holds a license for** — no one can be locked out of a race they joined.
- Track options are weighted-random from the current cycle type pool (`circuit` or `sprint`).
- Tie-break: random selection.
- Players who don't vote in time get a random vote applied automatically.

---

## Checkpoint Validation

The client sends `SPZ:checkpointHit(index)` — the server validates:
1. The player is in the race and not finished/DNF
2. The index matches the player's expected next checkpoint
3. (Optional) The player's server-side position is within the checkpoint radius

This prevents any form of checkpoint skipping.

---

## Track Registry

55 tracks total converted from GTA V Race Creator exports:

| Type | Count | Format |
|---|---|---|
| Circuit | 41 | Multi-lap loop, 3–5 laps |
| Sprint | 14 | Point-to-point, 1 run |

Tracks are stored in `data/tracks.lua` (auto-generated — never edit manually). Use `tools/convert_tracks.py` to regenerate from raw JSON exports.

---

## Exports Reference

```lua
-- Queue
exports["spz-races"]:JoinQueue(source)
exports["spz-races"]:LeaveQueue(source)
exports["spz-races"]:GetQueueCount()          -- number
exports["spz-races"]:GetQueuePlayers()        -- [source, ...]
exports["spz-races"]:IsQueued(source)         -- bool

-- Race state
exports["spz-races"]:GetRaceState()           -- SPZ.RaceState.*
exports["spz-races"]:GetRaceSession()         -- RaceSession{}
exports["spz-races"]:GetPlayerRaceData(src)   -- PlayerRaceData{} | nil

-- Admin
exports["spz-races"]:ForceEndRace(reason)     -- called by spz-admin
exports["spz-races"]:ForceStartPoll()         -- skip pre-poll countdown
```

---

## Key Events

### Fired by spz-races

| Event | Payload | When |
|---|---|---|
| `SPZ:pollOpen` | `{tracks, classes, duration}` | Poll opens |
| `SPZ:pollResult` | `{track, class, type, laps}` | Poll closes — winner announced |
| `SPZ:freezeRacer` | `bool` | Freeze on countdown, unfreeze on GO |
| `SPZ:countdown` | `number` | 3, 2, 1 ticks |
| `SPZ:go` | — | Race starts |
| `SPZ:applyNoCollision` | `targetPed` | Ghost car setup |
| `SPZ:positionUpdate` | `[{source, name, position, lap}]` | Every broadcast interval |
| `SPZ:raceEnd` | `results{}` | Race over — downstream modules react |
| `SPZ:tpToSafeZone` | — | After cleanup |
| `SPZ:intermissionStart` | `{seconds, nextType}` | Intermission begins |

### Listened to by spz-races

| Event | Fired by | Action |
|---|---|---|
| `SPZ:pollVote` | Client → Server | Record player vote |
| `SPZ:checkpointHit` | Client → Server | Validate and advance checkpoint |
| `SPZ:raceVehicleSpawned` | spz-vehicles | Track spawn confirmations for WAITING → COUNTDOWN |
| `SPZ:playerDisconnected` | spz-core | DNF mid-race disconnect |
| `SPZ:playerReady` | spz-identity | Register player as race-eligible |

---

## Configuration

```lua
Config.MinPlayersToStart         = 2        -- min queue size to open poll
Config.PollWaitTime              = 10       -- seconds after threshold before poll opens
Config.MaxPlayersPerRace         = 16       -- hard cap on queue size
Config.PollDuration              = 30       -- seconds the poll stays open
Config.CycleOrder                = { "circuit", "sprint" }   -- alternates each race
Config.CountdownSeconds          = 3        -- 3-2-1-GO
Config.RaceTimeout               = 300000   -- 5 min DNF timeout (ms)
Config.PositionBroadcastInterval = 1000     -- ms between live position updates
Config.ResultsDisplayTime        = 15000    -- ms stats screen shown before TP back
Config.IntermissionTime          = 60       -- seconds between races
Config.GridRowSpacing            = 8.0      -- metres front-to-back
Config.GridColSpacing            = 4.5      -- metres side-to-side
```

---

<div align="center">

*Part of the [SPiceZ-Core](https://github.com/SPiceZ-Core) ecosystem*

**[Docs](https://github.com/SPiceZ-Core/spz-docs) · [Discord](https://discord.gg/) · [Issues](https://github.com/SPiceZ-Core/spz-races/issues)**

</div>
