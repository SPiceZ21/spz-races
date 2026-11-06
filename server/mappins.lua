-- server/mappins.lua — the race tracks for the TAB hub's map (client/mappins.lua).
-- Tracks are server-side (data/tracks.lua + custom_tracks.json); the client asks
-- once per session for the start of each one.
lib.callback.register('spz-races:mapTracks', function()
    local out = {}
    for id, t in pairs(SPZ.Tracks or {}) do
        local c = t.start_coords or (t.checkpoints and t.checkpoints[1] and t.checkpoints[1].coords)
        if c then
            out[#out + 1] = {
                id = tostring(id), name = t.name or tostring(id), type = t.type or 'circuit',
                laps = t.laps, gates = t.checkpoints and #t.checkpoints or nil,
                x = c.x, y = c.y, z = c.z,
            }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end)
