-- server/progression/domain/rank.lua — ranking v3: rank.
-- Moved from spz-progression/domain/rank.lua when it was merged into spz-races.

-- domain/rank.lua
-- Pure rank lookup: Rank Points (RP) -> "C-5" … "S-1".
--
-- No natives, no exports, no DB. The rules table is passed in, so this file
-- runs unchanged inside FiveM and under plain Lua (tests/run.lua).
--
-- The ladder is 4 classes x 5 sub-ranks. Sub-rank 5 is the entry rung of a
-- class, 1 is the top. Each class has a fixed RP step between its rungs; past
-- S-1 there are no more rungs (the S-1 board orders by raw RP instead).

SPZ = SPZ or {}
SPZ.Rank = {}

local Rank = SPZ.Rank

--- Build the 20-row table from rules.tiers, ascending by RP.
--- rules.tiers = { { id, letter, enter, step }, ... } in ascending order.
function Rank.BuildTable(rules)
    local rows = {}
    for _, t in ipairs(rules.tiers) do
        for k = 0, 4 do
            rows[#rows + 1] = {
                rp   = t.enter + k * t.step,
                rank = ("%s-%d"):format(t.letter, 5 - k),
                tier = t.id,
            }
        end
    end
    table.sort(rows, function(a, b) return a.rp < b.rp end)
    return rows
end

--- Rank string and class tier (0-3) for an RP value.
--- The previous ComputeRank kept the LAST threshold that matched while walking
--- thresholds that fell as the index rose, so it always landed on "-5". This
--- walks ascending and stops at the first rung above the player.
function Rank.For(rp, rows)
    rp = tonumber(rp) or 0
    local found = rows[1]
    for i = 1, #rows do
        if rp >= rows[i].rp then found = rows[i] else break end
    end
    return found.rank, found.tier
end

--- RP at which the class containing `rp` starts. RP can never fall below this
--- (rank lock: you can lose sub-ranks, never a class).
function Rank.ClassFloor(rp, rules)
    rp = tonumber(rp) or 0
    local floor = rules.tiers[1].enter
    for _, t in ipairs(rules.tiers) do
        if rp >= t.enter then floor = t.enter end
    end
    return floor
end

--- Progress 0..1 from the current rung to the next one, plus the next rank
--- name. At S-1 the bar shows progress through one more S step (the board
--- position is what moves past that point).
function Rank.Progress(rp, rows)
    rp = tonumber(rp) or 0
    local idx = 1
    for i = 1, #rows do
        if rp >= rows[i].rp then idx = i else break end
    end
    local cur = rows[idx]
    local nxt = rows[idx + 1]
    if not nxt then
        local step = (idx > 1) and (cur.rp - rows[idx - 1].rp) or 1000
        local frac = ((rp - cur.rp) % step) / step
        return frac, nil
    end
    return (rp - cur.rp) / (nxt.rp - cur.rp), nxt.rank
end

--- Compare two rank strings: returns 1 if b is higher than a, -1 if lower,
--- 0 if equal. Used to tell promotions from demotions.
function Rank.Compare(a, b, rows)
    local ia, ib = 0, 0
    for i, r in ipairs(rows) do
        if r.rank == a then ia = i end
        if r.rank == b then ib = i end
    end
    if ib > ia then return 1 elseif ib < ia then return -1 end
    return 0
end

return Rank
