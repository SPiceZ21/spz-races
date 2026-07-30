-- client/cp_cross.lua
-- Checkpoint CROSSING detection, shared by the race and time-trial hit
-- detectors. Replaces the old radius/sphere check (which fired on entry, from
-- the sides, and before you actually passed the line).
--
-- A checkpoint's gate is the segment between its left and right posts. We form
-- the vertical plane through the checkpoint centre whose normal points along
-- the direction of travel, and register a hit only when the player:
--   1. moves from one side of that plane to the other (an actual crossing), AND
--   2. is laterally BETWEEN the posts (so passing near the side doesn't count).
--
-- Tracks of gate posts fall back to the old radius check.

local Z_THRESH     = 8.0    -- vertical tolerance
local GATE_MARGIN  = 2.0    -- metres of slack outside the posts (wide cars)

-- cp    : { coords, left, right, radius }
-- pos   : player position (vector3)
-- prev  : the previous side value this detector stored for this checkpoint
-- returns: crossed(bool), side(number|nil)  — store `side` back for next call
function SPZ_GateCross(cp, pos, prev)
    if not cp then return false, nil end

    local cx, cy, cz = cp.coords.x, cp.coords.y, cp.coords.z

    -- ── No gate posts: legacy radius check (entry-based) ─────────────────────
    if not (cp.left and cp.right) then
        local r  = cp.radius or 5.0
        local dx, dy = pos.x - cx, pos.y - cy
        if (dx*dx + dy*dy) < (r*r) and math.abs(pos.z - cz) < Z_THRESH then
            return true, prev
        end
        return false, prev
    end

    local ax, ay = cp.left.x,  cp.left.y
    local bx, by = cp.right.x, cp.right.y
    local gx, gy = bx - ax, by - ay
    local glen   = math.sqrt(gx*gx + gy*gy)
    if glen < 0.01 then
        -- degenerate gate → radius fallback
        local r  = cp.radius or 5.0
        local dx, dy = pos.x - cx, pos.y - cy
        if (dx*dx + dy*dy) < (r*r) and math.abs(pos.z - cz) < Z_THRESH then
            return true, prev
        end
        return false, prev
    end

    -- Plane normal = perpendicular to the gate line (≈ direction of travel).
    local nx, ny = -gy / glen, gx / glen
    -- Signed distance of the player from the plane through the centre.
    local d    = (pos.x - cx) * nx + (pos.y - cy) * ny
    local side = (d >= 0) and 1 or -1

    -- Lateral position along the gate axis, measured from the left post.
    -- Must lie within [0, glen] (± margin) to count as passing THROUGH the gate.
    local t          = ((pos.x - ax) * gx + (pos.y - ay) * gy) / glen
    local withinGate = t >= -GATE_MARGIN and t <= (glen + GATE_MARGIN)
    local zOk        = math.abs(pos.z - cz) < Z_THRESH

    -- A hit is a genuine side-flip while between the posts, at the right height.
    if prev ~= nil and prev ~= side and withinGate and zOk then
        return true, side
    end

    return false, side
end
