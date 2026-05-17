-- client/editor.lua
-- Separate standalone track editor script for in-game route fine-tuning

local editorActive    = false
local editTrackId     = ""
local editTrackName   = ""
local editTrackType   = "circuit"
local editCheckpoints = {}
local selectedIndex   = 1

-- ── 3D Text Helper ───────────────────────────────────────────────────────────

local function DrawText3D(x, y, z, text, isSelected)
    local onScreen, _x, _y = GetScreenCoordFrom3dCoords(x, y, z)
    if onScreen then
        SetTextScale(0.35, 0.35)
        SetTextFont(4)
        SetTextProportional(1)
        if isSelected then
            SetTextColour(255, 0, 255, 255)
        else
            SetTextColour(255, 255, 255, 200)
        end
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x, _y)
        local factor = (string.len(text)) / 370
        if isSelected then
            DrawRect(_x, _y + 0.0125, 0.015 + factor, 0.03, 255, 0, 255, 40)
        else
            DrawRect(_x, _y + 0.0125, 0.015 + factor, 0.03, 0, 0, 0, 100)
        end
    end
end

-- ── Perpendicular Boundary Helper ────────────────────────────────────────────

local function RecalculateGate(cp)
    local headingRad = math.rad(cp.heading + 90.0)
    cp.left = cp.coords + vector3(math.cos(headingRad) * (cp.radius / 2), math.sin(headingRad) * (cp.radius / 2), 0.0)
    cp.right = cp.coords - vector3(math.cos(headingRad) * (cp.radius / 2), math.sin(headingRad) * (cp.radius / 2), 0.0)
end

-- ── NUI Event to trigger from Tablet ──────────────────────────────────────────

RegisterNetEvent("SPZ:startTrackEditor", function(data)
    if not data or not data.id then return end
    
    SPZ.Callbacks.Trigger("spz-races:getTrackDetails", { id = data.id }, function(track)
        if not track then
            exports["spz-lib"]:Notify("Failed to fetch track details.", "error")
            return
        end
        
        editTrackId     = track.id
        editTrackName   = track.name
        editTrackType   = track.type
        editCheckpoints = {}
        
        -- Load checkpoints and convert table values to proper Vector3 structures
        for i, cp in ipairs(track.checkpoints) do
            local item = {
                coords  = vector3(cp.coords.x, cp.coords.y, cp.coords.z),
                heading = cp.heading or 0.0,
                radius  = cp.radius or 10.0
            }
            if cp.heading then
                RecalculateGate(item)
            else
                item.left  = vector3(cp.left.x, cp.left.y, cp.left.z)
                item.right = vector3(cp.right.x, cp.right.y, cp.right.z)
                -- Work backward to find approximate heading from left and right vectors
                local dir = item.right - item.left
                item.heading = math.deg(math.atan2(dir.y, dir.x)) - 90.0
            end
            table.insert(editCheckpoints, item)
        end
        
        editorActive  = true
        selectedIndex = 1
        
        -- Close tablet focus
        TriggerEvent("spz-tablet:closeTablet")
        exports["spz-lib"]:Notify("Route Editor active: Driving " .. editTrackName, "info")
    end)
end)

