-- client/startline.lua
-- Set a track's START LINE from two points on the road.  /setstart
--
-- Stand at one edge of the start line, press [E]. Stand at the other edge,
-- press [E]. That is the line: the midpoint becomes the track's start point and
-- the perpendicular becomes its heading. Which edge you take first does not
-- matter — the direction is resolved by aiming at the next checkpoint, not by
-- the order the points were captured in.
--
-- See server/startline.lua for where it is stored and why it is not written
-- into data/tracks.lua.
--
-- Controls
--   [E]          capture a point (first press = A, second = B, third = re-take A)
--   [R]          clear both points and start again
--   [ENTER]      save
--   [BACKSPACE]  exit without saving

local active = false
local track  = nil   -- { id, name, type, start, heading, nextCp, line }
local A, B   = nil, nil

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function ent()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and veh or ped
end

local function v3(t) return vector3(t.x, t.y, t.z) end

local function text3d(x, y, z, str, r, g, b)
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    SetTextScale(0.0, 0.36)
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

local function post(p, h, r, g, b)
    DrawLine(p.x, p.y, p.z, p.x, p.y, p.z + h, r, g, b, 230)
end

--- PREVIEW ONLY. The server recomputes this on save and its answer is the one
--- that gets stored — this exists so the arrow on screen is not lying while you
--- are still deciding where to stand. Same rule, same inputs: perpendicular to
--- the line, flipped to whichever side the next checkpoint is on.
local function headingFor(a, b)
    local gx, gy = b.x - a.x, b.y - a.y
    local glen = math.sqrt(gx * gx + gy * gy)
    if glen < 0.01 then return track and track.heading or 0.0, false end

    local nx, ny = -gy / glen, gx / glen
    local mx, my = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5

    if track and track.nextCp then
        if ((track.nextCp.x - mx) * nx + (track.nextCp.y - my) * ny) < 0 then
            nx, ny = -nx, -ny
        end
        return math.deg(math.atan(-nx, ny)) % 360.0, true
    end
    return math.deg(math.atan(-nx, ny)) % 360.0, false
end

local function close(msg, kind)
    active, track, A, B = false, nil, nil, nil
    if msg then lib.notify({ description = msg, type = kind or "inform", duration = 3000 }) end
end

-- ── Command ──────────────────────────────────────────────────────────────────
--
-- Every reply from the server is asynchronous, and every reason it might refuse
-- (not dev-gated, no tracks loaded, unknown track id) happens over there. If
-- none of them reach the player the command is indistinguishable from one that
-- does not exist — which is exactly how this failed the first time it was run.
--
-- So it says what it did, on the client console as well as in a notification:
-- a notification can be missed or suppressed by another resource, F8 cannot.
-- And if nothing answers at all, it says THAT, which is the one message that
-- points at the two causes the tool cannot see for itself — the resource not
-- having been restarted, and the request being dropped before it arrives.

local REPLY_TIMEOUT_MS = 3000
local pending = 0

RegisterCommand("setstart", function(_, args)
    if active then return close("Start line tool closed.") end

    local want = args[1]
    pending = GetGameTimer()
    print(("^5[spz-races] /setstart -> requesting %s^7"):format(want and ("track '" .. want .. "'") or "nearest track"))

    TriggerServerEvent("spz-startline:request", want)

    -- Nothing came back. The server either never received it or refused without
    -- a word; both look identical from here, so name both.
    local asked = pending
    SetTimeout(REPLY_TIMEOUT_MS, function()
        if pending ~= asked then return end   -- a reply landed, all good
        pending = 0
        print("^1[spz-races] /setstart: no reply from the server after 3s.^7")
        print("^3  * has spz-races been restarted since startline.lua was added?  (restart spz-races)^7")
        print("^3  * are you dev-gated?  needs ACE 'spz.dev' or convar spz_dev true^7")
        lib.notify({
            title = "Start line",
            description = "No reply from the server — see F8.",
            type = "error", duration = 6000,
        })
    end)
end, false)

RegisterNetEvent("spz-startline:open", function(data)
    pending = 0
    if not data then return end
    track  = data
    A, B   = nil, nil
    active = true

    -- Pre-load whatever is already stored, so re-opening the tool on a track
    -- that has a line is an EDIT rather than a blank slate. Walking away from a
    -- perfectly good line because the tool forgot it is how a survey gets done
    -- twice.
    if data.line and data.line.left and data.line.right then
        A, B = v3(data.line.left), v3(data.line.right)
    end

    lib.notify({
        title       = "Start line",
        description = ("%s (%s)%s"):format(data.name, data.type,
            data.distance and (" · %.0f m away"):format(data.distance) or ""),
        type = "inform", duration = 4000,
    })
end)

-- Server refused, with a reason. Clears the pending request so the timeout
-- above does not then claim nothing answered.
RegisterNetEvent("spz-startline:refused", function(reason)
    pending = 0
    print(("^1[spz-races] /setstart refused: %s^7"):format(tostring(reason)))
    lib.notify({ title = "Start line", description = reason or "Refused.", type = "error", duration = 5000 })
end)

RegisterNetEvent("spz-startline:saved", function(_, heading, width)
    lib.notify({
        title = "Start line",
        description = ("Saved · %.1f m wide · %.1f°"):format(width or 0, heading or 0),
        type = "success", duration = 4000,
    })
end)

