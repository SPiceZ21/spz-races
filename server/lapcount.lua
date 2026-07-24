-- server/lapcount.lua
-- Personalised lap count per track by length. Runs once after data/tracks.lua
-- loads and rewrites `laps` on every circuit in SPZ.Tracks, so every consumer
-- (race engine, poll, TT menu, results) reads the adjusted value with no other
-- code change. Sprints are point-to-point and always 1 lap — left untouched.
--
--   lap distance  >  Config.LongTrackMetres   -> Config.LongTrackLaps  (2)
--   lap distance  <= Config.LongTrackMetres   -> Config.ShortTrackLaps (3)

local LONG_M     = (Config and Config.LongTrackMetres) or 4200.0
local LONG_LAPS  = (Config and Config.LongTrackLaps)   or 2
local SHORT_LAPS = (Config and Config.ShortTrackLaps)  or 3

-- Total distance of ONE lap: sum of consecutive checkpoint gaps, plus the
-- closing gap back to the start (circuits are loops).
local function lapDistance(track)
    local cps = track.checkpoints
    if not cps or #cps < 2 then return 0.0 end

    local d = 0.0
    for i = 2, #cps do
        d = d + #(cps[i].coords - cps[i - 1].coords)
    end
    -- circuit: close the loop
    d = d + #(cps[1].coords - cps[#cps].coords)
    return d
end

CreateThread(function()
    if not SPZ or not SPZ.Tracks then return end

    local adjusted = 0
    for _, track in pairs(SPZ.Tracks) do
        if track.type == "circuit" then
            local dist = lapDistance(track)
            track.lapDistance = math.floor(dist)          -- handy for menus/UI
            track.laps = (dist > LONG_M) and LONG_LAPS or SHORT_LAPS
            adjusted = adjusted + 1
        else
            track.laps = 1
        end
    end

    print(("[Race] Lap counts set by length: %d circuits (>%dm = %d laps, else %d laps)")
        :format(adjusted, math.floor(LONG_M), LONG_LAPS, SHORT_LAPS))
end)