-- ── Editor Main Logic ─────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if editorActive then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            local targetEntity = veh ~= 0 and veh or ped
            local myCoords = GetEntityCoords(targetEntity)
            
            -- Keep player updated about the current editing controls
            -- Render sleek instructional HUD
            SetTextComponentFormat("STRING")
            AddTextComponentString(
                string.format(
                    "~y~TRACK ROUTE EDITOR — %s~s~\n" ..
                    "Selected Gate: ~p~#%d~s~ / %d (Width: %.1fm)\n\n" ..
                    "~g~[ARROW UP/DOWN]~s~ Cycle Gates\n" ..
                    "~g~[E]~s~ Move Gate to Me\n" ..
                    "~g~[R]~s~ Match My Heading\n" ..
                    "~g~[PageUp / PageDown]~s~ Resize (+/- 0.5m)\n" ..
                    "~g~[INSERT]~s~ Insert New Gate Here\n" ..
                    "~g~[DELETE]~s~ Delete Selected Gate\n" ..
                    "~y~[ENTER]~s~ Compile & Save Changes\n" ..
                    "~r~[BACKSPACE]~s~ Discard & Exit",
                    editTrackName, selectedIndex, #editCheckpoints, editCheckpoints[selectedIndex] and editCheckpoints[selectedIndex].radius or 0.0
                )
            )
            EndTextCommandDisplayHelp(0, 0, 1, -1)

            -- 1. Input Controls
            
            -- Cycle index UP
            if IsControlJustPressed(0, 172) then -- Arrow Up
                selectedIndex = selectedIndex + 1
                if selectedIndex > #editCheckpoints then selectedIndex = 1 end
                PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
            end
            
            -- Cycle index DOWN
            if IsControlJustPressed(0, 173) then -- Arrow Down
                selectedIndex = selectedIndex - 1
                if selectedIndex < 1 then selectedIndex = #editCheckpoints end
                PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
            end
            
            -- Move selected gate to player
            if IsControlJustPressed(0, 38) then -- [E] (INPUT_PICKUP / TALK)
                local currentCP = editCheckpoints[selectedIndex]
                if currentCP then
                    currentCP.coords = myCoords
                    currentCP.heading = GetEntityHeading(targetEntity)
                    RecalculateGate(currentCP)
                    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                    exports["spz-lib"]:Notify(string.format("Moved Checkpoint #%d to current position", selectedIndex), "success")
                end
            end
            
            -- Match heading
            if IsControlJustPressed(0, 45) then -- [R] (INPUT_RELOAD)
                local currentCP = editCheckpoints[selectedIndex]
                if currentCP then
                    currentCP.heading = GetEntityHeading(targetEntity)
                    RecalculateGate(currentCP)
                    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                    exports["spz-lib"]:Notify(string.format("Matched Checkpoint #%d heading", selectedIndex), "success")
                end
            end
            
            -- Widen width (radius)
            if IsControlJustPressed(0, 10) then -- [PageUp]
                local currentCP = editCheckpoints[selectedIndex]
                if currentCP then
                    currentCP.radius = math.min(35.0, currentCP.radius + 0.5)
                    RecalculateGate(currentCP)
                    PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                end
            end
            
            -- Shrink width (radius)
            if IsControlJustPressed(0, 11) then -- [PageDown]
                local currentCP = editCheckpoints[selectedIndex]
                if currentCP then
                    currentCP.radius = math.max(3.0, currentCP.radius - 0.5)
                    RecalculateGate(currentCP)
                    PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                end
            end
            
            -- Insert gate
            if IsControlJustPressed(0, 121) then -- [INSERT]
                local heading = GetEntityHeading(targetEntity)
                local newCP = {
                    coords  = myCoords,
                    heading = heading,
                    radius  = 10.0
                }
                RecalculateGate(newCP)
                table.insert(editCheckpoints, selectedIndex + 1, newCP)
                selectedIndex = selectedIndex + 1
                PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                exports["spz-lib"]:Notify(string.format("Inserted new checkpoint after #%d", selectedIndex - 1), "success")
            end
            
            -- Delete gate
            if IsControlJustPressed(0, 178) then -- [DELETE]
                if #editCheckpoints > 2 then
                    table.remove(editCheckpoints, selectedIndex)
                    if selectedIndex > #editCheckpoints then selectedIndex = #editCheckpoints end
                    PlaySoundFrontend(-1, "PROP_DROP_RED", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                    exports["spz-lib"]:Notify("Deleted selected checkpoint", "warning")
                else
                    exports["spz-lib"]:Notify("Tracks must contain at least 2 checkpoints", "error")
                end
            end
            
            -- Save Changes
            if IsControlJustPressed(0, 18) then -- [ENTER] (INPUT_CELLPHONE_SELECT)
                local cleanCheckpoints = {}
                for i, cp in ipairs(editCheckpoints) do
                    table.insert(cleanCheckpoints, {
                        coords  = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
                        left    = { x = cp.left.x, y = cp.left.y, z = cp.left.z },
                        right   = { x = cp.right.x, y = cp.right.y, z = cp.right.z },
                        heading = cp.heading,
                        radius  = cp.radius
                    })
                end
                
                TriggerServerEvent("SPZ:saveCustomTrack", {
                    name        = editTrackName,
                    type        = editTrackType,
                    checkpoints = cleanCheckpoints
                })
                
                editorActive = false
                editCheckpoints = {}
                PlaySoundFrontend(-1, "Save_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
            end
            
            -- Cancel Editor
            if IsControlJustPressed(0, 177) then -- [BACKSPACE]
                editorActive = false
                editCheckpoints = {}
                PlaySoundFrontend(-1, "QUIT_WHOOSH", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                exports["spz-lib"]:Notify("Editing session canceled.", "error")
            end

            -- 2. Render Checkpoint Route

            for i, cp in ipairs(editCheckpoints) do
                local dist = #(myCoords - cp.coords)
                if dist < 150.0 then
                    local isSelected = (i == selectedIndex)
                    
                    -- Color Palette: Magenta for selected gate, Neon Orange for standard gates
                    local r, g, b = 255, 98, 0
                    if isSelected then r, g, b = 255, 0, 255 end
                    
                    -- Center pillar
                    DrawMarker(1, cp.coords.x, cp.coords.y, cp.coords.z - 1.0, 
                               0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 
                               1.0, 1.0, isSelected and 4.0 or 2.0, r, g, b, 140, 
                               false, false, 2, nil, nil, false)
                    
                    -- Left Boundary Pin (Red)
                    DrawMarker(4, cp.left.x, cp.left.y, cp.left.z + 0.5, 
                               0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 
                               0.7, 0.7, 0.7, 230, 50, 50, 200, 
                               false, false, 2, nil, nil, false)
                               
                    -- Right Boundary Pin (Green)
                    DrawMarker(4, cp.right.x, cp.right.y, cp.right.z + 0.5, 
                               0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 
                               0.7, 0.7, 0.7, 50, 230, 50, 200, 
                               false, false, 2, nil, nil, false)
                    
                    -- Width connection line
                    DrawLine(cp.left.x, cp.left.y, cp.left.z, 
                             cp.right.x, cp.right.y, cp.right.z, 
                             r, g, b, 255)
                             
                    -- Sequential track routing line
                    if editCheckpoints[i + 1] then
                        local nextCp = editCheckpoints[i + 1]
                        DrawLine(cp.coords.x, cp.coords.y, cp.coords.z, 
                                 nextCp.coords.x, nextCp.coords.y, nextCp.coords.z, 
                                 255, 255, 255, isSelected and 180 or 80)
                    end
                    
                    -- 3D Text Floating above checkpoint gate
                    local label = string.format("Gate #%d\nWidth: %.1fm", i, cp.radius)
                    if isSelected then
                        label = string.format("~p~ACTIVE GATE #%d~s~\nWidth: %.1fm\nHeading: %d°", i, cp.radius, math.floor(cp.heading))
                    end
                    DrawText3D(cp.coords.x, cp.coords.y, cp.coords.z + (isSelected and 2.5 or 1.5), label, isSelected)
                end
            end
            Wait(0)
        else
            Wait(1000)
        end
    end
end)
