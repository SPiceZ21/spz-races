-- client/startline.lua
-- START SPAWN TOOL — place a track's two race-start spawn points by hand.
-- /setstart
--
-- The race start is split: half the field on one point, half on another. By
-- default those two points are COMPUTED — start_coords ± Config.SplitPointGap
-- sideways, facing start_heading — and on tracks where the start point or its
-- heading is off, both packs land wrong. This lets you stand on each spot,
-- facing down the track, and capture it. server/world.lua then starts the race
-- on exactly those two points, each pack facing the way you faced.
--
-- Walks every track like /fixheadings (client/dev_heading.lua):
--   [↑] / [↓]   next / previous track (teleports you to its start)
--   [E]         capture a spawn point: where you stand AND which way you face
--               first press = point 1, second = point 2, third starts over
--   [ENTER]     save both points
--   [R]         clear captured points
--   [BACKSPACE] exit
--
-- Easiest in the car you race: park it on the spot, pointed down the track,
-- and press [E] — the car's heading is what gets captured.
--
-- On screen: grey = the computed points the race uses now (tracks with no
-- manual points), cyan = points already saved, green = what you are capturing,
-- faint yellow = gate 1's posts, i.e. the edges of the road at the start.

local active  = false
local tracks  = {}
local idx     = 1
local A, B    = nil, nil

local REPLY_TIMEOUT_MS = 4000
local pending = 0

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function ent()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and veh or ped
end

local function v3(t) return vector3(t.x, t.y, t.z) end

local function notify(msg, kind)
    lib.notify({ title = "Start line", description = msg, type = kind or "inform", duration = 3000 })
end

local function text3d(x, y, z, str, r, g, b)
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
    AddTextComponentString(str)
    DrawText(sx, sy)
end

local function arrowFrom(p, h, r, g, b)
    local rad = math.rad(h)
    DrawLine(p.x, p.y, p.z + 0.4, p.x - math.sin(rad) * 6.0, p.y + math.cos(rad) * 6.0, p.z + 0.4,
        r, g, b, 255)
end

local function post(p, r, g, b)
    DrawMarker(1, p.x, p.y, p.z - 1.0, 0,0,0, 0,0,0, 0.6, 0.6, 3.5, r, g, b, 170,
        false, false, 2, false, nil, nil, false)
end

--- The two points the race uses now for a track with no manual points —
--- mirrors split mode in shared/race_states.lua: start_coords ± gap/2 along the
--- right-hand axis of start_heading.
local function computedPoints(t)
    local gap = (Config and Config.SplitPointGap) or 7.0
    local rad = math.rad(t.heading or 0.0)
    local rx, ry = math.cos(rad), math.sin(rad)
    local s0 = t.start
    return {
        { x = s0.x - rx * gap / 2, y = s0.y - ry * gap / 2, z = s0.z, h = t.heading or 0.0 },
        { x = s0.x + rx * gap / 2, y = s0.y + ry * gap / 2, z = s0.z, h = t.heading or 0.0 },
    }
end

