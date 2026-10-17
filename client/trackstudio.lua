-- client/trackstudio.lua — Track Studio: build and edit race tracks in the 3D world.
--
-- Replaces the old creator.lua + editor.lua. Opened from the admin menu
-- (spz-admin → Tracks) through the same events they used:
--   SPZ:startTrackCreator { name, type, laps, defaultWidth }   new track
--   SPZ:startTrackEditor  { id }                               existing track
-- and saved through the same server event (SPZ:saveCustomTrack), so the
-- server side is unchanged.
--
-- Two modes, toggled with P (not F: exit-vehicle; not F3: raceline panel):
--   DRIVE  — drive the route; E drops a gate where your car is (the old maker).
--   CAMERA — free-fly camera with a mouse cursor. Hover a gate to highlight it,
--            click to select, drag the centre to move it on the ground, drag a
--            post to reshape it (width + angle follow the posts). Wheel = width,
--            Ctrl+Wheel = rotate, Shift+Wheel = height. E places a gate at the
--            cursor after the selected one.
--
-- Every key is a RegisterKeyMapping command (rebindable in GTA settings), so
-- they work in a car or on foot and never collide with right-click / ESC.
-- The old tools read raw control ids, several of which were wrong ([P] was
-- F10, "Backspace" also fired on right-click and ESC, E did not fire in cars).

local active      = false
local mode        = "drive"      -- "drive" | "camera"
local gates       = {}           -- { coords, heading, radius, left, right }
local meta        = { id = nil, name = "Custom Track", type = "circuit", laps = 3 }
local defaultWidth = 12.0
local sel         = 0            -- selected gate index (0 = none)
local hover       = nil          -- { i, part = "c"|"l"|"r" }
local drag        = nil          -- { i, part }
local history     = {}           -- undo snapshots
local cam         = nil
local camRot      = vector3(-25.0, 0.0, 0.0)

local MAX_UNDO = 50

-- ── helpers ──────────────────────────────────────────────────────────────────

local function notify(msg, t) lib.notify({ title = "Track Studio", description = msg, type = t or "inform" }) end

local function recalc(g)
    local rad  = math.rad(g.heading + 90.0)
    local half = g.radius / 2
    local off  = vector3(math.cos(rad) * half, math.sin(rad) * half, 0.0)
    g.left, g.right = g.coords + off, g.coords - off
end

