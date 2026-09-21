-- config.lua
Config = {}

-- ── Queue ──────────────────────────────────────────────────────────────────
-- No minimum player count: the FIRST player to join arms a join window that
-- counts down for everyone ("race starting in Ns — press E"). Whoever is in
-- the queue when it expires races; latecomers can still join during the polls.
Config.JoinWindowSeconds    = 30      -- countdown armed by the first joiner
Config.MinPlayersToStart    = 1       -- legacy floor — only used as "queue empty" check
Config.PollWaitTime         = 2       -- (legacy, unused by the join-window flow)
Config.MaxPlayersPerRace    = 16      -- hard cap on queue size

-- ── Poll ───────────────────────────────────────────────────────────────────
Config.PollDuration         = 30      -- seconds the poll stays open
-- Cards per ballot phase — tracks, and cars. Three is a choice; two is a
-- coin toss, which is what made the reroll worth adding in the first place.
-- It is capped by what exists: a race type with only two tracks offers two.
Config.PollOptionsPerType   = 3

-- ── Checkpoint blips ───────────────────────────────────────────────────────
-- How the route reads on the minimap while driving.
--
-- The way line is the game's own orange GPS route, painted along the road on the
-- minimap. The track is plotted as POINTS — the checkpoints — and the game
-- pathfinds the roads between them (StartGpsMultiRoute): player → gate 1 →
-- gate 2 → gate 3, each leg solved in turn.
--
-- That chaining is the reason it is not SetBlipRoute. A blip route always runs
-- from the PLAYER to one blip, so a route to gate 2 is the best road to gate 2 —
-- which is generally not the road through gate 1. Routing every gate that way
-- draws a fan of shortcuts rather than the course.
--
--   routeMode      "multi" chained road route (default) | "blip" per-gate blip
--                  routes | "off" markers only
--   routeHudColour HUD colour index for the multi-route line (15 = orange).
--                  NOTE: HUD colours are a different scale from blip colours.
--   lookahead      gates plotted ahead, counting the one you are driving at
--   routeAll       blip mode only: route the whole lookahead, not just the first
--   routeColour    blip mode only: blip colour id (17 = bright orange)
--   hideFar        drop the gates past the lookahead instead of dimming them
--
-- Note that the route line is road PATHFINDING to each gate, so where a track
-- deliberately leaves the road network — an alley, the wrong side of a divided
-- road, a dirt cut, a car park — the line takes the road version of that leg.
Config.CpBlips = {
    routeMode      = "multi",
    routeHudColour = 15,
    lookahead      = 3,
    routeAll       = true,
    routeColour    = 17,
    hideFar        = false,

    -- Gate marker sizes on the minimap. These are a LADDER, not five
    -- independent dials: the descending order is what tells a driver at speed
    -- which gate is next. Scale them together, or the cue goes away.
    scale = {
        active  = 1.55,   -- the gate you are driving at
        near    = 1.20,   -- the one after it
        ahead   = 0.98,   -- two gates ahead
        pending = 0.82,   -- the rest of the course, as context
        finish  = 2.00,   -- the line
    },
}

-- ── Cycle ──────────────────────────────────────────────────────────────────
-- Rotation order. Repeats.
-- "circuit" = multi-lap, "sprint" = point-to-point
Config.CycleOrder           = { "circuit", "sprint" }  -- alternates each race

-- ── Warmup (90s freeroam + customization window) ────────────────────────────
Config.WarmupTimeSeconds    = 90      -- free-drive after TP before countdown (0 = skip)
                                      -- players practice-drive the track and/or open the
                                      -- tuner menu (/savecustom etc.) to set up their car

-- ── Countdown ──────────────────────────────────────────────────────────────
-- Staging is also the START SEQUENCE window: the grid is formed and frozen,
-- the camera is pushing down the centre line and the flag girl is walking out
-- to her mark. At 3 seconds none of that could land — she was still walking
-- when the lights went out and the camera move was longer than the phase that
-- contained it. Everything downstream is timed off (staging + countdown), so
-- this is the one number to change if the intro should breathe more.
Config.StagingTimeSeconds   = 9       -- silent grid settle + start-sequence run-up
                                      -- (no on-screen count; keeps players frozen while
                                      --  the TP settles, then the 3-2-1-GO plays)
Config.CountdownSeconds     = 5       -- 5-4-3-2-1-GO. Long enough for the flag
                                      -- girl's swing to read as the start
                                      -- signal rather than a shrug after it.

-- ── Race ───────────────────────────────────────────────────────────────────
Config.RaceTimeout          = 3600000  -- 60 minutes — DNF anyone not finished (was 5 mins)
Config.PositionBroadcastInterval = 1000   -- ms between live position updates

-- ms between SPZ:standings emits — the out-of-race feed consumed by the live
-- race board in spz-spectate and any other spectator UI. Separate from the racer
-- HUD interval above because each emit fans out to every non-racer on the
-- server, while racers need the tighter rate for an honest gap tower. This is
-- also the refresh rate of that board, so it is the visible update rate for
-- everyone watching from outside the race.
Config.StandingsBroadcastInterval = 2500

