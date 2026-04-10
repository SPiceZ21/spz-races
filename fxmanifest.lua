fx_version 'cerulean'
game 'gta5'

name 'spz-races'
description 'SPiceZ-Core — Race engine, poll, timing, checkpoints'
version '1.0.0'
author 'SPiceZ-Core'

shared_scripts {
  'shared/race_states.lua',
  'shared/events.lua',
  'shared/points.lua',
}

server_scripts {
  'data/tracks.lua',
  'server/main.lua',
  'server/state_machine.lua',
  'server/queue.lua',
  'server/poll.lua',
  'server/world.lua',
  'server/no_collision.lua',
  'server/countdown.lua',
  'server/checkpoints.lua',
  'server/timing.lua',
  'server/positions.lua',
  'server/dnf.lua',
  'server/results.lua',
  'server/cleanup.lua',
  'server/intermission.lua',
}

client_scripts {
  'client/main.lua',
  'client/checkpoints.lua',
  'client/hit_detector.lua',
  'client/nui_bridge.lua',
}

dependencies {
  'spz-lib',
  'spz-core',
  'spz-identity',
  'spz-vehicles',
}