local function goTo(i)
    local t = tracks[i]
    if not t then return end
    idx, A, B = i, nil, nil
    local e = ent()
    SetEntityCoords(e, t.start.x, t.start.y, t.start.z + 1.0, false, false, false, true)
    SetEntityHeading(e, t.heading or 0.0)
    notify(("[%d/%d] %s (%s)%s"):format(i, #tracks, t.name, t.type, t.points and " — points set" or ""))
end

local function save(t, a, b)
    TriggerServerEvent("spz-startline:save", t.id, a, b)
end

--- Where you are standing and which way you (or your car) face.
local function capture()
    local e = ent()
    local c = GetEntityCoords(e)
    return { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(e) }
end

-- ── Command ───────────────────────────────────────────────────────────────────

RegisterCommand("setstart", function()
    if active then
        active = false
        return notify("Start line tool closed.")
    end
    if LocalPlayer.state.inRace then
        return notify("Not during a race — this tool teleports you.", "error")
    end

    print("^5[spz-races] /setstart -> requesting track list^7")
    pending = GetGameTimer()
    local asked = pending
    TriggerServerEvent("spz-startline:reqList")

    -- If nothing answers, say so and name the causes the client cannot see.
    SetTimeout(REPLY_TIMEOUT_MS, function()
        if pending ~= asked then return end
        pending = 0
        print("^1[spz-races] /setstart: no reply from the server.^7")
        print("^3  * is the updated spz-races (server/startline.lua) on the server, and restarted?^7")
        print("^3  * check the SERVER console for a '/setstart list requested' line^7")
        notify("No reply from the server — see F8.", "error")
    end)
end, false)

RegisterNetEvent("spz-startline:list", function(list, startIdx)
    pending = 0
    if type(list) ~= "table" or #list == 0 then
        return notify("No tracks returned.", "error")
    end
    tracks = list
    active = true
    print(("^2[spz-races] /setstart -> %d tracks^7"):format(#list))
    goTo(startIdx or 1)
end)

RegisterNetEvent("spz-startline:refused", function(reason)
    pending = 0
    print(("^1[spz-races] /setstart refused: %s^7"):format(tostring(reason)))
    notify(reason or "Refused.", "error")
end)

RegisterNetEvent("spz-startline:saved", function(trackId, gap, points)
    -- Update the list in place so the HUD shows the stored points immediately.
    for _, t in ipairs(tracks) do
        if t.id == trackId then t.points = points end
    end
    A, B = nil, nil
    notify(("Saved · packs %.1f m apart"):format(gap or 0), "success")
end)

-- ── Main loop ─────────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if not active then
            Wait(300)
        else
            local t = tracks[idx]
            if t then
                -- Gate 1 posts — the road edges at the start, as a reference.
                if t.gate1 then
                    local l, r = v3(t.gate1.left), v3(t.gate1.right)
                    DrawLine(l.x, l.y, l.z + 0.3, r.x, r.y, r.z + 0.3, 255, 210, 0, 110)
                end

                -- Next gate (orange), so you know which way "down the track" is.
                if t.nextCp then
                    local n = v3(t.nextCp)
                    DrawMarker(1, n.x, n.y, n.z - 1.0, 0,0,0, 0,0,0,
                        1.6, 1.6, 3.0, 255, 98, 0, 120, false, false, 2, false, nil, nil, false)
                    text3d(n.x, n.y, n.z + 1.6, "NEXT GATE", 255, 98, 0)
                end

                -- What the race uses now: saved points (cyan) or computed (grey).
                local now, cr, cg, cb, tag = t.points, 0, 200, 255, "saved"
                if not now then now, cr, cg, cb, tag = computedPoints(t), 130, 140, 160, "computed" end
                for i, p in ipairs(now) do
                    local pv = v3(p)
                    post(pv, cr, cg, cb)
                    arrowFrom(pv, p.h or 0.0, cr, cg, cb)
                    text3d(pv.x, pv.y, pv.z + 2.2, ("%s %d"):format(tag, i), cr, cg, cb)
                end

                -- What you are capturing (green); point 2 follows you until taken.
                local live = capture()
                local c1 = A
                local c2 = B or (A and live or nil)
                if c1 then
                    post(v3(c1), 40, 220, 90); arrowFrom(v3(c1), c1.h, 40, 220, 90)
                    text3d(c1.x, c1.y, c1.z + 2.6, "POINT 1", 40, 220, 90)
                end
                if c2 then
                    post(v3(c2), 40, 220, 90); arrowFrom(v3(c2), c2.h, 40, 220, 90)
                    text3d(c2.x, c2.y, c2.z + 2.6, B and "POINT 2" or "POINT 2 (you)", 40, 220, 90)
                    text3d((c1.x + c2.x) / 2, (c1.y + c2.y) / 2, c1.z + 1.4,
                        ("%.1f m apart"):format(#(v3(c2) - v3(c1))), 40, 220, 90)
                end

                -- HUD
                SetTextFont(4); SetTextScale(0.42, 0.42); SetTextColour(255, 255, 255, 255)
                SetTextDropShadow(); SetTextEntry("STRING")
                AddTextComponentString(
                    ("~y~START SPAWNS~s~  [%d/%d]  ~b~%s~s~ (%s)  %s\n")
                        :format(idx, #tracks, t.name, t.type,
                                t.points and "~g~manual points~s~" or "~c~computed points~s~")
                    .. "~g~[E]~s~ Capture point " .. (A and (B and "(both set)" or "2") or "1")
                    .. " (position + facing)   ~y~[ENTER]~s~ Save   ~g~[R]~s~ Reset\n"
                    .. "~g~[↑/↓]~s~ Track   ~r~[BACKSPACE]~s~ Exit")
                DrawText(0.33, 0.02)

                -- ── Inputs ── (same control ids /fixheadings uses)
                if IsControlJustPressed(0, 172) then goTo((idx % #tracks) + 1) end               -- ↑
                if IsControlJustPressed(0, 173) then goTo(idx > 1 and idx - 1 or #tracks) end     -- ↓

                if IsControlJustPressed(0, 38) then                                              -- E
                    if not A then A = live
                    elseif not B then B = live
                    else A, B = live, nil end
                end

                if IsControlJustPressed(0, 45) then A, B = nil, nil end                          -- R

                if IsControlJustPressed(0, 18) then                                              -- ENTER
                    if A and B then save(t, A, B)
                    else notify("Capture both points with [E] first.", "error") end
                end

                if IsControlJustPressed(0, 177) then                                             -- BACKSPACE
                    active = false
                    notify("Start spawn tool closed.")
                end
            end
            Wait(0)
        end
    end
end)

-- /clearstart <trackId> — separate on purpose, so removing a line is never one
-- mis-press away while surveying.
RegisterCommand("clearstart", function(_, args)
    if not args[1] then
        return print("^3[spz-races] /clearstart <trackId> — /startlines on the server lists them^7")
    end
    TriggerServerEvent("spz-startline:clear", args[1])
end, false)