-- ── In-world race HUD elements ────────────────────────────────────────────────
--
--   CpDistancePill  anchored to the CHECKPOINT, with a stem down to the gate
--                   point. Tells you where the gate is and how far. Useful on
--                   unfamiliar tracks and for spotting a gate hidden behind
--                   geometry.
--
-- This is a DEFAULT. It can be overridden live from server.cfg without touching
-- this file or restarting the resource:
--
--   setr spz_hud_cp_pill 0
--
-- The convar wins when it is set; otherwise the value here applies.
Config.Hud = {
  CpDistancePill = true,
}

-- Overtake auto-clips. A pass triggers a real VIDEO clip recorded from the
-- overtaker's screen via `screencapture`, uploaded to FiveManage, and posted
-- to Discord. Recording starts the instant the pass is detected (so the clip
-- contains the overtake, not just the aftermath) and runs ClipDurationS.
-- Cooldown is per overtaking pair to stop spam in a back-and-forth battle.
Config.OvertakeCooldown = 20000

-- Nitrous flourish on a completed pass: the OVERTAKER's car spits exhaust
-- flames (networked, so the whole field sees it). Fires off the same detection
-- as the auto-clip, so it inherits OvertakeCooldown and cannot spam in a
-- back-and-forth battle.
Config.OvertakeNos = {
  enabled    = true,
  durationMs = 1400,   -- how long the flames burn
  pulseMs    = 110,    -- gap between particle bursts (lower = denser flame)
  scale      = 1.6,

  -- Rocket-Voltic boost on top of the flames. OFF deliberately: it is a real
  -- speed gain, so it pays for a pass with pace and makes overtaking
  -- self-reinforcing — the leader pulls away for winning a position. Turn it on
  -- only if that is the racing you want.
  boost      = false,
  boostMs    = 900,
}
Config.Clip = {
  enabled     = true,
  durationS   = 10,     -- seconds of video captured per overtake
  maxWidth    = 1280,
  maxHeight   = 720,
  -- FiveManage: create a Media API token at https://fivemanage.com and paste
  -- it here. Without a token the clip system falls back to a screenshot still,
  -- then to a text-only Discord post.
  fivemanageUrl   = "https://api.fivemanage.com/api/v3/file",
  fivemanageToken = "",   -- e.g. "fmapi_xxxxxxxxxxxxxxxx"
}
Config.SpawnTimeout         = 30000   -- ms hard ceiling when NOBODY has spawned yet

-- Gap between grid vehicle creations. Only there to keep every car off the same
-- network tick — it is NOT a pacing mechanism. Keep it small: the whole grid
-- must be spawned well before the spawn monitor advances the session, or the
-- spawn loop ends up running against a race that has already staged.
--   16 players × 800ms ≈ 13s   (fits inside SpawnTimeout)
--   16 players × 5000ms ≈ 75s  (the old value — outlived WARMUP)
Config.SpawnStaggerMs       = 800

-- ms to let the client-side grid teleport land (and collision stream in) before
-- the race vehicle is created at that spot.
Config.GridTpSettleMs       = 400

-- Warmup doubles as spawn grace: once the FIRST racer is ready, the race moves
-- on after this delay and slow clients keep spawning during the whole warmup
-- (with automatic retries). They're only cut at warmup end.
Config.FirstReadyGraceMs    = 5000    -- ms after first confirm before advancing
Config.SpawnRetryIntervalMs = 8000    -- ms between respawn retries during warmup

-- ── Poll reroll ─────────────────────────────────────────────────────────────
--
-- Any ballot can ask for the whole SET to be redrawn — different tracks,
-- different cars — instead of picking the least bad of what came up.
--
-- Decided by a strict majority of the players who actually VOTED, and only
-- once the poll closes. Deliberately not "first click wins": a reroll throws
-- away votes other people have already cast, and on a busy server an instant
-- one is a grief button.
Config.PollReroll = {
  Enabled    = true,

  -- What counts as "most of them".
  --
  -- nil = strict majority: 6 of 10, 4 of 7, 2 of 3. Half is not enough, so a
  -- 5-5 split never bins the other five players' votes.
  --
  -- Set a fraction to lower the bar — 0.4 means 4 of 10 carries it. The
  -- denominator is players who ACTUALLY VOTED, never the whole session: a
  -- player who ignores the ballot should not be able to block a reroll by
  -- doing nothing, which is what counting them would mean.
  Threshold  = nil,

  -- How many redraws a single poll can spend. Two rerolls of a server with
  -- three circuits is the same three circuits again, with the grid still
  -- waiting — raise it only if the track and car lists are deep.
  MaxPerPoll = 1,
}

