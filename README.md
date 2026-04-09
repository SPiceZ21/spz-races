<img src="https://github.com/SPiceZ21/spz-core-media-kit/raw/main/Banner/Banner%232.png" alt="SPiceZ-Core Banner" width="100%">

#  SPiceZ-Core Racing Framework (`spz-races`)

An authoritative, modular racing engine designed for high-performance Competitive Roleplay. Built for the **SPiceZ-Core** ecosystem, it handles everything from global queuing to millisecond-perfect lap timing.

## Features

*   **Authoritative Engine**: Every race state, from polling to results, is managed server-side to ensure maximum integrity and competitive fairness.
*   **High-Precision Detection**: Custom client-side hit detection loop running at 0ms delay during live races for frame-perfect checkpoint crossing.
*   **Ghost Car System**: Seamless "collision-free" racing between participants while maintaining full interaction with the world environment.
*   **Weighted Poll System**: Dynamic track selection based on community preference and weighted frequency bias.
*   **Leaderboard Integration**: Automated Personal Best (PB) tracking and record persistence via `spz-leaderboard`.
*   **Grid Isolation**: Automatic routing bucket management to isolate racers from freeroam traffic and interference.
*   **Automated Lifecycle**: 
    - `Polling` → `Waiting` → `Countdown` → `Live` → `Results` → `Cleanup` → `Intermission`.

## Dependencies

This resource is part of the SPiceZ-Core ecosystem and requires the following modules:

*   [`spz-core`](#): Central bucket and event management.
*   [`spz-identity`](#): License tier validation and player state tracking.
*   [`spz-vehicles`](#): Performance-based spawning and visual syncing.
*   [`spz-leaderboard`](#): Time recording and historical data retrieval.

## How to Play

### Commands
*   `/joinrace`: Enter the global race queue.
*   `/leaverace`: Exit the queue (only available during IDLE/POLLING states).

### The Race Loop
1.  **Queue**: Join the queue. Once the minimum player threshold is met, a poll will open.
2.  **Poll**: Vote for your preferred track and vehicle class.
3.  **Setup**: The server prepares the grid and spawns your race-tuned vehicle in an isolated bucket.
4.  **Countdown**: Freeze in position until the light turns green.
5.  **Race**: Hit every checkpoint! Missed checkpoints must be revisited to advance.
6.  **Results**: View your standing, lap times, and potential New Records.
7.  **Intermission**: Teleport back to the lobby and choose whether to re-enter the next cycle.

---

## Configuration

Tune your racing experience in `config.lua`:
- `Config.MinPlayersToStart`: Minimum racers required to trigger a poll.
- `Config.RaceTimeout`: Global fallback to prevent infinite sessions.
- `Config.CycleOrder`: Define the rotation of Circuit vs Sprint races.
- `Config.GridRowSpacing`: Adjust how tight or expansive the start grid is.

---

Developed with ❤️ by **SPiceZ21**.
