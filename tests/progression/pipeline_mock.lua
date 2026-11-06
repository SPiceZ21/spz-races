-- tests/progression/pipeline_mock.lua
-- Runs the REAL server files (main.lua, xp.lua, rank_admin.lua) against fake
-- FiveM / spz-identity / oxmysql to catch runtime errors in the pipeline.
--     python tests/progression/run_lupa.py pipeline

local base = (TEST_BASE or ".") .. "/"
SPZ = {}

-- ── FiveM fakes ────────────────────────────────────────────────────────────
local handlers, clientEvents, serverEvents, sql = {}, {}, {}, {}
function IsDuplicityVersion() return true end
function AddEventHandler(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
function TriggerEvent(name, ...)
    serverEvents[#serverEvents + 1] = { name = name, args = { ... } }
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end
function TriggerClientEvent(name, target, data) clientEvents[#clientEvents + 1] = { name = name, target = target, data = data } end
function CreateThread(fn) fn() end
function Wait() end
function SetTimeout(_, fn) fn() end
function RegisterCommand() end
function GetPlayers() return {} end
function GetPlayerName() return "x" end
json = { encode = function() return "{}" end }

-- ── oxmysql fake: remembers awards so idempotency can be tested ───────────
local awarded = {}
MySQL = {
    query = { await = function(q, p)
        sql[#sql + 1] = q
        if q:find("SELECT player_id FROM rank_awards") then
            local out = {}
            for pid in pairs(awarded[p[1]] or {}) do out[#out + 1] = { player_id = pid } end
            return out
        end
        if q:find("INSERT IGNORE INTO rank_awards") then
            -- params come in groups of 10, race_id first, player_id second
            for i = 1, #p, 10 do
                awarded[p[i]] = awarded[p[i]] or {}
                awarded[p[i]][p[i + 1]] = true
            end
        end
        return {}
    end },
    update = { await = function(q, p)
        sql[#sql + 1] = q
        if q:find("UPDATE players SET") and OFFLINE_ROW and p and p[#p] == OFFLINE_ROW.id then
            OFFLINE_ROW.lastUpdate = { q = q, params = p }
        end
        return 1
    end },
    single = { await = function(q, p)
        if q:find("FROM players WHERE identifier") and OFFLINE_ROW and p[1] == "license:quit" then
            local copy = {}
            for k, v in pairs(OFFLINE_ROW) do if k ~= "lastUpdate" then copy[k] = v end end
            return copy
        end
        return nil
    end },
    scalar = { await = function() return 0 end },
}

-- ── spz-identity fake ─────────────────────────────────────────────────────
local profiles = {}
local unlocks = {}
local identity = {
    GetProfile = function(_, src) return profiles[src] end,
    UpdateProfile = function(_, src, changes)
        for k, v in pairs(changes) do profiles[src][k] = v end
        return true
    end,
    UnlockLicense = function(_, src, tier, method, rank)
        unlocks[#unlocks + 1] = { src = src, tier = tier, rank = rank }
        profiles[src].license_tier = tier
        profiles[src].rank = rank
        TriggerEvent("SPZ:licenseUnlocked", src, tier)
        return true
    end,
    GetRankName = function() return "Title" end,
}
local own = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) own[name] = fn end,
    __index = function(_, res)
        if res == "spz-identity" then return identity end
        if res == "spz-races" then
            return setmetatable({}, { __index = function(_, k)
                return function(_, ...) return own[k](...) end
            end })
        end
        return setmetatable({}, { __index = function() return function() return false end end })
    end,
})

-- ── load the resource in manifest order ───────────────────────────────────
dofile(base .. "../spz-core/shared/events.lua")
dofile(base .. "shared/progression_init.lua")
SPZ.Logger = function() local f = function() end; return { info = f, warn = f, error = function(m) print("LOG ERROR " .. tostring(m)) end, debug = f } end
Config = {}
dofile(base .. "config_progression.lua")
for _, f in ipairs({ "server/progression/domain/rank.lua", "server/progression/domain/rp.lua", "server/progression/domain/irating.lua", "server/progression/domain/sr.lua",
                     "server/progression/xp.lua", "server/progression/main.lua", "server/progression/bonus.lua", "server/progression/rank_admin.lua" }) do
    dofile(base .. f)
end

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL  " .. name .. " " .. tostring(detail or "")) end
end

local function mkProfile(id, rp)
    return { id = id, rank_points = rp or 0, rank = "C-5", license_tier = 0, sr = 2.0, i_rating = 1500,
             xp = 0, level = 1, alltime_points = 0, top3_count = 0, rank_streak = 0 }
end

local function race(id, n, dnfs, opts)
    opts = opts or {}
    local r = { raceId = id, trackId = opts.track or "t1", carClass = "B", laps = 3,
                duration = opts.duration or 300, finishers = {}, dnf = {} }
    for i = 1, n do
        local src = i
        if i <= n - dnfs then
            r.finishers[#r.finishers + 1] = { source = src, position = i, collisions = {}, personal_best = (i == 1) }
        else
            r.dnf[#r.dnf + 1] = { source = src, dnf = true, dnf_reason = opts.reason or "idle", collisions = { {}, {} } }
        end
    end
    return r
end

-- 1) normal 8-player race, 1 DNF
for i = 1, 8 do profiles[i] = mkProfile(100 + i) end
TriggerEvent("SPZ:raceEnd", race("R1", 8, 1))
check("P1 gained", profiles[1].rank_points > 0, profiles[1].rank_points)
check("P1 got podium/clean", profiles[1].rank_points == 47, profiles[1].rank_points)  -- 41 * 1.15 = 47.15
check("DNF lost nothing in C (floor)", profiles[8].rank_points == 0, profiles[8].rank_points)
check("P1 streak 1", profiles[1].rank_streak == 1)
check("P7 streak 0", profiles[7].rank_streak == 0)
check("top3 counted", profiles[3].top3_count == 1 and profiles[4].top3_count == 0)
check("rank string updated", profiles[1].rank == "C-5" or profiles[1].rank == "C-4", profiles[1].rank)
check("iRating moved", profiles[1].i_rating > 1500 and profiles[8].i_rating < 1500)
check("SR moved", profiles[1].sr > 2.0)
check("XP given", profiles[1].xp > 0)
local applied
for _, e in ipairs(serverEvents) do if e.name == "SPZ:progressionApplied" then applied = e.args[1] end end
check("progressionApplied fired", applied and #applied.players == 8)
local progUpdates = 0
for _, e in ipairs(clientEvents) do if e.name == "SPZ:progressionUpdate" then progUpdates = progUpdates + 1 end end
check("8 client updates", progUpdates == 8, progUpdates)

-- 2) same race id again: no double scoring
local before = profiles[1].rank_points
TriggerEvent("SPZ:raceEnd", race("R1", 8, 1))
check("idempotent", profiles[1].rank_points == before, profiles[1].rank_points)

-- 3) solo race: XP only
profiles[20] = mkProfile(200)
TriggerEvent("SPZ:raceEnd", { raceId = "R2", trackId = "t", carClass = "C", laps = 2, duration = 200,
    finishers = { { source = 20, position = 1, collisions = {} } }, dnf = {} })
check("solo no RP", profiles[20].rank_points == 0)
check("solo no top3", profiles[20].top3_count == 0)
check("solo no iRating", profiles[20].i_rating == 1500)
check("solo XP", profiles[20].xp > 0)

-- 4) short race is void
profiles[21] = mkProfile(201); profiles[22] = mkProfile(202)
TriggerEvent("SPZ:raceEnd", { raceId = "R3", trackId = "t", duration = 20,
    finishers = { { source = 21, position = 1 }, { source = 22, position = 2 } }, dnf = {} })
check("short race void", profiles[21].xp == 0)

-- 5) class promotion: player at 240 RP wins -> B, identity stores it
for i = 1, 8 do profiles[i] = mkProfile(300 + i, 240) end
local nUnlock = #unlocks
TriggerEvent("SPZ:raceEnd", race("R4", 8, 0))
check("promoted to B", profiles[1].rank_points >= 250 and profiles[1].license_tier == 1, profiles[1].rank_points)
local promoted = 0
for i = 1, 8 do if profiles[i].license_tier == 1 then promoted = promoted + 1 end end
check("UnlockLicense once per promoted player", #unlocks - nUnlock == promoted and promoted >= 1, promoted)
check("promotion rank B-5", profiles[1].rank == "B-5", profiles[1].rank)
check("loser locked at C floor", profiles[8].rank_points >= 0)

-- 6) 200-player race (no limit)
for i = 1, 200 do profiles[i] = mkProfile(1000 + i) end
TriggerEvent("SPZ:raceEnd", race("R5", 200, 10))
check("200: winner +51ish", profiles[1].rank_points == 59, profiles[1].rank_points) -- (41+10)*1.15 = 58.65
check("200: streak zone 20", profiles[20].rank_streak == 1 and profiles[21].rank_streak == 0)

-- 7) admin-removed DNF is excluded from the field
for i = 1, 3 do profiles[i] = mkProfile(2000 + i) end
TriggerEvent("SPZ:raceEnd", race("R6", 3, 1, { reason = "admin" }))
check("admin DNF untouched", profiles[3].xp == 0 and profiles[3].rank_points == 0)

-- 8) flat RP for a perfect lap
profiles[50] = mkProfile(5000, 100)
TriggerEvent("SPZ:perfectLap", 50, {})
check("perfect lap +10 RP", profiles[50].rank_points == 110, profiles[50].rank_points)

-- 9) racer disconnected mid-race: no cached profile, still scored as a DNF
OFFLINE_ROW = { id = 9001, rank_points = 500, rank = "B-4", license_tier = 1, sr = 2.0, i_rating = 1500,
                xp = 0, level = 1, alltime_points = 0, top3_count = 0, rank_streak = 2 }
for i = 1, 6 do profiles[i] = mkProfile(6000 + i, 500) end
local r9 = race("R9", 7, 0)
r9.finishers[7] = nil
r9.dnf = { { source = 7777, identifier = "license:quit", dnf = true, dnf_reason = "disconnect", collisions = {} } }
TriggerEvent("SPZ:raceEnd", r9)
local up = OFFLINE_ROW.lastUpdate
check("offline DNF written to DB", up ~= nil)
local rpSet
if up then
    local cols = {}
    for c in up.q:gmatch("`([%w_]+)` = %?") do cols[#cols + 1] = c end
    for i, c in ipairs(cols) do if c == "rank_points" then rpSet = up.params[i] end end
end
check("offline DNF lost RP (B, half loss)", rpSet and rpSet < 500, tostring(rpSet))
check("field size counted the quitter", awarded["R9"] and awarded["R9"][9001] == true)

print(("pipeline: %d passed, %d failed"):format(pass, fail))
if fail > 0 then error("pipeline tests failed") end
