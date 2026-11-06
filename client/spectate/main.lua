-- client/spectate/main.lua — spectate (main).
-- Moved from spz-spectate/client/main.lua when it was merged into spz-races.
-- Its page is still the "spz-spectate" app in spz-hud; these locals send to that page only.
local SendNUIMessage, SetNuiFocus, SetNuiFocusKeepInput = SpzHudApp('spz-spectate')

-- client/main.lua
-- Spectator client. /spectate opens a clean overlay and lets you cycle every
-- online player. The server drops us into the target's routing bucket; we then
-- hand the engine's spectator camera the target ped and read live data from
-- statebags + the streamed entity for the overlay.

local active   = false
local targets  = {}      -- { {id,name,racing,nation,number}, ... }
local idx      = 1
local myBack   = nil     -- coords to restore to on exit

-- Base theme (server.cfg spz_theme_* convars via spz-core).
local function pushSpectateTheme(theme)
    if theme and next(theme) then
        SendNUIMessage({ action = 'theme', theme = theme })
    end
end
CreateThread(function()
    local ok, theme = pcall(function() return exports['spz-core']:GetTheme() end)
    if ok then pushSpectateTheme(theme) end
end)
AddEventHandler('SPZ:themeUpdated', function(theme) pushSpectateTheme(theme) end)

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function targetPed(serverId)
    local lp = GetPlayerFromServerId(serverId)
    if lp == -1 then return 0 end
    local ped = GetPlayerPed(lp)
    return (ped ~= 0 and DoesEntityExist(ped)) and ped or 0
end

-- Wait for the target ped to stream in after a bucket move.
local function awaitPed(serverId, timeout)
    local deadline = GetGameTimer() + (timeout or 4000)
    while GetGameTimer() < deadline do
        local ped = targetPed(serverId)
        if ped ~= 0 then return ped end
        Wait(50)
    end
    return 0
end

local function currentTarget()
    return targets[idx]
end

-- ── Data feed to the overlay ──────────────────────────────────────────────────

local function vehName(ped)
    local v = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if v == 0 then return nil end
    local lbl = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(v)))
    if lbl == "NULL" then lbl = GetDisplayNameFromVehicleModel(GetEntityModel(v)) end
    return lbl
end

local function speedKmh(ped)
    if ped == 0 then return 0 end
    local v = GetVehiclePedIsIn(ped, false)
    local ent = v ~= 0 and v or ped
    return math.floor(GetEntitySpeed(ent) * 3.6 + 0.5)
end

local function pushCard()
    local t = currentTarget()
    if not t then return end
    local st  = Player(t.id).state
    local ped = targetPed(t.id)

    SendNUIMessage({
        action = "update",
        data = {
            name    = (st and st['spz:name']) or t.name,
            nation  = st and st['spz:nation'] or nil,
            number  = st and st['spz:raceNumber'] or nil,
            rank    = st and st['spz:license'] or nil,
            crew    = st and st['spz:crew'] or nil,
            records = (st and st['spz:records']) or 0,
            racing  = st and st['inRace'] == true or false,
            position = st and st['racePosition'] or nil,
            lap      = st and st['raceLap'] or nil,
            speed    = speedKmh(ped),
            vehicle  = vehName(ped),
            index    = idx,
            total    = #targets,
        },
    })
end

-- ── Spectate lifecycle ────────────────────────────────────────────────────────

local function attach()
    local t = currentTarget()
    if not t then return false end

    local res = lib.callback.await("spz-spectate:enter", false, t.id)
    if not res or not res.ok then
        lib.notify({ description = "Can't spectate that player", type = "error" })
        return false
    end

    -- Teleport our own (frozen, invisible) ped onto the target so it streams into
    -- scope, THEN hand the spectator camera the real target ped.
    if res.x then
        local me = PlayerPedId()
        SetEntityCoords(me, res.x, res.y, res.z + 1.5, false, false, false, false)
    end

    local ped = awaitPed(t.id, 6000)
    if ped == 0 then
        lib.notify({ description = "Player not in view range", type = "warning" })
    end

    NetworkSetInSpectatorMode(true, ped ~= 0 and ped or PlayerPedId())
    return true
end

local function stop()
    if not active then return end
    active = false

    NetworkSetInSpectatorMode(false, PlayerPedId())
    TriggerServerEvent("spz-spectate:leave")

    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    if myBack then
        SetEntityCoords(ped, myBack.x, myBack.y, myBack.z, false, false, false, false)
        myBack = nil
    end

    SetNuiFocus(false, false)
    SendNUIMessage({ action = "hide" })
end

local function switchBy(delta)
    if #targets == 0 then return end
    idx = ((idx - 1 + delta) % #targets) + 1
    attach()
    pushCard()
end

local function start()
    if active then return end

    local myState = LocalPlayer.state
    if myState and myState.inRace then
        lib.notify({ description = "Can't spectate while racing", type = "error" })
        return
    end

    targets = lib.callback.await("spz-spectate:getTargets", false) or {}
    if #targets == 0 then
        lib.notify({ description = "No active racers to spectate", type = "info" })
        return
    end

    -- Server returns active racers only — just order them by name.
    table.sort(targets, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    idx = 1

    local ped = PlayerPedId()
    myBack = GetEntityCoords(ped)
    SetEntityVisible(ped, false, false)
    FreezeEntityPosition(ped, true)

    active = true
    SendNUIMessage({ action = "show" })
    if not attach() then stop(); return end
    pushCard()
end

-- ── Input + data loop ─────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if active then
            if IsControlJustPressed(0, 175) or IsControlJustPressed(0, 45) then      -- arrow right / R
                switchBy(1)
            elseif IsControlJustPressed(0, 174) or IsControlJustPressed(0, 44) then  -- arrow left / Q
                switchBy(-1)
            elseif IsControlJustPressed(0, 177) or IsControlJustPressed(0, 202) then -- backspace / esc
                stop()
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)

CreateThread(function()
    while true do
        if active then
            -- Target left the server / bucket collapsed: drop them and advance.
            local t = currentTarget()
            if not t or GetPlayerFromServerId(t.id) == -1 and Player(t.id).state['spz:name'] == nil then
                -- fall through to refresh below
            end
            pushCard()
            Wait(200)
        else
            Wait(500)
        end
    end
end)

RegisterNetEvent("spz-spectate:targetGone", function()
    if not active then return end
    -- Remove the vanished target and hop to the next one, or exit if none left.
    local goneId = currentTarget() and currentTarget().id
    if goneId then
        for i = #targets, 1, -1 do
            if targets[i].id == goneId then table.remove(targets, i) end
        end
    end
    if #targets == 0 then
        lib.notify({ description = "No more players to spectate", type = "info" })
        stop()
    else
        if idx > #targets then idx = 1 end
        attach()
        pushCard()
    end
end)

-- ── Command / keybind ─────────────────────────────────────────────────────────

RegisterCommand("spectate", function()
    if active then stop() else start() end
end, false)

RegisterKeyMapping("spectate", "Toggle spectator mode", "keyboard", "")

-- Other resources (spz-races lobby pill) check this to hide their prompts.
exports("IsSpectating", function() return active end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and active then stop() end
end)
