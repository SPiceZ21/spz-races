-- client/raceblips.lua
-- Live map blips for every racer while you're in a race. Roster + positions
-- come from the SPZ:positionUpdate broadcast; a blip is attached to each
-- racer's ped so it tracks automatically. Leader is purple, you are blue, the
-- rest orange.

local Blips = {}   -- [serverId] = blip handle

-- 27 is the same purple spz-raceline paints its ghost with, so "purple = the
-- car setting the pace" reads the same in both features.
local COL_LEADER = 27   -- purple/violet
local COL_ME     = 3    -- light blue
local COL_OTHER  = 47   -- orange

-- Blips are scaled by how much you need to find them at a glance. The default
-- 0.85 dot is lost against the minimap's road clutter at racing speed, and the
-- two you actually look for -- the leader and yourself -- get the extra size.
local SCALE_LEADER = 1.35
local SCALE_ME     = 1.35
local SCALE_OTHER  = 1.15

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
    SetBlipScale(blip, SCALE_OTHER)    -- re-set per role on every position update
    SetBlipAsShortRange(blip, false)   -- always visible on the minimap
    -- High detail keeps the blip drawn at full size out at the minimap edge
    -- instead of being culled with the rest of the distant clutter, which is
    -- exactly where a racer you are chasing sits.
    SetBlipHighDetail(blip, true)
    -- An arrow rather than a dot: at speed, which way the car ahead is pointing
    -- is as much of the information as where it is.
    ShowHeadingIndicatorOnBlip(blip, true)
    Blips[serverId] = blip
    return blip
end

RegisterNetEvent("SPZ:positionUpdate", function(payload)
    if type(payload) ~= "table" then return end
    if not LocalPlayer.state.inRace then clearAll() return end

    local myId  = GetPlayerServerId(PlayerId())
    local alive = {}

    for _, racer in ipairs(payload) do
        local sid = racer.source
        alive[sid] = true
        local blip = ensureBlip(sid)
        if blip then
            local leader = (racer.position == 1)
            local mine   = (sid == myId)

            local col = leader and COL_LEADER
                     or mine and COL_ME
                     or COL_OTHER
            SetBlipColour(blip, col)

            -- Re-asserted every update because the lead changes hands: the blip
            -- that shrinks back to SCALE_OTHER is the one that just lost P1.
            SetBlipScale(blip, leader and SCALE_LEADER
                            or mine and SCALE_ME
                            or SCALE_OTHER)
            -- name shows their position + name on the big map
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName(("P%s  %s"):format(racer.position or "?", racer.name or ""))
            EndTextCommandSetBlipName(blip)
        end
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
