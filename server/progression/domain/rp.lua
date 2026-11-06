-- server/progression/domain/rp.lua — ranking v3: rp.
-- Moved from spz-progression/domain/rp.lua when it was merged into spz-races.

-- domain/rp.lua
-- Pure Rank Points formula (ranking v3). One integer delta per player per race.
--
--   s     = (N - position) / (N - 1)          winner 1.0, last 0.0, DNF 0.0
--   w     = min(1, (N - 1) / weightDivisor)    small fields count for less
--   base  = (slope * (s - breakEven) + participation) * w + podium
--   f     = clamp(1 + (fieldAvg - rp) / strengthScale, min, max)
--   gain  = base * f * min(boostCap, 1 + clean + streak)      (base > 0)
--   loss  = base * (2 - f)                                     (base <= 0)
--   delta = round(gain|loss + flat)
--
-- Nothing here depends on a maximum field size: s is a percentile, and the
-- podium bonus / streak zone are the only things that look at N at all.
-- No natives, no exports, no DB — see tests/run.lua.

SPZ = SPZ or {}
SPZ.RP = {}

local RP = SPZ.RP

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Round half away from zero (math.floor alone would bias losses).
local function round(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end
RP.Round = round

function RP.Weight(n, r)
    return math.min(1, (n - 1) / r.weightDivisor)
end

function RP.Strength(fieldAvg, rp, r)
    return clamp(1 + (fieldAvg - rp) / r.strengthScale, r.strengthMin, r.strengthMax)
end

--- Extra RP for P1..P3, ramping in with field size. Zero in small fields and
--- for DNFs.
function RP.Podium(position, n, dnf, r)
    if dnf or not position or position > #r.podium or n <= r.podiumFrom then return 0 end
    local ramp = math.min(1, (n - r.podiumFrom) / (r.podiumFull - r.podiumFrom))
    return r.podium[position] * ramp
end

--- How many top places extend a streak: top 3, or top 10% in big fields.
function RP.StreakTop(n, r)
    return math.max(r.streakTopMin, math.ceil(r.streakTopFraction * n))
end

--- e = { position, n, rp, fieldAvg, dnf, clean, streak, perfectLap, trackRecord }
--- Returns the integer delta (before the class floor and the daily cap).
function RP.Compute(e, r)
    local n = e.n or 0
    if n < r.ratedMinField then return 0 end

    local s    = e.dnf and 0 or (n - e.position) / (n - 1)
    local base = (r.slope * (s - r.breakEven) + r.participation) * RP.Weight(n, r)
               + RP.Podium(e.position, n, e.dnf, r)
    local f    = RP.Strength(e.fieldAvg or 0, e.rp or 0, r)

    local d
    if base > 0 then
        local streak = math.min(r.streakMax, r.streakStep * (e.streak or 0))
        local boost  = 1 + (e.clean and r.clean or 0) + streak
        d = base * f * math.min(r.boostCap, boost)
    else
        d = base * (2 - f)
    end

    d = d + (e.perfectLap and r.perfectLap or 0) + (e.trackRecord and r.trackRecord or 0)
    return round(d)
end

--- Apply the class floor and the daily cap to a raw delta.
--- Returns the delta actually applied and the new RP.
---   floor    : class floor of the player's CURRENT class
---   dayGain  : positive RP already earned today
function RP.Apply(rp, delta, floor, dayGain, r)
    if delta > 0 then
        local room = math.max(0, r.dailyCap - (dayGain or 0))
        delta = math.min(delta, room)
    end
    local after = math.max(floor, rp + delta)
    return after - rp, after
end

return RP
