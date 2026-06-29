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

SPZ.Math = SPZ.Math or {}

function SPZ.Math.GridPositions(origin, heading, count, rowSpacing, colSpacing)
    local grid = {}
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