-- rebuild centre / width / heading from the two posts (post drag)
local function fromPosts(g)
    local d = g.left - g.right
    g.coords  = (g.left + g.right) / 2
    g.radius  = math.max(3.0, math.min(60.0, #(vector2(d.x, d.y))))
    g.heading = (math.deg(math.atan(d.y, d.x)) - 90.0) % 360.0
    recalc(g)
end

local function newGate(pos, heading, width)
    local g = { coords = pos, heading = heading % 360.0, radius = width }
    recalc(g)
    return g
end

local function snapshot()
    local copy = {}
    for i, g in ipairs(gates) do
        copy[i] = { coords = g.coords, heading = g.heading, radius = g.radius }
    end
    history[#history + 1] = { gates = copy, sel = sel }
    if #history > MAX_UNDO then table.remove(history, 1) end
end

local function undo()
    local h = table.remove(history)
    if not h then return notify("Nothing to undo", "error") end
    gates = {}
    for i, g in ipairs(h.gates) do gates[i] = newGate(g.coords, g.heading, g.radius) end
    sel = math.min(h.sel, #gates)
    PlaySoundFrontend(-1, "BACK", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
end

local function groundZ(p)
    local ok, z = GetGroundZFor_3dCoord(p.x, p.y, p.z + 3.0, false)
    return ok and z or nil
end

local function targetEnt()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and veh or ped
end

-- ── camera ───────────────────────────────────────────────────────────────────

local function rotToDir(r)
    local z, x = math.rad(r.z), math.rad(r.x)
    return vector3(-math.sin(z) * math.cos(x), math.cos(z) * math.cos(x), math.sin(x))
end

local function camEnter()
    local ent = targetEnt()
    local p = GetEntityCoords(ent)
    local h = GetEntityHeading(ent)
    camRot = vector3(-35.0, 0.0, h)
    local back = rotToDir(camRot) * -14.0
    cam = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA", p.x + back.x, p.y + back.y, p.z + 10.0,
        camRot.x, camRot.y, camRot.z, 60.0, false, 0)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 400, true, false)
    FreezeEntityPosition(ent, true)
    mode = "camera"
end

local function camExit()
    if cam then
        RenderScriptCams(false, true, 400, true, false)
        DestroyCam(cam, false)
        cam = nil
    end
    FreezeEntityPosition(targetEnt(), false)
    mode = "drive"
    drag, hover = nil, nil
end

-- cursor (0..1) -> world ray from the camera
local function cursorRay()
    local cx, cy = GetDisabledControlNormal(0, 239), GetDisabledControlNormal(0, 240)
    local pos, rot, fov = GetCamCoord(cam), GetCamRot(cam, 2), GetCamFov(cam)
    local fwd = rotToDir(rot)
    local zr = math.rad(rot.z)
    local right = vector3(math.cos(zr), math.sin(zr), 0.0)
    local up = vector3(
        right.y * fwd.z - right.z * fwd.y,
        right.z * fwd.x - right.x * fwd.z,
        right.x * fwd.y - right.y * fwd.x)
    local t = math.tan(math.rad(fov) / 2)
    local x = (cx * 2 - 1) * t * GetAspectRatio(false)
    local y = (1 - cy * 2) * t
    local d = fwd + right * x + up * y
    return pos, d / #d
end

local function rayHit(from, dir)
    local to = from + dir * 1500.0
    local h = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1, PlayerPedId(), 7)
    local _, hit, pos = GetShapeTestResult(h)
    return hit == 1 and pos or nil
end

-- distance from a point to the ray
local function rayDist(from, dir, p)
    local v = p - from
    local t = math.max(0.0, v.x * dir.x + v.y * dir.y + v.z * dir.z)
    return #(v - dir * t), t
end

local function pick(from, dir)
    local best, bd = nil, math.huge
    for i, g in ipairs(gates) do
        for _, part in ipairs({ { "l", g.left }, { "r", g.right }, { "c", g.coords } }) do
            local p = part[2] + vector3(0.0, 0.0, 0.6)
            local d, along = rayDist(from, dir, p)
            local tol = 0.9 + along * 0.012           -- easier to grab far away
            if d < tol and d < bd then best, bd = { i = i, part = part[1] }, d end
        end
    end
    return best
end

-- ── start / stop ─────────────────────────────────────────────────────────────

-- Live key labels: every Track Studio key is a key mapping, so show the
-- player's actual binding (spz-core KeyFor) rather than the default.
local DEFAULTS = { camera = "P", place = "E", delete = "DEL", nextg = "→", prevg = "←", ground = "Y",
                   undo = "U", lapsup = "=", lapsdown = "-", save = "ENTER", cancel = "BKSP" }
-- controller buttons for the actions that make sense on a pad (driving the
-- route and stepping through gates); mouse editing stays keyboard + mouse.
local PADS = { camera = "SELECT_INDEX", place = "RDOWN_INDEX", nextg = "R1_INDEX", prevg = "L1_INDEX", undo = "RLEFT_INDEX" }
local function K(name, default)
    local ok, k = pcall(function() return exports["spz-core"]:KeyFor("+trackstudio_" .. name, default or DEFAULTS[name], PADS[name]) end)
    return (ok and k) or default or DEFAULTS[name]
end

local shownHelp = nil
local function showHelp(force)
    local mouse = mode == "camera"
        and ("**Click** select · **drag** centre = move · **drag post** = reshape  \n"
          .. "**Wheel** width · **Ctrl+Wheel** rotate · **Shift+Wheel** height  \n"
          .. "**WASD** fly · **Space/Q** up/down · **Hold RMB** look")
        or "Drive the route and press **[" .. K("place") .. "]** at each gate"
    local text = table.concat({
        "**TRACK STUDIO** — " .. meta.name .. ("  ·  %d gates"):format(#gates),
        ("**[%s]** %s   **[%s]** place gate"):format(K("camera"), mode == "camera" and "back to driving" or "3D camera", K("place")),
        mouse,
        ("**[%s/%s]** cycle  **[%s]** delete  **[%s]** snap to ground  **[%s]** undo"):format(K("prevg"), K("nextg"), K("delete"), K("ground"), K("undo")),
        ("**[%s/%s]** laps  **[%s]** save  **[%s]** cancel"):format(K("lapsup"), K("lapsdown"), K("save"), K("cancel")),
    }, "  \n")
    if force or text ~= shownHelp then
        shownHelp = text
        lib.showTextUI(text, { position = "left-center", icon = "route" })
    end
end

-- refresh: rebinds, mode switch and gate count show up live
CreateThread(function()
    while true do
        Wait(1500)
        if active then showHelp(false) end
    end
end)

local function start(data, loaded)
    if active then return notify("Track Studio is already open", "error") end
    active, mode, sel, hover, drag, history = true, "drive", 0, nil, nil, {}
    gates = loaded or {}
    meta = {
        id = data.id, name = data.name or "Custom Track",
        type = data.type or "circuit", laps = tonumber(data.laps) or 3,
    }
    defaultWidth = tonumber(data.defaultWidth) or defaultWidth
    if #gates > 0 then sel = 1 end
    showHelp(true)
    notify(("%s — %d gates. Press %s for the 3D camera."):format(meta.name, #gates, K("camera", "P")), "success")
end

local function stop()
    shownHelp = nil
    if mode == "camera" then camExit() end
    active, gates, history, sel, hover, drag = false, {}, {}, 0, nil, nil
    lib.hideTextUI()
end

RegisterNetEvent("SPZ:startTrackCreator", function(data)
    start(data or {}, {})
end)

RegisterNetEvent("SPZ:startTrackEditor", function(data)
    if not data or not data.id then return notify("Invalid track", "error") end
    local track = lib.callback.await("spz-races:getTrackDetails", false, { id = data.id })
    if not track then return notify("Could not load that track", "error") end
    local loaded = {}
    for _, cp in ipairs(track.checkpoints) do
        local c = vector3(cp.coords.x, cp.coords.y, cp.coords.z)
        local g
        if cp.heading then
            g = newGate(c, cp.heading, cp.radius or 10.0)
        else
            g = { left = vector3(cp.left.x, cp.left.y, cp.left.z), right = vector3(cp.right.x, cp.right.y, cp.right.z) }
            fromPosts(g)
        end
        loaded[#loaded + 1] = g
    end
    start({ id = track.id, name = track.name, type = track.type, laps = track.laps }, loaded)
end)

exports("IsTrackStudioActive", function() return active end)
-- kept for spz-admin's "a track tool is already open" check
exports("IsTrackCreatorActive", function() return active end)
exports("IsTrackEditorActive", function() return false end)

-- ── actions (key mappings) ───────────────────────────────────────────────────

local function save()
    if #gates < 2 then return notify("Need at least 2 gates", "error") end
    local clean = {}
    for i, g in ipairs(gates) do
        clean[i] = {
            coords  = { x = g.coords.x, y = g.coords.y, z = g.coords.z },
            left    = { x = g.left.x,   y = g.left.y,   z = g.left.z },
            right   = { x = g.right.x,  y = g.right.y,  z = g.right.z },
            heading = g.heading, radius = g.radius,
        }
    end
    TriggerServerEvent("SPZ:saveCustomTrack", {
        id = meta.id, name = meta.name, type = meta.type,
        laps = meta.type == "sprint" and 1 or meta.laps, checkpoints = clean,
    })
    PlaySoundFrontend(-1, "Save_Prop_Success", "DLC_DHE_PROP_SOUNDS", true)
    stop()
end

local function place()
    local pos, heading
    if mode == "camera" then
        local from, dir = cursorRay()
        local hit = rayHit(from, dir)
        if not hit then return notify("Point the cursor at the ground", "error") end
        pos = hit + vector3(0.0, 0.0, 1.0)
        -- face along the route: from the selected gate towards the new one
        local prev = gates[sel]
        heading = prev and (math.deg(math.atan(pos.y - prev.coords.y, pos.x - prev.coords.x)) - 90.0)
            or camRot.z
    else
        local ent = targetEnt()
        pos, heading = GetEntityCoords(ent), GetEntityHeading(ent)
    end
    snapshot()
    local w = gates[sel] and gates[sel].radius or defaultWidth
    table.insert(gates, sel + 1, newGate(pos, heading, w))
    sel = sel + 1
    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", true)
end

local actions = {
    camera   = { "P",         "Track Studio: camera / drive", function() if mode == "camera" then camExit() else camEnter() end end },
    place    = { "E",         "Track Studio: place gate",     place },
    delete   = { "DELETE",    "Track Studio: delete gate",    function()
        if not gates[sel] then return end
        snapshot(); table.remove(gates, sel); sel = math.min(sel, #gates)
        PlaySoundFrontend(-1, "PROP_DROP_RED", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
    end },
    nextg    = { "RIGHT",     "Track Studio: next gate",      function() if #gates > 0 then sel = sel % #gates + 1 end end },
    prevg    = { "LEFT",      "Track Studio: previous gate",  function() if #gates > 0 then sel = (sel - 2) % #gates + 1 end end },
    ground   = { "Y",         "Track Studio: snap to ground", function()
        local g = gates[sel]; if not g then return end
        local z = groundZ(g.coords); if not z then return end
        snapshot(); g.coords = vector3(g.coords.x, g.coords.y, z + 1.0); recalc(g)
    end },
    undo     = { "U",         "Track Studio: undo",           undo },
    lapsup   = { "EQUALS",    "Track Studio: laps +",         function()
        if meta.type ~= "circuit" then return end
        meta.laps = math.min(20, meta.laps + 1); notify(("Laps: %d"):format(meta.laps))
    end },
    lapsdown = { "MINUS",     "Track Studio: laps -",         function()
        if meta.type ~= "circuit" then return end
        meta.laps = math.max(1, meta.laps - 1); notify(("Laps: %d"):format(meta.laps))
    end },
    save     = { "RETURN",    "Track Studio: save",           save },
    cancel   = { "BACK",      "Track Studio: cancel",         function() notify("Discarded — nothing saved", "error"); stop() end },
}

for name, a in pairs(actions) do
    local cmd = "+trackstudio_" .. name
    RegisterCommand(cmd, function() if active then a[3]() end end, false)
    RegisterCommand("-trackstudio_" .. name, function() end, false)
    RegisterKeyMapping(cmd, a[2], "keyboard", a[1])
    if PADS[name] then RegisterKeyMapping(cmd, a[2] .. " (controller)", "PAD_DIGITALBUTTON", PADS[name]) end
end

-- ── camera mode: fly, look, pick, drag, wheel ────────────────────────────────

CreateThread(function()
    while true do
        if active and mode == "camera" and cam then
            DisableAllControlActions(0)
            EnableControlAction(0, 249, true)            -- push-to-talk stays usable
            SetMouseCursorActiveThisFrame()

            -- look: hold right mouse
            if IsDisabledControlPressed(0, 25) then
                SetMouseCursorSprite(1)
                camRot = vector3(
                    math.max(-89.0, math.min(89.0, camRot.x - GetDisabledControlNormal(0, 2) * 6.0)),
                    0.0, camRot.z - GetDisabledControlNormal(0, 1) * 8.0)
            end

            -- fly: WASD, Space up, Q down, Shift fast
            local speed = (IsDisabledControlPressed(0, 21) and 1.6 or 0.45)
            local fwd = rotToDir(camRot)
            local zr = math.rad(camRot.z)
            local right = vector3(math.cos(zr), math.sin(zr), 0.0)
            local move = vector3(0.0, 0.0, 0.0)
            if IsDisabledControlPressed(0, 32) then move = move + fwd end
            if IsDisabledControlPressed(0, 33) then move = move - fwd end
            if IsDisabledControlPressed(0, 34) then move = move - right end
            if IsDisabledControlPressed(0, 35) then move = move + right end
            if IsDisabledControlPressed(0, 22) then move = move + vector3(0.0, 0.0, 1.0) end
            if IsDisabledControlPressed(0, 44) then move = move - vector3(0.0, 0.0, 1.0) end
            SetCamCoord(cam, GetCamCoord(cam) + move * speed)
            SetCamRot(cam, camRot.x, camRot.y, camRot.z, 2)

            local from, dir = cursorRay()
            if not drag then hover = pick(from, dir) end

            -- click: select + start dragging
            if IsDisabledControlJustPressed(0, 24) then
                if hover then
                    sel = hover.i
                    drag = { i = hover.i, part = hover.part }
                    snapshot()
                    PlaySoundFrontend(-1, "NAV_UP_DOWN", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
                end
            end
            if drag and IsDisabledControlPressed(0, 24) then
                local g = gates[drag.i]
                local hit = g and rayHit(from, dir)
                if hit then
                    local p = hit + vector3(0.0, 0.0, 1.0)
                    if drag.part == "c" then
                        g.coords = p; recalc(g)
                    elseif drag.part == "l" then
                        g.left = vector3(p.x, p.y, g.coords.z); fromPosts(g)
                    else
                        g.right = vector3(p.x, p.y, g.coords.z); fromPosts(g)
                    end
                end
            elseif drag then
                drag = nil
            end

            -- wheel on the selected gate
            local g = gates[sel]
            local up, dn = IsDisabledControlJustPressed(0, 241), IsDisabledControlJustPressed(0, 242)
            if g and (up or dn) then
                local s = up and 1 or -1
                snapshot()
                if IsDisabledControlPressed(0, 36) then          -- Ctrl: rotate
                    g.heading = (g.heading + s * 5.0) % 360.0
                elseif IsDisabledControlPressed(0, 21) then      -- Shift: height
                    g.coords = g.coords + vector3(0.0, 0.0, s * 0.25)
                else                                             -- width
                    g.radius = math.max(3.0, math.min(60.0, g.radius + s * 0.5))
                end
                recalc(g)
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- ── drawing (both modes) ─────────────────────────────────────────────────────

local function label(p, text, r, g, b)
    local on, sx, sy = GetScreenCoordFrom3dCoords(p.x, p.y, p.z)
    if not on then return end
    SetTextScale(0.32, 0.32); SetTextFont(4); SetTextCentre(true)
    SetTextColour(r, g, b, 255); SetTextOutline()
    BeginTextCommandDisplayText("STRING"); AddTextComponentSubstringPlayerName(text); EndTextCommandDisplayText(sx, sy)
end

CreateThread(function()
    while true do
        if active then
            local me = mode == "camera" and cam and GetCamCoord(cam) or GetEntityCoords(targetEnt())
            local n = #gates
            for i, gt in ipairs(gates) do
                if #(me - gt.coords) < 300.0 then
                    local isSel = i == sel
                    local isHov = hover and hover.i == i
                    local r, g, b = 255, 255, 255
                    if i == 1 then r, g, b = 255, 215, 0 end               -- start / finish
                    if isHov then r, g, b = 120, 220, 255 end
                    if isSel then r, g, b = 255, 60, 220 end

                    -- posts (hovered / dragged post glows)
                    for _, side in ipairs({ { gt.left, "l", 230, 60, 60 }, { gt.right, "r", 60, 230, 90 } }) do
                        local p = side[1]
                        local hot = (hover and hover.i == i and hover.part == side[2]) or (drag and drag.i == i and drag.part == side[2])
                        DrawMarker(1, p.x, p.y, p.z - 1.0, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 3.2,
                            side[3], side[4], side[5], hot and 255 or 170, false, false, 2, false, nil, nil, false)
                        if isSel or hot then
                            DrawMarker(28, p.x, p.y, p.z + 0.6, 0, 0, 0, 0, 0, 0, 0.45, 0.45, 0.45,
                                255, 255, 255, hot and 230 or 120, false, false, 2, false, nil, nil, false)
                        end
                    end
                    -- gate line + direction arrow
                    DrawLine(gt.left.x, gt.left.y, gt.left.z + 1.5, gt.right.x, gt.right.y, gt.right.z + 1.5, r, g, b, 255)
                    DrawMarker(22, gt.coords.x, gt.coords.y, gt.coords.z + 0.6, 0, 0, 0,
                        -90.0, 0.0, -gt.heading, 1.4, 1.4, 1.4, r, g, b, isSel and 230 or 150, false, false, 2, false, nil, nil, false)
                    -- route line
                    local nx = gates[i + 1] or (meta.type == "circuit" and n > 2 and gates[1])
                    if nx then
                        DrawLine(gt.coords.x, gt.coords.y, gt.coords.z + 0.3, nx.coords.x, nx.coords.y, nx.coords.z + 0.3,
                            255, 255, 255, i == n and 90 or 160)
                    end
                    local txt = (i == 1 and "START  #1" or ("#%d"):format(i))
                    if isSel then txt = txt .. ("\n%.1fm · %d°"):format(gt.radius, math.floor(gt.heading)) end
                    label(gt.coords + vector3(0.0, 0.0, 2.6), txt, r, g, b)
                end
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and active then stop() end
end)