-- ── Race intro (cover → sweep → details card) ───────────────────────────────
--
-- The warmup ends with the whole field being teleported back onto the grid,
-- which is the ugliest moment in a race from the driver's seat: the world jumps
-- and collision streams back in around them. So a branded cover — the same
-- screen spz-spawn uses — goes up first, the teleport happens behind it, and
-- it sweeps away onto the start camera with a card naming the race.
--
-- Set Enabled = false and the sequence is exactly what it was before: no
-- cover, no card, straight from warmup to the grid.
Config.RaceIntro = {
  Enabled    = true,

  -- How long the cover is up BEFORE the teleport is sent. It only has to
  -- outlast one NUI frame; the rest of the cover's life is the teleport and
  -- settle that follow, which are timed by their own config below.
  CoverLeadMs = 700,

  -- How long the card stays up once the sweep has opened. Clamped so it always
  -- ends before the lights: the staging phase is the window it lives in, and
  -- anything still on screen at T-3 is competing with the countdown.
  --
  -- nil = fill the staging phase, less the gap below.
  CardHoldMs  = nil,
  CardGapMs   = 1500,   -- clear this long before the 3-2-1 starts
}

-- ── Mid-race reconnect ──────────────────────────────────────────────────────
-- A crash/timeout during a LIVE race no longer means instant DNF: the grid
-- slot is held this long, and rejoining restores lap/checkpoint/time at the
-- last crossed checkpoint. Must be shorter than IdleKickMs.
Config.ReconnectWindowMs    = 60000

-- ── Incidents (clean-race / SR) ─────────────────────────────────────────────
-- Racers are ghosted from each other, so a tracked incident is a hard impact
-- with the world (walls, barriers, props). The client detects these and
-- reports them; spz-progression converts the count into an SR penalty and
-- gates the clean-race bonus. Kept lenient so light kerb-hopping is ignored.
Config.Incidents = {
  enabled           = true,
  minImpactSpeed    = 30,     -- km/h below which an impact is ignored
  minSpeedDropKmh   = 22,     -- sudden speed loss in one frame that counts as a hit
  minBodyDamage     = 45.0,   -- body-health drop that counts as a hit
  cooldownMs        = 1500,   -- ignore repeat hits within this window (one crash = one incident)
  startBufferMs     = 3000,   -- ignore impacts in the first N ms after GO (grid shuffle)
  maxPerRace        = 20,     -- hard cap on reported incidents (anti-spam)
}

-- ── Physics ────────────────────────────────────────────────────────────────
Config.RaceAssists = {
  tcs = true,
  abs = true,
  esc = false,
  lc  = true,
}
-- ── Post-race ──────────────────────────────────────────────────────────────
Config.ResultsDisplayTime   = 12000   -- ms stats screen shown before TP back

-- Armed by the FIRST finisher: everyone still driving gets this long to cross
-- the line, then they're force-DNF'd and results fire. Stops the podium from
-- waiting minutes on cruisers (the 120s idle-kick only catches AFK, not slow).
Config.FinishWindowSeconds  = 180

-- ── Intermission ───────────────────────────────────────────────────────────
-- Runs OVERLAPPED with the results screen: the countdown starts the moment
-- results appear, not after they close.
Config.IntermissionTime     = 30      -- seconds between races

-- ── Grid ───────────────────────────────────────────────────────────────────
-- Passed to SPZ.Math.GridPositions
-- "grid" = staggered F1 grid · "point" = everyone on a ring at the start point
--
-- This was "point" with radius 0 — every car created at IDENTICAL coordinates,
-- on the theory that ghosting made overlap safe. It does not, and this was the
-- cause of the grid launching cars across the map:
--
--   SetEntityNoCollisionEntity suppresses contact RESPONSE between two entities
--   on the client that sets it. It does not touch the engine's interpenetration
--   resolver, which fires when a vehicle is created or a ped is teleported into
--   a space something else already occupies, and whose entire job is to eject
--   whatever is overlapping. Two cars at the same coordinate are overlapping by
--   definition, and stay overlapping for the whole race — every physics
--   re-evaluation is another chance to be thrown.
--
-- Grid mode is the fix, because it removes the overlap instead of trying to
-- survive it. Point mode is a RING, not a stack, and its radius is floored
-- (see SPZ.Math.GridPositions) — a zero-radius ring for more than one car is
-- not a configuration, it is the bug.
--
-- The two phases want opposite shapes, so they are set separately:
--
--   WARMUP  grid. Free-driving before the race, nothing is being won or lost,
--           and spread-out slots are the safest way to put sixteen cars on a
--           road at once.
--
--   RACE    point, radius 0 — every car on the SAME coordinate. A staggered
--           grid hands row 1 roughly 56 metres over row 8 on a full field,
--           which is a result decided before the lights. One point is the only
--           genuinely equal start.
--
--           This works at the re-stage and NOT at creation, and the difference
--           matters. Here the cars already exist, they are frozen either side
--           of the teleport, and they are ghosted against each other, so
--           nothing simulates contact while they sit stacked; on GO they simply
--           drive through one another. The teleport must not pass clearArea —
--           see SPZ:tpToGrid, where each arrival was booting the cars already
--           on the line.
--
--           A radius above 0 turns this into a ring instead (spread but still
--           equal-distance), floored and capped for the reasons below.
--           SPLIT is that idea in two: the field halves onto two points set
--           side by side, eight and eight on a full grid, with a lane down the
--           middle. Every car in a pack still covers the same distance as its
--           pack-mates and the two packs are level with each other, so the
--           start stays fair — and the open centre is where the flag girl
--           stands (client/gridgirl.lua). Same stacking rules as point mode,
--           and the same reason it is only safe at the re-stage.
Config.WarmupSpawnMode      = "grid"
Config.RaceStartMode        = "split"

