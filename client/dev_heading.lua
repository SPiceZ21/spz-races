-- client/dev_heading.lua
-- LOCAL DEV TOOL — walk every track, align the start heading, save to file.
--
-- Controls (while active):
--   [↑] / [↓]   next / prev track
--   [G]         auto-face the next checkpoint  + save   (fixes most tracks)
--   [E]         capture your current facing    + save   (manual align)
--   [ / ]       nudge heading -1° / +1°
--   [ENTER]     save current heading
--   [BACKSPACE] exit tool
--
-- Start:  /fixheadings

local active   = false
local tracks   = {}
local idx      = 1
local curHead  = 0.0

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function _ent()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and veh or ped
end

-- GTA heading (0 = +Y / north) from A → B
local function _headingTo(from, to)
    local dx = to.x - from.x
    local dy = to.y - from.y
    local h  = math.deg(math.atan2(-dx, dy))
    if h < 0 then h = h + 360.0 end
    return h
end

local function _apply(head)
    curHead = head % 360.0
    SetEntityHeading(_ent(), curHead)
end

local function _goto(i)
    local t = tracks[i]
    if not t then return end
    idx = i
    local e = _ent()
    SetEntityCoords(e, t.start.x, t.start.y, t.start.z + 1.0, false, false, false, true)
    _apply(t.heading or 0.0)
    lib.notify({
        description = ("[%d/%d] %s (%s)"):format(i, #tracks, t.name, t.type),
        type = "inform",
        duration = 2500,
    })
end

local function _save()
    local t = tracks[idx]
    if not t then return end
    t.heading = curHead
    TriggerServerEvent("spz-dev:saveHeading", t.id, curHead)
end

local function _drawText3D(x, y, z, text, r, g, b)
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    SetTextScale(0.0, 0.4)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(r, g, b, 235)
    SetTextDropShadow()
    SetTextOutline()
    SetTextCentre(true)
    SetTextEntry("STRING")
    AddTextComponentString(text)
    DrawText(sx, sy)
end

-- ── Command ───────────────────────────────────────────────────────────────────
RegisterCommand("fixheadings", function()
    TriggerServerEvent("spz-dev:reqTracks")
end, false)

RegisterNetEvent("spz-dev:tracks", function(list)
    if not list or #list == 0 then
        lib.notify({ description = "No tracks returned.", type = "error" })
        return
    end
    tracks = list
    active = true
    _goto(1)
end)

-- ── Main loop ─────────────────────────────────────────────────────────────────
CreateThread(function()
    while true do
        if active then
            local t = tracks[idx]
            if t then
                local start  = vector3(t.start.x, t.start.y, t.start.z)
                local nextCp = vector3(t.nextCp.x, t.nextCp.y, t.nextCp.z)
                local toCp   = _headingTo(start, nextCp)

                -- Start point marker (green)
                DrawMarker(1, start.x, start.y, start.z - 1.0, 0,0,0, 0,0,0,
                    2.0, 2.0, 2.5, 40, 220, 90, 120, false, false, 2, false, nil, nil, false)
                _drawText3D(start.x, start.y, start.z + 1.4, "START", 40, 220, 90)

                -- Next CP marker (orange) + line
                DrawMarker(1, nextCp.x, nextCp.y, nextCp.z - 1.0, 0,0,0, 0,0,0,
                    2.0, 2.0, 4.0, 255, 98, 0, 130, false, false, 2, false, nil, nil, false)
                _drawText3D(nextCp.x, nextCp.y, nextCp.z + 1.6, "NEXT CP", 255, 98, 0)
                DrawLine(start.x, start.y, start.z, nextCp.x, nextCp.y, nextCp.z, 255, 98, 0, 200)

                -- Facing arrow from start along current heading (blue)
                local rad = math.rad(curHead)
                local fx  = start.x - math.sin(rad) * 8.0
                local fy  = start.y + math.cos(rad) * 8.0
                DrawLine(start.x, start.y, start.z + 0.5, fx, fy, start.z + 0.5, 0, 160, 255, 255)
                _drawText3D(fx, fy, start.z + 0.8, "FACING", 0, 160, 255)

                -- HUD
                SetTextFont(4); SetTextScale(0.42, 0.42); SetTextColour(255,255,255,255)
                SetTextDropShadow(); SetTextEntry("STRING")
                AddTextComponentString(
                    ("~y~HEADING FIXER~s~  [%d/%d]  ~b~%s~s~\n"):format(idx, #tracks, t.name)
                    .. ("Current: ~y~%.2f°~s~   Face-CP: ~o~%.2f°~s~\n"):format(curHead, toCp)
                    .. "~g~[G]~s~ Face CP+Save   ~g~[E]~s~ Capture+Save   ~g~[ / ]~s~ Nudge\n"
                    .. "~g~[↑/↓]~s~ Track   ~y~[ENTER]~s~ Save   ~r~[BACKSPACE]~s~ Exit")
                DrawText(0.35, 0.02)

                -- ── Inputs ──
                if IsControlJustPressed(0, 172) then _goto((idx % #tracks) + 1) end            -- ↑ next
                if IsControlJustPressed(0, 173) then _goto(idx > 1 and idx - 1 or #tracks) end  -- ↓ prev

                if IsControlJustPressed(0, 58) then      -- [G] auto-face CP + save
                    _apply(toCp); _save()
                end
                if IsControlJustPressed(0, 38) then      -- [E] capture current facing + save
                    _apply(GetEntityHeading(_ent())); _save()
                end
                if IsControlJustPressed(0, 39) then _apply(curHead - 1.0) end   -- [ nudge -
                if IsControlJustPressed(0, 40) then _apply(curHead + 1.0) end   -- ] nudge +
                if IsControlJustPressed(0, 18) then _save() end                 -- ENTER save
                if IsControlJustPressed(0, 177) then                           -- BACKSPACE exit
                    active = false
                    lib.notify({ description = "Heading fixer closed.", type = "inform" })
                end
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)
