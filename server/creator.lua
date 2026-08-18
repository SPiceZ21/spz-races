-- server/creator.lua
-- Server-side persistence and loading for custom track creator system

local function LoadCustomTracks()
    local file = LoadResourceFile(GetCurrentResourceName(), "data/custom_tracks.json")
    if file then
        local ok, parsed = pcall(json.decode, file)
        if ok and parsed then
            local loadedCount = 0
            for id, track in pairs(parsed) do
                -- Convert simple JSON tables back to CFX native Vector3 values
                local loadedTrack = {
                    name          = track.name,
                    type          = track.type or "circuit",
                    laps          = track.laps or 3,
                    min_class     = track.min_class or 0,
                    poll_weight   = track.poll_weight or 8,
                    start_coords  = vector3(track.start_coords.x, track.start_coords.y, track.start_coords.z),
                    start_heading = track.start_heading or 0.0,
                    checkpoints   = {}
                }
                
                for _, cp in ipairs(track.checkpoints) do
                    table.insert(loadedTrack.checkpoints, {
                        coords = vector3(cp.coords.x, cp.coords.y, cp.coords.z),
                        left   = vector3(cp.left.x, cp.left.y, cp.left.z),
                        right  = vector3(cp.right.x, cp.right.y, cp.right.z),
                        radius = cp.radius or 10.0
                    })
                end
                
                SPZ.Tracks[id] = loadedTrack
                loadedCount = loadedCount + 1
            end
            print(string.format("^2[spz-races] Successfully loaded %d custom tracks from custom_tracks.json^7", loadedCount))
        end
    end
end

-- Initialize custom tracks at resource start
Citizen.CreateThread(function()
    LoadCustomTracks()
end)

-- ── Net Events ───────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:saveCustomTrack", function(payload)
    local src = source
    if not payload or not payload.checkpoints or #payload.checkpoints < 2 then
        TriggerClientEvent("ox_lib:notify", src, { description = "Save failed: need at least 2 checkpoints.", type = "error", position = "center-left" })
        return
    end

    -- If editor passes an explicit id, keep it (overwrite).
    -- Otherwise derive from name (creator new track).
    local trackId
    if payload.id and payload.id ~= "" then
        trackId = payload.id
    else
        trackId = string.lower(payload.name:gsub("%s+", ""):gsub("%W+", ""))
        if trackId == "" then trackId = "custom_" .. os.time() end
    end
    
    -- Load current custom tracks
    local currentTracks = {}
    local file = LoadResourceFile(GetCurrentResourceName(), "data/custom_tracks.json")
    if file then
        local ok, parsed = pcall(json.decode, file)
        if ok and parsed then
            currentTracks = parsed
        end
    end
    
    -- Format coordinates cleanly for JSON saving
    local cleanTrack = {
        name          = payload.name,
        type          = payload.type or "circuit",
        laps          = tonumber(payload.laps) or (payload.type == "circuit" and 3 or 1),
        min_class     = 0,
        poll_weight   = 8,
        start_coords  = {
            x = payload.checkpoints[1].coords.x,
            y = payload.checkpoints[1].coords.y,
            z = payload.checkpoints[1].coords.z
        },
        start_heading = payload.checkpoints[1].heading or 0.0,
        checkpoints   = {}
    }
    
    for i, cp in ipairs(payload.checkpoints) do
        table.insert(cleanTrack.checkpoints, {
            coords = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
            left   = { x = cp.left.x, y = cp.left.y, z = cp.left.z },
            right  = { x = cp.right.x, y = cp.right.y, z = cp.right.z },
            radius = cp.radius
        })
    end
    
    -- Save to table
    currentTracks[trackId] = cleanTrack
    
    -- Write to JSON file
    SaveResourceFile(GetCurrentResourceName(), "data/custom_tracks.json", json.encode(currentTracks, { indent = true }), -1)
    
    -- Dynamically load it into runtime memory immediately so they can race it right away!
    local loadedTrack = {
        name          = cleanTrack.name,
        type          = cleanTrack.type,
        laps          = cleanTrack.laps,
        min_class     = cleanTrack.min_class,
        poll_weight   = cleanTrack.poll_weight,
        start_coords  = vector3(cleanTrack.start_coords.x, cleanTrack.start_coords.y, cleanTrack.start_coords.z),
        start_heading = cleanTrack.start_heading,
        checkpoints   = {}
    }
    
    for _, cp in ipairs(cleanTrack.checkpoints) do
        table.insert(loadedTrack.checkpoints, {
            coords = vector3(cp.coords.x, cp.coords.y, cp.coords.z),
            left   = vector3(cp.left.x, cp.left.y, cp.left.z),
            right  = vector3(cp.right.x, cp.right.y, cp.right.z),
            radius = cp.radius
        })
    end
    
    SPZ.Tracks[trackId] = loadedTrack
    
    SPZ.Notify(src, ("Track '%s' saved and live (%d gates, %d laps)!"):format(cleanTrack.name, #cleanTrack.checkpoints, cleanTrack.laps), "success")
    print(string.format("^2[spz-races] Saved custom track '%s' (ID: %s)^7", cleanTrack.name, trackId))
end)

-- ── Callbacks ────────────────────────────────────────────────────────────────

lib.callback.register("spz-races:getTracks", function(source)
    local list = {}
    for id, track in pairs(SPZ.Tracks) do
        table.insert(list, {
            id = id,
            name = track.name,
            type = track.type or "circuit",
            laps = track.laps or 3,
            checkpointCount = track.checkpoints and #track.checkpoints or 0,
            isCustom = (id:sub(1, 7) == "custom_") or (id:find("custom") ~= nil) or false
        })
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end)

lib.callback.register("spz-races:deleteTrack", function(source, data)
    if not data or not data.id then
        return false, "Invalid Track ID"
    end

    local trackId = data.id
    if not SPZ.Tracks[trackId] then
        return false, "Track not found"
    end

    -- Load custom tracks
    local currentTracks = {}
    local file = LoadResourceFile(GetCurrentResourceName(), "data/custom_tracks.json")
    if file then
        local ok, parsed = pcall(json.decode, file)
        if ok and parsed then
            currentTracks = parsed
        end
    end

    if currentTracks[trackId] then
        currentTracks[trackId] = nil
        SaveResourceFile(GetCurrentResourceName(), "data/custom_tracks.json", json.encode(currentTracks, { indent = true }), -1)
    end

    SPZ.Tracks[trackId] = nil
    TriggerClientEvent('ox_lib:notify', source, { description = "Track deleted.", type = "success", position = "center-left" })
    return true
end)

lib.callback.register("spz-races:getTrackDetails", function(source, data)
    if not data or not data.id then
        return nil
    end

    local track = SPZ.Tracks[data.id]
    if not track then
        return nil
    end

    local cps = {}
    for i, cp in ipairs(track.checkpoints) do
        table.insert(cps, {
            coords = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
            left   = { x = cp.left.x, y = cp.left.y, z = cp.left.z },
            right  = { x = cp.right.x, y = cp.right.y, z = cp.right.z },
            radius = cp.radius or 10.0
        })
    end

    return {
        id = data.id,
        name = track.name,
        type = track.type or "circuit",
        laps = track.laps or 3,
        start_coords = { x = track.start_coords.x, y = track.start_coords.y, z = track.start_coords.z },
        start_heading = track.start_heading or 0.0,
        checkpoints = cps
    }
end)



