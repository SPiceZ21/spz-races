-- server/progression/xp.lua — progression: xp.
-- Moved from spz-progression/server/xp.lua when it was merged into spz-races.
local Config = Config.Progression

local Log = SPZ.Logger("spz-progression")

---Calculates XP required to reach a specific level (cumulative).
---@param level number
---@return number
local function XPRequired(level)
    if level <= 1 then return 0 end
    -- Quadratic curve: math.floor(50 * (level - 1) ^ 2 + 50 * (level - 1))
    return math.floor(50 * (level - 1) ^ 2 + 50 * (level - 1))
end

---Calculates level from total XP.
---@param xp number
---@return number
local function LevelFromXP(xp)
    -- Inverse of XPRequired: floor((-50 + sqrt(50^2 + 4 * 50 * xp)) / 100) + 1
    if xp <= 0 then return 1 end
    local level = math.floor((-50 + math.sqrt(50^2 + 4 * 50 * xp)) / 100) + 1
    return math.max(1, math.min(100, level))
end

---Calculates XP gain based on race performance.
---@param data table Race results data (position, laps, class, bonuses)
---@return number xpGain
local function CalculateXP(data)
    local xp = 0
    
    -- 1. Base position XP
    if data.dnf then
        xp = Config.XPRewards.dnf
    else
        local pos = data.position or 8
        xp = Config.XPRewards.positions[pos] or Config.XPRewards.positions[#Config.XPRewards.positions]
    end

    -- 2. Class multiplier
    local classMulti = Config.ClassMultipliers[data.class] or 1.0
    xp = xp * classMulti

    -- 3. Lap bonuses
    local lapBonus = (data.laps or 0) * Config.XPRewards.perLap
    xp = xp + math.min(lapBonus, Config.XPRewards.maxLapBonus)

    -- 4. Achievement bonuses
    if data.cleanRace then xp = xp + Config.XPRewards.cleanRace end
    if data.personalBest then xp = xp + Config.XPRewards.personalBest end
    if data.trackRecord then xp = xp + Config.XPRewards.trackRecord end

    -- 5. Comeback bonus (gained >= N positions from the grid)
    if data.comeback then xp = xp + Config.Bonuses.comeback.xpBonus end

    -- 6. Apply Pace Multiplier
    local pace = Config.PaceMultipliers[Config.Pace] or Config.PaceMultipliers.MEDIUM
    xp = xp * pace.xp

    return math.floor(xp)
end

exports("XPRequired", XPRequired)
exports("LevelFromXP", LevelFromXP)
exports("CalculateXP", CalculateXP)
