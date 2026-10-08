-- server/creator.lua
-- Server-side persistence and loading for custom track creator system
--
-- Every checkpoint carries a `heading`, and it is load-bearing: cp_cross.lua
-- uses it to orient the gate plane so that a crossing counts in the direction of
-- travel and not against it. Without it the plane's "forward" side falls out of
-- whatever order the left/right posts happen to be in, and gates become
-- scoreable from either direction.
--
-- The creator records it per gate, but all four conversion sites in this file
-- used to drop it — save to JSON, load from JSON, publish to runtime, and hand
-- back to the editor — so every custom track lost its direction the moment it
-- was written. Keep `heading` in any new mapping added here.

-- The built-in tracks (data/tracks.lua), captured at file load, before the
-- custom tracks are merged in. An editor save of a built-in track writes a
-- copy into custom_tracks.json under the same id; deleting that copy puts the
-- original back instead of removing the track.
local BuiltinTracks = {}
for id, t in pairs(SPZ.Tracks or {}) do BuiltinTracks[id] = t end

function IsBuiltinTrack(id) return BuiltinTracks[id] ~= nil end

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
                        coords  = vector3(cp.coords.x, cp.coords.y, cp.coords.z),
                        left    = vector3(cp.left.x, cp.left.y, cp.left.z),
                        right   = vector3(cp.right.x, cp.right.y, cp.right.z),
                        radius  = cp.radius or 10.0,
                        heading = cp.heading,
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
    -- Admin only (TrackAdminAllowed in server/trackadmin.lua). Without this any
    -- client could overwrite or add tracks by firing the event.
    if not (TrackAdminAllowed and TrackAdminAllowed(src)) then return end
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
            coords  = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
            left    = { x = cp.left.x, y = cp.left.y, z = cp.left.z },
            right   = { x = cp.right.x, y = cp.right.y, z = cp.right.z },
            radius  = cp.radius,
            heading = cp.heading,
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
            coords  = vector3(cp.coords.x, cp.coords.y, cp.coords.z),
            left    = vector3(cp.left.x, cp.left.y, cp.left.z),
            right   = vector3(cp.right.x, cp.right.y, cp.right.z),
            radius  = cp.radius,
            heading = cp.heading,
        })
    end
    
    SPZ.Tracks[trackId] = loadedTrack
    -- Keep the track manager's on/off, laps and weight for this id.
    if ApplyTrackOverride then ApplyTrackOverride(trackId) end
    if GetResourceState("spz-analytics") == "started" then
        pcall(function() exports["spz-analytics"]:AdminAction(src, "track_save",
            ("%s (%s), %d gates"):format(cleanTrack.name, trackId, #cleanTrack.checkpoints)) end)
    end

    SPZ.Notify(src, ("Track '%s' saved and live (%d gates, %d laps)!"):format(cleanTrack.name, #cleanTrack.checkpoints, cleanTrack.laps), "success")
    print(string.format("^2[spz-races] Saved custom track '%s' (ID: %s)^7", cleanTrack.name, trackId))
end)

-- ── Callbacks ────────────────────────────────────────────────────────────────

lib.callback.register("spz-races:deleteTrack", function(source, data)
    if not (TrackAdminAllowed and TrackAdminAllowed(source)) then return false, "Not authorised" end
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

    -- Only tracks made in the creator can be deleted; built-in ones live in
    -- data/tracks.lua and come back on restart, so switch them off instead.
    if not currentTracks[trackId] then
        return false, "Built-in track: switch it off in the track manager instead"
    end
    currentTracks[trackId] = nil
    SaveResourceFile(GetCurrentResourceName(), "data/custom_tracks.json", json.encode(currentTracks, { indent = true }), -1)
    if GetResourceState("spz-analytics") == "started" then
        pcall(function() exports["spz-analytics"]:AdminAction(source, "track_delete", trackId) end)
    end

    if BuiltinTracks[trackId] then
        SPZ.Tracks[trackId] = BuiltinTracks[trackId]
        if ApplyTrackOverride then ApplyTrackOverride(trackId) end
        return true, "Edits removed, original track restored"
    end
    SPZ.Tracks[trackId] = nil
    return true, "Track deleted"
end)

lib.callback.register("spz-races:getTrackDetails", function(source, data)
    if not (TrackAdminAllowed and TrackAdminAllowed(source)) then return nil end
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
            coords  = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
            left    = { x = cp.left.x, y = cp.left.y, z = cp.left.z },
            right   = { x = cp.right.x, y = cp.right.y, z = cp.right.z },
            radius  = cp.radius or 10.0,
            heading = cp.heading,
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

