-- client/duel.lua
-- Ghost-duel client: replays the OPPONENT's stored line as a translucent ghost
-- car (the pace target), synced to the challenger's timed lap, plus a small
-- on-screen banner with the target time and stake. The server owns the result;
-- this is purely the visual opponent to chase.

local duel      = nil     -- { targetMs, oppName, stake }
local route     = nil     -- { pts = {{x,y,z,s,t}}, model }
local ghostVeh  = 0
local ghostBlip = 0
local running   = false
local runStart  = 0
local cursor    = 1
local curHeading = 0.0

local Z_LIFT = 0.45

local function fmt(ms)
    if not ms or ms <= 0 then return "--:--.---" end
    local m = math.floor(ms / 60000)
    local s = math.floor((ms % 60000) / 1000)
    local t = ms % 1000
    return ("%d:%02d.%03d"):format(m, s, t)
end

-- Flat {x,y,z,state,t,...} → array of point tables with cumulative times.
local function buildRoute(model, flat)
    if type(flat) ~= "table" or #flat < 10 then return nil end
    local pts = {}
    for i = 1, #flat, 5 do
        pts[#pts + 1] = { x = flat[i], y = flat[i + 1], z = flat[i + 2], s = flat[i + 3], t = flat[i + 4] }
    end
    if #pts < 3 then return nil end
    return { pts = pts, model = (model and model ~= 0) and model or 'sultan' }
end

local function removeGhost()
    running = false
    if ghostBlip ~= 0 and DoesBlipExist(ghostBlip) then RemoveBlip(ghostBlip) end
    ghostBlip = 0
    if ghostVeh ~= 0 and DoesEntityExist(ghostVeh) then DeleteEntity(ghostVeh) end
    ghostVeh = 0
end

local function spawnGhost(model, at, heading)
    if not IsModelInCdimage(model) then model = 'sultan' end
    RequestModel(model)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(25) end
    if not HasModelLoaded(model) then return false end

    ghostVeh = CreateVehicle(model, at.x, at.y, at.z + Z_LIFT, heading, false, false)
    SetModelAsNoLongerNeeded(model)
    if ghostVeh == 0 then return false end

    SetEntityAlpha(ghostVeh, 150, false)     -- intentional ghost translucency
    SetEntityCollision(ghostVeh, false, false)
    SetEntityInvincible(ghostVeh, true)
    FreezeEntityPosition(ghostVeh, true)     -- driven by hand each frame
    SetVehicleEngineOn(ghostVeh, true, true, false)

    ghostBlip = AddBlipForEntity(ghostVeh)
    SetBlipSprite(ghostBlip, 1)
    SetBlipColour(ghostBlip, 1)              -- red: the rival to beat
    SetBlipScale(ghostBlip, 0.8)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(duel and duel.oppName or "Rival")
    EndTextCommandSetBlipName(ghostBlip)
    return true
end

local function lerpAngle(a, b, f)
    local d = (b - a + 180.0) % 360.0 - 180.0
    return (a + d * math.min(f, 1.0)) % 360.0
end

local function startRun()
    if not route then return end
    local p1, p2 = route.pts[1], route.pts[2]
    local heading = math.deg(math.atan(-(p2.x - p1.x), p2.y - p1.y)) % 360

    if ghostVeh == 0 or not DoesEntityExist(ghostVeh) then
        if not spawnGhost(route.model, p1, heading) then return end
    else
        SetEntityCoordsNoOffset(ghostVeh, p1.x, p1.y, p1.z + Z_LIFT, false, false, false)
        SetEntityHeading(ghostVeh, heading)
        SetEntityVisible(ghostVeh, true, false)
    end

    curHeading = heading
    cursor     = 1
    runStart   = GetGameTimer()
    running    = true
end

-- Replay loop
CreateThread(function()
    while true do
        if running and route and ghostVeh ~= 0 and DoesEntityExist(ghostVeh) then
            local pts = route.pts
            local n   = #pts
            local elapsed = GetGameTimer() - runStart

            while cursor < n - 1 and pts[cursor + 1].t <= elapsed do
                cursor = cursor + 1
            end

            if elapsed >= pts[n].t then
                SetEntityVisible(ghostVeh, false, false)
                running = false
            else
                local a, b = pts[cursor], pts[cursor + 1]
                local span = b.t - a.t
                local f    = span > 0 and (elapsed - a.t) / span or 0.0
                local x = a.x + (b.x - a.x) * f
                local y = a.y + (b.y - a.y) * f
                local z = a.z + (b.z - a.z) * f + Z_LIFT
                local target = math.deg(math.atan(-(b.x - a.x), b.y - a.y)) % 360
                curHeading = lerpAngle(curHeading, target, 10.0 * GetFrameTime())
                SetEntityCoordsNoOffset(ghostVeh, x, y, z, false, false, false)
                SetEntityHeading(ghostVeh, curHeading)
                DisableCamCollisionForObject(ghostVeh)
            end
            Wait(0)
        else
            Wait(200)
        end
    end
end)

-- ── Banner ────────────────────────────────────────────────────────────────────
CreateThread(function()
    while true do
        if duel then
            SetTextFont(4)
            SetTextScale(0.0, 0.42)
            SetTextColour(255, 255, 255, 220)
            SetTextCentre(true)
            SetTextOutline()
            BeginTextCommandDisplayText("STRING")
            AddTextComponentSubstringPlayerName(
                ("DUEL vs %s   TARGET %s   STAKE %d"):format(duel.oppName or "?", fmt(duel.targetMs), duel.stake or 0))
            EndTextCommandDisplayText(0.5, 0.06)
            Wait(0)
        else
            Wait(400)
        end
    end
end)

-- ── Events (piggyback the TT lifecycle) ──────────────────────────────────────

RegisterNetEvent("SPZ:duel:Begin", function(data)
    if not data then return end
    duel  = { targetMs = data.targetMs, oppName = data.oppName, stake = data.stake }
    route = buildRoute(data.line and data.line.model, data.line and data.line.points)
    removeGhost()
end)

RegisterNetEvent("SPZ:tt:LapStarted", function()
    if duel then startRun() end
end)

RegisterNetEvent("SPZ:tt:End", function()
    duel = nil
    removeGhost()
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then removeGhost() end
end)
