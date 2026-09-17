-- client/cp_debug.lua
-- 3D checkpoint debug overlay.  /cpdebug
--
-- WHY THIS EXISTS
--
-- Everything that goes wrong with a checkpoint is a GEOMETRY problem, and none
-- of it can be read off a console print. A gate that scores from the wrong
-- direction, one that cannot be scored at all, one that fires from the pavement
-- beside it, a "checkpoint missed" prompt on a gate you drove straight through
-- — all of those are the left/right posts, the heading, or the plane they
-- define being wrong, and all of them are invisible from the driving seat.
--
-- `/checkgateprops` in client/checkpoints.lua prints which gate MODELS resolve.
-- This is the other half: what the detector actually thinks the gate IS.
--
-- WHAT IT DRAWS
--
--   gate line     left post → right post, the segment a crossing must pass
--                 between. Coloured by state: cleared, active, or pending.
--   posts         vertical bars at each end, so the gate reads in 3D rather
--                 than as a line lying on the road.
--   heading arrow the stored `cp.heading`, which is what orients the plane.
--   normal        the plane's actual normal AFTER heading alignment. When the
--                 posts were stored back-to-front these two disagree, and that
--                 disagreement is the bug — it is called out in the panel.
--   corridor      the tracking region (TRACK_SPAN × TRACK_DEPTH). Outside it
--                 the detector deliberately forgets which side you are on, so
--                 a gate that will not score often turns out to be one whose
--                 corridor you never entered. Active gate only — drawing this
--                 for every gate on the track is a wireframe city.
--   radius ring   for gates with no posts, which fall back to the old
--                 radius check.
--
-- and a panel with the live crossing maths for the active gate: the signed
-- distance to the plane, the lateral position along the gate, and each of the
-- four tests that decide whether a crossing counts.
--
-- Every one of those numbers comes from SPZ_GateProbe in client/cp_cross.lua,
-- computed by the same code and the same constants the real detector uses. This
-- file does no geometry of its own on purpose: a debug view with its own copy
-- of the maths is one that eventually describes a detector that no longer
-- exists, and is believed anyway.
--
-- Costs nothing while off: the draw thread sleeps until it is switched on.

local active = false
local range  = 150.0   -- metres; gates further than this are not drawn
local showAll = true   -- false = active gate only, for a busy start/finish area
-- Base line width in METRES, so a gate reads the same at 10 m and at 100 m
-- relative to the road it is drawn on. Tune live with `/cpdebug width 0.5`.
local WIDTH  = 0.30

-- Thick lines are not free the way hairlines were: every one is four DrawPoly
-- calls instead of one DrawLine, and a gate costs nine lines (two posts, the
-- gate segment, and two three-part arrows) — about 36 calls each. A dense
-- circuit can put a lot of gates inside 150 m, so the number DRAWN is capped
-- even when more are in range. The panel reports both, so a capped view is
-- visible as one rather than looking like missing checkpoints.
--
-- For reference, spz-raceline's ribbon runs to 300 quads (1200 calls) as its
-- normal operating mode, so 14 gates is a conservative ceiling.
local MAX_GATES = 14

-- ── Colours ──────────────────────────────────────────────────────────────────
local C_ACTIVE  = { 255, 150, 0   }   -- the gate you are due to cross
local C_CLEARED = { 60,  200, 90  }
local C_PENDING = { 130, 140, 160 }
local C_NORMAL  = { 0,   170, 255 }   -- plane normal (direction of travel)
local C_HEADING = { 200, 80,  255 }   -- stored cp.heading
local C_CORRIDOR= { 255, 210, 0   }
local C_BAD     = { 255, 60,  60  }

-- ── Draw helpers ─────────────────────────────────────────────────────────────

local function text3d(x, y, z, str, col)
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    SetTextScale(0.0, 0.32)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(col[1], col[2], col[3], 235)
    SetTextDropShadow()
    SetTextOutline()
    SetTextCentre(true)
    SetTextEntry("STRING")
    AddTextComponentString(str)
    DrawText(sx, sy)
end

--- Camera position, read once a frame rather than once a line. Every quad
--- below needs it, and a gate at four stars is a few hundred of them.
local camPos = vec3(0, 0, 0)