-- ── Draw / input loop ────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if not active or not track then
            Wait(300)
            goto continue
        end

        do
            local me  = GetEntityCoords(ent())
            local old = v3(track.start)

            -- The point being replaced, so you can see what you are moving away
            -- from rather than trusting that the new one is better.
            DrawMarker(1, old.x, old.y, old.z - 1.0, 0,0,0, 0,0,0,
                1.6, 1.6, 2.0, 130, 140, 160, 90, false, false, 2, false, nil, nil, false)
            text3d(old.x, old.y, old.z + 1.3, "current start", 130, 140, 160)

            -- Old heading, faint, for comparison against the new one.
            local orad = math.rad(track.heading or 0.0)
            DrawLine(old.x, old.y, old.z + 0.4,
                     old.x - math.sin(orad) * 6.0, old.y + math.cos(orad) * 6.0, old.z + 0.4,
                     130, 140, 160, 120)

            if track.nextCp then
                local n = v3(track.nextCp)
                DrawMarker(1, n.x, n.y, n.z - 1.0, 0,0,0, 0,0,0,
                    1.6, 1.6, 3.0, 255, 98, 0, 110, false, false, 2, false, nil, nil, false)
                text3d(n.x, n.y, n.z + 1.6, "next gate", 255, 98, 0)
            end

            -- The live end of the line is wherever you are standing until the
            -- second point is taken, so the width and the heading update as you
            -- walk rather than only once you commit.
            local a = A
            local b = B or (A and me or nil)

            if a then
                post(a, 3.0, 40, 220, 90)
                text3d(a.x, a.y, a.z + 3.3, "A", 40, 220, 90)
            end
            if a and b then
                post(b, 3.0, B and 40 or 255, B and 220 or 210, B and 90 or 0)
                text3d(b.x, b.y, b.z + 3.3, B and "B" or "B (live)", B and 40 or 255, B and 220 or 210, B and 90 or 0)
                DrawLine(a.x, a.y, a.z + 1.2, b.x, b.y, b.z + 1.2, 40, 220, 90, 240)

                local mid = vector3((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5)
                local width = #(b - a)
                local heading, aimed = headingFor(a, b)

                DrawMarker(1, mid.x, mid.y, mid.z - 1.0, 0,0,0, 0,0,0,
                    1.8, 1.8, 2.2, 40, 220, 90, 120, false, false, 2, false, nil, nil, false)

                local hrad = math.rad(heading)
                DrawLine(mid.x, mid.y, mid.z + 0.7,
                         mid.x - math.sin(hrad) * 10.0, mid.y + math.cos(hrad) * 10.0, mid.z + 0.7,
                         0, 170, 255, 255)
                text3d(mid.x, mid.y, mid.z + 2.2,
                       ("%.1f m · %.1f°%s"):format(width, heading, aimed and "" or " ~r~(no gate to aim at)~s~"),
                       0, 170, 255)
            end

            -- ── Panel ────────────────────────────────────────────────────────
            SetTextFont(4); SetTextScale(0.42, 0.42); SetTextColour(255, 255, 255, 255)
            SetTextDropShadow(); SetTextEntry("STRING")
            AddTextComponentString(
                ("~y~START LINE~s~  ~b~%s~s~  (%s)\n"):format(track.name, track.id)
                .. (A and B and "Both points set. " or (A and "Point A set — walk to the other edge. " or "Stand at one edge of the start line. "))
                .. (track.line and "~o~editing an existing line~s~\n" or "\n")
                .. "~g~[E]~s~ capture point   ~g~[R]~s~ reset   "
                .. ((A and B) and "~y~[ENTER]~s~ save   " or "~s~[ENTER] save   ")
                .. "~r~[BACKSPACE]~s~ exit")
            DrawText(0.30, 0.02)

            -- ── Input ────────────────────────────────────────────────────────
            if IsControlJustPressed(0, 38) then          -- [E]
                if not A then
                    A = me
                elseif not B then
                    B = me
                else
                    -- Third press starts over from here rather than doing
                    -- nothing: by the time both are set, the next press is
                    -- almost always "that first one was wrong".
                    A, B = me, nil
                end
            end

            if IsControlJustPressed(0, 45) then A, B = nil, nil end   -- [R]

            if IsControlJustPressed(0, 18) then                        -- [ENTER]
                if A and B then
                    TriggerServerEvent("spz-startline:save", track.id,
                        { x = A.x, y = A.y, z = A.z },
                        { x = B.x, y = B.y, z = B.z })
                    close()
                else
                    lib.notify({ description = "Set both points first ([E] at each edge).", type = "error" })
                end
            end

            if IsControlJustPressed(0, 177) then close("Start line tool closed — nothing saved.") end
        end

        Wait(0)
        ::continue::
    end
end)

-- ── Clear ────────────────────────────────────────────────────────────────────
-- Separate command rather than a key in the tool: removing a stored line is not
-- something to be one mis-press away from while surveying one.
RegisterCommand("clearstart", function(_, args)
    if not args[1] then
        print("^3[spz-races] /clearstart <trackId> — see /startlines on the server console^7")
        return
    end
    TriggerServerEvent("spz-startline:clear", args[1])
end, false)
