-- server/speedcam.lua — speed cameras and records (server).
-- Moved from spz-speedcam/server/main.lua when it was merged into spz-races.

-- server/main.lua

Citizen.CreateThread(function()
    -- ── Schema ────────────────────────────────────────────────────────────────

    -- Schema (speedcam_bests) is owned by spz-core/migrations/core/003_module_tables.sql

    -- ── Capture event (Client → Server) ──────────────────────────────────────

    RegisterNetEvent("spz-speedcam:capture", function(camId, speedKmh, vehicleModel)
        local src = source

        -- Validate camera ID
        if not SpeedCamById[camId] then return end

        -- Validate speed is a reasonable number
        speedKmh = tonumber(speedKmh)
        if not speedKmh or speedKmh < 0 or speedKmh > 600 then return end

        local ok, profile = pcall(function() return exports["spz-core"]:GetProfile(src) end)
        local playerId = ok and profile and profile.id or nil

        -- ── Check personal best ───────────────────────────────────────────────

        local isPersonalBest = false
        local prevPersonalBest = nil

        if playerId then
            local rows = MySQL.query.await(
                "SELECT speed_kmh FROM speedcam_bests WHERE camera_id = ? AND player_id = ? LIMIT 1",
                { camId, playerId }
            )
            local existing = rows and rows[1]
            prevPersonalBest = existing and existing.speed_kmh or nil
            isPersonalBest   = not existing or speedKmh > existing.speed_kmh

            if isPersonalBest then
                MySQL.query.await([[
                    INSERT INTO speedcam_bests (camera_id, player_id, speed_kmh, vehicle_model)
                    VALUES (?, ?, ?, ?)
                    ON DUPLICATE KEY UPDATE
                        speed_kmh     = VALUES(speed_kmh),
                        vehicle_model = VALUES(vehicle_model),
                        updated_at    = NOW()
                ]], { camId, playerId, speedKmh, vehicleModel })
            end
        end

        -- ── Check global record ───────────────────────────────────────────────

        local isGlobalRecord = false
        local globalRows = MySQL.query.await(
            "SELECT MAX(speed_kmh) AS top FROM speedcam_bests WHERE camera_id = ?",
            { camId }
        )
        local currentGlobal = globalRows and globalRows[1] and globalRows[1].top or nil

        -- After our INSERT, re-query (or just compare)
        if isPersonalBest then
            isGlobalRecord = not currentGlobal or speedKmh >= currentGlobal
        end

        -- ── Respond to client ─────────────────────────────────────────────────

        TriggerClientEvent("spz-speedcam:captured", src, {
            cameraId        = camId,
            cameraName      = SpeedCamById[camId].name,
            speedKmh        = speedKmh,
            isPersonalBest  = isPersonalBest,
            isGlobalRecord  = isGlobalRecord,
            prevPersonalBest = prevPersonalBest,
        })

        -- ── Broadcast global record to all players ────────────────────────────

        if isGlobalRecord then
            local playerName = GetPlayerName(src) or "Unknown"
            TriggerClientEvent("spz-speedcam:newGlobalRecord", -1, {
                cameraName   = SpeedCamById[camId].name,
                speedKmh     = speedKmh,
                playerName   = playerName,
                vehicleModel = vehicleModel,
            })
        end
    end)

    -- ── SPZ Callbacks ─────────────────────────────────────────────────────────

    -- Get player's personal bests across all cameras
    lib.callback.register("spz-speedcam:getPersonalBests", function(source)
        local ok, profile = pcall(function() return exports["spz-core"]:GetProfile(source) end)
        if not ok or not profile then return {} end

        local rows = MySQL.query.await([[
            SELECT camera_id, speed_kmh, vehicle_model, updated_at
            FROM speedcam_bests
            WHERE player_id = ?
            ORDER BY speed_kmh DESC
        ]], { profile.id })
        return rows or {}
    end)

    print("^2[spz-speedcam] Server ready — " .. #SpeedCams .. " cameras active^7")
end)