--- A line with actual THICKNESS.
---
--- DrawLine has no width: it is a one-pixel hairline at any distance, which is
--- why the old overlay was close to invisible against the road at anything past
--- arm's length. There is no native for a thick 3D line, so it is built the way
--- spz-raceline builds its racing ribbon — as quads, drawn with DrawPoly.
---
--- The difference from that one is the ORIENTATION. The ribbon lies flat in the
--- road plane because a racing line belongs on the road; a debug line has to be
--- readable from anywhere, and a flat quad seen edge-on is a hairline again. So
--- the quad is BILLBOARDED: the offset axis is the cross product of the segment
--- and the direction to the camera, which turns the ribbon to face the viewer
--- and holds its apparent width at every angle. The one degenerate case —
--- looking exactly down the barrel of the segment — has zero length and is
--- skipped, which is correct, because end-on a line has no width to show.
---
--- Four DrawPolys: two triangles, each wound both ways, because DrawPoly is
--- single-sided. Same as the ribbon.
local function line(a, b, col, width, alpha)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local vx = camPos.x - (a.x + b.x) * 0.5
    local vy = camPos.y - (a.y + b.y) * 0.5
    local vz = camPos.z - (a.z + b.z) * 0.5

    -- cross(segment, toCamera) → the axis to offset along
    local ox = dy * vz - dz * vy
    local oy = dz * vx - dx * vz
    local oz = dx * vy - dy * vx
    local len = math.sqrt(ox * ox + oy * oy + oz * oz)
    if len < 1e-6 then return end

    local h = (width or WIDTH) * 0.5 / len
    ox, oy, oz = ox * h, oy * h, oz * h

    local r, g, bl, al = col[1], col[2], col[3], alpha or 235
    local a1x, a1y, a1z = a.x + ox, a.y + oy, a.z + oz
    local a2x, a2y, a2z = a.x - ox, a.y - oy, a.z - oz
    local b1x, b1y, b1z = b.x + ox, b.y + oy, b.z + oz
    local b2x, b2y, b2z = b.x - ox, b.y - oy, b.z - oz

    DrawPoly(a1x, a1y, a1z, a2x, a2y, a2z, b1x, b1y, b1z, r, g, bl, al)
    DrawPoly(b1x, b1y, b1z, a2x, a2y, a2z, a1x, a1y, a1z, r, g, bl, al)
    DrawPoly(a2x, a2y, a2z, b2x, b2y, b2z, b1x, b1y, b1z, r, g, bl, al)
    DrawPoly(b1x, b1y, b1z, b2x, b2y, b2z, a2x, a2y, a2z, r, g, bl, al)
end

--- A vertical bar, because a gate drawn flat on the road disappears the moment
--- you are level with it — which is exactly when you are trying to look at it.
local function post(p, height, col, width, alpha)
    line(p, vec3(p.x, p.y, p.z + height), col, width or (WIDTH * 1.2), alpha)
end

local function arrow(from, dirx, diry, len, col)
    local tip = vec3(from.x + dirx * len, from.y + diry * len, from.z)
    line(from, tip, col, WIDTH, 245)
    -- Two short barbs, so the arrow reads as pointing rather than just being a
    -- second line lying next to the first one.
    local bx, by = -diry, dirx
    for _, s in ipairs({ 1, -1 }) do
        line(tip, vec3(tip.x - dirx * 1.6 + bx * 0.9 * s,
                       tip.y - diry * 1.6 + by * 0.9 * s,
                       tip.z), col, WIDTH * 0.85, 245)
    end
    return tip
end

--- Flat ring on the ground, for the radius fallback.
local function ring(centre, r, col, segments)
    segments = segments or 24
    local prev
    for i = 0, segments do
        local a = (i / segments) * math.pi * 2
        local p = vec3(centre.x + math.cos(a) * r, centre.y + math.sin(a) * r, centre.z)
        if prev then line(prev, p, col, WIDTH * 0.8, 210) end
        prev = p
    end
end

-- ── Panel ────────────────────────────────────────────────────────────────────

local function panel(str, row)
    SetTextFont(4)
    SetTextScale(0.30, 0.30)
    SetTextColour(255, 255, 255, 220)
    SetTextOutline()
    SetTextEntry("STRING")
    AddTextComponentString(str)
    DrawText(0.015, 0.30 + (row * 0.019))
end

local function yesno(b) return b and "~g~yes~s~" or "~r~no~s~" end

