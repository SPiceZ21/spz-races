-- server/progression/domain/irating.lua — ranking v3: irating.
-- Moved from spz-progression/domain/irating.lua when it was merged into spz-races.

-- domain/irating.lua
-- Pure pairwise Elo for iRating (display + rival matching; not a rank input).
--
-- The old table (+25, +18, ... -10) summed to +45 across an 8-car field, so
-- ratings inflated with play, and a solo race paid +25 every time. Pairwise
-- Elo is zero-sum: every pair (i, j) exchanges K * (S - E) / (N - 1) points,
-- with S = 1 if i finished ahead of j, 0.5 for two DNFs, 0 otherwise.
-- A field of one has no pairs, so it changes nothing.

SPZ = SPZ or {}
SPZ.IRating = {}

local IR = SPZ.IRating

local function expected(ri, rj)
    return 1 / (1 + 10 ^ ((rj - ri) / 400))
end

--- field = { { key, rating, position, dnf }, ... }
--- r     = { k, min, max }
--- Returns { [key] = integer delta }.
function IR.Deltas(field, r)
    local n = #field
    local out = {}
    for _, p in ipairs(field) do out[p.key] = 0 end
    if n < 2 then return out end

    for i = 1, n do
        local a = field[i]
        local sum = 0
        for j = 1, n do
            if i ~= j then
                local b = field[j]
                local s
                if a.dnf and b.dnf then s = 0.5
                elseif a.dnf then s = 0
                elseif b.dnf then s = 1
                elseif a.position < b.position then s = 1
                elseif a.position > b.position then s = 0
                else s = 0.5 end
                sum = sum + (s - expected(a.rating, b.rating))
            end
        end
        local d = r.k * sum / (n - 1)
        out[a.key] = (d >= 0) and math.floor(d + 0.5) or -math.floor(-d + 0.5)
    end
    return out
end

function IR.Clamp(rating, r)
    return math.max(r.min, math.min(r.max, rating))
end

return IR
