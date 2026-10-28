-- client/trackstudio.lua — Track Studio: build and edit race tracks in the 3D world.
--
-- Opened from the admin menu (spz-admin → Tracks) through the same events as
-- before, and saved through the same server event, so the server is unchanged:
--   SPZ:startTrackCreator { name, type, laps, defaultWidth }   new track
--   SPZ:startTrackEditor  { id }                               existing track
--   SPZ:saveCustomTrack   → server/creator.lua
--
-- You DRIVE the route and a
-- preview gate rides in front of the car. Shape it with the arrow keys, drop
-- it with Enter, take the last one back with Delete, save with Shift+Enter.
-- Editing an existing track loads its gates and carries on from the last one.
--
-- Keys are read straight from the controls and only while the studio is open
-- -- no RegisterKeyMapping, so nothing here ever binds over a player's own
-- keys -- and each one is disabled for the game while it's ours (Enter, the
-- arrows, Delete, PgUp/PgDn, F9, F10, Esc). Keyboard only, so a pad's d-pad
-- and A button keep driving the car.
--
--   Enter            drop the preview gate
--   Shift + Enter    save
--   Delete           remove the last gate
--   Up / Down        gate wider / narrower
--   Left / Right     slide the gate sideways
--   Shift + ←/→      move the left post only
--   Ctrl  + ←/→      move the right post only
--   PgUp / PgDn      laps (circuits)
--   F9               circuit / sprint
--   F10              show / hide the controls
--   Esc              cancel (press twice)

local active   = false
local gates    = {}            -- { coords, heading, radius, left, right }
local meta     = { id = nil, name = "Custom Track", type = "circuit", laps = 3 }
local pv       = { l = 6.0, r = 6.0 }   -- preview half-widths left / right of the car's centre line
local pvGate   = nil                    -- { left, right } this frame
local showKeys = true
local escAt    = 0                      -- first Esc press (cancel needs a second within 3s)
local saving   = false

local PREVIEW_AHEAD = 7.0      -- metres in front of the car
local MIN_GAP       = 8.0      -- a new gate this close to the last one is refused
local CIRCUIT_CLOSE = 250.0    -- circuit: last gate must be within this of the start line
local MIN_GATES     = 2
local STEP          = 0.08     -- arrow keys: metres per frame

-- Control ids (keyboard).
local K = {
    ENTER = 191, DELETE = 178, UP = 172, DOWN = 173, LEFT = 174, RIGHT = 175,
    PGUP = 10, PGDN = 11, F9 = 56, F10 = 57, ESC = 322, ESC2 = 200,
    SHIFT = 21, CTRL = 36,
}
local OURS = { K.ENTER, K.DELETE, K.UP, K.DOWN, K.LEFT, K.RIGHT, K.PGUP, K.PGDN, K.F9, K.F10, K.ESC, K.ESC2,
               201, 194, 177 }   -- frontend accept / cancel twins of Enter and Backspace

-- ── helpers ──────────────────────────────────────────────────────────────────

local function notify(msg, t) lib.notify({ title = "Track Studio", description = msg, type = t or "inform" }) end

-- heading is a GTA heading (forward = (-sin h, cos h), what cp_cross.lua uses);
-- the posts sit along the car's right vector (cos h, sin h), across the road.
local function recalc(g)
    local rad  = math.rad(g.heading)
    local half = g.radius / 2
    local off  = vector3(math.cos(rad) * half, math.sin(rad) * half, 0.0)
    g.left, g.right = g.coords - off, g.coords + off
end

