SPZ = SPZ or {}

-- 5.1 Race State Enum
SPZ.RaceState = {
  IDLE      = "IDLE",
  POLLING   = "POLLING",
  WAITING   = "WAITING",
  WARMUP    = "WARMUP",
  COUNTDOWN = "COUNTDOWN",
  LIVE      = "LIVE",
  ENDED     = "ENDED",
  CLEANUP   = "CLEANUP",
}

-- 4. Race Types
SPZ.RaceType = {
  CIRCUIT = "circuit",
  SPRINT  = "sprint",
}

if IsDuplicityVersion() then
    function SPZ.Notify(src, msg, ntype, duration)
        TriggerClientEvent('ox_lib:notify', src, { description = msg, type = ntype or "info", duration = duration, position = "center-left" })
    end
end

SPZ.Math = SPZ.Math or {}

--- Spawn slots for `count` cars around `origin`.
---
--- `mode` picks the shape and is passed per PHASE rather than read from one
--- global, because warmup and the race start want opposite things:
---
---   "grid"  staggered rows. Spread out and unambiguous, which is what you want
---           while people are milling around before a race. As a START it hands
---           row 1 a free ~56 m over row 8 on a full field.
---
---   "point" a ring centred on the start point. Every car is the same distance
---           from the centre, so nobody is gifted places by their slot — the
---           spread is ±radius (~10 m on a full grid) against a race measured in
---           kilometres, instead of a queue eight rows deep.
---
--- Point mode is what a fair start looks like once you accept that literally
--- stacking cars on one coordinate is not available: the engine ejects
--- overlapping entities on creation and teleport, and no collision flag reaches
--- that code path. The ring is "one point" as closely as physics permits.
function SPZ.Math.GridPositions(origin, heading, count, rowSpacing, colSpacing, mode)
    local grid = {}
    mode = mode or (Config and Config.SpawnMode) or "grid"

    -- Split mode: TWO start points side by side, half the field on each.
    --
    -- A sixteen-car field is eight cars on the left point and eight on the
    -- right, with a gap down the middle wide enough for the flag girl to stand
    -- in (see client/gridgirl.lua). It is point mode twice over, so it inherits
    -- point mode's guarantee — every car in a pack covers the same distance —
    -- while keeping the two halves clear of each other and leaving the centre
    -- line open.
    --
    -- Each pack is placed by delegating back to point mode about its own
    -- centre, so the radius rules, the ring fallback and the "radius 0 stacks
    -- them, and that is only safe at the re-stage" contract all live in exactly
    -- one place rather than being restated here.
    if mode == "split" then
        local gap = (Config and Config.SplitPointGap) or 6.0
        local rad = math.rad(heading)
        local right = vec3(math.cos(rad), math.sin(rad), 0.0)

        -- Odd fields put the extra car on the left pack; nothing rides on which
        -- side that is, only that the two halves stay within one of each other.
        local leftCount  = math.ceil(count / 2)
        local rightCount = count - leftCount

        local packs = {
            { origin = origin - (right * (gap / 2)), count = leftCount  },
            { origin = origin + (right * (gap / 2)), count = rightCount },
        }

        for _, pack in ipairs(packs) do
            if pack.count > 0 then
                local slots = SPZ.Math.GridPositions(
                    pack.origin, heading, pack.count, rowSpacing, colSpacing, "point")
                for _, slot in ipairs(slots) do
                    grid[#grid + 1] = slot
                end
            end
        end

        return grid
    end

    -- Point mode: everyone spawns around the start point instead of on a
    -- staggered grid. Slots fan out on a ring — visually "all at the point",
    -- physically non-overlapping.
    --
    -- The radius is FLOORED, and that is not a defensive nicety. This used to
    -- honour radius 0, putting every car on identical coordinates on the theory
    -- that ghosting made overlap harmless. It does not: SetEntityNoCollisionEntity
    -- suppresses contact response, but the engine's interpenetration resolver
    -- runs on creation and teleport regardless, and its whole job is to eject
    -- overlapping entities. That is what threw the grid across the map.
    --
    -- A configuration that cannot physically work should not be silently
    -- honoured, so a ring big enough to hold the cars apart is imposed and the
    -- override is logged rather than applied.
    if mode == "point" then
        local MIN_RADIUS = 3.0
        local radius = (Config and Config.PointSpawnRadius) or 0.0

        -- Radius 0 is an explicit "stack them", and it is honoured.
        --
        -- Every car on one coordinate is the fairest start there is, and it is
        -- survivable in this ONE place — the race re-stage — in a way it is not
        -- at vehicle creation. The cars already exist, they are frozen before
        -- and after the teleport, and they are ghosted against each other, so
        -- nothing simulates contact while they sit stacked on the line.
        --
        -- Two things make or break it, both handled in SPZ:tpToGrid:
        -- the teleport must NOT pass clearArea, and the ghost pass has to be
        -- live before the lights. Overlapping cars separate harmlessly on GO
        -- because they drive through each other.
        --
        -- Creation is different and still needs real slots — see
        -- Config.WarmupSpawnMode. Do not reuse radius 0 there.
        if radius <= 0.0 then
            for i = 1, count do
                grid[i] = { coords = origin, heading = heading }
            end
            return grid
        end

        if count > 1 and radius < MIN_RADIUS then
            print(("^3[spz-races] PointSpawnRadius %.1f is below the %.1f m minimum for a RING. "
                .. "Set it to 0 for a deliberate single-point start.^7")
                :format(radius, MIN_RADIUS))
            radius = MIN_RADIUS
        end

        -- Ring circumference has to grow with the field, or a large grid packs
        -- the cars back into each other at a fixed radius.
        --
        -- The per-car arc allowance is set by car LENGTH, not width. Every car
        -- on the ring faces the same way (down the track), so the two at the
        -- front and back of the circle are separated nose-to-tail: 4 m of arc
        -- clears a 2 m-wide car side by side but not a 4.5 m-long one end to
        -- end, and those two would spawn inside each other.
        local CAR_ARC = 6.0
        local needed = (count * CAR_ARC) / (2 * math.pi)
        if needed > radius then radius = needed end

        -- A ring big enough for a full field does not fit on a street.
        --
        -- Sixteen cars need roughly a 15 m radius, which is a 30 m circle — wider
        -- than a four-lane road, so the outer slots land on pavements, in walls
        -- or through shopfronts. That is a worse race start than an unfair one.
        --
        -- Past the cap the field falls back to a grid, and says so. Silently
        -- spawning half the grid inside a building to honour a fairness setting
        -- would be the wrong trade, and silently doing it without a word in the
        -- console would be worse.
        local maxRadius = (Config and Config.PointSpawnMaxRadius) or 12.0
        if radius > maxRadius then
            print(("^3[spz-races] %d cars need a %.1f m start ring, over the %.1f m limit — "
                .. "falling back to a grid start. Raise Config.PointSpawnMaxRadius only if the "
                .. "start line really is that wide.^7"):format(count, radius, maxRadius))
        else
            for i = 1, count do
                if count == 1 then
                    grid[i] = { coords = origin, heading = heading }
                else
                    local a  = (i - 1) * (2 * math.pi / count)
                    local dx = math.cos(a) * radius
                    local dy = math.sin(a) * radius
                    grid[i] = { coords = origin + vec3(dx, dy, 0.0), heading = heading }
                end
            end
            return grid
        end
    end

    rowSpacing = rowSpacing or (Config and Config.GridRowSpacing) or 10.0
    colSpacing = colSpacing or (Config and Config.GridColSpacing) or 5.0

    local rad     = math.rad(heading)
    local forward = vec3(-math.sin(rad), math.cos(rad), 0.0)
    local right   = vec3(math.cos(rad), math.sin(rad), 0.0)

    -- Cars per row. Wider rows mean fewer rows, and rows are what decide a race
    -- before the lights: at 2 abreast a sixteen-car field is eight rows deep and
    -- the back row starts 56 m down. At 4 abreast it is four rows and 24 m. The
    -- start line has to actually be that wide, which is why it is configurable
    -- rather than simply maximised.
    local perRow = (Config and Config.GridCarsPerRow) or 2
    if perRow < 1 then perRow = 1 end

    for i = 1, count do
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow

        -- Centre each row on the start point rather than growing to one side,
        -- so the field straddles the road instead of hugging one kerb.
        local colOffset = (col - (perRow - 1) / 2) * colSpacing
        local rowOffset = -(row * rowSpacing)

        local pos = origin + (forward * rowOffset) + (right * colOffset)
        table.insert(grid, { coords = pos, heading = heading })
    end

    return grid
end
