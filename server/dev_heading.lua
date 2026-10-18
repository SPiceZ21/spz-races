-- server/dev_heading.lua
-- LOCAL DEV TOOL — fix messed-up track start_heading values.
-- Cycles tracks in-world; writes corrected start_heading back into data/tracks.lua.
-- Gated: ACE "spz.dev" OR convar spz_dev true (set for localhost testing).

local function IsDev(src)
    if src == 0 then return true end
    if GetConvar("spz_dev", "false") == "true" then return true end
    return IsPlayerAceAllowed(src, "spz.dev")
end

-- Distance helper
local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Build the ordered track list for the dev client.
local function BuildDevTrackList()
    local list = {}
    for id, t in pairs(SPZ.Tracks or {}) do
        if t.start_coords and t.checkpoints and #t.checkpoints > 0 then
            local start = t.start_coords

            -- "next CP" = first checkpoint more than 5 m from the start point
            local nextCp = t.checkpoints[1].coords
            for _, cp in ipairs(t.checkpoints) do
                if cp.coords and dist3(cp.coords, start) > 5.0 then
                    nextCp = cp.coords
                    break
                end
            end

            list[#list + 1] = {
                id      = id,
                name    = t.name or id,
                type    = t.type or "circuit",
                heading = t.start_heading or 0.0,
                start   = { x = start.x, y = start.y, z = start.z },
                nextCp  = { x = nextCp.x, y = nextCp.y, z = nextCp.z },
            }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

RegisterNetEvent("spz-dev:reqTracks", function()
    local src = source
    if not IsDev(src) then
        TriggerClientEvent('ox_lib:notify', src, { description = "Dev tool locked (need spz.dev ACE or spz_dev convar).", type = "error" })
        return
    end
    TriggerClientEvent("spz-dev:tracks", src, BuildDevTrackList())
end)

-- Persist a corrected heading into data/tracks.lua (and live SPZ.Tracks).
RegisterNetEvent("spz-dev:saveHeading", function(trackId, heading)
    local src = source
    if not IsDev(src) then return end
    if type(trackId) ~= "string" then return end
    heading = tonumber(heading)
    if not heading then return end
    heading = heading % 360.0

    -- live update
    if SPZ.Tracks and SPZ.Tracks[trackId] then
        SPZ.Tracks[trackId].start_heading = heading
    end

    local res  = GetCurrentResourceName()
    local file = LoadResourceFile(res, "data/tracks.lua")
    if not file then
        TriggerClientEvent('ox_lib:notify', src, { description = "Could not read data/tracks.lua", type = "error" })
        return
    end

    -- Escape Lua-pattern magic chars in the id (ids are alnum/_ but be safe).
    local idEsc = trackId:gsub("(%W)", "%%%1")
    -- Match:  ["id"] = { ... start_heading = <number>
    -- Lua '.' matches newlines, so '.-' spans the block up to start_heading.
    local pattern = '(%["' .. idEsc .. '"%]%s*=%s*{.-start_heading%s*=%s*)[%-%d%.]+'
    local newVal  = string.format("%.2f", heading)

    local updated, n = file:gsub(pattern, "%1" .. newVal, 1)
    if n == 0 then
        TriggerClientEvent('ox_lib:notify', src, { description = "Track '" .. trackId .. "' not found in file.", type = "error" })
        return
    end

    SaveResourceFile(res, "data/tracks.lua", updated, -1)
    print(("[spz-dev] Saved start_heading %.2f for track '%s'"):format(heading, trackId))
    TriggerClientEvent('ox_lib:notify', src, { description = ("Saved %s → %.2f°"):format(trackId, heading), type = "success" })
end)
