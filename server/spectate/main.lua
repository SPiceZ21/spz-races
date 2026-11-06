-- server/spectate/main.lua — spectate (main).
-- Moved from spz-spectate/server/main.lua when it was merged into spz-races.

-- server/main.lua
-- Spectator system, usable by every player. To see a player who is inside an
-- isolated race routing bucket we transiently move the spectator into that
-- bucket (native SetPlayerRoutingBucket, snapshot + restore — we deliberately
-- do NOT touch spz-core's bucket registry, since this is a temporary view, not
-- a real session move). Player data for the overlay comes from statebags, which
-- replicate globally, so the card fills in even before the bucket move lands.

local Spectating = {}   -- [spectatorSrc] = { target = tgt, prevBucket = n }

-- Read by spz-analytics (activity mode / server snapshots).
exports("IsSpectating", function(src) return Spectating[tonumber(src)] ~= nil end)

local function nameOf(src)
    local st = Player(src).state
    local n = st and st['spz:name']
    if not n or n == "" or n == "**INVALID**" then n = GetPlayerName(src) end
    if not n or n == "" or n == "**INVALID**" then n = "Driver " .. src end
    return n
end

-- List of players you can spectate. Only ACTIVE RACERS are spectatable — you
-- can't watch someone driving around freeroam.
lib.callback.register("spz-spectate:getTargets", function(source)
    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        local s = tonumber(sid)
        if s ~= source then
            local st = Player(s).state
            if st and st['inRace'] == true then
                out[#out + 1] = {
                    id     = s,
                    name   = nameOf(s),
                    racing = true,
                    nation = st['spz:nation'] or nil,
                    number = st['spz:raceNumber'] or nil,
                }
            end
        end
    end
    return out
end)

-- Move the spectator into the target's bucket. Returns ok so the client knows
-- when to attach the spectator camera.
lib.callback.register("spz-spectate:enter", function(source, targetSrc)
    targetSrc = tonumber(targetSrc)
    if not targetSrc or targetSrc == source then return false end
    if GetPlayerName(targetSrc) == nil then return false end   -- offline

    -- Block spectating while you're an active competitor yourself.
    local myState = Player(source).state
    if myState and myState['inRace'] == true then return false end

    -- Only active racers are spectatable — reject freeroam targets.
    local tState = Player(targetSrc).state
    if not (tState and tState['inRace'] == true) then return false end

    local rec = Spectating[source]
    local prevBucket = rec and rec.prevBucket or GetPlayerRoutingBucket(source)
    local targetBucket = GetPlayerRoutingBucket(targetSrc)

    -- Target position so the client can teleport its (invisible) ped next to the
    -- target — otherwise the target never streams into scope and the spectator
    -- camera falls back to yourself (UI shows, but you don't see them).
    local tped = GetPlayerPed(targetSrc)
    local tc = (tped and tped ~= 0) and GetEntityCoords(tped) or nil

    SetPlayerRoutingBucket(source, targetBucket)
    Spectating[source] = { target = targetSrc, prevBucket = prevBucket }
    return { ok = true, x = tc and tc.x, y = tc and tc.y, z = tc and tc.z }
end)

local function restore(source)
    local rec = Spectating[source]
    if not rec then return end

    local back = rec.prevBucket or 0
    SetPlayerRoutingBucket(source, back)
    Spectating[source] = nil

    -- Hand the player back to spz-core's registry. The transient move above is
    -- raw on purpose, but leaving it raw desynced session.bucket from the engine
    -- and later bucket calls no-opped, stranding spectators in the race world.
    if GetResourceState("spz-core") == "started" then
        pcall(function() exports["spz-core"]:AssignPlayerToBucket(source, back) end)
    end
end

RegisterNetEvent("spz-spectate:leave", function()
    restore(source)
end)

-- If the player being watched leaves, kick their spectators back out cleanly.
AddEventHandler("playerDropped", function()
    local dropped = source
    restore(dropped)                       -- they were spectating
    for spec, rec in pairs(Spectating) do  -- someone was spectating them
        if rec.target == dropped then
            TriggerClientEvent("spz-spectate:targetGone", spec)
        end
    end
end)

-- Safety: if a race bucket is torn down under a spectator, send them home.
AddEventHandler("SPZ:raceEnd", function()
    -- Spectators of racers may be sitting in a bucket about to be deleted; the
    -- client re-validates its target each tick and calls leave if it vanished.
end)
