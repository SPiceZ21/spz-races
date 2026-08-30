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
-- returns: crossed(bool), side(number|nil), missed(bool)
--   `side`   — store back and pass in as `prev` next call
--   `missed` — the player crossed the gate PLANE but outside the posts. That is
--              the precise definition of missing a checkpoint, and it is already
--              computed here to decide `crossed`; returning it means callers do
--              not have to re-derive it from distance guesswork.
--              Radius-only checkpoints (no posts) have no "outside the gate"
--              geometry, so they never report a miss.
function SPZ_GateCross(cp, pos, prev)
    if not cp then return false, nil, false end

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

    -- Plane normal, perpendicular to the gate line, ALIGNED to the direction of
    -- travel via the checkpoint heading. Alignment lets us call the "before"
    -- side deterministically (negative), independent of left/right post order.
    local nx, ny = -gy / glen, gx / glen
    if cp.heading then
        local rad = math.rad(cp.heading)
        local hx, hy = -math.sin(rad), math.cos(rad)   -- forward vector
        if (nx * hx + ny * hy) < 0 then nx, ny = -nx, -ny end
    end

    -- Signed distance from the plane: >0 = past the line, <0 = before it.
    local d    = (pos.x - cx) * nx + (pos.y - cy) * ny
    local side = (d >= 0) and 1 or -1

    -- Lateral position along the gate axis, measured from the left post.
    -- Must lie within [0, glen] (± margin) to count as passing THROUGH the gate.
    local t          = ((pos.x - ax) * gx + (pos.y - ay) * gy) / glen
    local withinGate = t >= -GATE_MARGIN and t <= (glen + GATE_MARGIN)
    local zOk        = math.abs(pos.z - cz) < Z_THRESH

    -- First sample after this checkpoint became active: seed the side to
    -- "before" (-1). At the START you spawn ON the line, so there is no
    -- approach to flip from — seeding "before" means the very first forward
    -- move across the line registers, instead of the start point being skipped.
    if prev == nil then
        return false, -1
    end

    -- A hit is a genuine before→after flip while between the posts.
    local flipped = (prev ~= side) and side == 1
    if flipped and withinGate and zOk then
        return true, side, false
    end

    -- Same flip, but wide of the posts (or well above/below them): the player
    -- went past this checkpoint without going through it.
    return false, side, flipped
end
