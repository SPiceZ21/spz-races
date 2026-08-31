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
local ON_LINE      = 3.0    -- distance from the plane still counted as "on" it

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

    -- First sample after this checkpoint became active: seed from where the
    -- player ACTUALLY is.
    --
    -- This used to seed "before" (-1) unconditionally, which is wrong whenever
    -- the player is already past the plane when the checkpoint arms — and since
    -- the plane is infinite, that is ordinary geometry on any circuit that bends
    -- back on itself, not a mistake. The very next sample then read side = +1
    -- against a fabricated prev of -1 and called it a forward crossing. Two
    -- symptoms, one cause: standing past a gate inside the posts scored it
    -- instantly (a checkpoint that could be taken from behind), and standing
    -- past it outside the posts fired "Checkpoint missed" out of nowhere.
    --
    -- The one case that genuinely has no approach to flip from is the start
    -- line, where the car sits ON the plane between the posts. That still seeds
    -- "before", or the first checkpoint could never be scored.
    if prev == nil then
        if withinGate and math.abs(d) < ON_LINE then return false, -1 end
        return false, side
    end

    -- A hit is a genuine before→after flip while between the posts.
    local flipped = (prev ~= side) and side == 1
    if flipped and withinGate and zOk then
        return true, side, false
    end

    -- Same flip, but wide of the posts: the player went past this checkpoint
    -- without going through it.
    --
    -- Gated on being NEAR the gate, because the plane has no width — a flip can
    -- happen hundreds of metres off to the side, where the player has not missed
    -- anything, they are simply somewhere else on the track. A real miss is
    -- driving past just outside a post, so the window is one gate-width beyond
    -- each post.
    local nearGate = t >= -glen and t <= (glen * 2)
    local missed   = flipped and zOk and nearGate

    return false, side, missed
end
