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
local HYSTERESIS   = 0.4    -- dead band around the plane; kills stationary jitter

-- Corridor in which the player's side of the plane is tracked at all.
--
-- TRACK_DEPTH is deliberately inside the band where the hit detector polls
-- every 20 ms or faster: at racing speed a 100 ms poll covers five metres, and
-- the corridor has to be sampled densely enough that a car cannot enter it and
-- cross the plane within a single sample. Widening this without also raising
-- the poll rate would let fast cars tunnel straight through a gate.
local TRACK_SPAN   = 1.0    -- gate widths of lateral slack on each side
local TRACK_DEPTH  = 50.0   -- metres in front of / behind the plane

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
    local d       = (pos.x - cx) * nx + (pos.y - cy) * ny
    local rawSide = (d >= 0) and 1 or -1

    -- Lateral position along the gate axis, measured from the left post.
    -- Must lie within [0, glen] (± margin) to count as passing THROUGH the gate.
    local t          = ((pos.x - ax) * gx + (pos.y - ay) * gy) / glen
    local withinGate = t >= -GATE_MARGIN and t <= (glen + GATE_MARGIN)
    local zOk        = math.abs(pos.z - cz) < Z_THRESH

    -- ── Tracking region ──────────────────────────────────────────────────────
    --
    -- Which side of the plane the player is on is only MEANINGFUL near the gate.
    -- The plane is infinite: a reading taken two hundred metres out on the flank
    -- says nothing about which way they will eventually arrive, and on a circuit
    -- that bends back on itself the player spends most of a lap technically
    -- "past" the plane of the checkpoint they are driving towards.
    --
    -- So side is tracked inside a corridor in front of and behind the gate, and
    -- forgotten outside it. Both previous versions of this got it wrong in
    -- opposite directions by treating the reading as meaningful everywhere:
    --
    --   Seeding "before" unconditionally scored the gate the instant it armed if
    --   the player happened to be past the plane — a checkpoint you could take
    --   from behind, plus phantom "checkpoint missed" prompts.
    --
    --   Seeding from the raw side fixed that but broke the normal case: a player
    --   approaching from far out on the flank was seeded "past" before they were
    --   anywhere near the gate, so driving through it correctly registered
    --   nothing, and the only way to score was to double back and come again.
    --
    -- Inside the corridor the reading is real, because the only way to get from
    -- one side to the other is to actually pass the gate.
    local nearGate = t >= -(glen * TRACK_SPAN) and t <= (glen * (1.0 + TRACK_SPAN))
    local inRegion = nearGate and math.abs(d) < TRACK_DEPTH

    if not inRegion then
        -- Outside the corridor: forget the side entirely, so the next approach
        -- re-seeds from wherever they genuinely enter from.
        return false, nil, false
    end

    -- First sample INSIDE the corridor: seed from where the player actually is.
    -- The one case with no approach to flip from is the start line, where the
    -- car sits on the plane between the posts — that seeds "before", or the
    -- first checkpoint of a race could never be scored.
    if prev == nil then
        if withinGate and math.abs(d) < ON_LINE then return false, -1, false end
        return false, rawSide, false
    end

    -- Hysteresis band around the plane.
    --
    -- A car sitting on the line is never perfectly still — suspension settle,
    -- collision jitter and network correction all wobble its position by
    -- centimetres, and each wobble across d = 0 is a side change. Holding the
    -- previous side inside a narrow band means a flip has to be an actual
    -- movement through the gate rather than the car breathing on the spot.
    -- This matters far more now that a crossing counts in EITHER direction:
    -- unidirectional scoring only ever saw half of that jitter.
    local side = rawSide
    if math.abs(d) < HYSTERESIS then side = prev end

    -- A hit is a crossing of the plane between the posts, in EITHER direction.
    --
    -- Direction used to be enforced — only a before→after flip scored — and it
    -- was removed on request: players who spun, reversed through a gate, or came
    -- at it from the far side found the checkpoint silently refusing to count,
    -- and being stranded is a worse experience than the shortcut this allows.
    -- Order and proximity are still enforced by the server, so the gate has to
    -- be the one you were actually due to cross and you have to be near it; only
    -- the direction you pass through it is now free.
    local flipped = (prev ~= side)
    if flipped and withinGate and zOk then
        return true, side, false
    end

    -- Same flip, but wide of the posts: the player went past this checkpoint
    -- without going through it. Being inside the corridor is already the
    -- proximity test, so no extra distance check is needed here.
    return false, side, (flipped and zOk)
end
