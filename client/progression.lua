-- client/progression.lua — progression (client).
-- Moved from spz-progression/client/main.lua when it was merged into spz-races.

---Relays progression updates from the server to the HUD.
---@param data table The progression payload containing gains and rank updates.
RegisterNetEvent("SPZ:progressionUpdate", function(data)
    -- Relay to hud for the post-race summary screen
    -- exports["spz-hud"]:ShowProgression(data)
    print("[Progression] Received update: " .. json.encode(data))
end)