-- ── Main ─────────────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if not active then
            Wait(400)
            goto continue
        end

        do
            -- Every quad below billboards against this, so it is read once per
            -- frame rather than once per line.
            camPos = GetGameplayCamCoord()

            local cps, idx, trackType, lastCaught = exports["spz-races"]:GetCheckpointDebug()
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            local pos = GetEntityCoords(veh ~= 0 and veh or ped)

            if not cps or #cps == 0 then
                panel("~y~CP DEBUG~s~  no checkpoints loaded — start a race or a time trial", 0)
                Wait(0)
                goto continue
            end

            local rangeSq = range * range
            local drawn, inRange = 0, 0

            for i = 1, #cps do
                local cp = cps[i]
                local isActive = (i == idx)

                if cp and cp.coords and (showAll or isActive) then
                    local dx, dy = cp.coords.x - pos.x, cp.coords.y - pos.y
                    -- The ACTIVE gate is always drawn, cap or not: it is the one
                    -- the panel's numbers describe, and a debug view whose
                    -- subject can be culled is not a debug view.
                    if (dx * dx + dy * dy) <= rangeSq then inRange = inRange + 1 end
                    if (dx * dx + dy * dy) <= rangeSq and (isActive or drawn < MAX_GATES) then
                        drawn = drawn + 1

                        local col = isActive and C_ACTIVE
                            or ((lastCaught and i <= lastCaught) and C_CLEARED or C_PENDING)
                        local h = isActive and 4.0 or 2.5

                        local probe = SPZ_GateProbe(cp, pos)

                        if cp.left and cp.right then
                            post(cp.left,  h, col, WIDTH * 1.4, 255)
                            post(cp.right, h, col, WIDTH * 1.4, 255)
                            -- The gate itself, drawn at post height so it is not
                            -- buried in the road surface.
                            line(vec3(cp.left.x,  cp.left.y,  cp.left.z  + h * 0.5),
                                 vec3(cp.right.x, cp.right.y, cp.right.z + h * 0.5),
                                 col, WIDTH * 1.4, 255)
                            text3d(cp.left.x,  cp.left.y,  cp.left.z  + h + 0.4, "L", col)
                            text3d(cp.right.x, cp.right.y, cp.right.z + h + 0.4, "R", col)
                        else
                            -- No posts: this gate is on the legacy radius check,
                            -- and that is worth seeing at a glance.
                            ring(cp.coords, cp.radius or 5.0, C_BAD)
                            text3d(cp.coords.x, cp.coords.y, cp.coords.z + 1.2,
                                   "~r~NO POSTS — radius only~s~", C_BAD)
                        end

                        -- Label. Width and heading are the two numbers you
                        -- actually re-tune, so they go on the gate rather than
                        -- only in the panel.
                        --
                        -- Two calls at two heights, not one string with a
                        -- newline in it: DrawText draws a single line and drops
                        -- whatever follows, so the second half would simply
                        -- never have appeared.
                        local state = isActive and "~y~ACTIVE~s~"
                            or ((lastCaught and i <= lastCaught) and "cleared" or "pending")
                        text3d(cp.coords.x, cp.coords.y, cp.coords.z + h + 1.6,
                               ("%d/%d  %s"):format(i, #cps, state), col)
                        if probe and probe.hasGate then
                            text3d(cp.coords.x, cp.coords.y, cp.coords.z + h + 1.1,
                                   ("w %.1fm  hdg %.1f°"):format(probe.glen, cp.heading or 0.0), col)
                        end

                        -- Heading and normal. On a correct gate these point the
                        -- same way and sit on top of each other; when they do
                        -- not, the posts are stored back-to-front and the plane
                        -- is oriented off the heading instead.
                        if cp.heading then
                            local rad = math.rad(cp.heading)
                            arrow(vec3(cp.coords.x, cp.coords.y, cp.coords.z + 0.6),
                                  -math.sin(rad), math.cos(rad), 7.0, C_HEADING)
                        end
                        if probe and probe.hasGate then
                            arrow(vec3(cp.coords.x, cp.coords.y, cp.coords.z + 0.9),
                                  probe.nx, probe.ny, 5.0, C_NORMAL)
                        end

                        -- Corridor, active gate only.
                        if isActive and probe and probe.hasGate then
                            local gx = (cp.right.x - cp.left.x) / probe.glen
                            local gy = (cp.right.y - cp.left.y) / probe.glen
                            local span = probe.glen * probe.trackSpan
                            local dep  = probe.trackDepth
                            local z    = cp.coords.z + 0.05

                            -- Corners of the tracking region, in gate-space.
                            local function corner(alongGate, alongNormal)
                                return vec3(
                                    cp.coords.x + gx * alongGate + probe.nx * alongNormal,
                                    cp.coords.y + gy * alongGate + probe.ny * alongNormal,
                                    z)
                            end
                            local half = probe.glen * 0.5
                            local c1 = corner(-(half + span), -dep)
                            local c2 = corner( (half + span), -dep)
                            local c3 = corner( (half + span),  dep)
                            local c4 = corner(-(half + span),  dep)
                            -- Thinner and dimmer than the gate itself: the
                            -- corridor is context, and at full weight it draws
                            -- the eye away from the thing being debugged.
                            local cw = WIDTH * 0.55
                            line(c1, c2, C_CORRIDOR, cw, 150)
                            line(c2, c3, C_CORRIDOR, cw, 150)
                            line(c3, c4, C_CORRIDOR, cw, 150)
                            line(c4, c1, C_CORRIDOR, cw, 150)
                        end
                    end
                end
            end

            -- ── Panel ───────────────────────────────────────────────────────
            local row = 0
            local cp  = cps[idx]
            panel(("~y~CP DEBUG~s~  track ~b~%s~s~  gates ~b~%d~s~  drawn ~b~%d~s~/%d in range  range ~b~%.0fm~s~  width ~b~%.2fm~s~")
                :format(tostring(trackType), #cps, drawn, inRange, range, WIDTH), row) ; row = row + 1
            panel(("active ~b~%d~s~   last crossed ~b~%s~s~   /cpdebug all|active|<range>")
                :format(idx, tostring(lastCaught or "-")), row) ; row = row + 1

            if cp then
                local probe = SPZ_GateProbe(cp, pos)
                if not probe then
                    panel("~r~active gate has no coords~s~", row)
                elseif not probe.hasGate then
                    panel(("~r~radius fallback~s~ %s  dist ~b~%.1f~s~/%.1f  inside %s")
                        :format(probe.degenerate and "(posts identical)" or "(no posts)",
                                probe.dist, probe.radius, yesno(probe.inside)), row) ; row = row + 1
                else
                    -- The four things the detector asks, in the order it asks
                    -- them. A gate that will not score fails exactly one of
                    -- these, and this row is how you find out which.
                    panel(("plane d ~b~%+.2f~s~m (side ~b~%+d~s~)   along gate t ~b~%.2f~s~ / %.2fm")
                        :format(probe.d, probe.side, probe.t, probe.glen), row) ; row = row + 1
                    panel(("in corridor %s   between posts %s   height ok %s (dz ~b~%+.1f~s~/%.0f)")
                        :format(yesno(probe.inRegion), yesno(probe.withinGate),
                                yesno(probe.zOk), probe.dz, probe.zThresh), row) ; row = row + 1
                    if probe.normalFlipped then
                        panel("~o~posts stored right-to-left — plane was re-oriented from cp.heading~s~", row)
                        row = row + 1
                    end
                    if not cp.heading then
                        panel("~r~no cp.heading — plane direction falls out of post order, gate scores either way~s~", row)
                        row = row + 1
                    end
                end
            end
        end

        Wait(0)
        ::continue::
    end
end)

-- ── Command ──────────────────────────────────────────────────────────────────
--
--   /cpdebug            toggle
--   /cpdebug all        draw every gate in range (default)
--   /cpdebug active     draw only the gate you are due to cross
--   /cpdebug 300        set the draw range in metres
--   /cpdebug width 0.5  set the line thickness in metres
RegisterCommand("cpdebug", function(_, args)
    local a = (args[1] or ""):lower()

    if a == "all" or a == "active" then
        showAll = (a == "all")
        active  = true
    elseif a == "width" then
        WIDTH  = math.max(0.05, math.min(2.0, tonumber(args[2]) or WIDTH))
        active = true
    elseif tonumber(a) then
        range  = math.max(20.0, math.min(1000.0, tonumber(a) + 0.0))
        active = true
    else
        active = not active
    end

    print(("^2[spz-races] cp debug %s — %s gates, %.0fm, %.2fm lines^7")
        :format(active and "ON" or "OFF", showAll and "all" or "active only", range, WIDTH))
end, false)
