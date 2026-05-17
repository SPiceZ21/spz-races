-- client/creator.lua
-- Track creation and editing logic with high-fidelity visualizers

local creatorActive   = false
local checkpoints     = {}
local trackName       = "Unnamed Custom Track"
local trackType       = "circuit"
local defaultWidth    = 10.0

-- ── Events & Net Events ───────────────────────────────────────────────────────

RegisterNetEvent("SPZ:startTrackCreator", function(data)
    creatorActive = true
    checkpoints   = {}
    trackName     = data.name or "Unnamed Custom Track"
    trackType     = data.type or "circuit"
    defaultWidth  = tonumber(data.defaultWidth) or 10.0
    exports["spz-lib"]:Notify("Track creation started: " .. trackName, "info")
end)

-- ── Exports ───────────────────────────────────────────────────────────────────

-- Add checkpoint at player's current vehicle location
exports("AddTrackCheckpoint", function(width)
    if not creatorActive then return false, 0 end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local targetEntity = veh ~= 0 and veh or ped
    
    local coords = GetEntityCoords(targetEntity)
    local heading = GetEntityHeading(targetEntity)
    local w = tonumber(width) or defaultWidth
    
    -- Calculate left and right perpendicular vectors
    local headingRad = math.rad(heading + 90.0)
    local left = coords + vector3(math.cos(headingRad) * (w / 2), math.sin(headingRad) * (w / 2), 0.0)
    local right = coords - vector3(math.cos(headingRad) * (w / 2), math.sin(headingRad) * (w / 2), 0.0)
    
    local cp = {
        coords = coords,
        heading = heading,
        radius = w,
        left = left,
        right = right
    }
    
    table.insert(checkpoints, cp)
    exports["spz-lib"]:Notify(string.format("Checkpoint #%d placed", #checkpoints), "success")
    return true, #checkpoints
end)

-- Remove the last placed checkpoint
exports("DeleteLastCheckpoint", function()
    if not creatorActive or #checkpoints == 0 then return false, 0 end
    table.remove(checkpoints)
    exports["spz-lib"]:Notify(string.format("Checkpoint removed. Remaining: %d", #checkpoints), "warning")
    return true, #checkpoints
end)

-- Cancel track creation completely
exports("CancelTrackCreator", function()
    creatorActive = false
    checkpoints   = {}
    exports["spz-lib"]:Notify("Track creation canceled.", "error")
    return true
end)

-- Save the track and compile coordinates
exports("SaveTrack", function(name, type, cb)
    if not creatorActive then
        if cb then cb(false, "Creator is not active") end
        return
    end
    if #checkpoints < 2 then
        if cb then cb(false, "You need at least 2 checkpoints to save a track") end
        exports["spz-lib"]:Notify("Cannot save: Need at least 2 checkpoints", "error")
        return
    end
    
    local tName = name or trackName
    local tType = type or trackType
    
    local cleanCheckpoints = {}
    for i, cp in ipairs(checkpoints) do
        table.insert(cleanCheckpoints, {
            coords = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
            left   = { x = cp.left.x, y = cp.left.y, z = cp.left.z },
            right  = { x = cp.right.x, y = cp.right.y, z = cp.right.z },
            radius = cp.radius
        })
    end
    
    TriggerServerEvent("SPZ:saveCustomTrack", {
        name = tName,
        type = tType,
        checkpoints = cleanCheckpoints
    })
    
    creatorActive = false
    checkpoints   = {}
    if cb then cb(true) end
end)

-- ── 3D Visualizer Thread ──────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if creatorActive and #checkpoints > 0 then
            local ped = PlayerPedId()
            local myCoords = GetEntityCoords(ped)
            
            for i, cp in ipairs(checkpoints) do
                local dist = #(myCoords - cp.coords)
                if dist < 120.0 then
                    -- 1. Draw checkpoint center column
                    DrawMarker(1, cp.coords.x, cp.coords.y, cp.coords.z - 1.0, 
                               0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 
                               1.2, 1.2, 2.0, 255, 98, 0, 120, 
                               false, false, 2, nil, nil, false)
                    
                    -- 2. Draw left gate boundary marker (Red pin)
                    DrawMarker(4, cp.left.x, cp.left.y, cp.left.z + 0.5, 
                               0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 
                               0.8, 0.8, 0.8, 230, 50, 50, 200, 
                               false, false, 2, nil, nil, false)
                               
                    -- 3. Draw right gate boundary marker (Green pin)
                    DrawMarker(4, cp.right.x, cp.right.y, cp.right.z + 0.5, 
                               0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 
                               0.8, 0.8, 0.8, 50, 230, 50, 200, 
                               false, false, 2, nil, nil, false)
                    
                    -- 4. Draw neon connection bar bridging the gate
                    DrawLine(cp.left.x, cp.left.y, cp.left.z, 
                             cp.right.x, cp.right.y, cp.right.z, 
                             255, 98, 0, 255)
                    
                    -- 5. Draw visual route line to next checkpoint
                    if checkpoints[i + 1] then
                        local nextCp = checkpoints[i + 1]
                        DrawLine(cp.coords.x, cp.coords.y, cp.coords.z, 
                                 nextCp.coords.x, nextCp.coords.y, nextCp.coords.z, 
                                 255, 255, 255, 80)
                    end
                end
            end
            Wait(0)
        else
            Wait(1000)
        end
    end
end)
