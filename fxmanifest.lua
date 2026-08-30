fx_version 'cerulean'
game 'gta5'

name 'spz-races'
description 'SPiceZ-Core — Race engine, poll, timing, checkpoints'
version '1.9.0'
author 'SPiceZ-Core'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
  'shared/race_states.lua',
  -- Core registry first: shared/events.lua MERGES the race names into
  -- SPZ.Events rather than declaring its own table.
  '@spz-core/shared/events.lua',
  'shared/events.lua',
  'shared/points.lua',
  'shared/sectors.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',

  -- Core race engine
  'data/tracks.lua',
  'server/lapcount.lua',
  'server/main.lua',
  'server/queue.lua',
  'server/poll.lua',
  'server/world.lua',
  'server/countdown.lua',
  'server/sectors.lua',
  'server/checkpoints.lua',
  'server/incidents.lua',
  -- 'server/timing.lua',
  'server/bots.lua',
  'server/positions.lua',
  'server/overtakes.lua',
  'server/dnf.lua',
  'server/reconnect.lua',
  'server/results.lua',
  'server/showcase.lua',
  'server/cleanup.lua',
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
  'server/dev_heading.lua',
}

client_scripts {
  'client/main.lua',
  'client/checkpoints.lua',
  'client/cp_cross.lua',
  'client/hit_detector.lua',
  'client/incidents.lua',
  'client/nui_bridge.lua',
  'client/raceblips.lua',
  'client/bots.lua',
  'client/trackboard.lua',
  'client/showcase.lua',
  'client/bonus.lua',
  'client/lockin.lua',
  'client/recover.lua',
  'client/rewind.lua',
  'client/timetrail.lua',
  'client/duel.lua',
  'client/creator.lua',
  'client/editor.lua',
  'client/dev_heading.lua',
}

-- Custom checkpoint / start / finish props.
-- The .ydr + .ytd stream automatically from stream/, but the .ytyp must be
-- declared and requested as a DLC ITYP so the models resolve.
files {
  'stream/bzzz_checkpoint_package.ytyp',
}

data_file 'DLC_ITYP_REQUEST' 'stream/bzzz_checkpoint_package.ytyp'

dependencies {
  'ox_lib',
  'spz-core',
  'spz-identity',
  'spz-vehicles',
  'oxmysql',
}
