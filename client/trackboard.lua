-- client/trackboard.lua
-- In-world record boards. A floating scoreboard rendered at a fixed world
-- location showing the fastest-lap holders for a track — walk up and read the
-- times in the world, no menu. Records come from the server (racelines store),
-- cached and refreshed on approach.

local Boards = Config.RecordBoards or {}
local RANGE  = (Config.BoardRange or 12.0)
local REFRESH = (Config.BoardRefresh or 30000)

local cache = {}   -- [i] = { rows = {}, at = ms }

local function fmt(ms)
    if not ms or ms <= 0 then return "--:--.---" end
    local m = math.floor(ms / 60000)
    local s = math.floor((ms % 60000) / 1000)
    local t = ms % 1000
    return string.format("%d:%02d.%03d", m, s, t)
end

-- Screen-space text at the current draw origin.
local function text(x, y, scale, r, g, b, a, str, centre)
    SetTextScale(scale, scale)
    SetTextFont(4)
    SetTextColour(r, g, b, a)
    SetTextOutline()
    if centre then SetTextCentre(true) end
    BeginTextCommandDisplayText("STRING")
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y)
end

local function fetch(i, board)
    local c = cache[i]
    if c and (GetGameTimer() - c.at) < REFRESH then return end
    cache[i] = { rows = c and c.rows or {}, at = GetGameTimer() }   -- throttle
    CreateThread(function()
        local rows = lib.callback.await("spz-races:getBoardRecords", false,
            { track = board.track, limit = 5 })
        cache[i] = { rows = rows or {}, at = GetGameTimer() }
    end)
end

-- Draw one board as a camera-facing panel at its world coords.
local function draw(board, rows)
    local c = board.coords
    SetDrawOrigin(c.x, c.y, c.z, 0)

    -- Panel background (two stacked rects: header bar + body)
    DrawRect(0.0,  0.0,  0.26, 0.30, 8, 9, 12, 200)
    DrawRect(0.0, -0.12, 0.26, 0.055, 255, 98, 0, 220)   -- header strip

    -- Header
    text(0.0, -0.135, 0.42, 10, 10, 10, 255, "TRACK RECORDS", true)
    text(0.0, -0.095, 0.30, 255, 255, 255, 255, board.track or "", true)

    -- Rows
    if #rows == 0 then
        text(0.0, 0.0, 0.34, 200, 200, 200, 200, "No times set yet", true)
    else
        local y = -0.055
        for i = 1, math.min(#rows, 5) do
            local row = rows[i]
            local gold = (i == 1)
            local cr, cg, cb = gold and 255 or 220, gold and 215 or 220, gold and 0 or 220
            text(-0.115, y, 0.32, cr, cg, cb, 255, ("P%d"):format(row.rank or i))
            text(-0.075, y, 0.32, 255, 255, 255, 240, tostring(row.name or "?"))
            text( 0.055, y, 0.32, cr, cg, cb, 255, fmt(row.ms))
            y = y + 0.042
        end
    end

    ClearDrawOrigin()
end

CreateThread(function()
    if #Boards == 0 then return end
    while true do
        local sleep = 1000
        local p = GetEntityCoords(PlayerPedId())

        for i, board in ipairs(Boards) do
            local d = #(p - board.coords)
            if d < RANGE then
                sleep = 0
                fetch(i, board)
                draw(board, (cache[i] and cache[i].rows) or {})
            end
        end

        Wait(sleep)
    end
end)
