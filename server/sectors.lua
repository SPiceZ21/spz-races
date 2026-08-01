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

-- Tracks split into 3 sectors (shared/sectors.lua). A "perfect lap" is purple
-- in all three within the same lap.
local SECTORS_PER_LAP = 3

-- Record a purple sector on a lap; when all three land in one lap, fire the
-- perfect-lap reward exactly once. `bag` is the per-player session table
-- (race pData or TT session), so state is naturally scoped and cleaned up.
local function MarkPurple(bag, lap, sector, source, trackName, class)
    bag._purple = bag._purple or {}
    local set = bag._purple[lap]
    if not set then set = { n = 0 }; bag._purple[lap] = set end
    if not set[sector] then
        set[sector] = true
        set.n = set.n + 1
    end
    if set.n >= SECTORS_PER_LAP and not set.done then
        set.done = true
        TriggerEvent("SPZ:perfectLap", source, { track = trackName, class = class, lap = lap })
    end
end

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

    if colour == "purple" then
        MarkPurple(pData, lap, sector, source, track.name, RaceSession.carClassId)
    end

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

-- ── Time-trial sectors ────────────────────────────────────────────────────────
-- TT runs outside RaceSession (own routing bucket, own session table in
-- timetrail.lua), so it gets its own entry points operating on that table.
-- Sector PBs are stored under car class -1: TT allows any car, so its times
-- must not pollute the class-scoped race sector bests.

local TT_CLASS = -1

function TT_InitSectors(source, s)
    s.best_sectors = {}   -- fastest this TT session, per sector
    s.pb_sectors   = {}
    s.sector_start = nil

    local trackName = s.track and s.track.name
    if not trackName then return end
    CreateThread(function()
        local pbs = LoadSectorPBs(source, trackName, TT_CLASS)
        for sector, ms in pairs(pbs) do
            if s.pb_sectors[sector] == nil then
                s.pb_sectors[sector] = ms
            end
        end
    end)
end

function TT_StartSectorClock(s, atTime)
    s.sector_start = atTime
end

function TT_RecordSectorHit(source, s, cpIndex, now)
    local track = s.track
    if not track or not s.best_sectors then return end

    local sector = SPZ.IsSectorEnd(track, cpIndex)
    if not sector then return end

    local startedAt = s.sector_start or s.lapStart
    if not startedAt then return end

    local ms = now - startedAt
    s.sector_start = now

    local ownBest = s.best_sectors[sector]
    local pb      = s.pb_sectors[sector]
    local isOwnBest = (ownBest == nil) or (ms < ownBest)
    local isPB      = (pb == nil) or (ms < pb)

    if isOwnBest then s.best_sectors[sector] = ms end

    -- Solo context: purple = beats the stored all-time PB, green = best of
    -- this TT session, yellow = slower than both.
    local colour = isPB and "purple" or (isOwnBest and "green" or "yellow")

    if colour == "purple" then
        MarkPurple(s, s.currentLap or 1, sector, source, track.name, TT_CLASS)
    end

    local ref   = ownBest or pb
    local delta = ref and (ms - ref) or nil

    if isPB then
        s.pb_sectors[sector] = ms
        CreateThread(function()
            SaveSectorPB(source, track.name, TT_CLASS, sector, ms)
        end)
    end

    TriggerClientEvent("SPZ:sectorComplete", source, {
        sector   = sector,
        time     = ms,
        colour   = colour,
        delta    = delta,
        personal = s.best_sectors[sector],
    })
end

exports("RecordSectorHit", RecordSectorHit)
exports("GetSessionBestSectors", function() return SessionBest end)
