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

-- One track's route for the hub map (drawn as a ribbon over the city when its
-- pin is selected): the centre of every gate, in order.
lib.callback.register('spz-races:mapTrackLayout', function(_, id)
    local t = SPZ.Tracks and SPZ.Tracks[id]
    if not t or not t.checkpoints then return nil end
    local pts = {}
    for i, cp in ipairs(t.checkpoints) do
        local c = cp.coords
        if cp.left and cp.right then
            c = vector3((cp.left.x + cp.right.x) * 0.5, (cp.left.y + cp.right.y) * 0.5, (cp.left.z + cp.right.z) * 0.5)
        end
        if c then pts[#pts + 1] = { x = c.x, y = c.y, z = c.z } end
    end
    return { points = pts, loop = t.type ~= 'sprint' }
end)
