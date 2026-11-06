-- client/accent.lua — the one colour the race visuals use: the checkpoint
-- distance pill, the pending checkpoint props, the GPS route and the gate
-- blips. Config.RaceColour if set, else spz-core's theme accent
-- (spz_theme_accent), else the brand orange.

local function parse(hex)
    hex = tostring(hex or ''):gsub('#', '')
    if not hex:match('^%x%x%x%x%x%x$') then return nil end
    return '#' .. hex:lower(), tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

--- "#rrggbb", r, g, b
function SPZ_RaceAccent()
    local hex, r, g, b = parse(Config and Config.RaceColour)
    if hex then return hex, r, g, b end
    local ok, theme = pcall(function() return exports['spz-core']:GetTheme() end)
    hex, r, g, b = parse(ok and theme and theme.accent)
    if hex then return hex, r, g, b end
    return '#ff6200', 255, 98, 0
end

--- The accent as a blip colour (SetBlipColour takes 0xRRGGBBAA).
function SPZ_RaceAccentBlip()
    local _, r, g, b = SPZ_RaceAccent()
    return (r << 24) | (g << 16) | (b << 8) | 0xFF
end
