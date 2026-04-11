-- client/checkpoints.lua

local CurrentCheckpoints = {}
local CurrentCPIndex = 1
local RaceState = "IDLE"
local CurrentBlip = nil

-- 11.1 Blip Management
local function UpdateCheckpointBlip()
    -- Cleanup old blip/route
    if CurrentBlip then
        RemoveBlip(CurrentBlip)
        CurrentBlip = nil
    end

    if #CurrentCheckpoints == 0 or RaceState == "IDLE" then return end

    local cp = CurrentCheckpoints[CurrentCPIndex]
    if cp then
        -- Create new blip at CP coordinates
        CurrentBlip = AddBlipForCoord(cp.coords.x, cp.coords.y, cp.coords.z)
        
        SetBlipSprite(CurrentBlip, 1) -- Standard point
        SetBlipColour(CurrentBlip, 17) -- Orange
        SetBlipScale(CurrentBlip, 1.0)
        SetBlipAsShortRange(CurrentBlip, false)
        
        -- Enable GPS route to the checkpoint
        SetBlipRoute(CurrentBlip, true)
        SetBlipRouteColour(CurrentBlip, 17) -- Match orange route

        -- Add legend name
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString("Race Checkpoint")
        EndTextCommandSetBlipName(CurrentBlip)
    end
end

-- 11.2 Checkpoint Visuals
local function DrawRaceMarkers()
    if #CurrentCheckpoints == 0 or RaceState == "IDLE" then return end

    local cp = CurrentCheckpoints[CurrentCPIndex]
    if cp then
        -- Active checkpoint: bright yellow cylinder
        DrawMarker(1, cp.coords.x, cp.coords.y, cp.coords.z - 1.0,
                   0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                   cp.radius * 2.0, cp.radius * 2.0, 2.0,
                   255, 255, 0, 100, false, true, 2, false, nil, nil, false)
    end

    local nextCp = CurrentCheckpoints[CurrentCPIndex + 1]
    if nextCp then
        -- Next checkpoint: semi-transparent white
        DrawMarker(1, nextCp.coords.x, nextCp.coords.y, nextCp.coords.z - 1.0,
                   0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                   nextCp.radius * 2.0, nextCp.radius * 2.0, 2.0,
                   255, 255, 255, 50, false, true, 2, false, nil, nil, false)
    end
end

-- Thread for visual rendering (consistent with standard marker draw rates)
Citizen.CreateThread(function()
    while true do
        if #CurrentCheckpoints > 0 and (RaceState == "LIVE" or RaceState == "COUNTDOWN") then
            DrawRaceMarkers()
            Citizen.Wait(0)
        else
            Citizen.Wait(500)
        end
    end
end)

-- Initialization and synchronization
RegisterNetEvent("SPZ:spawnCheckpoints", function(checkpoints, startIdx)
    print(string.format("[Checkpoints] Loading track with %d points", #checkpoints))
    CurrentCheckpoints = checkpoints
    CurrentCPIndex = startIdx or 1
    UpdateCheckpointBlip()
end)

RegisterNetEvent("SPZ:nextCheckpoint", function(newIndex)
    CurrentCPIndex = newIndex
    -- Local feedback: Sound effect or visual pop could go here
    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", 1)
    UpdateCheckpointBlip()
end)

RegisterNetEvent("spz_race:state_updated", function(newState)
    RaceState = newState
    if newState == "IDLE" or newState == "CLEANUP" then
        CurrentCheckpoints = {}
        CurrentCPIndex = 1
    end
    UpdateCheckpointBlip()
end)

-- Export for hit detector access
exports("GetCurrentCP", function()
    return CurrentCheckpoints[CurrentCPIndex], CurrentCPIndex
end)

exports("GetRaceState", function()
    return RaceState
end)
