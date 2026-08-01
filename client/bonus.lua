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

    if not IsAnimpostfxRunning("SuccessNeutral") then
        AnimpostfxPlay("SuccessNeutral", 900, false)
        SetTimeout(900, function() AnimpostfxStop("SuccessNeutral") end)
    end
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
