fx_version 'cerulean'
game 'gta5'

name 'spz-races'
description 'SPiceZ-Core — Race engine: queue, vote, timing, checkpoints, race HUD, leaderboard, progression, spectate, replays, speed cameras'
version '3.0.1'
author 'SPiceZ-Core'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
  'shared/race_states.lua',
  -- Core registry first: shared/events.lua MERGES the race names into
  -- SPZ.Events rather than declaring its own table.
  '@spz-core/shared/events.lua',
  'shared/events.lua',
  'shared/sectors.lua',

  -- Merged in from spz-progression, spz-spectate, spz-replay, spz-speedcam.
  -- Each has its options under Config.<Name>; its files alias that table.
  'shared/progression_init.lua',
  'config_spectate.lua',
  'config_replay.lua',
  'shared/replay_codec.lua',
  'config_speedcam.lua',
  'shared/speedcam_cameras.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',

  -- Core race engine
  'data/tracks.lua',
  'server/lapcount.lua',
  'server/main.lua',
  'server/queue.lua',
  'server/poll.lua',
  'server/srace.lua',
  'server/world.lua',
  'server/countdown.lua',
  'server/sectors.lua',
  'server/checkpoints.lua',
  'server/incidents.lua',
  -- 'server/timing.lua',
  'server/positions.lua',
  'server/overtakes.lua',
  'server/dnf.lua',
  'server/reconnect.lua',
  'server/results.lua',
  'server/showcase.lua',
  'server/cleanup.lua',
  'server/copchase.lua',     -- server-side spawning of the shared NPC cops
  'server/intermission.lua',
  'server/timetrail.lua',
  'server/duel.lua',
  'server/state_machine.lua',

  -- Leaderboard (absorbed from spz-leaderboard)
  'server/leaderboard/config.lua',
  'server/leaderboard/cache.lua',
  'server/leaderboard/utils.lua',
  'server/leaderboard/writer.lua',
  'server/leaderboard/records.lua',
  'server/leaderboard/standings.lua',
  'server/leaderboard/stats.lua',
  'server/leaderboard/archive.lua',
  'server/leaderboard/duels.lua',
  'server/leaderboard/callbacks.lua',
  'server/creator.lua',
  -- After creator.lua, and it matters: start-line overrides are applied to
  -- SPZ.Tracks from a thread, and custom tracks are ADDED from creator's own
  -- thread. Threads run in creation order, so listing this first would apply a
  -- line to a custom track that did not exist yet.
  'server/startline.lua',
  'server/dev_heading.lua',
  'server/trackadmin.lua',   -- after creator.lua: overrides apply to custom tracks too

  -- Progression (merged from spz-progression): XP, SR, iRating, rank points
  'config_progression.lua',
  'server/progression/domain/rank.lua',
  'server/progression/domain/rp.lua',
  'server/progression/domain/irating.lua',
  'server/progression/domain/sr.lua',
  'server/progression/xp.lua',
  'server/progression/main.lua',
  'server/progression/bonus.lua',
  'server/progression/rank_admin.lua',
  'server/progression/rivals.lua',

  -- Spectate and the live race board (merged from spz-spectate)
  'server/spectate/main.lua',
  'server/spectate/racefeed.lua',

  -- Replays (merged from spz-replay)
  'server/replay/recorder.lua',
  'server/replay/main.lua',

  -- Speed cameras (merged from spz-speedcam)
  'server/speedcam.lua',
}

client_scripts {
  -- Race HUD, vote and leaderboard pages (merged from spz-raceUI, spz-poll and
  -- spz-leaderboard). Their pages are spz-hud apps; app.lua binds each file to
  -- its page. First, so their exports exist before anything below uses them.
  '@spz-hud/app.lua',
  'client/ui/raceui_boot.lua',
  'client/ui/raceui.lua',
  'client/ui/poll.lua',
  'client/ui/leaderboard.lua',

  'client/main.lua',
  'client/gridgirl.lua',
  'client/startcam.lua',
  'client/cp_anim.lua',
  'client/checkpoints.lua',
  'client/cp_cross.lua',
  -- After cp_cross.lua: the overlay renders SPZ_GateProbe's output and defines
  -- none of that geometry itself.
  'client/cp_debug.lua',
  'client/hit_detector.lua',
  'client/incidents.lua',
  'client/copchase.lua',
  'client/nui_bridge.lua',
  'client/cp_pill3d.lua',     -- 3D distance pills over the next gates
  'client/raceblips.lua',
  'client/trackboard.lua',
  'client/showcase.lua',
  'client/bonus.lua',
  'client/lockin.lua',
  'client/recover.lua',
  'client/rewind.lua',
  'client/timetrail.lua',
  'client/srace.lua',
  'client/duel.lua',
  'client/trackstudio.lua',   -- track maker + 3D editor (replaced creator.lua / editor.lua)
  'client/dev_heading.lua',
  'client/startline.lua',

  -- Merged in from spz-progression, spz-spectate, spz-replay, spz-speedcam.
  -- The spectate, replay and speed camera pages are spz-hud apps (app.lua).
  'client/progression.lua',
  'client/spectate/main.lua',
  'client/spectate/racefeed.lua',
  'client/replay/recorder.lua',
  'client/replay/cameras.lua',
  'client/replay/player.lua',
  'client/replay/main.lua',
  'client/speedcam/main.lua',
  'client/speedcam/blips.lua',
}

-- Custom checkpoint / start / finish props.
-- The .ydr + .ytd stream automatically from stream/, but the .ytyp must be
-- declared and requested as a DLC ITYP so the models resolve.
files {
  'stream/spz_checkpoint.ytyp',
}

data_file 'DLC_ITYP_REQUEST' 'stream/spz_checkpoint.ytyp'

dependencies {
  'ox_lib',
  'spz-core',
  'spz-hud',        -- serves the checkpoint DUI pages (dui/cp)
  'spz-vehicles',
  'oxmysql',
}