-- Metres between the two start points in split mode. Wide enough to walk
-- between and be seen from both packs; narrow enough to stay on the road.
Config.SplitPointGap        = 7.0

-- ── Flag girl ──────────────────────────────────────────────────────────────
-- The ped who starts the race from the lane the split grid opens up
-- (client/gridgirl.lua). She is placed on her mark for staging and performs the
-- flag routine once the countdown ends.
--
-- Her clip ends with her walking off the road. The client finds where that
-- walk-off starts (from the clip's root motion) and times the clip against it;
-- after GO she drops the flag and walks off, then is removed.
--
-- This is how many milliseconds BEFORE GO the walk-off starts. The flag drop
-- sits about 3 seconds before the walk-off, so -3000 (walk-off 3s AFTER GO)
-- lands the drop on the lights. Move it toward 0 if the drop is late, further
-- negative if it is early.
Config.FlagAnimEndOffsetMs  = -3000

-- ...and how long before the 3-2-1 STARTS she begins performing. Matching
-- Config.StagingTimeSeconds (in ms) has her performing from the moment the grid
-- forms, which is the whole time the start camera is on her.
Config.FlagAnimLeadMs       = 5000

Config.PointSpawnRadius     = 0.0     -- 0 = one point · >0 = ring of that radius
Config.PointSpawnMaxRadius  = 12.0    -- metres; past this the ring is wider than
                                      -- the road, so it falls back to a grid and
                                      -- logs why. ~14 cars at the default arc.

Config.GridRowSpacing       = 8.0     -- metres front-to-back (grid mode)
Config.GridColSpacing       = 4.5     -- metres side-to-side (grid mode)
Config.GridCarsPerRow       = 2       -- rows are what decide a race before the
                                      -- lights: 16 cars at 2 abreast is 8 rows
                                      -- and 56 m of stagger, at 4 abreast it is
                                      -- 4 rows and 24 m. Raise it only as far as
                                      -- the start line is genuinely wide.

-- Fallback for anything still reading the old single-mode key.
Config.SpawnMode            = Config.WarmupSpawnMode

-- ── Safe Zone ──────────────────────────────────────────────────────────────
-- Location players are sent after race cleanup. Set to your paddock / lobby spawn.
Config.SafeZone             = vector3(-1323.8, -1199.1, 4.0)
Config.SafeZoneHeading      = 210.0

-- ── Checkpoints ────────────────────────────────────────────────────────────
-- How long (ms) a racer can go without hitting any checkpoint before they are
-- automatically DNF'd for idling / going off-route.
Config.IdleKickMs           = 120000  -- 2 minutes

-- Teleport back to the last checkpoint you crossed (client/recover.lua).
-- Declared here, not inline in the key mapping, because the missed-checkpoint
-- prompt and the HUD key strip both print it — one source, no drift.
--
-- NOT F6: spz-leaderboard already owns that key for the results board.
Config.RecoverKey           = "F4"

-- Range (metres) within which checkpoint gate props are spawned.
-- Beyond this the props are removed again to keep the entity count low.
Config.GateRange            = 130.0

-- GPS route colour index (GTA colour palette, 51 = bright yellow).
Config.GpsRouteColour       = 51

-- Ghost-bots (the cold-start field filler that backfilled thin races with
-- replayed stored lines) were REMOVED. The standings, the results grid, the map
-- blips and the race board are humans only again. Ghost DUELS below and the
-- time-trial ghost in spz-raceline are separate features and still live.

-- ── Ghost duels (async PvP wagers) ──────────────────────────────────────────
-- /duel <player|id> <track> <stake> — race an opponent's STORED best line (a
-- ghost) for credits. Reuses the Time-Trial harness (bucket, CP timing, ghost).
-- Server-authoritative: it compares its measured lap to the stored best_ms.
Config.Duel = {
  Enabled  = true,
  MinStake = 100,
  MaxStake = 10000,
  -- HouseFunded = true  → winnings are a house bounty; the (possibly offline)
  --   opponent is NEVER charged. Winner nets +stake (stake back + matched bonus).
  -- HouseFunded = false → the opponent's balance covers the matched stake: they
  --   lose it if their ghost is beaten, win the challenger's stake if it holds.
  --   Charges an offline player without consent — off by default.
  HouseFunded = true,
  -- Car for the challenger when the opponent's stored model can't be resolved to
  -- a registered race vehicle.
  FallbackModel = "sultan",
}

-- ── Debug ──────────────────────────────────────────────────────────────────
Config.Debug                = false

