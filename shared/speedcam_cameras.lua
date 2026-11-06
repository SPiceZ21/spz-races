-- shared/speedcam_cameras.lua — speed camera list.
-- Moved from spz-speedcam/shared/cameras.lua when it was merged into spz-races.
local Config = Config.Speedcam

-- Speed camera network — GTA V key road locations
-- coords       = trigger sphere centre
-- radius       = trigger sphere radius (overrides Config.DetectionRadius)
-- minSpeedKmh  = per-camera trigger speed (overrides Config.MinSpeedKmh)
--
-- Source trigger speeds were in mph; converted to km/h (mph * 1.60934).

SpeedCams = {
    { id = "speedcam_hawick",           name = "Hawick Ave",            coords = vector3(71.9733, -167.5430, 54.8357),      radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_vespucci_bvd",     name = "Vespucci Blvd",         coords = vector3(-995.1254, -813.7751, 15.2711),    radius = 20, minSpeedKmh = 104.6 }, -- 65 mph
    { id = "speedcam_richman",          name = "Richman",               coords = vector3(-1449.8134, -91.5597, 50.4048),    radius = 20, minSpeedKmh = 112.7 }, -- 70 mph
    { id = "speedcam_del_perro",        name = "Del Perro",             coords = vector3(-1380.7408, -563.6718, 29.6369),   radius = 20, minSpeedKmh = 88.5 },  -- 55 mph
    { id = "speedcam_pillbox_hill",     name = "Pillbox Hill",          coords = vector3(-40.5624, -744.6534, 32.4038),     radius = 10, minSpeedKmh = 88.5 },  -- 55 mph
    { id = "speedcam_power_station",    name = "Power Station",         coords = vector3(827.5869, 214.2349, 81.2721),      radius = 20, minSpeedKmh = 112.7 }, -- 70 mph
    { id = "speedcam_strawberry",       name = "Strawberry",            coords = vector3(-82.7454, -1358.5077, 28.9933),    radius = 20, minSpeedKmh = 88.5 },  -- 55 mph
    { id = "speedcam_magellan_ave",     name = "Magellan Ave",          coords = vector3(-1206.8033, -1425.4154, 3.6623),   radius = 20, minSpeedKmh = 88.5 },  -- 55 mph
    { id = "speedcam_la_puerta",        name = "La Puerta",             coords = vector3(-950.4027, -1826.6072, 19.1202),   radius = 20, minSpeedKmh = 88.5 },  -- 55 mph
    { id = "speedcam_roy_lowenstein",   name = "Roy Lowenstein Blvd",   coords = vector3(270.2276, -1830.8854, 26.0439),    radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_el_burro_heights", name = "El Burro Heights",      coords = vector3(1245.5765, -1803.8717, 40.2087),   radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_la_mesa",          name = "La Mesa",               coords = vector3(790.3174, -787.0955, 25.6392),     radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_vinewood_hills",   name = "Vinewood Hills",        coords = vector3(283.3477, 761.3006, 183.7673),     radius = 20, minSpeedKmh = 88.5 },  -- 55 mph
    { id = "speedcam_banham_canyon",    name = "Banham Canyon",         coords = vector3(-3038.6099, 466.0157, 5.8107),     radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_tongva_hills",     name = "Tongva Hills",          coords = vector3(-2502.6150, 1737.2671, 154.7481),  radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_route68",          name = "Route 68",              coords = vector3(-2541.6262, 3404.4719, 12.6126),   radius = 25, minSpeedKmh = 120.7 }, -- 75 mph
    { id = "speedcam_raton_canyon",     name = "Raton Canyon Highway",  coords = vector3(-2217.4910, 4352.2700, 50.4360),   radius = 25, minSpeedKmh = 128.7 }, -- 80 mph
    { id = "speedcam_paleto_forest",    name = "Paleto Forest",         coords = vector3(-541.9440, 5425.3364, 62.5591),    radius = 25, minSpeedKmh = 120.7 }, -- 75 mph
    { id = "speedcam_paleto_bay",       name = "Paleto Bay",            coords = vector3(-130.9262, 6417.1587, 30.8790),    radius = 20, minSpeedKmh = 88.5 },  -- 55 mph
    { id = "speedcam_grapeseed",        name = "Grapeseed",             coords = vector3(2169.0115, 4898.5552, 40.0830),    radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_sandy_shores",     name = "Sandy Shores",          coords = vector3(1872.5623, 3686.1357, 32.9408),    radius = 20, minSpeedKmh = 96.6 },  -- 60 mph
    { id = "speedcam_grand_senora",     name = "Grand Senora Desert",   coords = vector3(1099.4556, 3375.0732, 33.7809),    radius = 25, minSpeedKmh = 112.7 }, -- 70 mph
    { id = "speedcam_redwood_lights",   name = "Redwood Lights Track",  coords = vector3(964.8541, 2150.3367, 48.1428),     radius = 25, minSpeedKmh = 112.7 }, -- 70 mph
    { id = "speedcam_davis_quartz",     name = "Davis Quartz",          coords = vector3(2758.9541, 2901.8479, 35.7019),    radius = 20, minSpeedKmh = 104.6 }, -- 65 mph
    { id = "speedcam_ron_wind_farm",    name = "RON Wind Farm",         coords = vector3(2190.2292, 2440.7639, 88.0224),    radius = 25, minSpeedKmh = 112.7 }, -- 70 mph
    { id = "speedcam_burton",           name = "Burton",                coords = vector3(-58.9258, 27.3499, 71.4968),       radius = 20, minSpeedKmh = 88.5 },  -- 55 mph
}

-- Lookup helper used by both client and server
SpeedCamById = {}
for _, cam in ipairs(SpeedCams) do
    SpeedCamById[cam.id] = cam
end
