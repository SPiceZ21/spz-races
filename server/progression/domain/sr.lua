-- server/progression/domain/sr.lua — ranking v3: sr.
-- Moved from spz-progression/domain/sr.lua when it was merged into spz-races.

-- domain/sr.lua
-- Pure Safety Rating maths (display stat; not a rank input).
--
-- The daily caps in config were never enforced: ApplySR was a TODO and the
-- race pipeline added the raw delta. Apply() below enforces both caps per UTC
-- day, using the sr_daily_gain / sr_daily_loss / sr_day_marker profile columns.

SPZ = SPZ or {}
SPZ.SR = {}

local SR = SPZ.SR

--- d = { dnf, position, personalBest, incidents }
function SR.Delta(d, r)
    if d.dnf then return r.dnfPenalty end
    local delta = r.finishGain
    if d.position <= 3 then
        delta = delta + r.top3Gain
    elseif d.position <= 5 then
        delta = delta + r.top5Gain
    end
    if d.personalBest then delta = delta + r.pbGain end
    if (d.incidents or 0) > 0 then
        delta = delta + math.max(d.incidents * r.collisionPenalty, r.collisionCapPerRace)
    end
    return delta
end

--- Apply a delta with the daily caps.
--- day = { gain, loss, marker }; today = integer day number (UTC).
--- Returns newSR, appliedDelta, newDay.
function SR.Apply(sr, delta, day, today, r)
    local gain, loss = day.gain or 0, day.loss or 0
    if day.marker ~= today then gain, loss = 0, 0 end

    if delta > 0 then
        delta = math.max(0, math.min(delta, r.dailyMaxGain - gain))
        gain = gain + delta
    elseif delta < 0 then
        delta = math.min(0, math.max(delta, r.dailyMaxLoss - loss))
        loss = loss + delta
    end

    local new = math.max(r.min, math.min(r.max, sr + delta))
    new = math.floor(new * 100 + 0.5) / 100
    return new, new - sr, { gain = gain, loss = loss, marker = today }
end

return SR
