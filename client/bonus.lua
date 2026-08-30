-- client/bonus.lua
-- Client-side feedback for out-of-race rewards fired by spz-progression.

-- Perfect lap: all three sectors purple in one lap. Flourish = notify + sound
-- + a brief bright post-fx pop so it FEELS earned, not just a toast.
RegisterNetEvent("SPZ:perfectLapFlourish", function()
    lib.notify({
        title       = "PERFECT LAP",
        description  = "All sectors purple",
        type        = "success",
        duration    = 6000,
        position    = "top",
        icon        = "bolt",
    })

    PlaySoundFrontend(-1, "RANK_UP", "HUD_AWARDS", true)

    if not AnimpostfxIsRunning("SuccessNeutral") then
        AnimpostfxPlay("SuccessNeutral", 900, false)
        SetTimeout(900, function() AnimpostfxStop("SuccessNeutral") end)
    end
end)

-- ── Overtake flourish ────────────────────────────────────────────────────────
-- A confirmed clean pass, broadcast to the whole race by server/overtakes.lua.
-- Everyone gets the toast; the OVERTAKER's car also spits nitrous flames.
--
-- The particle is networked, so only the overtaker's client starts it and every
-- other player sees it on that car — no extra broadcast, and no chance of eight
-- clients each spawning their own copy on the same vehicle.

local NOS = (Config and Config.OvertakeNos) or {}

-- Exhaust bones, in the order GTA names them. Most cars have one or two; some
-- have none at all (open-wheel, some imports), which is why there is a fallback.
local function _exhaustBones(veh)
    local bones = {}
    local b = GetEntityBoneIndexByName(veh, "exhaust")
    if b ~= -1 then bones[#bones + 1] = b end
    for i = 2, 16 do
        b = GetEntityBoneIndexByName(veh, ("exhaust_%d"):format(i))
        if b ~= -1 then bones[#bones + 1] = b end
    end
    return bones
end

local _nosUntil = 0

local function _playNos(veh)
    local dur = NOS.durationMs or 1400
    local now = GetGameTimer()
    -- Back-to-back passes should extend the burn, not stack a second emitter.
    local wasRunning = now < _nosUntil
    _nosUntil = now + dur
    if wasRunning then return end

    CreateThread(function()
        local ok = pcall(function() lib.requestNamedPtfxAsset("core") end)
        if not ok then return end

        local bones = _exhaustBones(veh)
        local scale = NOS.scale or 1.6

        while GetGameTimer() < _nosUntil do
            if not DoesEntityExist(veh) then return end

            if #bones > 0 then
                for _, bone in ipairs(bones) do
                    UseParticleFxAssetNextCall("core")
                    StartNetworkedParticleFxNonLoopedOnEntityBone(
                        "veh_backfire", veh,
                        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        bone, scale, false, false, false)
                end
            else
                -- No exhaust bone: fire from behind the rear axle instead so the
                -- car still reads as boosting rather than showing nothing.
                UseParticleFxAssetNextCall("core")
                StartNetworkedParticleFxNonLoopedOnEntity(
                    "veh_backfire", veh,
                    0.0, -2.2, 0.2, 0.0, 0.0, 0.0,
                    scale, false, false, false)
            end

            Wait(NOS.pulseMs or 110)
        end
    end)

    -- Rocket-Voltic style boost. OFF by default and deliberately so: it is a
    -- real speed gain, so it rewards the pass with pace and makes overtaking
    -- self-reinforcing. Visual-only is the safe default for a timed race.
    if NOS.boost == true then
        SetVehicleBoostActive(veh, true)
        SetTimeout(NOS.boostMs or 900, function()
            if DoesEntityExist(veh) then SetVehicleBoostActive(veh, false) end
        end)
    end
end

RegisterNetEvent("SPZ:overtake", function(data)
    if not data then return end

    lib.notify({
        title = "OVERTAKE",
        description = ("%s passed %s"):format(data.over or "?", data.under or "?"),
        type = "inform", duration = 4000, position = "top",
    })

    if NOS.enabled == false then return end
    if data.overSrc ~= GetPlayerServerId(PlayerId()) then return end

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or not DoesEntityExist(veh) then return end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return end   -- driver only

    _playNos(veh)
end)

-- Generic XP/credit grant toast.
RegisterNetEvent("SPZ:bonusGranted", function(d)
    if not d then return end
    local bits = {}
    if (d.xp or 0) ~= 0 then bits[#bits + 1] = ("+%d XP"):format(d.xp) end
    if (d.credits or 0) ~= 0 then bits[#bits + 1] = ("+%d credits"):format(d.credits) end
    if #bits == 0 then return end

    lib.notify({
        description = ("%s — %s"):format(table.concat(bits, "  "), d.reason or "Bonus"),
        type        = "success",
        position    = "top",
    })
end)
