-- client/creator.lua
-- SPZ Track Creator — full in-game route creation tool

local creatorActive = false
local checkpoints   = {}
local trackMeta     = { name = "Custom Track", type = "circuit", laps = 3 }
local defaultWidth  = 10.0

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function CalcGate(coords, heading, radius)
    local rad   = math.rad(heading + 90.0)
    local half  = radius / 2
    local left  = coords + vector3(math.cos(rad) * half, math.sin(rad) * half, 0.0)
    local right = coords - vector3(math.cos(rad) * half, math.sin(rad) * half, 0.0)
    return left, right
end

local function GetTargetEntity()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and veh or ped
end

local function Notify(msg, t)
    exports["spz-lib"]:Notify(msg, t or "info")
end

local function DrawText3D(x, y, z, text, col)
    local onScreen, sx, sy = GetScreenCoordFrom3dCoords(x, y, z)
    if not onScreen then return end
    SetTextScale(0.3, 0.3)
    SetTextFont(4)
    SetTextProportional(1)
    local r, g, b = table.unpack(col or {255, 255, 255})
    SetTextColour(r, g, b, 255)
    SetTextEntry("STRING")
    SetTextCentre(1)
    AddTextComponentString(text)
    DrawText(sx, sy)
    local factor = (#text) / 400
    DrawRect(sx, sy + 0.012, 0.012 + factor, 0.025, 0, 0, 0, 100)
end

-- ── Start/Stop ────────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:startTrackCreator", function(data)
    creatorActive     = true
    checkpoints       = {}
    trackMeta.name    = data and data.name  or "Custom Track"
    trackMeta.type    = data and data.type  or "circuit"
    trackMeta.laps    = data and data.laps  or 3
    defaultWidth      = data and tonumber(data.defaultWidth) or 10.0

    FreezeEntityPosition(PlayerPedId(), false)
    DisplayHud(true)
    Notify("Track Creator active — get in a vehicle and start placing gates!", "success")
    print(("^2[Creator] Started: %s (%s)^7"):format(trackMeta.name, trackMeta.type))
end)

-- ── Exports (called from tablet NUI bridge) ───────────────────────────────────

