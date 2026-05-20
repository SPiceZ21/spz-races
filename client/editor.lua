-- client/editor.lua
-- SPZ Track Editor — fine-tune any existing track in-world

local SPZ = nil
CreateThread(function()
    while not SPZ do
        pcall(function() SPZ = exports["spz-lib"]:GetCoreObject() end)
        if not SPZ then Wait(500) end
    end
end)

local editorActive    = false
local editTrackId     = ""
local editTrackName   = ""
local editTrackType   = "circuit"
local editTrackLaps   = 3
local editCheckpoints = {}
local selectedIndex   = 1
local previewMode     = false  -- P: test-drive the route without HUD

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function Notify(msg, t)
    exports["spz-lib"]:Notify(msg, t or "info")
end

local function RecalcGate(cp)
    local rad  = math.rad(cp.heading + 90.0)
    local half = cp.radius / 2
    cp.left  = cp.coords + vector3(math.cos(rad) * half, math.sin(rad) * half, 0.0)
    cp.right = cp.coords - vector3(math.cos(rad) * half, math.sin(rad) * half, 0.0)
end

local function DrawText3D(x, y, z, text, isSelected)
    local onScreen, sx, sy = GetScreenCoordFrom3dCoords(x, y, z)
    if not onScreen then return end
    SetTextScale(0.3, 0.3)
    SetTextFont(4)
    SetTextProportional(1)
    if isSelected then SetTextColour(255, 0, 255, 255)
    else           SetTextColour(255, 255, 255, 210)
    end
    SetTextEntry("STRING")
    SetTextCentre(1)
    AddTextComponentString(text)
    DrawText(sx, sy)
    local factor = (#text) / 400
    if isSelected then
        DrawRect(sx, sy + 0.012, 0.012 + factor, 0.025, 255, 0, 255, 40)
    else
        DrawRect(sx, sy + 0.012, 0.012 + factor, 0.025, 0, 0, 0, 90)
    end
end

local function GetTargetEntity()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and veh or ped
end

-- ── Compile & send save ───────────────────────────────────────────────────────

local function CommitSave()
    local clean = {}
    for _, cp in ipairs(editCheckpoints) do
        table.insert(clean, {
            coords  = { x = cp.coords.x,  y = cp.coords.y,  z = cp.coords.z  },
            left    = { x = cp.left.x,    y = cp.left.y,    z = cp.left.z    },
            right   = { x = cp.right.x,   y = cp.right.y,   z = cp.right.z   },
            heading = cp.heading,
            radius  = cp.radius,
        })
    end

    -- Pass editTrackId so server overwrites the correct entry, not creates new
    TriggerServerEvent("SPZ:saveCustomTrack", {
        id          = editTrackId,  -- explicit overwrite key
        name        = editTrackName,
        type        = editTrackType,
        laps        = editTrackLaps,
        checkpoints = clean,
    })

    editorActive    = false
    editCheckpoints = {}
    previewMode     = false
    PlaySoundFrontend(-1, "Save_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
    Notify(("Track '%s' saved (%d gates)"):format(editTrackName, #clean), "success")
end

-- ── Start editor ──────────────────────────────────────────────────────────────

RegisterNetEvent("SPZ:startTrackEditor", function(data)
    if not data or not data.id then
        Notify("Invalid track ID.", "error")
        return
    end

    if not SPZ then
        Notify("SPZ core not ready — try again.", "error")
        return
    end

    SPZ.Callbacks.Trigger("spz-races:getTrackDetails", { id = data.id }, function(track)
        if not track then
            Notify("Failed to fetch track details.", "error")
            return
        end

        editTrackId    = track.id
        editTrackName  = track.name
        editTrackType  = track.type  or "circuit"
        editTrackLaps  = track.laps  or 3
        editCheckpoints = {}

        for _, cp in ipairs(track.checkpoints) do
            local item = {
                coords  = vector3(cp.coords.x, cp.coords.y, cp.coords.z),
                heading = cp.heading or 0.0,
                radius  = cp.radius  or 10.0,
            }
            if cp.heading then
                RecalcGate(item)
            else
                item.left  = vector3(cp.left.x,  cp.left.y,  cp.left.z)
                item.right = vector3(cp.right.x, cp.right.y, cp.right.z)
                local dir  = item.right - item.left
                item.heading = math.deg(math.atan2(dir.y, dir.x)) - 90.0
            end
            table.insert(editCheckpoints, item)
        end

        editorActive  = true
        selectedIndex = 1
        previewMode   = false

        TriggerEvent("spz-tablet:closeTablet")
        Notify(("Editor: '%s' — %d gates loaded"):format(editTrackName, #editCheckpoints), "success")
    end)
end)

-- ── Command shortcut ──────────────────────────────────────────────────────────

RegisterCommand("trackeditor", function(_, args)
    local trackId = args[1]
    if not trackId then
        Notify("Usage: /trackeditor <trackId>", "error")
        return
    end
    TriggerEvent("SPZ:startTrackEditor", { id = trackId })
end, false)

-- ── Main editor loop ──────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if editorActive then
            Wait(0)
            local ent      = GetTargetEntity()
            local myCoords = GetEntityCoords(ent)
            local cp       = editCheckpoints[selectedIndex]

            if not previewMode then
                -- ── Inputs ───────────────────────────────────────────────────

                -- Arrow UP — next gate
                if IsControlJustPressed(0, 172) then
                    selectedIndex = (selectedIndex % #editCheckpoints) + 1
                    PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                end

                -- Arrow DOWN — prev gate
                if IsControlJustPressed(0, 173) then
                    selectedIndex = selectedIndex - 1
                    if selectedIndex < 1 then selectedIndex = #editCheckpoints end
                    PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                end

                -- [E] — Move selected gate to player
                if IsControlJustPressed(0, 38) and cp then
                    cp.coords  = myCoords
                    cp.heading = GetEntityHeading(ent)
                    RecalcGate(cp)
                    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                    Notify(("Gate #%d moved"):format(selectedIndex), "success")
                end

                -- [R] — Match heading only
                if IsControlJustPressed(0, 45) and cp then
                    cp.heading = GetEntityHeading(ent)
                    RecalcGate(cp)
                    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                    Notify(("Gate #%d heading matched"):format(selectedIndex), "success")
                end

                -- [PageUp] — Widen gate
                if IsControlJustPressed(0, 10) and cp then
                    cp.radius = math.min(40.0, cp.radius + 0.5)
                    RecalcGate(cp)
                    PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                end

                -- [PageDown] — Narrow gate
                if IsControlJustPressed(0, 11) and cp then
                    cp.radius = math.max(3.0, cp.radius - 0.5)
                    RecalcGate(cp)
                    PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                end

                -- [INSERT] — Insert new gate after selected
                if IsControlJustPressed(0, 121) then
                    local head = GetEntityHeading(ent)
                    local newCP = { coords = myCoords, heading = head, radius = 10.0 }
                    RecalcGate(newCP)
                    table.insert(editCheckpoints, selectedIndex + 1, newCP)
                    selectedIndex = selectedIndex + 1
                    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", 1)
                    Notify(("Inserted gate after #%d"):format(selectedIndex - 1), "success")
                end

                -- [DELETE] — Delete selected gate
                if IsControlJustPressed(0, 178) then
                    if #editCheckpoints > 2 then
                        table.remove(editCheckpoints, selectedIndex)
                        if selectedIndex > #editCheckpoints then selectedIndex = #editCheckpoints end
                        PlaySoundFrontend(-1, "PROP_DROP_RED", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                        Notify("Gate deleted", "warning")
                    else
                        Notify("Min 2 gates required", "error")
                    end
                end

                -- [+] / [=] — Laps up (circuit only)
                if IsControlJustPressed(0, 97) and editTrackType == "circuit" then
                    editTrackLaps = math.min(10, editTrackLaps + 1)
                    Notify(("Laps: %d"):format(editTrackLaps), "info")
                end

                -- [-] — Laps down
                if IsControlJustPressed(0, 109) and editTrackType == "circuit" then
                    editTrackLaps = math.max(1, editTrackLaps - 1)
                    Notify(("Laps: %d"):format(editTrackLaps), "info")
                end

                -- [P] — Toggle preview mode
                if IsControlJustPressed(0, 57) then -- P
                    previewMode = true
                    DisplayHud(true)
                    Notify("Preview mode — drive the route. [P] to return to editing.", "info")
                end

                -- [ENTER] — Save
                if IsControlJustPressed(0, 18) then
                    CommitSave()
                end

                -- [BACKSPACE] — Cancel
                if IsControlJustPressed(0, 177) then
                    editorActive    = false
                    editCheckpoints = {}
                    previewMode     = false
                    PlaySoundFrontend(-1, "QUIT_WHOOSH", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                    Notify("Editor canceled — changes discarded.", "error")
                end

                -- ── HUD ──────────────────────────────────────────────────────
                SetTextComponentFormat("STRING")
                AddTextComponentString(
                    ("~y~EDITOR — %s~s~  [%s]\n"):format(editTrackName, editTrackType:upper())
                    .. ("Gate: ~p~#%d~s~ / %d   Width: ~g~%.1fm~s~"):format(
                            selectedIndex, #editCheckpoints, cp and cp.radius or 0.0)
                    .. (editTrackType == "circuit" and ("   Laps: ~b~%d~s~"):format(editTrackLaps) or "")
                    .. "\n\n"
                    .. "~g~[↑/↓]~s~ Cycle   ~g~[E]~s~ Move   ~g~[R]~s~ Heading\n"
                    .. "~g~[PgUp/Dn]~s~ Width   ~g~[+/-]~s~ Laps   ~g~[INS]~s~ Insert   ~r~[DEL]~s~ Delete\n"
                    .. "~b~[P]~s~ Preview   ~y~[ENTER]~s~ Save   ~r~[BACKSPACE]~s~ Cancel"
                )
                EndTextCommandDisplayHelp(0, 0, 1, -1)

            else
                -- ── Preview mode — minimal HUD, just "return" hint ────────────
                SetTextComponentFormat("STRING")
                AddTextComponentString("~b~PREVIEW MODE~s~ — ~g~[P]~s~ back to editor   ~y~[ENTER]~s~ save now")
                EndTextCommandDisplayHelp(0, 0, 1, -1)

                if IsControlJustPressed(0, 57) then
                    previewMode = false
                    Notify("Back in editor mode.", "info")
                end

                if IsControlJustPressed(0, 18) then
                    CommitSave()
                end

                if IsControlJustPressed(0, 177) then
                    editorActive    = false
                    editCheckpoints = {}
                    previewMode     = false
                    Notify("Editor canceled.", "error")
                end
            end

            -- ── 3D route rendering (always, even in preview) ─────────────────
            for i, gate in ipairs(editCheckpoints) do
                local dist       = #(myCoords - gate.coords)
                if dist < 160.0 then
                    local isSel  = (not previewMode) and (i == selectedIndex)
                    local r, g, b = 255, 98, 0
                    if isSel then r, g, b = 255, 0, 255 end

                    -- Center pillar
                    DrawMarker(1,
                        gate.coords.x, gate.coords.y, gate.coords.z - 1.0,
                        0,0,0,0,0,0,
                        1.0, 1.0, isSel and 4.5 or 2.0,
                        r, g, b, 130,
                        false, false, 2, nil, nil, false)

                    -- Left pin
                    DrawMarker(4,
                        gate.left.x, gate.left.y, gate.left.z + 0.5,
                        0,0,0,0,0,0, 0.7,0.7,0.7, 230,50,50,200,
                        false,false,2,nil,nil,false)

                    -- Right pin
                    DrawMarker(4,
                        gate.right.x, gate.right.y, gate.right.z + 0.5,
                        0,0,0,0,0,0, 0.7,0.7,0.7, 50,230,50,200,
                        false,false,2,nil,nil,false)

                    -- Gate span line
                    DrawLine(gate.left.x, gate.left.y, gate.left.z,
                             gate.right.x, gate.right.y, gate.right.z,
                             r, g, b, 255)

                    -- Route line to next gate
                    if editCheckpoints[i + 1] then
                        local nxt = editCheckpoints[i + 1]
                        DrawLine(gate.coords.x, gate.coords.y, gate.coords.z,
                                 nxt.coords.x,  nxt.coords.y,  nxt.coords.z,
                                 255, 255, 255, isSel and 180 or 70)
                    end

                    -- Circuit close-loop (last → first)
                    if editTrackType == "circuit" and i == #editCheckpoints and editCheckpoints[1] then
                        local f = editCheckpoints[1]
                        DrawLine(gate.coords.x, gate.coords.y, gate.coords.z,
                                 f.coords.x,   f.coords.y,   f.coords.z,
                                 255, 220, 0, 90)
                    end

                    -- 3D label
                    if not previewMode then
                        local lbl = isSel
                            and ("~p~#%d SELECTED~s~\n%.1fm  %d°"):format(i, gate.radius, math.floor(gate.heading))
                            or  ("#%d\n%.1fm"):format(i, gate.radius)
                        DrawText3D(gate.coords.x, gate.coords.y, gate.coords.z + (isSel and 3.0 or 2.0), lbl, isSel)
                    end
                end
            end

        else
            Wait(500)
        end
    end
end)
