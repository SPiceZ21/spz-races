-- client/raceblips.lua
-- Live map blips for every racer while you're in a race. Roster + positions
-- come from the SPZ:positionUpdate broadcast; a blip is attached to each
-- racer's ped so it tracks automatically. Leader is gold, you are blue, the
-- rest orange.

local Blips = {}   -- [serverId] = blip handle

local COL_LEADER = 46   -- yellow/gold
local COL_ME     = 3    -- light blue
local COL_OTHER  = 47   -- orange

local function clearAll()
    for _, b in pairs(Blips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    Blips = {}
end

local function ensureBlip(serverId)
    if Blips[serverId] and DoesBlipExist(Blips[serverId]) then return Blips[serverId] end
    local plr = GetPlayerFromServerId(serverId)
    if plr == -1 then return nil end
    local ped = GetPlayerPed(plr)
    if ped == 0 or not DoesEntityExist(ped) then return nil end

    local blip = AddBlipForEntity(ped)
    SetBlipSprite(blip, 1)
    SetBlipScale(blip, 0.85)
    SetBlipAsShortRange(blip, false)   -- always visible on the minimap
    Blips[serverId] = blip
    return blip
end

RegisterNetEvent("SPZ:positionUpdate", function(payload)
    if type(payload) ~= "table" then return end
    if not LocalPlayer.state.inRace then clearAll() return end

    local myId  = GetPlayerServerId(PlayerId())
    local alive = {}

    for _, racer in ipairs(payload) do
        -- Bots carry a string id and no ped; their blips are owned by
        -- client/bots.lua (attached to the local replay car).
        if not racer.bot then
        local sid = racer.source
        alive[sid] = true
        local blip = ensureBlip(sid)
        if blip then
            local col = (racer.position == 1) and COL_LEADER
                     or (sid == myId) and COL_ME
                     or COL_OTHER
            SetBlipColour(blip, col)
            -- name shows their position + name on the big map
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName(("P%s  %s"):format(racer.position or "?", racer.name or ""))
            EndTextCommandSetBlipName(blip)
        end
        end   -- not racer.bot
    end

    -- drop blips for racers no longer in the payload (finished / DNF / left)
    for sid, b in pairs(Blips) do
        if not alive[sid] then
            if DoesBlipExist(b) then RemoveBlip(b) end
            Blips[sid] = nil
        end
    end
end)

RegisterNetEvent("SPZ:raceEnd",       clearAll)
RegisterNetEvent("SPZ:tpToSafeZone",  clearAll)
AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then clearAll() end
end)
