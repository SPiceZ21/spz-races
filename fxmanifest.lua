fx_version 'cerulean'
game 'gta5'

name 'spz-races'
description 'SPiceZ-Core — Race engine, poll, timing, checkpoints'
version '1.9.0'
author 'SPiceZ-Core'

shared_scripts {
  'config.lua',
  'shared/race_states.lua',
  'shared/events.lua',
  'shared/points.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',

  -- Core race engine
  'data/tracks.lua',
  'server/main.lua',
  'server/queue.lua',
  'server/poll.lua',
  'server/world.lua',
  'server/no_collision.lua',
  'server/countdown.lua',
  'server/checkpoints.lua',
  -- 'server/timing.lua',
  'server/positions.lua',
  'server/dnf.lua',
  'server/results.lua',
  'server/cleanup.lua',
  'server/intermission.lua',
  'server/timetrail.lua',
  'server/state_machine.lua',

  -- Leaderboard (absorbed from spz-leaderboard)
  'server/leaderboard/config.lua',
  'server/leaderboard/cache.lua',
  'server/leaderboard/utils.lua',
  'server/leaderboard/writer.lua',
  'server/leaderboard/records.lua',
  'server/leaderboard/standings.lua',
  'server/leaderboard/stats.lua',
  'server/leaderboard/callbacks.lua',
  'server/creator.lua',
}

client_scripts {
  'client/main.lua',
  'client/checkpoints.lua',
  'client/hit_detector.lua',
  'client/nui_bridge.lua',
  'client/timetrail.lua',
  'client/creator.lua',
  'client/editor.lua',
}

dependencies {
  'spz-lib',
  'spz-core',
  'spz-identity',
  'spz-vehicles',
  'oxmysql',
}