exports("AddTrackCheckpoint", function(width, heading)
    if not creatorActive then return false, 0 end
    local ent   = GetTargetEntity()
    local pos   = GetEntityCoords(ent)
    local head  = tonumber(heading) or GetEntityHeading(ent)
    local w     = tonumber(width) or defaultWidth
    local left, right = CalcGate(pos, head, w)

    table.insert(checkpoints, {
        coords  = pos,
        heading = head,
        radius  = w,
        left    = left,
        right   = right,
    })

    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
    Notify(("Gate #%d placed"):format(#checkpoints), "success")
    return true, #checkpoints
end)

exports("DeleteLastCheckpoint", function()
    if not creatorActive or #checkpoints == 0 then return false, 0 end
    table.remove(checkpoints)
    PlaySoundFrontend(-1, "PROP_DROP_RED", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
    Notify(("Gate removed — %d remaining"):format(#checkpoints), "warning")
    return true, #checkpoints
end)

exports("CancelTrackCreator", function()
    creatorActive = false
    checkpoints   = {}
    Notify("Track creation canceled.", "error")
    return true
end)

exports("SaveTrack", function(name, type, cb)
    if not creatorActive then
        if cb then cb(false, "Creator not active") end
        return
    end
    if #checkpoints < 2 then
        Notify("Need at least 2 gates to save!", "error")
        if cb then cb(false, "Too few checkpoints") end
        return
    end

    local tName = name or trackMeta.name
    local tType = type or trackMeta.type
    local tLaps = trackMeta.laps

    local clean = {}
    for _, cp in ipairs(checkpoints) do
        table.insert(clean, {
            coords  = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
            left    = { x = cp.left.x,   y = cp.left.y,   z = cp.left.z   },
            right   = { x = cp.right.x,  y = cp.right.y,  z = cp.right.z  },
            heading = cp.heading,
            radius  = cp.radius,
        })
    end

    TriggerServerEvent("SPZ:saveCustomTrack", {
        name        = tName,
        type        = tType,
        laps        = tLaps,
        checkpoints = clean,
    })

    creatorActive = false
    checkpoints   = {}
    if cb then cb(true) end
end)

-- ── Keyboard-driven in-world controls ────────────────────────────────────────
-- (Works WITHOUT the tablet open — full standalone tool)

CreateThread(function()
    while true do
        if creatorActive then
            Wait(0)
            local ent      = GetTargetEntity()
            local myCoords = GetEntityCoords(ent)

            -- [E] — Place gate at current position
            if IsControlJustPressed(0, 38) then
                local head  = GetEntityHeading(ent)
                local left, right = CalcGate(myCoords, head, defaultWidth)
                table.insert(checkpoints, {
                    coords  = myCoords,
                    heading = head,
                    radius  = defaultWidth,
                    left    = left,
                    right   = right,
                })
                PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                Notify(("Gate #%d placed"):format(#checkpoints), "success")
            end

            -- [BACKSPACE] — Remove last gate
            if IsControlJustPressed(0, 177) then
                if #checkpoints > 0 then
                    table.remove(checkpoints)
                    PlaySoundFrontend(-1, "PROP_DROP_RED", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                    Notify(("Gate removed — %d remaining"):format(#checkpoints), "warning")
                end
            end

            -- [PageUp] — Widen default width
            if IsControlJustPressed(0, 10) then
                defaultWidth = math.min(40.0, defaultWidth + 1.0)
                Notify(("Gate width: %.1fm"):format(defaultWidth), "info")
            end

            -- [PageDown] — Narrow default width
            if IsControlJustPressed(0, 11) then
                defaultWidth = math.max(3.0, defaultWidth - 1.0)
                Notify(("Gate width: %.1fm"):format(defaultWidth), "info")
            end

            -- [+] / [=] — Increase laps (circuit only)
            if IsControlJustPressed(0, 97) and trackMeta.type == "circuit" then
                trackMeta.laps = math.min(10, trackMeta.laps + 1)
                Notify(("Laps: %d"):format(trackMeta.laps), "info")
            end

            -- [-] — Decrease laps
            if IsControlJustPressed(0, 109) and trackMeta.type == "circuit" then
                trackMeta.laps = math.max(1, trackMeta.laps - 1)
                Notify(("Laps: %d"):format(trackMeta.laps), "info")
            end

            -- [ENTER] — Save track
            if IsControlJustPressed(0, 18) then
                if #checkpoints >= 2 then
                    local clean = {}
                    for _, cp in ipairs(checkpoints) do
                        table.insert(clean, {
                            coords  = { x = cp.coords.x, y = cp.coords.y, z = cp.coords.z },
                            left    = { x = cp.left.x,   y = cp.left.y,   z = cp.left.z   },
                            right   = { x = cp.right.x,  y = cp.right.y,  z = cp.right.z  },
                            heading = cp.heading,
                            radius  = cp.radius,
                        })
                    end
                    TriggerServerEvent("SPZ:saveCustomTrack", {
                        name        = trackMeta.name,
                        type        = trackMeta.type,
                        laps        = trackMeta.laps,
                        checkpoints = clean,
                    })
                    creatorActive = false
                    checkpoints   = {}
                    PlaySoundFrontend(-1, "Save_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                    TriggerEvent("spz-races:creatorDone")
                else
                    Notify("Need at least 2 gates to save!", "error")
                end
            end

            -- [DELETE] — Cancel entirely
            if IsControlJustPressed(0, 178) then
                creatorActive = false
                checkpoints   = {}
                Notify("Track creation canceled.", "error")
                TriggerEvent("spz-races:creatorDone")
            end

            -- ── HUD ─────────────────────────────────────────────────────────
            SetTextComponentFormat("STRING")
            AddTextComponentString(
                ("~y~TRACK CREATOR — %s~s~ [%s]\n"):format(trackMeta.name, trackMeta.type:upper())
                .. ("Gates placed: ~p~%d~s~   Width: ~g~%.1fm~s~"):format(#checkpoints, defaultWidth)
                .. (trackMeta.type == "circuit" and ("   Laps: ~b~%d~s~"):format(trackMeta.laps) or "")
                .. "\n\n"
                .. "~g~[E]~s~ Place Gate   ~g~[BACKSPACE]~s~ Undo Last\n"
                .. "~g~[PageUp/Down]~s~ Width   ~g~[+/-]~s~ Laps (circuit)\n"
                .. "~y~[ENTER]~s~ Save Track   ~r~[DELETE]~s~ Cancel"
            )
            EndTextCommandDisplayHelp(0, 0, 1, -1)

            -- ── 3D visualizer ────────────────────────────────────────────────
            for i, cp in ipairs(checkpoints) do
                local dist = #(myCoords - cp.coords)
                if dist < 150.0 then
                    local isLast = (i == #checkpoints)
                    local r, g, b = 255, 98, 0
                    if isLast then r, g, b = 0, 220, 255 end -- cyan = latest gate

                    -- Center pillar
                    DrawMarker(1,
                        cp.coords.x, cp.coords.y, cp.coords.z - 1.0,
                        0, 0, 0, 0, 0, 0,
                        1.2, 1.2, isLast and 3.5 or 2.0,
                        r, g, b, 140,
                        false, false, 2, nil, nil, false)

                    -- Left pin (red)
                    DrawMarker(4, cp.left.x, cp.left.y, cp.left.z + 0.5,
                        0,0,0,0,0,0, 0.8,0.8,0.8, 230,50,50,200,
                        false,false,2,nil,nil,false)

                    -- Right pin (green)
                    DrawMarker(4, cp.right.x, cp.right.y, cp.right.z + 0.5,
                        0,0,0,0,0,0, 0.8,0.8,0.8, 50,230,50,200,
                        false,false,2,nil,nil,false)

                    -- Gate span line
                    DrawLine(cp.left.x, cp.left.y, cp.left.z,
                             cp.right.x, cp.right.y, cp.right.z,
                             r, g, b, 255)

                    -- Route line to next gate
                    if checkpoints[i + 1] then
                        local n = checkpoints[i + 1]
                        DrawLine(cp.coords.x, cp.coords.y, cp.coords.z,
                                 n.coords.x, n.coords.y, n.coords.z,
                                 255, 255, 255, 80)
                    end

                    -- Circuit close-loop line (last → first, dashed effect via color)
                    if trackMeta.type == "circuit" and i == #checkpoints and checkpoints[1] then
                        local f = checkpoints[1]
                        DrawLine(cp.coords.x, cp.coords.y, cp.coords.z,
                                 f.coords.x, f.coords.y, f.coords.z,
                                 255, 220, 0, 100)
                    end

                    -- Gate label
                    DrawText3D(
                        cp.coords.x, cp.coords.y, cp.coords.z + (isLast and 2.8 or 1.8),
                        isLast and ("~b~Gate #%d (Latest)~s~\n%.1fm"):format(i, cp.radius)
                              or  ("Gate #%d\n%.1fm"):format(i, cp.radius),
                        isLast and {0, 220, 255} or {255, 255, 255}
                    )
                end
            end

        else
            Wait(500)
        end
    end
end)

-- ── Command shortcut ──────────────────────────────────────────────────────────

RegisterCommand("trackcreator", function()
    if creatorActive then
        Notify("Creator already active!", "warning")
        return
    end
    TriggerEvent("SPZ:startTrackCreator", {
        name  = "Custom_" .. GetGameTimer(),
        type  = "circuit",
        laps  = 3,
    })
end, false)

RegisterCommand("tracktype", function(_, args)
    if not creatorActive then return end
    local t = args[1]
    if t == "circuit" or t == "sprint" then
        trackMeta.type = t
        if t == "sprint" then trackMeta.laps = 1 end
        Notify("Track type set: " .. t, "info")
    else
        Notify("Usage: /tracktype circuit|sprint", "error")
    end
end, false)

RegisterCommand("trackname", function(_, args)
    if not creatorActive then return end
    trackMeta.name = table.concat(args, " ")
    Notify("Track name: " .. trackMeta.name, "info")
end, false)
