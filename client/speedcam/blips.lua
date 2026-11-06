-- client/speedcam/blips.lua — speed cameras (blips).
-- Moved from spz-speedcam/client/blips.lua when it was merged into spz-races.
local Config = Config.Speedcam

-- client/blips.lua
-- Map blips for every speed camera (SpeedCams, shared/cameras.lua).
--   • Short-range: on the MINIMAP they only appear when you're near one.
--   • Collection: on the big PAUSE MAP they group under a single category
--     ("Speed Cameras") in the legend instead of dozens of loose pins.

CreateThread(function()
    if Config and Config.ShowBlips == false then return end
    if type(SpeedCams) ~= "table" then
        print("^1[spz-speedcam] blips: SpeedCams table missing^0")
        return
    end

    -- Named category → the full-map legend collects the blips under one header.
    local CAT = (Config and Config.BlipCategory) or 10
    AddTextEntry("SPZ_SPEEDCAM_CAT", "Speed Cameras")

    local n = 0
    for _, cam in ipairs(SpeedCams) do
        local c = cam.coords
        if c then
            local blip = AddBlipForCoord(c.x, c.y, c.z)
            SetBlipSprite(blip, (Config and Config.BlipSprite) or 184)
            SetBlipColour(blip, (Config and Config.BlipColour) or 1)
            SetBlipScale(blip,  (Config and Config.BlipScale)  or 0.7)
            SetBlipAsShortRange(blip, true)    -- minimap: only when near
            SetBlipCategory(blip, CAT)         -- big map: grouped collection

            -- Shared name → legend lists them as one collapsible group.
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName("Speed Camera")
            EndTextCommandSetBlipName(blip)
            n = n + 1
        end
    end
    print(("^2[spz-speedcam] %d camera blips placed (short-range, grouped)^0"):format(n))
end)
