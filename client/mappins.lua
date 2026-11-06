-- client/mappins.lua — map pins for the TAB hub (spz-hud client/hub_map.lua):
-- race track starts and speed cameras.
--   exports['spz-races']:GetMapPins() -> { { id, kind, label, sub, x, y, z, info = {...} }, ... }
local tracks

local function loadTracks()
    if tracks then return tracks end
    local ok, list = pcall(function() return lib.callback.await('spz-races:mapTracks', false) end)
    tracks = (ok and type(list) == 'table') and list or {}
    return tracks
end

exports('GetMapPins', function()
    local pins = {}
    for _, t in ipairs(loadTracks()) do
        pins[#pins + 1] = {
            id = 'track:' .. t.id, kind = 'track', label = t.name,
            sub = (t.type == 'sprint' and 'Sprint' or 'Circuit'),
            x = t.x, y = t.y, z = t.z,
            info = { { 'Type', t.type == 'sprint' and 'Sprint' or 'Circuit' }, { 'Laps', t.type == 'sprint' and '—' or tostring(t.laps or 1) }, { 'Gates', tostring(t.gates or '—') } },
        }
    end
    for _, c in ipairs(SpeedCams or {}) do
        pins[#pins + 1] = {
            id = 'cam:' .. c.id, kind = 'speedcam', label = c.name, sub = 'Speed camera',
            x = c.coords.x, y = c.coords.y, z = c.coords.z,
            info = { { 'Trigger', ('%d km/h'):format(math.floor(c.minSpeedKmh or 0)) } },
        }
    end
    return pins
end)
