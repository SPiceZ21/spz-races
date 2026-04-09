fx_version 'cerulean'
game 'gta5'

author 'SPiceZ'
description 'SPiceZ-Core Racing Resource'
version '1.0.0'

shared_scripts {
    'config.lua',
    'data/tracks.lua',
    'shared/race_states.lua',
    'shared/events.lua',
    'shared/points.lua'
}

client_scripts {
    'client/main.lua',
    'client/checkpoints.lua',
    'client/hit_detector.lua',
    'client/nui_bridge.lua'
}

server_scripts {
    'server/main.lua',
    'server/state_machine.lua',
    'server/queue.lua',
    'server/poll.lua',
    'server/world.lua',
    'server/no_collision.lua',
    'server/countdown.lua',
    'server/checkpoints.lua',
    'server/positions.lua',
    'server/dnf.lua',
    'server/results.lua',
    'server/cleanup.lua',
    'server/intermission.lua'
}
