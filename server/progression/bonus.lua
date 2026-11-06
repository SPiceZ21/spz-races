-- server/progression/bonus.lua — progression: bonus.
-- Moved from spz-progression/server/bonus.lua when it was merged into spz-races.
local Config = Config.Progression

-- server/bonus.lua
-- Flat XP + credit grants for out-of-race achievements (perfect lap, etc.).
-- Separate from the race-results pipeline in main.lua: those grants are
-- position-derived, these are one-off rewards fired by other modules.

local Log = SPZ.Logger("spz-progression")

-- Grant xp/credits directly to a player's profile and tell the client.
-- opts = { xp, credits, reason, flourish }
local function GrantBonus(source, opts)
    source = tonumber(source)
    if not source or not opts then return end

    local xp      = math.floor(opts.xp or 0)
    local credits = math.floor(opts.credits or 0)
    if xp == 0 and credits == 0 then return end

    local profile = exports["spz-identity"]:GetProfile(source)
    if not profile then return end

    local updates = {}
    local newXP
    if xp ~= 0 then
        newXP = (profile.xp or 0) + xp
        updates.xp = newXP
    end
    if credits ~= 0 then
        updates.credits = (profile.credits or 0) + credits
    end

    -- Recompute level in the same write if XP crossed a threshold.
    local oldLevel = profile.level or 1
    local newLevel = oldLevel
    if newXP then
        newLevel = exports["spz-races"]:LevelFromXP(newXP)
        if newLevel ~= oldLevel then updates.level = newLevel end
    end

    exports["spz-identity"]:UpdateProfile(source, updates)

    if newLevel > oldLevel then
        TriggerEvent("SPZ:levelUp", source, oldLevel, newLevel)
    end

    TriggerClientEvent("SPZ:bonusGranted", source, {
        xp = xp, credits = credits,
        reason = opts.reason or "Bonus",
        flourish = opts.flourish,
    })

    Log.info(("GrantBonus src=%s xp=%d credits=%d (%s)")
        :format(source, xp, credits, opts.reason or "bonus"))
end

exports("GrantBonus", GrantBonus)

-- ── Perfect lap ────────────────────────────────────────────────────────────
-- Fired by spz-races sector timing when a racer clocks purple in every sector
-- of a single lap. info = { track, class, lap }.
AddEventHandler("SPZ:perfectLap", function(source, info)
    local r = Config.PerfectLap or {}
    GrantBonus(source, {
        xp = r.xp or 150, credits = r.credits or 500,
        reason = "PERFECT LAP", flourish = "perfectlap",
    })
    TriggerClientEvent("SPZ:perfectLapFlourish", source, info or {})
end)