-- Personalised lap count per circuit by track length (server/lapcount.lua).
-- Long tracks get fewer laps, short tracks more, so total race distance stays
-- roughly even. Sprints are always 1 lap.
-- Threshold ~ the median lap length across all 75 circuits (~9.5 km), so the
-- split is roughly even: longer half = 2 laps, shorter half = 3.
Config.LongTrackMetres = 9500.0   -- a lap longer than this counts as "long"
Config.LongTrackLaps   = 2
Config.ShortTrackLaps  = 3

-- ── Rewind (Forza Horizon-style time rewind) ────────────────────────────────
-- Hold the key to scrub the car backward along its recent path; release to
-- resume driving from that point with the momentum it had back then. Bounded
-- only by the rolling history buffer — no use cap, no cooldown beyond a short
-- settle after release.
--
-- RACES ONLY (LIVE state). Time trial has no rewind at all: the clock is the
-- whole point of that mode, and a TT lap feeds the stored line, the ghost and
-- duel targets — refunded time there seeds a target nobody can match honestly.
-- No leaderboard exploit: checkpoints must still be crossed for real, so every
-- gate you scrub back past has to be re-driven at racing speed.
Config.Rewind = {
  enabled           = true,
  -- NOT F5: spz-carspawner owns that key, and two commands on one key both fire.
  -- A held key wants a letter anyway — F5 was chosen to sit beside the respawn
  -- key, which stopped being a reason once respawn moved to F4.
  -- Registry: Docs/keybinds.md
  key               = "B",
  bufferSeconds     = 10,     -- how far back you can scrub
  recordIntervalMs  = 66,     -- ~15 Hz history sampling
  playbackSpeedMult = 2.5,    -- scrub speed vs real time (10s buffer plays back in 4s)
  resumeCooldownMs  = 350,    -- short lockout after releasing before rewinding again

  -- ── Clock credit ─────────────────────────────────────────────────────────
  -- The clock rewinds WITH the car: scrub back 4 s and the race/lap timer runs
  -- backward by 4 s too, so the car and its time land at the same moment. That
  -- is what makes a rewind read as "undo" instead of "teleport + penalty".
  --   1.0 = full refund (Forza) · 0.0 = clock keeps running (old behaviour)
  --   anything between = partial refund, i.e. a rewind costs you the difference
  timeCreditFactor  = 1.0,
  -- Server-side ceiling on how much clock a single lap/run can win back, no
  -- matter how many rewinds are chained. Nothing above this is credited.
  -- This is PER LAP, so a 3-lap circuit allowed 3x this much refund on a time
  -- that reaches the leaderboard — 60s/lap made a rewound run strictly faster
  -- than a clean one. Any run that credits a single millisecond is now barred
  -- from track records and personal bests (see leaderboard/writer.lua), so this
  -- number only governs how forgiving the mid-race experience is.
  maxCreditPerLapMs = 15000,

  -- ── Landing ──────────────────────────────────────────────────────────────
  -- The crash you rewound out of did not happen any more, so the car comes back
  -- as it was. GTA cannot roll the WORLD back, so the loose wreckage around the
  -- landing point is cleared instead — objects only, never peds or vehicles
  -- (this runs mid-race; another racer's car is not debris).
  repairOnLand      = true,
  clearDebrisOnLand = true,
  clearDebrisRadius = 12.0,
}

-- ── In-world record boards ─────────────────────────────────────────────────
-- Physical floating scoreboards showing the fastest lap holders for a track.
-- Walk near one and the top times render in the world. Each board is pinned to
-- a track name (must match a key/name in data/tracks.lua). Add as many as you
-- like — e.g. one at spawn, one at each track's start line.
Config.RecordBoards = {
    -- { coords = vector3(x, y, z), heading = 0.0, track = "10-80" },
    -- Removed: this board sat right on the after-race safe-zone TP spot
    -- (SafeZone -1323.8,-1199.1) so it rendered in the player's face every race.
    -- { coords = vector3(-1327.5, -1196.0, 5.6), heading = 120.0, track = "10-80" },
}
Config.BoardRange   = 12.0     -- metres: render when the player is this close
Config.BoardRefresh = 30000    -- ms between record re-fetches

-- ── NPC cop chase ───────────────────────────────────────────────────────────
-- Street-race heat. Racers pick this up as a wanted level from how they drive
-- (speed on public road, wrecking traffic, mowing down peds); once they have
-- stars, scripted police units spawn behind them and hunt.
--
-- The units NEVER shoot. They are drivers only: follow at low heat, ram/PIT at
-- high heat. Vanilla dispatch stays off (spz-core kills it server-wide) — every
-- car here is spawned, tasked and deleted by client/copchase.lua, LOCALLY, so
-- each racer is chased by their own pack and nobody eats another player's cops.
--
-- Voted on per race: the traffic ballot carries an on/off switch, majority wins
-- (`Default` breaks a tie and covers a poll where nobody touched it).
-- ── Start-line tool (/setstart) ─────────────────────────────────────────────
-- The in-game surveying tool that sets a track's start line from two points.
-- See spz-races/server/startline.lua.
--
-- OPEN BY DEFAULT. It used to require ACE "spz.dev" or the spz_dev convar, and
-- that turned out to be a wall rather than a gate: the permission is defined in
-- spz-txrecipe/server.cfg but never assigned to anybody (the add_principal line
-- next to it is commented out), and the obvious way to grant it at runtime —
-- `set spz_dev true` in the console — is refused outright on any server running
-- FXServer's production console lockdown. So the tool was unusable out of the
-- box on exactly the servers it was written for.
--
-- WHAT OPEN MEANS: any player can permanently move any track's start line, and
-- the change is written to disk and survives restarts. That is fine on a
-- private or development server and is not fine on a public one.
--
-- To lock it on a public server, set RequireAce = true and grant the ACE in
-- server.cfg (the tool prints the exact line when it refuses someone):
--     add_ace identifier.license:<theirs> spz.dev allow
Config.StartLineTool = {
  RequireAce = false,   -- true = back to ACE "spz.dev" / spz_dev convar
}

Config.CopChase = {
  Enabled  = true,     -- false removes the switch from the ballot entirely
  Default  = false,    -- tie / no votes → this

  -- ── Heat → stars ─────────────────────────────────────────────────────────
  -- Heat is 0-100 and maps to 1 star per 20. It comes from TWO places, and
  -- keeping those two apart is the whole reason the star row stops behaving
  -- like a second speedometer:
  --
  --   OFFENCE heat   how you are DRIVING — speed on a public road, wrecking
  --                  traffic, hitting peds. This is what STARTS a pursuit.
  --
  --   PURSUIT heat   how long you have been RUNNING once the police are
  --                  actually on you. This is what ESCALATES one.
  --
  -- The old model had only the first, so the level tracked the speedometer:
  -- flat out on an empty straight with the pack half a mile back climbed to
  -- five stars, while a cruiser leaning on the door at 60 km/h through traffic
  -- bled stars off — further away meant MORE wanted, caught meant LESS. Both
  -- are backwards, and both are fixed by where decay is allowed to happen:
  --
  --   * while a unit has CONTACT (see the bottom of this table), heat never
  --     falls. Not slower — never. The heat cannot be lowered by being caught.
  --   * once contact is broken it falls at EvadeDecayPerSec, which is the only
  --     place "shaking them" is allowed to pay.
  --   * with nobody after you at all it falls at IdleDecayPerSec.
  SpeedKmh         = 130,   -- above this on a public road, offence heat climbs
  SpeedHeatPerSec  = 3.5,   -- heat/s while over the limit
  HeatPerVehHit    = 9,     -- ramming an ambient vehicle
  HeatPerPedHit    = 22,    -- hitting a ped
  IdleDecayPerSec  = 2.0,   -- heat/s bled off while driving clean and unchased
  EvadeDecayPerSec = 1.2,   -- heat/s while the pack is out but has lost you
  MaxStars         = 5,

  -- Speeding alone is an offence, not a manhunt. The SPEED half of offence heat
  -- stops buying stars at this level, so three and up have to be EARNED — by
  -- wrecking things (wreckage is uncapped) or by staying in front of the police
  -- long enough that they escalate on their own.
  SpeedMaxStars    = 2,

  -- ── Escalation while they are on you ─────────────────────────────────────
  -- The pursuit clock, and the only thing that reliably takes a chase from two
  -- stars to five. It ticks only while a unit actually has contact, so it is
  -- time spent BEING CHASED — not time spent driving fast.
  PursuitHeatPerSec   = 1.5,
  PursuitGraceSec     = 6.0,   -- seconds of pursuit before escalation starts
  HeatPerRoadblockRun = 14,    -- you went through the block instead of round it
  HeatPerPitSurvived  = 6,     -- they threw a PIT and you drove out of it

  -- ── Star stickiness ──────────────────────────────────────────────────────
  -- A level that can be re-crossed by a rounding error flickers between two
  -- numbers, and a flickering star row spawns and deletes cars underneath you.
  -- A star has to be given up properly: fall a clear margin below the band AND
  -- hold there for a moment.
  StarDropMargin = 6.0,    -- heat below the band floor before the star is lost
  StarDwellSec   = 5.0,    -- minimum time at a level before it may drop

  -- ── Pursuit units ────────────────────────────────────────────────────────
  -- Each star level fields a PACK with roles, not a queue of identical cars
  -- following you nose to tail:
  --
  --   tail       sits behind you and stays there. The pressure unit.
  --   flank      pulls up alongside (alternating left/right) and tries to live
  --              there — it is what turns a chase into being boxed in, and it is
  --              also what puts a car in position for a PIT.
  --   intercept  does not chase at all: it spawns on the road AHEAD of where you
  --              are pointed and comes at you. This is the one that stops the
  --              whole thing being a rear-view mirror game.
  --
  --   pit        contact allowed. A PIT is only thrown when a unit is actually
  --              in position (alongside/behind quarter, close, and you are not
  --              going so fast the hit would be a launch) — never on a timer
  --              alone. pitEvery is the MINIMUM gap between attempts.
  --   roadblock  seconds between roadblocks; 0 = never. Two cruisers parked
  --              across the road ahead, called out before you reach them.
  --   heli       a police maverick overhead, holding station on you. It never
  --              blocks or rams; what it does is make hiding pointless, which
  --              is exactly its job in the base game.
  Levels = {
    [1] = { tail = 1, flank = 0, intercept = 0, heli = 0, pit = false, pitEvery = 0,    roadblock = 0,  speed = 38.0 },
    [2] = { tail = 2, flank = 0, intercept = 0, heli = 0, pit = false, pitEvery = 0,    roadblock = 0,  speed = 42.0 },
    [3] = { tail = 2, flank = 1, intercept = 0, heli = 1, pit = true,  pitEvery = 11.0, roadblock = 0,  speed = 46.0 },
    [4] = { tail = 2, flank = 2, intercept = 1, heli = 1, pit = true,  pitEvery = 8.0,  roadblock = 55, speed = 50.0 },
    [5] = { tail = 3, flank = 2, intercept = 1, heli = 1, pit = true,  pitEvery = 5.0,  roadblock = 35, speed = 56.0 },
  },

  -- ── How the police themselves behave ─────────────────────────────────────
  --
  -- true  — the GAME'S police AI. The peds are real cops: in the COP
  --         relationship group, flagged with SetPedAsCop and driven by a real
  --         wanted level, so the base game decides how they read the road and
  --         how they commit to a corner. They are still stripped of every
  --         weapon and cannot leave the vehicle — the car is the only pressure.
  --
  -- false — the scripted-only pack: weapons stripped, combat unreachable, every
  --         non-temporary event blocked so nothing can pull them out of the
  --         driving task.
  --
  -- Vanilla DISPATCH stays off either way (spz-core kills all 15 services), so
  -- the wanted level never summons anything — it is what makes the police AI
  -- treat the racer as a suspect, nothing more. Every unit on the road is still
  -- one this file asked for.
  VanillaBehaviour = true,
  Accuracy         = 25,     -- vanilla mode: ped accuracy, 0-100. Cops are not snipers.
  Armour           = 100,

  -- ── Air support ──────────────────────────────────────────────────────────
  -- Fielded from the star level that asks for one (see `heli` above). It holds
  -- station overhead with its searchlight on you, and it is the reason ducking
  -- into a side street stops working.
  Heli = {
    Enabled     = true,
    Model       = "polmav",
    PedModel    = "s_m_y_cop_01",
    Height      = 45.0,    -- metres it tries to hold above you
    Behind      = 45.0,    -- metres back it arrives from
    Speed       = 65.0,    -- m/s chase speed
    Searchlight = true,    -- the light itself
    Blip        = true,

    -- The chopper has EYES, and they now count. It used to be excluded from the
    -- escape test entirely — it sits overhead, so counting its DISTANCE meant no
    -- pursuit above two stars could ever be shaken. Counting its LINE OF SIGHT
    -- instead is both fairer and truer to the base game: while it can see you,
    -- you have not lost them; a tunnel, an underpass or a multi-storey breaks
    -- the sightline and the escape clock starts.
    HoldsContact = true,
    SightDist    = 280.0,
  },

  Models     = { "police", "police2", "police3" },  -- cruisers (randomised)
  FastModels = { "police2", "police3" },            -- used from 4 stars up
  PedModels  = { "s_m_y_cop_01", "s_m_y_sheriff_01" },
  Sirens     = true,

  -- ── Arriving ─────────────────────────────────────────────────────────────
  -- The old spawn put a STATIONARY cruiser on a node a fixed 130 m behind a car
  -- doing 250 km/h. By the time its engine was turning, the racer was another
  -- 60 m away and the gap only ever grew: the pursuit lived two streets back and
  -- nothing ever actually arrived.
  --
  -- Two changes fix that. The gap is expressed in SECONDS of your speed rather
  -- than in metres, so it is the same distance behind in a 60 km/h alley as it
  -- is on the freeway; and the unit arrives ALREADY ROLLING at your pace instead
  -- of from a standstill.
  BehindSec      = 2.2,     -- spawn this many seconds of your speed behind
  SpawnBehindMin = 75.0,    -- ...but never closer than this
  SpawnBehindMax = 200.0,   -- ...and never further than this
  SpawnBehind    = 130.0,   -- used when your speed cannot be read (on foot)
  SpawnAhead     = 240.0,   -- metres up the road an intercept unit sets up
  SpawnMinDist   = 60.0,    -- never closer than this to the racer
  SpawnAtSpeed   = true,    -- arrive rolling at your pace, not from a standstill
  SpawnOffScreen = true,    -- push the point back if it would pop into view
  DespawnDist    = 340.0,   -- a unit this far adrift is recycled
  PitDurationMs  = 3500,    -- how long a ram attempt runs before resuming chase

  -- How fast the pack is fielded. The FIRST unit of a pursuit skips the gap
  -- entirely — the moment you are wanted there is something behind you — and
  -- while the pack is under half strength two may arrive per tick, so reaching
  -- four stars does not mean waiting fifteen seconds for four cars.
  SpawnGapMs       = 1600,
  FirstUnitInstant = true,
  SpawnBurst       = 2,

  -- ── Keeping up ───────────────────────────────────────────────────────────
  -- A stock cruiser cannot live with a race-tuned car. Engine output is scaled
  -- per star level so units hold station instead of falling off, and their
  -- cruise target tracks YOUR speed rather than sitting at a fixed number.
  --
  -- On top of that there is a CATCH-UP assist, and it is deliberately a rubber
  -- band — a bounded one. A unit more than CatchUpFrom metres back gets extra
  -- cruise speed and extra engine, scaling with how far back it is and maxing
  -- out at CatchUpSpan metres over. Inside HoldDist it eases off completely and
  -- just sits on you, so the pack pressures rather than permanently rear-ends.
  --
  -- The assist is capped and the escape radius is unchanged, so a genuinely
  -- faster car driven well still breaks contact — it just has to out-DRIVE them
  -- rather than out-accelerate a cruiser that started from a standstill.
  PowerBoost   = { [1] = 0.15, [2] = 0.25, [3] = 0.40, [4] = 0.60, [5] = 0.85 },
  SpeedMatch   = 1.12,     -- cruise target as a multiple of your current speed
  SpeedFloor   = 30.0,     -- m/s: never crawl, even when you are stopped
  SpeedCeiling = 82.0,     -- m/s: hard cap so a boosted cruiser stays plausible
  CatchUpFrom  = 55.0,     -- metres back before the assist starts
  CatchUpSpan  = 130.0,    -- ...and metres over that at which it is maxed
  CatchUpSpeed = 16.0,     -- m/s added to the cruise target at full stretch
  CatchUpPower = 0.45,     -- engine multiplier added at full stretch
  HoldDist     = 22.0,     -- inside this the assist is off entirely

  -- ── Roadblocks ───────────────────────────────────────────────────────────
  RoadblockAhead   = 320.0,  -- metres up the road it is set up
  RoadblockWarnSec = 0,      -- 0 = warn as soon as it is placed
  RoadblockLifeSec = 40,     -- torn down after this, or once you are past it

  -- Radio chatter. Short callouts when the pack does something — a flanker
  -- arriving, a PIT going in, a block going up. Off = silent pursuit.
  Chatter = true,

  -- ── Dispatch radio (the SOUND of the callouts) ───────────────────────────
  -- Independent of `Chatter` above, which is only the on-screen text: a server
  -- can run a silent HUD and still want the radio, or the reverse.
  Radio = {
    Enabled = true,

    -- The CB key-up click. Always available, and on its own it is most of what
    -- makes a callout sound like it came over a radio.
    Squelch = true,

    -- Real police-scanner lines, played at random. These are GAME AUDIO names,
    -- not an API: an unrecognised one plays nothing at all and reports no error,
    -- which is exactly why they are data here rather than baked into the client.
    -- Trim or extend the list freely; empty or nil means squelch only.
    Reports = {
      "CRIME_SUSPECT_IN_VEHICLE",
      "CRIME_RECKLESS_DRIVING",
      "CRIME_SPEEDING_VEHICLE",
      "CRIME_TERRORIST_ACTIVITY",
    },

    -- Scanner lines run for several seconds. Two at once is noise, not chatter.
    ReportGapMs = 9000,

    -- Background radio while a pursuit runs, so the gaps between events are not
    -- silent. 0 disables it and leaves the radio to callouts only.
    AmbientEverySec = 20,
  },

  -- ── Losing them ──────────────────────────────────────────────────────────
  -- CONTACT is the whole model. A ground unit has contact when it is within
  -- ContactDist AND has a clear line to you, or when it is inside
  -- ContactCloseDist at all — a car on your bumper round a blind corner has not
  -- lost you. The chopper has contact on its own sightline, above.
  --
  -- While ANYTHING has contact the heat is locked and the pack stays. Contact
  -- has to be broken for ContactGraceSec before the escape clock even starts —
  -- a corner is not an escape — and the clock then has to run EscapeSeconds
  -- without it being regained. Regaining contact resets the clock to zero.
  --
  -- This is what stops a pursuit evaporating with a cruiser still in the mirror.
  ContactDist      = 175.0,
  ContactCloseDist = 45.0,
  ContactGraceSec  = 2.5,
  EscapeSeconds    = 14,

  -- Before the FIRST contact of a pursuit the escape clock does not run at all:
  -- units are still closing and have not had their chance yet. This is the
  -- backstop for the pursuit that never manages one — a pack spawned into
  -- geometry it cannot drive out of would otherwise follow you, unseen and
  -- undismissable, for the rest of the race.
  NoContactTimeoutSec = 40,

  -- Kept for anything still reading the old key; ContactDist is what is used.
  EscapeDist = 175.0,

  Hud = true,    -- draw the star readout (the vanilla one is hidden by spz-core)

  -- Mirror the star count onto the game's own wanted level. The game's police AI
  -- keys off the wanted level: without one, a cop ped has no suspect and simply
  -- drives. On with VanillaBehaviour, and harmless either way because dispatch
  -- is disabled — it summons nothing.
  UseNativeWanted = true,
}
