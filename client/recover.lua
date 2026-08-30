-- client/recover.lua
-- Two in-race recovery keys:
--   F4  — teleport back to the last checkpoint you crossed (missed a gate / went
--         off-track). Points you at the next checkpoint. Race-only.
--   X   — flip the car upright if it's rolled/upside down.
-- Both rebindable in Settings → Key Bindings.

local RESPAWN_COOLDOWN = 2000   -- ms between respawns (anti-spam)
local _lastRespawn     = 0

-- Default bindings, declared once so the key that is REGISTERED and the key the
-- HUD PRINTS can never drift apart. These are defaults only: a player who
-- rebinds in Settings gets the new key, but the hint still shows this one --
-- FiveM exposes no way to read back a live command binding.
local KEY_RESPAWN = (Config and Config.RecoverKey) or "F6"
local KEY_FLIP    = "X"

local function inRace()
    return LocalPlayer.state.inRace == true
end

-- ── Back to last checkpoint ──────────────────────────────────────────────────

local function respawnToLastCP()
    if not inRace() then return end
    local now = GetGameTimer()
    if now - _lastRespawn < RESPAWN_COOLDOWN then return end

    local rp = exports["spz-races"]:GetRespawnPoint()
    if not rp or not rp.coords then
        lib.notify({ description = "No checkpoint to return to yet", type = "error" })
        return
    end
    _lastRespawn = now

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local ent = (veh ~= 0 and DoesEntityExist(veh)) and veh or ped

    local c = rp.coords
    SetEntityCoords(ent, c.x, c.y, c.z + 0.5, false, false, false, false)
    SetEntityHeading(ent, rp.heading or 0.0)
    if veh ~= 0 then
        SetVehicleOnGroundProperly(veh)
    end
    SetEntityVelocity(ent, 0.0, 0.0, 0.0)   -- kill momentum

    lib.notify({ description = "Returned to last checkpoint", type = "info" })
end

RegisterCommand("spz_respawn_cp", respawnToLastCP, false)
RegisterKeyMapping("spz_respawn_cp", "Race: back to last checkpoint", "keyboard", KEY_RESPAWN)

-- ── Flip car upright ─────────────────────────────────────────────────────────

local function flipCar()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or not DoesEntityExist(veh) then return end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return end   -- driver only

    -- Only when actually tipped over (roll beyond ~50°), so it can't be used as a
    -- free re-orient mid-corner.
    local roll = GetEntityRoll(veh)
    if math.abs(roll) < 50.0 then
        lib.notify({ description = "Car isn't flipped", type = "error" })
        return
    end

    local h = GetEntityHeading(veh)
    SetVehicleOnGroundProperly(veh)
    SetEntityRotation(veh, 0.0, 0.0, h, 2, true)
    SetEntityHeading(veh, h)
    SetEntityVelocity(veh, 0.0, 0.0, 0.0)
end

RegisterCommand("spz_flip_car", flipCar, false)
RegisterKeyMapping("spz_flip_car", "Race: flip car upright", "keyboard", KEY_FLIP)

-- ── Tell the HUD which keys to print ─────────────────────────────────────────
-- The recovery keys live here, but the surface that shows them is spz-raceUI.
-- Pushing them across keeps this file the single source for both.
CreateThread(function()
    while GetResourceState("spz-raceUI") ~= "started" do Wait(500) end
    local rw = Config and Config.Rewind or {}
    exports["spz-raceUI"]:SetKeyHints({
        respawn = KEY_RESPAWN,
        flip    = KEY_FLIP,
        rewind  = (rw.enabled ~= false) and (rw.key or "F5") or nil,
    })
end)