-- centre / width / heading from the two posts
local function fromPosts(g)
    local d = g.right - g.left
    g.coords  = (g.left + g.right) / 2
    g.radius  = math.max(3.0, math.min(60.0, #(vector2(d.x, d.y))))
    g.heading = math.deg(math.atan(d.y, d.x)) % 360.0
    recalc(g)
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

local function pressed(c)  return IsDisabledControlJustPressed(0, c) end
local function held(c)     return IsDisabledControlPressed(0, c) end

-- ── start / stop ─────────────────────────────────────────────────────────────

local function start(data, loaded)
    if active then return notify("Track Studio is already open", "error") end
    gates = loaded or {}
    meta = {
        id = data.id, name = data.name or "Custom Track",
        type = data.type == "sprint" and "sprint" or "circuit", laps = tonumber(data.laps) or 3,
    }
    local w = tonumber(data.defaultWidth) or (gates[#gates] and gates[#gates].radius) or 12.0
    pv = { l = w / 2, r = w / 2 }
    showKeys, escAt, saving = true, 0, false
    active = true
    PlaySoundFrontend(-1, "Hit_In", "PLAYER_SWITCH_CUSTOM_SOUNDSET", true)
end

local function stop()
    active, gates, pvGate, saving = false, {}, nil, false
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
        -- Posts first: they're what races cross.
        local g
        if cp.left and cp.right then
            g = { left = vector3(cp.left.x, cp.left.y, cp.left.z), right = vector3(cp.right.x, cp.right.y, cp.right.z) }
            fromPosts(g)
        else
            g = { coords = vector3(cp.coords.x, cp.coords.y, cp.coords.z), heading = cp.heading or 0.0, radius = cp.radius or 10.0 }
            recalc(g)
        end
        loaded[#loaded + 1] = g
    end
    start({ id = track.id, name = track.name, type = track.type, laps = track.laps }, loaded)
end)

exports("IsTrackStudioActive", function() return active end)
-- kept for spz-admin's "a track tool is already open" check
exports("IsTrackCreatorActive", function() return active end)
exports("IsTrackEditorActive", function() return false end)

-- ── actions ──────────────────────────────────────────────────────────────────

local function addGate()
    if not pvGate then return end
    local g = { left = pvGate.left, right = pvGate.right }
    fromPosts(g)
    local last = gates[#gates]
    if last and #(last.coords - g.coords) < MIN_GAP then
        PlaySoundFrontend(-1, "ERROR", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
        return notify(("Too close to gate %d — drive at least %dm on"):format(#gates, MIN_GAP), "error")
    end
    gates[#gates + 1] = g
    PlaySoundFrontend(-1, "Place_Prop_Success", "DLC_DHE_PROP_SOUNDS", true)
end

local function deleteLast()
    if #gates == 0 then return end
    gates[#gates] = nil
    PlaySoundFrontend(-1, "PROP_DROP_RED", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
end

local function save()
    if #gates < MIN_GATES then return notify(("You need at least %d gates"):format(MIN_GATES), "error") end
    if meta.type == "circuit" and #gates > 2 then
        local d = #(gates[#gates].coords - gates[1].coords)
        if d > CIRCUIT_CLOSE then
            return notify(("Last gate must be within %dm of the start line to close the circuit (it's %dm)")
                :format(CIRCUIT_CLOSE, math.floor(d)), "error")
        end
    end

    -- Face every gate along the course. cp_cross.lua uses the heading to tell
    -- "before" from "past" the line, so a gate with mirrored posts would read
    -- backwards. Forward vs the direction to the next gate (previous for the last).
    for i, g in ipairs(gates) do
        local a, b = g, gates[i + 1]
        if not b then a, b = gates[i - 1], g end
        if a and b then
            local rad = math.rad(g.heading)
            local d = b.coords - a.coords
            if -math.sin(rad) * d.x + math.cos(rad) * d.y < 0 then
                g.left, g.right = g.right, g.left
                fromPosts(g)
            end
        end
    end

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

-- ── input + preview gate ─────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if not active then Wait(300) goto continue end

        DisableFrontendThisFrame()                       -- Esc must not open the pause menu
        for _, c in ipairs(OURS) do DisableControlAction(0, c, true) end

        if IsUsingKeyboard(0) and not saving then
            local shift, ctrl = IsControlPressed(0, K.SHIFT), IsControlPressed(0, K.CTRL)

            if pressed(K.ENTER) then
                if shift then save() else addGate() end
            elseif pressed(K.DELETE) then
                deleteLast()
            elseif pressed(K.PGUP) and meta.type == "circuit" then
                meta.laps = math.min(20, meta.laps + 1)
            elseif pressed(K.PGDN) and meta.type == "circuit" then
                meta.laps = math.max(1, meta.laps - 1)
            elseif pressed(K.F9) then
                meta.type = meta.type == "circuit" and "sprint" or "circuit"
                PlaySoundFrontend(-1, "NAV_LEFT_RIGHT", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
            elseif pressed(K.F10) then
                showKeys = not showKeys
            elseif pressed(K.ESC) or pressed(K.ESC2) then
                if GetGameTimer() - escAt < 3000 then
                    notify("Discarded — nothing saved", "error"); stop()
                else
                    escAt = GetGameTimer()
                    notify("Press Esc again to discard this track", "warning")
                end
            end

            if active then
                if held(K.UP)   then pv.l, pv.r = pv.l + STEP, pv.r + STEP end
                if held(K.DOWN) then pv.l, pv.r = pv.l - STEP, pv.r - STEP end
                for _, k in ipairs({ { K.LEFT, -1 }, { K.RIGHT, 1 } }) do
                    if held(k[1]) then
                        local d = k[2] * STEP
                        if shift then    pv.l = pv.l - d          -- left post only
                        elseif ctrl then pv.r = pv.r + d          -- right post only
                        else             pv.l, pv.r = pv.l - d, pv.r + d end
                    end
                end
                pv.l = math.max(-25.0, math.min(30.0, pv.l))
                pv.r = math.max(-25.0, math.min(30.0, pv.r))
                if pv.l + pv.r < 3.0 then pv.r = 3.0 - pv.l end   -- keep a drivable gap
            end
        end

        if active then
            local ent = targetEnt()
            local function post(x)
                local p = GetOffsetFromEntityInWorldCoords(ent, x, PREVIEW_AHEAD, 0.0)
                local z = groundZ(p)
                return z and vector3(p.x, p.y, z + 1.0) or p
            end
            pvGate = { left = post(-pv.l), right = post(pv.r) }
        end

        Wait(0)
        ::continue::
    end
end)

-- ── world drawing ────────────────────────────────────────────────────────────

local function text3d(p, txt, r, g, b, scale)
    local on, sx, sy = GetScreenCoordFrom3dCoords(p.x, p.y, p.z)
    if not on then return end
    SetTextScale(scale or 0.32, scale or 0.32); SetTextFont(4); SetTextCentre(true)
    SetTextColour(r, g, b, 255); SetTextOutline()
    BeginTextCommandDisplayText("STRING"); AddTextComponentSubstringPlayerName(txt); EndTextCommandDisplayText(sx, sy)
end

local function drawPosts(L, R, r, g, b, a)
    DrawMarker(1, L.x, L.y, L.z - 1.0, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 3.2, 230, 60, 60, a, false, false, 2, false, nil, nil, false)
    DrawMarker(1, R.x, R.y, R.z - 1.0, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 3.2, 60, 230, 90, a, false, false, 2, false, nil, nil, false)
    DrawLine(L.x, L.y, L.z + 1.5, R.x, R.y, R.z + 1.5, r, g, b, 255)
end

CreateThread(function()
    while true do
        if not active then Wait(500) goto continue end
        do
            local me = GetEntityCoords(targetEnt())
            local n = #gates
            for i, gt in ipairs(gates) do
                if #(me - gt.coords) < 350.0 then
                    local r, g, b = 255, 255, 255
                    if i == 1 then r, g, b = 255, 200, 0 end            -- start
                    if i == n and i > 1 then r, g, b = 255, 120, 40 end -- last placed
                    drawPosts(gt.left, gt.right, r, g, b, 150)
                    DrawMarker(22, gt.coords.x, gt.coords.y, gt.coords.z + 0.6, 0, 0, 0,
                        -90.0, 0.0, -gt.heading, 1.3, 1.3, 1.3, r, g, b, 160, false, false, 2, false, nil, nil, false)
                    local nx = gates[i + 1] or (meta.type == "circuit" and n > 2 and gates[1])
                    if nx then
                        DrawLine(gt.coords.x, gt.coords.y, gt.coords.z + 0.3, nx.coords.x, nx.coords.y, nx.coords.z + 0.3,
                            255, 255, 255, nx == gates[1] and 70 or 150)
                    end
                    text3d(gt.coords + vector3(0.0, 0.0, 2.6), i == 1 and "START" or tostring(i), r, g, b)
                end
            end

            -- preview gate
            if pvGate then
                local L, R = pvGate.left, pvGate.right
                local mid  = (L + R) / 2
                local last = gates[n]
                local tooClose = last and #(last.coords - mid) < MIN_GAP
                local cr, cg, cb = 80, 190, 255
                if tooClose then cr, cg, cb = 255, 70, 70 end
                drawPosts(L, R, cr, cg, cb, 120)
                if last then
                    DrawLine(last.coords.x, last.coords.y, last.coords.z + 0.3, mid.x, mid.y, mid.z + 0.3, cr, cg, cb, 170)
                end
                text3d(mid + vector3(0.0, 0.0, 2.6), tooClose and "TOO CLOSE" or ("GATE %d  ·  %.1fm"):format(n + 1, pv.l + pv.r), cr, cg, cb, 0.36)
            end
        end
        Wait(0)
        ::continue::
    end
end)

-- ── studio panel (screen) ────────────────────────────────────────────────────
-- Drawn natively: no NUI focus to fight with while driving.

local PX, PY, PW = 0.835, 0.30, 0.15     -- panel left / top / width (screen fractions)
local ROW = 0.026
local ACC = { 255, 106, 0 }

local function txt(x, y, s, scale, r, g, b, a, right)
    SetTextFont(4); SetTextScale(scale, scale); SetTextColour(r, g, b, a or 255)
    if right then SetTextRightJustify(true); SetTextWrap(0.0, x) end
    BeginTextCommandDisplayText("STRING"); AddTextComponentSubstringPlayerName(s); EndTextCommandDisplayText(x, y)
end

local function row(i, label, value, vr, vg, vb)
    local y = PY + 0.045 + (i - 1) * ROW
    txt(PX + 0.008, y, label, 0.34, 170, 175, 185)
    txt(PX + PW - 0.008, y, value, 0.36, vr or 255, vg or 255, vb or 255, 255, true)
end

local function keyRow(y, key, what)
    local kw = 0.012 + #key * 0.0042
    DrawRect(PX + 0.008 + kw / 2, y + 0.011, kw, 0.021, 255, 255, 255, 230)
    txt(PX + 0.0095, y + 0.0005, key, 0.28, 15, 15, 20)
    txt(PX + 0.014 + kw, y, what, 0.30, 220, 222, 228)
end

local KEYS = {
    { "ENTER", "Drop gate" }, { "SHIFT+ENTER", "Save track" }, { "DEL", "Remove last gate" },
    { "UP/DOWN", "Width" }, { "LEFT/RIGHT", "Slide gate" }, { "SHIFT+L/R", "Left post" },
    { "CTRL+L/R", "Right post" }, { "PGUP/PGDN", "Laps" }, { "F9", "Circuit / sprint" },
    { "F10", "Hide controls" }, { "ESC x2", "Discard" },
}

CreateThread(function()
    while true do
        if not active then Wait(500) goto continue end
        do
            local rows = 5
            local h = 0.05 + rows * ROW
            -- header
            DrawRect(PX + PW / 2, PY + 0.017, PW, 0.034, ACC[1], ACC[2], ACC[3], 235)
            txt(PX + 0.008, PY + 0.004, "TRACK STUDIO", 0.42, 255, 255, 255)
            -- body
            DrawRect(PX + PW / 2, PY + 0.034 + (h - 0.034) / 2 + 0.004, PW, h - 0.026, 12, 14, 18, 215)

            local n = #gates
            local w = pv.l + pv.r
            local closeTxt, cr, cg, cb = "-", 255, 255, 255
            if meta.type == "circuit" and n > 2 then
                local d = math.floor(#(gates[n].coords - gates[1].coords))
                closeTxt = ("%dm"):format(d)
                if d > CIRCUIT_CLOSE then cr, cg, cb = 255, 90, 90 else cr, cg, cb = 90, 230, 120 end
            end
            row(1, "Track", meta.name)
            row(2, "Type", meta.type == "circuit" and ("Circuit · %d laps"):format(meta.laps) or "Sprint")
            row(3, "Gates", tostring(n), n >= MIN_GATES and 255 or 255, n >= MIN_GATES and 255 or 180, n >= MIN_GATES and 255 or 90)
            row(4, "Gate width", ("%.1fm"):format(w))
            row(5, "To start line", closeTxt, cr, cg, cb)

            -- controls
            if showKeys then
                local y0 = PY + h + 0.012
                local kh = #KEYS * 0.024 + 0.012
                DrawRect(PX + PW / 2, y0 + kh / 2, PW, kh, 12, 14, 18, 200)
                for i, k in ipairs(KEYS) do keyRow(y0 + 0.006 + (i - 1) * 0.024, k[1], k[2]) end
            else
                txt(PX + 0.008, PY + h + 0.012, "F10  controls", 0.30, 170, 175, 185)
            end
        end
        Wait(0)
        ::continue::
    end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and active then stop() end
end)
