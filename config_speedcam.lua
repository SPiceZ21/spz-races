-- config_speedcam.lua — speed camera network.
-- Moved from spz-speedcam/config.lua when it was merged into spz-races. Read as Config.Speedcam.<option>.

Config.Speedcam = {}
local Config = Config.Speedcam
-- Detection
Config.DetectionRadius = 18.0    -- metres: trigger sphere around camera
Config.NearbyRadius    = 100.0   -- metres: broad radius — enables fast-poll mode
Config.MinSpeedKmh     = 40.0    -- minimum speed to register a capture
Config.CooldownMs      = 25000   -- ms before same camera can capture same player again

-- Display
Config.Units           = 'kmh'   -- 'kmh' or 'mph'
Config.CardDurationMs  = 6000    -- how long the capture card stays on screen

-- Records command
Config.RecordsCommand  = 'speedrecords'
Config.RecordsKeyCommand = 'speedcam_records'   -- key mapping command (see client/main.lua)
Config.RecordsKey      = 'F2'                   -- was F7; F7 is now the minigame hub

-- Map blips for every speed camera.
Config.ShowBlips   = true
Config.BlipSprite  = 184     -- speed camera icon
Config.BlipColour  = 1       -- red
Config.BlipScale    = 0.7     -- minimap icon size
Config.BlipCategory = 10      -- big-map legend group ("Speed Cameras")
