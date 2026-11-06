-- client/ui/poll.lua — race vote page.
-- Moved from spz-poll/client/main.lua when it was merged into spz-races. Its page is still
-- the "spz-poll" app in spz-hud; these locals send to that page only.
local SendNUIMessage, SetNuiFocus, SetNuiFocusKeepInput = SpzHudApp('spz-poll')

-- Base theme (server.cfg spz_theme_* convars via spz-core).
local function pushPollTheme(theme)
    if theme and next(theme) then
        SendNUIMessage({ action = 'theme', theme = theme })
    end
end
CreateThread(function()
    local ok, theme = pcall(function() return exports['spz-core']:GetTheme() end)
    if ok then pushPollTheme(theme) end
end)
AddEventHandler('SPZ:themeUpdated', function(theme) pushPollTheme(theme) end)

local isPollOpen = false

-- ── Vehicle names ────────────────────────────────────────────────────────────
--
-- The server sends a model name and whatever label its registry holds. The
-- MANUFACTURER and the game's own display name only exist client-side — they
-- are GXT entries, and GetLabelText is a client native — so the card is
-- completed here rather than by sending a name the server had to guess at.
--
-- That matters most for add-on cars: spz-vehicles has to derive their label
-- from the model name ("gbelegyrh2" -> "Gbelegyrh2"), while the pack itself
-- ships the real text. Reading it here gets "Annis / Elegy RH2" on the card
-- for free, and falls back to the server's label when a pack ships no text.
local function labelOrNil(gxt)
    if type(gxt) ~= "string" or gxt == "" then return nil end
    local text = GetLabelText(gxt)
    if not text or text == "" or text == "NULL" then return nil end
    return text
end

local shotBase, shotFmt
local function carPhoto(model)
    local primary
    -- The car spawner's photos ship from spz-hud now (its copy of the spawner UI).
    if GetResourceState("spz-hud") == "started"
    and LoadResourceFile("spz-hud", "ui/apps/spz-carspawner/img/" .. model .. ".png") then
        primary = ("https://cfx-nui-spz-hud/ui/apps/spz-carspawner/img/%s.png"):format(model)
    end
    if shotBase == nil and GetResourceState("uz_AutoShot") == "started" then
        local ok, base = pcall(function() return exports["uz_AutoShot"]:getShotsBaseURL() end)
        local okF, fmt = pcall(function() return exports["uz_AutoShot"]:getPhotoFormat() end)
        if ok and base then shotBase, shotFmt = base .. "/vehicles", (okF and fmt) or "png" end
    end
    local shot = shotBase and ("%s/%s.%s"):format(shotBase, model, shotFmt) or nil
    if primary then return primary, shot end
    return shot, nil
end

--- Adds `brand` and `code` to a vehicle option, and upgrades `label` to the
--- game's display name when there is one.
local function describeVehicle(opt)
    if opt and opt.reroll then return end   -- the "none of these" card
    local model = opt and opt.name
    if type(model) ~= "string" or model == "" then return end

    -- The spawn code is the model name itself, and it is worth printing: it is
    -- what a player types into the spawner to try the car again later, and for
    -- an add-on it is the only handle they have on it.
    opt.code = model:lower()

    -- Photo: spz-carspawner's ui/img/<model>.png first, then the uz_AutoShot
    -- capture. The page drops the picture if neither loads.
    opt.img, opt.imgAlt = carPhoto(opt.code)

    local hash = GetHashKey(model)
    if not IsModelInCdimage(hash) then return end

    opt.brand = labelOrNil(GetMakeNameFromVehicleModel(hash))
    opt.label = labelOrNil(GetDisplayNameFromVehicleModel(hash)) or opt.label
end

---@param data table { phase: string, timer: number, options: table }
local function StartPoll(data)
    if not data then return end
    isPollOpen = true
    SetNuiFocus(true, true)

    if data.phase == "vehicle" and type(data.options) == "table" then
        for _, opt in ipairs(data.options) do describeVehicle(opt) end
    end

    SendNUIMessage({
        action = "openPoll",
        data = data
    })
end

local function StopPoll()
    isPollOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({
        action = "closePoll"
    })
end

local function UpdatePoll(data)
    SendNUIMessage({
        action = "updatePoll",
        data = data
    })
end

-- Exports
exports('StartPoll', StartPoll)
exports('StopPoll', StopPoll)
exports('UpdatePoll', UpdatePoll)

-- NUI Callbacks
-- A ballot can carry a switch alongside the cards (the traffic phase votes on
-- NPC cops that way instead of spending a whole extra phase on one yes/no), so
-- the toggle position rides with the picked index in a single submission.
-- "Give us a different set." Counted at the close as a majority of the players
-- who actually voted (spz-races/server/poll.lua), so this only records the
-- player's position — it never restarts anything on its own.
RegisterNUICallback('pollReroll', function(data, cb)
    TriggerServerEvent('SPZ:pollReroll', data and data.on == true)
    cb('ok')
end)

RegisterNUICallback('pollVote', function(data, cb)
    TriggerServerEvent('SPZ:pollVote', {
        index  = data.index,
        toggle = data.toggle,
    })

    cb('ok')
end)
