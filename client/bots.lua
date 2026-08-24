-- client/bots.lua
-- Renders ghost-bots as SOLID, non-collidable replay cars. The server picks the
-- lines and simulates scoring; each client replays them locally in sync with the
-- shared GO clock, so every screen sees the bots in the same place without any
-- per-frame network traffic.
--
-- Same kinematic replay as the time-trial ghost (spz-raceline/client/ghost.lua),
-- but OPAQUE (looks like a real opponent) and multi-lap (loops the line).

local FALLBACK  = 'sultan'
local ZLIFT     = 0.45
local HEAD_LERP = 10.0
local LABEL_RANGE = (Config.Bots and Config.Bots.labelRange) or 80.0

local Bots      = {}    -- [id] = { veh, blip, pts, times, period, laps, name, cursor, lastLap, heading }
local GoTime    = nil   -- GetGameTimer() at GO; replay elapsed is measured from here

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function lerpAngle(a, b, f)
    local diff = (b - a + 180.0) % 360.0 - 180.0
    return (a + diff * math.min(f, 1.0)) % 360.0
end

-- Flat {x,y,z,state,t,...} → pts[]{x,y,z,s} + times[] (ms into lap).
local function unpackLine(flat)
    local pts, times = {}, {}
    local n = #flat
    local j = 0
    for i = 1, n, 5 do
        j = j + 1
        pts[j]   = { x = flat[i], y = flat[i + 1], z = flat[i + 2], s = flat[i + 3] }
        times[j] = flat[i + 4] or 0
    end
    return pts, times
end

local function drawText3D(x, y, z, str)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.32, 0.32)
    SetTextFont(4)
    SetTextColour(235, 235, 235, 220)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText("STRING")
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

-- ── Spawn / teardown ─────────────────────────────────────────────────────────

local function spawnCar(model, at, heading)
    if not model or model == 0 or not IsModelInCdimage(model) then model = FALLBACK end
    RequestModel(model)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(25) end
    if not HasModelLoaded(model) then return 0 end

    local veh = CreateVehicle(model, at.x, at.y, at.z + ZLIFT, heading, false, false)
    SetModelAsNoLongerNeeded(model)
    if veh == 0 then return 0 end

    -- Solid: no alpha override. Non-collidable + hand-driven every frame.
    SetEntityCollision(veh, false, false)
    SetEntityInvincible(veh, true)
    FreezeEntityPosition(veh, true)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleLights(veh, 2)
    SetVehicleDoorsLocked(veh, 4)
    return veh
end

local function addBlip(veh, name)
    local blip = AddBlipForEntity(veh)
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 40)          -- grey: a bot, distinct from human racers
    SetBlipScale(blip, 0.75)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName((name or "Ghost") .. " [BOT]")
    EndTextCommandSetBlipName(blip)
    return blip
end

local function clearBots()
    for _, b in pairs(Bots) do
        if b.blip and DoesBlipExist(b.blip) then RemoveBlip(b.blip) end
        if b.veh and DoesEntityExist(b.veh) then DeleteEntity(b.veh) end
    end
    Bots = {}
end

-- ── Events ───────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:go", function()
    GoTime = GetGameTimer()
end)

RegisterNetEvent("SPZ:bots:spawn", function(list)
    if type(list) ~= "table" then return end
    clearBots()
    -- If GO already fired (bots data can arrive just after), anchor to it;
    -- otherwise the SPZ:go handler sets GoTime and replay begins then.
    GoTime = GoTime or GetGameTimer()

    for _, b in ipairs(list) do
        if type(b.points) == "table" and #b.points >= 10 then
            local pts, times = unpackLine(b.points)
            if #pts >= 2 then
                local p1, p2 = pts[1], pts[2]
                local heading = math.deg(math.atan(-(p2.x - p1.x), p2.y - p1.y)) % 360
                local veh = spawnCar(b.model, p1, heading)
                if veh ~= 0 then
                    Bots[b.id] = {
                        veh     = veh,
                        blip    = addBlip(veh, b.name),
                        pts     = pts,
                        times   = times,
                        period  = (times[#times] and times[#times] > 0) and times[#times] or (b.lapMs or 90000),
                        laps    = b.laps or 1,
                        name    = b.name or "Ghost",
                        cursor  = 1,
                        lastLap = -1,
                        heading = heading,
                    }
                end
            end
        end
    end
end)

RegisterNetEvent("SPZ:bots:clear", function() clearBots() end)
RegisterNetEvent("SPZ:raceEnd", function() clearBots() end)
AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then clearBots() end
end)

-- ── Replay loop ──────────────────────────────────────────────────────────────
CreateThread(function()
    while true do
        if GoTime and next(Bots) then
            local now    = GetGameTimer()
            local myPos  = GetEntityCoords(PlayerPedId())
            local total  = now - GoTime
            local dt     = GetFrameTime()

            for _, b in pairs(Bots) do
                if b.veh and DoesEntityExist(b.veh) then
                    local n = #b.pts

                    -- Which lap, and time into it. Bots hold their finish pose
                    -- once they've run all laps (they wait at the line).
                    local lap = math.floor(total / b.period) + 1
                    local lapElapsed
                    if lap > b.laps then
                        lapElapsed = b.times[n]         -- park at the final point
                        lap = b.laps
                    else
                        lapElapsed = total % b.period
                    end

                    -- Reset the monotonic cursor when a new lap wraps around.
                    if lap ~= b.lastLap then
                        b.cursor  = 1
                        b.lastLap = lap
                    end
                    while b.cursor < n - 1 and b.times[b.cursor + 1] <= lapElapsed do
                        b.cursor = b.cursor + 1
                    end

                    local a, c = b.pts[b.cursor], b.pts[math.min(b.cursor + 1, n)]
                    local ta   = b.times[b.cursor]
                    local tc   = b.times[math.min(b.cursor + 1, n)]
                    local span = tc - ta
                    local f    = span > 0 and (lapElapsed - ta) / span or 0.0
                    if f < 0 then f = 0 elseif f > 1 then f = 1 end

                    local x = a.x + (c.x - a.x) * f
                    local y = a.y + (c.y - a.y) * f
                    local z = a.z + (c.z - a.z) * f + ZLIFT

                    local target = math.deg(math.atan(-(c.x - a.x), c.y - a.y)) % 360
                    b.heading = lerpAngle(b.heading, target, HEAD_LERP * dt)

                    SetEntityCoordsNoOffset(b.veh, x, y, z, false, false, false)
                    SetEntityHeading(b.veh, b.heading)
                    SetVehicleBrakeLights(b.veh, c.s == 2)
                    DisableCamCollisionForObject(b.veh)

                    -- Floating "name [BOT]" tag when close.
                    if #(myPos - vector3(x, y, z)) < LABEL_RANGE then
                        drawText3D(x, y, z + 1.3, b.name .. "  [BOT]")
                    end
                end
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)
