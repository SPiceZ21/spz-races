-- client/cp_pill3d.lua
-- 3D checkpoint pills: a distance pill standing in the world over the gate you
-- are driving at, plus smaller ones over the next few gates after it.
--
-- Same idea as the moving gate panels (cp_anim.lua): the pill art is a small
-- DUI page (html/cp/pill.html) turned into a runtime texture. It is an ATLAS of
-- SLOTS rows, one per gate, and each row is drawn with DrawSpritePoly on a quad
-- that always faces the camera. Unlike the old screen-space pill this sits in
-- the world -- it lines up with the gate, goes behind the car, and the next
-- gates show where the course goes after this one.
--
-- The quad grows with distance so it stays readable far off, and floats higher
-- the further away the gate is so a far pill clears the scenery in front of it.
-- A stem runs down to the gate centre.
--
-- On while Config.Hud.CpPill3D is true and the race HUD pill toggle
-- (GlobalState.hudCpPill / setr spz_hud_cp_pill) is on. When it is on,
-- nui_bridge.lua stops drawing the old flat pill.

local SLOTS     = 4                      -- rows in html/cp/pill.html
local W, H      = 512, 256 * SLOTS
local TXD, TEX  = "spz_cp_pill", "pill"

local HUD       = (Config and Config.Hud) or {}
local AHEAD     = math.max(0, math.min(SLOTS - 1, HUD.CpPillAhead or 2))  -- gates shown after the active one
local SIZE_K    = 0.055                  -- quad width per metre of distance
local SIZE_MIN  = 2.6                    -- quad width up close (m)
local LIFT_MIN  = 2.5                    -- height over the gate up close (m)
local LIFT_MAX  = 22.0
local ACCENT    = { 255, 106, 0 }        -- stem colour, matches the pill border

local dui, ready = nil, false

function SPZ_CpPill3DEnabled()
    if HUD.CpPill3D == false then return false end
    local v = GlobalState.hudCpPill
    if v == nil then return HUD.CpDistancePill == true end
    return v == true
end

local function ensureDui()
    if dui then return ready end
    local url = ("nui://%s/html/cp/pill.html"):format(GetCurrentResourceName())
    dui = CreateDui(url, W, H)
    CreateRuntimeTextureFromDuiHandle(CreateRuntimeTxd(TXD), TEX, GetDuiHandle(dui))
    -- The page needs a moment to load before it takes messages.
    SetTimeout(500, function() ready = true end)
    return false
end

local function destroyDui()
    if not dui then return end
    DestroyDui(dui)
    dui, ready = nil, false
end

-- Midpoint of the two posts is the gap you drive through; cp.coords sits on
-- one post on some tracks (see nui_bridge.lua). Older tracks have no posts.
local function gateCentre(cp)
    if cp.left and cp.right then
        return vector3((cp.left.x + cp.right.x) * 0.5, (cp.left.y + cp.right.y) * 0.5, (cp.left.z + cp.right.z) * 0.5)
    end
    return vector3(cp.coords.x, cp.coords.y, cp.coords.z)
end

-- Camera right / up vectors, so the quad always faces the camera.
local function camBasis()
    local rot = GetFinalRenderedCamRot(2)
    local p, y = math.rad(rot.x), math.rad(rot.z)
    local sp, cp, sy, cy = math.sin(p), math.cos(p), math.sin(y), math.cos(y)
    return vector3(cy, sy, 0.0), vector3(sy * sp, -cy * sp, cp)
end

local function drawSlot(slot, centre, dist, right, up)
    local w   = math.max(SIZE_MIN, dist * SIZE_K)
    local hw  = w * 0.5
    local hh  = hw * (256 / 512)
    local lift = LIFT_MIN + math.min(LIFT_MAX - LIFT_MIN, dist * 0.06)
    local c   = centre + vector3(0.0, 0.0, lift + hh)

    local r, u = right * hw, up * hh
    local tl, tr = c - r + u, c + r + u
    local bl, br = c - r - u, c + r - u
    local v0, v1 = slot / SLOTS, (slot + 1) / SLOTS

    -- Both windings: a single-sided poly vanishes when seen from behind.
    DrawSpritePoly(tl.x, tl.y, tl.z, bl.x, bl.y, bl.z, tr.x, tr.y, tr.z, 255, 255, 255, 255, TXD, TEX,
        0.0, v0, 1.0,  0.0, v1, 1.0,  1.0, v0, 1.0)
    DrawSpritePoly(tr.x, tr.y, tr.z, bl.x, bl.y, bl.z, br.x, br.y, br.z, 255, 255, 255, 255, TXD, TEX,
        1.0, v0, 1.0,  0.0, v1, 1.0,  1.0, v1, 1.0)
    DrawSpritePoly(tr.x, tr.y, tr.z, bl.x, bl.y, bl.z, tl.x, tl.y, tl.z, 255, 255, 255, 255, TXD, TEX,
        1.0, v0, 1.0,  0.0, v1, 1.0,  0.0, v0, 1.0)
    DrawSpritePoly(br.x, br.y, br.z, bl.x, bl.y, bl.z, tr.x, tr.y, tr.z, 255, 255, 255, 255, TXD, TEX,
        1.0, v1, 1.0,  0.0, v1, 1.0,  1.0, v0, 1.0)

    if slot == 0 then
        local base = c - u
        DrawLine(centre.x, centre.y, centre.z + 0.3, base.x, base.y, base.z, ACCENT[1], ACCENT[2], ACCENT[3], 220)
    end
end

local function label(i, total, trackType)
    local finish = (trackType == "circuit") and 1 or total
    if i == finish then return "FINISH", true end
    return ("CP %d"):format(i), false
end

CreateThread(function()
    local lastSend, lastSig = 0, ""
    while true do
        -- SPZ_CpReadoutLive is set by nui_bridge.lua's readout loop: racing a
        -- route (race or TT) and not finished.
        if not (SPZ_CpReadoutLive and SPZ_CpPill3DEnabled()) then
            if dui then destroyDui() lastSig = "" end
            Wait(400)
            goto continue
        end
        if not ensureDui() then Wait(100) goto continue end

        do
            local cps, idx, trackType = exports["spz-races"]:GetCheckpointDebug()
            local total = cps and #cps or 0
            if total == 0 or not idx then Wait(200) goto continue end

            local pos = GetEntityCoords(PlayerPedId())
            local right, up = camBasis()
            local slots, draws = {}, {}
            for n = 0, AHEAD do
                local at = idx + n
                if at > total then
                    if trackType ~= "circuit" then break end
                    at = ((at - 1) % total) + 1
                end
                local cp = cps[at]
                if not cp then break end
                local centre = gateCentre(cp)
                local dist = #(pos - centre)
                local text, isFinish = label(at, total, trackType)
                slots[n + 1] = { dist = ("%d"):format(math.floor(dist)), label = text, finish = isFinish }
                draws[#draws + 1] = { n, centre, dist }
                if isFinish and trackType ~= "circuit" then break end
            end

            -- Text only changes a few times a second; don't re-render the page
            -- every frame.
            local now = GetGameTimer()
            if now - lastSend > 120 then
                local sig = json.encode(slots)
                if sig ~= lastSig then
                    SendDuiMessage(dui, json.encode({ type = "cpPill", slots = slots }))
                    lastSig = sig
                end
                lastSend = now
            end

            -- Far ones first so the active pill draws on top.
            for k = #draws, 1, -1 do
                local d = draws[k]
                drawSlot(d[1], d[2], d[3], right, up)
            end
        end
        Wait(0)
        ::continue::
    end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then destroyDui() end
end)
