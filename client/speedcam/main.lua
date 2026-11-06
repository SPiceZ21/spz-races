-- client/speedcam/main.lua — speed cameras (main).
-- Moved from spz-speedcam/client/main.lua when it was merged into spz-races.
-- Its page is still the "spz-speedcam" app in spz-hud; these locals send to that page only.
local SendNUIMessage, SetNuiFocus, SetNuiFocusKeepInput = SpzHudApp('spz-speedcam')
local Config = Config.Speedcam

-- client/main.lua

-- Base theme (server.cfg spz_theme_* convars via spz-core).
local function pushSpeedcamTheme(theme)
    if theme and next(theme) then
        SendNUIMessage({ type = 'theme', theme = theme })
    end
end
CreateThread(function()
    local ok, theme = pcall(function() return exports['spz-core']:GetTheme() end)
    if ok then pushSpeedcamTheme(theme) end
end)
AddEventHandler('SPZ:themeUpdated', function(theme) pushSpeedcamTheme(theme) end)

-- ── State ─────────────────────────────────────────────────────────────────────

local inZone      = {}   -- [camId] = true while player is inside radius
local onCooldown  = {}   -- [camId] = true while cooling down after capture
local snapshot    = {}   -- [camId] = plate/vehicle data grabbed at trigger time

-- ── Minimap anchor ────────────────────────────────────────────────────────────
-- The capture card matches the GTA minimap's exact rect. Safezone is a user
-- setting, so recompute periodically and push fractions to the NUI.

local function GetMinimapRect()
    local safeZone    = GetSafeZoneSize()
    local aspectRatio = GetAspectRatio(false)
    local resX, resY  = GetActiveScreenResolution()

    local width   = (resX / (4 * aspectRatio)) / resX
    local height  = (resY / 5.674) / resY
    local leftX   = (resX * (0.05 * (math.abs(safeZone - 1.0) * 10))) / resX
    local bottomY = 1.0 - (resY * (0.05 * (math.abs(safeZone - 1.0) * 10))) / resY

    return {
        left   = leftX,
        width  = width,
        top    = bottomY - height,
        bottom = bottomY,
    }
end

CreateThread(function()
    local last
    while true do
        local m = GetMinimapRect()
        local key = ("%f|%f|%f"):format(m.left, m.width, m.top)
        if key ~= last then
            last = key
            SendNUIMessage({ type = 'minimap', minimap = m })
        end
        Wait(2000)
    end
end)

-- ── Detection loop (adaptive sleep) ──────────────────────────────────────────
-- When far from all cameras: sleeps 1000ms (cheap background check).
-- When within NearbyRadius of any camera: switches to 100ms for precise trigger.
-- Capture fires ONCE on zone-enter, then per-camera cooldown applies.

Citizen.CreateThread(function()
    while true do
        local ped     = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle == 0 then
            inZone = {}
            Citizen.Wait(1000)
        else
            local vPos      = GetEntityCoords(vehicle)
            local nearAny   = false

            for _, cam in ipairs(SpeedCams) do
                local dist   = #(vPos - cam.coords)
                local radius = cam.radius or Config.DetectionRadius

                if dist <= Config.NearbyRadius then
                    nearAny = true
                end

                local inside = dist <= radius

                if inside and not inZone[cam.id] and not onCooldown[cam.id] then
                    local speedMs  = GetEntitySpeed(vehicle)
                    local speedKmh = speedMs * 3.6
                    local minSpeed = cam.minSpeedKmh or Config.MinSpeedKmh

                    if speedKmh >= minSpeed then
                        local model = GetEntityModel(vehicle)

                        -- Grab the plate as it was when the shot fired — the player
                        -- may swap vehicles before the server answers.
                        snapshot[cam.id] = {
                            plate      = (GetVehicleNumberPlateText(vehicle) or ''):gsub('%s+$', ''),
                            plateIndex = GetVehicleNumberPlateTextIndex(vehicle),
                        }

                        TriggerServerEvent("spz-speedcam:capture", cam.id, speedKmh, model)

                        onCooldown[cam.id] = true
                        SetTimeout(Config.CooldownMs, function()
                            onCooldown[cam.id] = nil
                        end)
                    end
                end

                inZone[cam.id] = inside
            end

            -- Far from all cameras → sleep 1 s, near one → sleep 100 ms
            Citizen.Wait(nearAny and 100 or 1000)
        end
    end
end)

-- ── Server responses ──────────────────────────────────────────────────────────

