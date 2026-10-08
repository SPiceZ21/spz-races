-- server/trackadmin.lua
-- Track manager for the admin menu (spz-admin → Tracks).
--
--   * Turn any track on or off. An OFF track is never offered in the race poll
--     (/srace and duels can still pick it on purpose).
--   * Change a track's laps and poll weight without touching data/tracks.lua.
--   * List every track for the editor (creator.lua does the gate editing and
--     the saving of custom tracks).
--
-- Settings live in data/track_overrides.json, keyed by track id:
--   { "10_80": { "enabled": false, "laps": 4, "poll_weight": 2 } }
-- They are applied over SPZ.Tracks at start and after every change, so they
-- survive restarts and apply to both built-in and custom tracks.

local OVERRIDES_FILE = "data/track_overrides.json"
local Overrides = {}

--- One admin check for every track tool (manager here, creator.lua's save and
--- delete). spz-admin's export honours menu-granted admins too.
function TrackAdminAllowed(src)
    src = tonumber(src)
    if not src then return false end
    if src == 0 then return true end
    if GetResourceState("spz-admin") == "started" then
        local ok, allowed = pcall(function() return exports["spz-admin"]:IsAdmin(src) end)
        if ok and allowed then return true end
    end
    local ok, allowed = pcall(function() return exports["spz-core"]:HasPermission(src, "spz.admin") end)
    return (ok and allowed == true) or IsPlayerAceAllowed(src, "spz.admin")
end

local function adminLog(src, action, detail)
    if GetResourceState("spz-analytics") == "started" then
        pcall(function() exports["spz-analytics"]:AdminAction(src, action, detail) end)
    end
    print(("^5[spz-races]^7 %s (%s): %s — %s"):format(GetPlayerName(src) or "console", tostring(src), action, detail or ""))
end

local function loadOverrides()
    local raw = LoadResourceFile(GetCurrentResourceName(), OVERRIDES_FILE)
    if not raw or raw == "" then Overrides = {}; return end
    local ok, parsed = pcall(json.decode, raw)
    Overrides = (ok and type(parsed) == "table") and parsed or {}
end

local function saveOverrides()
    SaveResourceFile(GetCurrentResourceName(), OVERRIDES_FILE, json.encode(Overrides, { indent = true }), -1)
end

-- Built-in values, remembered the first time an override touches a track, so
-- clearing an override puts the original back.
local Original = {}

--- Apply the saved override (if any) to one track in SPZ.Tracks.
function ApplyTrackOverride(id)
    local t = SPZ.Tracks and SPZ.Tracks[id]
    if not t then return end
    Original[id] = Original[id] or { laps = t.laps, poll_weight = t.poll_weight }
    local o = Overrides[id] or {}
    t.disabled    = o.enabled == false
    t.laps        = tonumber(o.laps) or Original[id].laps
    t.poll_weight = tonumber(o.poll_weight) or Original[id].poll_weight
    if t.type == "sprint" then t.laps = 1 end
end

local function applyAll()
    for id in pairs(SPZ.Tracks or {}) do ApplyTrackOverride(id) end
end

-- After creator.lua's thread has added the custom tracks (threads start in
-- manifest order, and this file is listed after it).
CreateThread(function()
    loadOverrides()
    applyAll()
    local off = 0
    for _, t in pairs(SPZ.Tracks or {}) do if t.disabled then off = off + 1 end end
    if off > 0 then print(("^3[spz-races] %d track(s) switched off in the track manager^7"):format(off)) end
end)

local function setOverride(id, key, value)
    Overrides[id] = Overrides[id] or {}
    Overrides[id][key] = value
    if next(Overrides[id]) == nil then Overrides[id] = nil end
    saveOverrides()
    ApplyTrackOverride(id)
end

-- ── Callbacks (admin menu) ───────────────────────────────────────────────────

lib.callback.register("spz-races:trackAdmin:list", function(src)
    if not TrackAdminAllowed(src) then return nil end
    local custom = {}
    local raw = LoadResourceFile(GetCurrentResourceName(), "data/custom_tracks.json")
    if raw then
        local ok, parsed = pcall(json.decode, raw)
        if ok and type(parsed) == "table" then custom = parsed end
    end

    local list = {}
    for id, t in pairs(SPZ.Tracks or {}) do
        list[#list + 1] = {
            id = id, name = t.name, type = t.type or "circuit", laps = t.laps or 1,
            cps = t.checkpoints and #t.checkpoints or 0,
            poll_weight = t.poll_weight or 1,
            enabled = not t.disabled,
            custom = custom[id] ~= nil,                          -- saved from the creator/editor
            builtin = IsBuiltinTrack and IsBuiltinTrack(id) or false,
            start = t.start_coords and { x = t.start_coords.x, y = t.start_coords.y, z = t.start_coords.z } or nil,
            heading = t.start_heading or 0.0,
        }
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end)

lib.callback.register("spz-races:trackAdmin:setEnabled", function(src, id, on)
    if not TrackAdminAllowed(src) then return false, "Not authorised" end
    local t = SPZ.Tracks[id]
    if not t then return false, "Track not found" end

    -- Never switch off the last track of a type: the poll would have nothing
    -- to offer and every race of that type would abort.
    if not on then
        local left = 0
        for oid, o in pairs(SPZ.Tracks) do
            if oid ~= id and (o.type or "circuit") == (t.type or "circuit") and not o.disabled then left = left + 1 end
        end
        if left == 0 then return false, ("It is the last %s that is on"):format(t.type or "circuit") end
    end

    setOverride(id, "enabled", (not on) and false or nil)
    adminLog(src, on and "track_on" or "track_off", ("%s (%s)"):format(t.name, id))
    return true
end)

lib.callback.register("spz-races:trackAdmin:setMeta", function(src, id, laps, weight)
    if not TrackAdminAllowed(src) then return false, "Not authorised" end
    local t = SPZ.Tracks[id]
    if not t then return false, "Track not found" end
    laps, weight = tonumber(laps), tonumber(weight)
    if laps and (laps < 1 or laps > 20) then return false, "Laps must be 1-20" end
    if weight and (weight < 0 or weight > 100) then return false, "Poll weight must be 0-100" end

    Overrides[id] = Overrides[id] or {}
    Overrides[id].laps        = (laps and t.type ~= "sprint") and math.floor(laps) or nil
    Overrides[id].poll_weight = weight
    if next(Overrides[id]) == nil then Overrides[id] = nil end
    saveOverrides()
    ApplyTrackOverride(id)
    adminLog(src, "track_edit", ("%s (%s): %d laps, weight %s"):format(t.name, id, t.laps or 1, tostring(t.poll_weight)))
    return true
end)

--- Turn every track back on and drop every override.
lib.callback.register("spz-races:trackAdmin:resetAll", function(src)
    if not TrackAdminAllowed(src) then return false end
    Overrides = {}
    saveOverrides()
    applyAll()
    adminLog(src, "track_reset", "all tracks on, overrides cleared")
    return true
end)

