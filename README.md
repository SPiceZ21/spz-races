<div align="center">

<img src="https://github.com/SPiceZ21/spz-core-media-kit/raw/main/Banner/Banner%232.png" alt="SPiceZ-Core Banner" width="100%"/>

<br/>

# spz-races
> Race engine, poll, timing, checkpoints · `v1.7.6`

## Scripts

| Side   | File                        | Purpose                                               |
| ------ | --------------------------- | ----------------------------------------------------- |
| Shared | `config.lua`                | Race configuration, tuning parameters                 |
| Shared | `shared/race_states.lua`    | Race state enum definitions                           |
| Shared | `shared/events.lua`         | Shared event name constants                           |
| Shared | `shared/points.lua`         | Points scoring table and logic                        |
| Server | `data/tracks.lua`           | Track definitions and metadata                        |
| Server | `server/main.lua`           | Entry point, event registration                       |
| Server | `server/state_machine.lua`  | Race lifecycle state machine                          |
| Server | `server/queue.lua`          | Player queue management for race entry                |
| Server | `server/poll.lua`           | Track and vehicle vote poll integration               |
| Server | `server/world.lua`          | World setup (weather, time, routing buckets)          |
| Server | `server/no_collision.lua`   | Disable player-player collisions during race          |
| Server | `server/countdown.lua`      | Race start countdown orchestration                    |
| Server | `server/checkpoints.lua`    | Server-side checkpoint authority and validation       |
| Server | `server/positions.lua`      | Live race position tracking                           |
| Server | `server/dnf.lua`            | Did-not-finish detection and handling                 |
| Server | `server/results.lua`        | Race result collection and dispatch                   |
| Server | `server/cleanup.lua`        | Post-race world and state cleanup                     |
| Server | `server/intermission.lua`   | Intermission phase management between races           |
| Server | `server/timetrail.lua`      | Time trial mode server logic                          |
| Client | `client/main.lua`           | Race flow, UI triggers, event handling                |
| Client | `client/checkpoints.lua`    | Client-side checkpoint rendering and detection        |
| Client | `client/hit_detector.lua`   | Checkpoint hit detection and reporting                |
| Client | `client/nui_bridge.lua`     | Delegates UI events to spz-raceUI and spz-poll        |
| Client | `client/timetrail.lua`      | Time trial mode client logic                          |

## Dependencies
- ox_lib
- spz-core
- spz-identity
- spz-vehicles

## Credits

Checkpoint prop models by BzZzi

Original release:
https://forum.cfx.re/t/props-checkpoints/5267670

## CI
Built and released via `.github/workflows/release.yml` on push to `main`.
