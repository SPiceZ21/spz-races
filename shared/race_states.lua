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

function SPZ.Math.GridPositions(origin, heading, count, rowSpacing, colSpacing)
    local grid = {}

    -- Point mode: everyone spawns at the start point instead of a staggered
    -- grid. Vehicles at the EXACT same coords explode on spawn, so slots fan
    -- out on a tiny ring around the point — visually "all at the point",
    -- physically non-overlapping.
    if Config and Config.SpawnMode == "point" then
        -- radius 0 = literally everyone on the same spot. Safe because
        -- the race ghost group is assigned before any vehicle spawns,
        -- so overlapping cars never exchange collision impulses.
        local radius = Config.PointSpawnRadius or 0.0
        for i = 1, count do
            if i == 1 or radius <= 0.0 then
                grid[i] = { coords = origin, heading = heading }
            else
                local a  = (i - 1) * (2 * math.pi / math.max(count - 1, 1))
                local dx = math.cos(a) * radius
                local dy = math.sin(a) * radius
                grid[i] = { coords = origin + vec3(dx, dy, 0.0), heading = heading }
            end
        end
        return grid
    end

    rowSpacing = rowSpacing or (Config and Config.GridRowSpacing) or 10.0
    colSpacing = colSpacing or (Config and Config.GridColSpacing) or 5.0

    local rad     = math.rad(heading)
    local forward = vec3(-math.sin(rad), math.cos(rad), 0.0)
    local right   = vec3(math.cos(rad), math.sin(rad), 0.0)

    for i = 1, count do
        local row = math.floor((i - 1) / 2)
        local col = (i - 1) % 2
        local colOffset = (col == 0) and -colSpacing / 2 or colSpacing / 2
        local rowOffset = -(row * rowSpacing)
        local pos = origin + (forward * rowOffset) + (right * colOffset)
        table.insert(grid, { coords = pos, heading = heading })
    end

    return grid
end
