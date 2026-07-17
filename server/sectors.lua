-- server/sectors.lua
-- Sector timing. Splits are derived (shared/sectors.lua); this file only times
-- them, colours them, and persists the personal bests.
--
-- Colour rules follow sim-racing convention:
--   purple = fastest in this race session, by anyone
--   green  = the player's own best (this session or stored PB), not overall
--   yellow = slower than the player's own best

-- Fastest sector times seen in the current race, across all racers.
local SessionBest = { nil, nil, nil }

-- ── Personal bests ───────────────────────────────────────────────────────────

-- Stored bests are loaded once per racer at race start so the hot path (a
-- checkpoint hit) never blocks on the database.
function LoadSectorPBs(source, track, carClass)
    local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(source) end)
    if not ok or not profile then return {} end

    local rows = MySQL.query.await(
        [[SELECT sector, best_ms FROM track_sectors
          WHERE player_id = ? AND track = ? AND car_class = ?]],
        { profile.id, track, carClass }
    )

    local pbs = {}
    for _, row in ipairs(rows or {}) do
        pbs[row.sector] = row.best_ms
    end
    return pbs
end

local function SaveSectorPB(source, track, carClass, sector, ms)
    local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(source) end)
    if not ok or not profile then return end

    MySQL.query.await([[
        INSERT INTO track_sectors (player_id, track, car_class, sector, best_ms)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE best_ms = LEAST(best_ms, VALUES(best_ms))
    ]], { profile.id, track, carClass, sector, ms })
end

-- ── Race lifecycle ───────────────────────────────────────────────────────────

function ResetSessionSectors()
    SessionBest = { nil, nil, nil }
end

-- Called once per racer when the race goes live. The stored PBs load on their
-- own thread: this runs inside the GO loop, and an await here would delay the
-- unfreeze for every racer behind it. Nothing reads pb_sectors until the first
-- sector closes, which is a lap-fraction away.
function InitPlayerSectors(source, pData, track, carClass)
    pData.sector_times   = {}   -- [lap] = { s1, s2, s3 }
    pData.best_sectors   = {}   -- fastest this session, per sector
    pData.pb_sectors     = {}
    pData.sector_start   = nil  -- set by StartSectorClock

    CreateThread(function()
        local pbs = LoadSectorPBs(source, track, carClass)
        -- Only fill blanks: a sector may already have closed while we loaded.
        for sector, ms in pairs(pbs) do
            if pData.pb_sectors[sector] == nil then
                pData.pb_sectors[sector] = ms
            end
        end
    end)
end

-- Sector 1 of a new lap starts the moment the previous lap closes.
function StartSectorClock(pData, atTime)
    pData.sector_start = atTime
end

-- ── Hot path ─────────────────────────────────────────────────────────────────

-- Called on every validated checkpoint hit, before current_cp advances.
function RecordSectorHit(source, pData, cpIndex, now)
    local track = RaceSession.track
    if not track then return end

    local sector = SPZ.IsSectorEnd(track, cpIndex)
    if not sector then return end

    local startedAt = pData.sector_start or pData.lap_start_time or RaceSession.startTime
    if not startedAt then return end

    local ms = now - startedAt
    pData.sector_start = now   -- next sector starts here

    local lap = pData.current_lap or 1
    pData.sector_times[lap] = pData.sector_times[lap] or {}
    pData.sector_times[lap][sector] = ms

    -- Personal best for this sector: session-so-far or the stored PB.
    local ownBest = pData.best_sectors[sector]
    local pb      = pData.pb_sectors[sector]
    local isOwnBest = (ownBest == nil) or (ms < ownBest)
    local isPB      = (pb == nil) or (ms < pb)

    if isOwnBest then pData.best_sectors[sector] = ms end

    local isSessionBest = (SessionBest[sector] == nil) or (ms < SessionBest[sector])
    if isSessionBest then SessionBest[sector] = ms end

    local colour = isSessionBest and "purple" or (isOwnBest and "green" or "yellow")

    -- Delta against the player's own reference, so it reads the same way the
    -- lap delta does: negative is faster.
    local ref   = ownBest or pb
    local delta = ref and (ms - ref) or nil

    if isPB then
        -- Fire and forget: the write must not stall the checkpoint handler.
        CreateThread(function()
            SaveSectorPB(source, track.name, RaceSession.carClassId, sector, ms)
        end)
    end

    TriggerClientEvent("SPZ:sectorComplete", source, {
        sector      = sector,
        time        = ms,
        colour      = colour,
        delta       = delta,
        sessionBest = SessionBest[sector],
        personal    = pData.best_sectors[sector],
    })
end

exports("RecordSectorHit", RecordSectorHit)
exports("GetSessionBestSectors", function() return SessionBest end)