-- ── Character headshot ────────────────────────────────────────────────────────
-- The game renders a headshot of any ped into a runtime texture; NUI shows it
-- through https://nui-img/<txd>/<txd>. One at a time, released after the card
-- has gone, because the game only has a handful of headshot slots.
local headshot = nil

local function releaseHeadshot()
    if headshot then UnregisterPedheadshot(headshot); headshot = nil end
end

local function takeHeadshot()
    releaseHeadshot()
    local ped = PlayerPedId()
    if not DoesEntityExist(ped) then return nil end
    -- Transparent background so the face sits cleanly on the card.
    local h = RegisterPedheadshotTransparent(ped)
    local deadline = GetGameTimer() + 1500
    while not IsPedheadshotReady(h) or not IsPedheadshotValid(h) do
        if GetGameTimer() > deadline then UnregisterPedheadshot(h); return nil end
        Wait(0)
    end
    headshot = h
    return GetPedheadshotTxdString(h)
end

RegisterNetEvent("spz-speedcam:captured", function(data)
    -- Build display speed string
    local displaySpeed
    if Config.Units == 'mph' then
        displaySpeed = math.floor(data.speedKmh * 0.621371)
    else
        displaySpeed = math.floor(data.speedKmh)
    end

    local snap = snapshot[data.cameraId]
    snapshot[data.cameraId] = nil

    SendNUIMessage({
        type          = "capture",
        cameraName    = data.cameraName,
        plate         = snap and snap.plate or nil,
        plateIndex    = snap and snap.plateIndex or 0,
        speed         = displaySpeed,
        unit          = Config.Units == 'mph' and 'MPH' or 'KM/H',
        personalBest  = data.isPersonalBest,
        globalRecord  = data.isGlobalRecord,
        prevBest      = data.prevPersonalBest and math.floor(
                            Config.Units == 'mph' and data.prevPersonalBest * 0.621371 or data.prevPersonalBest
                        ) or nil,
        duration      = Config.CardDurationMs,
        headshot      = takeHeadshot(),
    })
    local mine = headshot
    SetTimeout((Config.CardDurationMs or 6000) + 1500, function()
        if headshot == mine then releaseHeadshot() end
    end)
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then releaseHeadshot() end
end)

RegisterNetEvent("spz-speedcam:newGlobalRecord", function(data)
    local displaySpeed = math.floor(
        Config.Units == 'mph' and data.speedKmh * 0.621371 or data.speedKmh
    )
    local unit = Config.Units == 'mph' and 'MPH' or 'KM/H'

    lib.notify({
        description = ("NEW RECORD — %s\n%s reached %d %s on %s"):format(
            data.cameraName,
            data.playerName,
            displaySpeed,
            unit,
            data.vehicleModel or "unknown vehicle"
        ),
        type = "info"
    })
end)

-- ── Records command ───────────────────────────────────────────────────────────

local isRecordsOpen = false

local function CloseRecordsNUI()
    isRecordsOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = "closeRecords" })
end

-- spz-tutorial closes whatever it opened when the tour moves on.
AddEventHandler("spz-tutorial:closeUI", function() if isRecordsOpen then CloseRecordsNUI() end end)


RegisterCommand(Config.RecordsCommand, function()
    if isRecordsOpen then
        CloseRecordsNUI()
        return
    end

    isRecordsOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ type = "openRecords" })

    lib.callback("spz-speedcam:getPersonalBests", false, function(records)
        if not isRecordsOpen then return end
        if not records or #records == 0 then
            SendNUIMessage({ type = "records", records = {}, cameraList = SpeedCams })
            return
        end
        SendNUIMessage({ type = "records", records = records, cameraList = SpeedCams })
    end, {})
end, false)

-- Registry: Docs/keybinds.md
-- The key is on its own command (old binding on "speedrecords" was F7, now the
-- minigame hub); the typed /speedrecords still works.
-- No default key any more: speed records live under Leaderboard in the quick
-- menu (Z), and /speedrecords still works. Players can still bind one.
RegisterCommand(Config.RecordsKeyCommand, function() ExecuteCommand(Config.RecordsCommand) end, false)
RegisterKeyMapping(Config.RecordsKeyCommand, "Speed Camera Records", "keyboard", "")

RegisterNUICallback("closeRecords", function(_, cb)
    isRecordsOpen = false
    SetNuiFocus(false, false)
    cb("ok")
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then
        SetNuiFocus(false, false)
    end
end)
