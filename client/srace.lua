-- client/srace.lua — /srace admin menu (ox_lib context).
--
--   Start a race
--     Track: <pick>        → circuits / sprints
--     Car:   <pick>        → class → car
--     Start now            race with whoever is queued (you're added)
--     Start with join window   the normal 30 s window so others can /joinrace
--
-- The server re-checks admin and both picks; this menu is only the picker.

local MENU = "spz_srace"
local data, pick = nil, { track = nil, car = nil }

local function trackLabel(t)
    return ("%s"):format(t.name)
end

local openMain

local function openTracks(kind)
    local opts = {}
    for _, t in ipairs(data.tracks) do
        if t.type == kind then
            opts[#opts + 1] = {
                title = t.name,
                description = kind == "sprint" and ("Sprint · %d checkpoints"):format(t.cps)
                    or ("Circuit · %d laps · %d checkpoints"):format(t.laps or 1, t.cps),
                icon = pick.track and pick.track.id == t.id and "check" or (kind == "sprint" and "route" or "flag-checkered"),
                iconColor = pick.track and pick.track.id == t.id and "#ff6200" or nil,
                onSelect = function() pick.track = t; openMain() end,
            }
        end
    end
    if #opts == 0 then opts[1] = { title = "No tracks of this type", disabled = true } end
    lib.registerContext({ id = MENU .. "_t_" .. kind, title = kind == "sprint" and "Sprints" or "Circuits",
        menu = MENU .. "_tracks", options = opts })
    lib.showContext(MENU .. "_t_" .. kind)
end

local function openTrackTypes()
    local n = { circuit = 0, sprint = 0 }
    for _, t in ipairs(data.tracks) do n[t.type] = (n[t.type] or 0) + 1 end
    lib.registerContext({
        id = MENU .. "_tracks", title = "Pick a track", menu = MENU,
        options = {
            { title = "Circuits", description = ("%d tracks"):format(n.circuit), icon = "flag-checkered", arrow = true,
              onSelect = function() openTracks("circuit") end },
            { title = "Sprints", description = ("%d tracks"):format(n.sprint), icon = "route", arrow = true,
              onSelect = function() openTracks("sprint") end },
        },
    })
    lib.showContext(MENU .. "_tracks")
end

local function openCars(class)
    local opts = {}
    for _, c in ipairs(class.cars) do
        local on = pick.car and pick.car.model == c.model
        opts[#opts + 1] = {
            title = c.label, description = c.model,
            icon = on and "check" or "car", iconColor = on and "#ff6200" or nil,
            onSelect = function() pick.car = { model = c.model, label = c.label, class = class.name }; openMain() end,
        }
    end
    lib.registerContext({ id = MENU .. "_c_" .. class.id, title = class.name, menu = MENU .. "_classes",
        search = #opts > 8, options = opts })
    lib.showContext(MENU .. "_c_" .. class.id)
end

local function openClasses()
    local opts = {}
    for _, cl in ipairs(data.classes) do
        opts[#opts + 1] = {
            title = cl.name, description = ("%d cars"):format(#cl.cars),
            icon = "car-side", iconColor = cl.color, arrow = true,
            onSelect = function() openCars(cl) end,
        }
    end
    if #opts == 0 then opts[1] = { title = "No race-eligible cars", disabled = true } end
    lib.registerContext({ id = MENU .. "_classes", title = "Pick a car", menu = MENU, options = opts })
    lib.showContext(MENU .. "_classes")
end

local function start(mode)
    local ok, err = lib.callback.await("spz-races:srace:start", false,
        { trackId = pick.track.id, model = pick.car.model, mode = mode })
    if ok then
        lib.notify({ title = "Admin race", description = ("%s · %s"):format(pick.track.name, pick.car.label), type = "success" })
    else
        lib.notify({ title = "Admin race", description = err or "Couldn't start the race.", type = "error" })
    end
end

openMain = function()
    local ready = pick.track and pick.car
    local busy = data.state ~= "IDLE" and data.state ~= "POLLING"
    local opts = {
        { title = "Track: " .. (pick.track and trackLabel(pick.track) or "—"),
          description = pick.track and (pick.track.type == "sprint" and "Sprint" or ("Circuit · %d laps"):format(pick.track.laps or 1)) or "Choose where to race",
          icon = "map-location-dot", arrow = true, onSelect = openTrackTypes },
        { title = "Car: " .. (pick.car and pick.car.label or "—"),
          description = pick.car and pick.car.class or "Everyone races this car",
          icon = "car", arrow = true, onSelect = openClasses },
        { title = "Start now", icon = "play", iconColor = ready and not busy and "#ff6200" or nil,
          description = busy and ("A race is running (%s)"):format(data.state)
              or ("Race with the %d queued player%s (you're added)"):format(data.queued, data.queued == 1 and "" or "s"),
          disabled = not ready or busy, onSelect = function() start("now") end },
        { title = "Start with join window", icon = "hourglass-half",
          description = "Opens the normal join window so others can /joinrace first",
          disabled = not ready or busy or data.state == "POLLING", onSelect = function() start("window") end },
    }
    lib.registerContext({ id = MENU, title = "🏁 Admin race", options = opts })
    lib.showContext(MENU)
end

RegisterCommand("srace", function()
    data = lib.callback.await("spz-races:srace:options", false)
    if not data then
        lib.notify({ title = "Admin race", description = "Admins only.", type = "error" })
        return
    end
    openMain()
end, false)
