-- server/dnf.lua

-- 12.3 DNF Logic
function ProcessDNF(source, reason)
    local pData = RaceSession.players[source]
    if not pData or pData.finished or pData.dnf then return end

    print(string.format("[Race Engine] Player %s (%s) DNF! Reason: %s", pData.name, source, reason))

    pData.dnf = true
    pData.dnf_reason = reason
    pData.finish_time = nil -- No finish time for DNF

    TriggerClientEvent("SPZ:raceDNF", source, reason)

    -- Force return to default bucket if they were in one
    exports["spz-core"]:AssignPlayerToBucket(source, 0)
    exports["spz-core"]:SetPlayerState(source, "IDLE")

    -- Check if everyone is finished or DNF
    CheckAllFinished()
end

function CheckAllFinished()
    local allDone = true
    local participantsCount = 0
    
    for _, p in pairs(RaceSession.players) do
        participantsCount = participantsCount + 1
        if not p.finished and not p.dnf then
            allDone = false
            break
        end
    end
    
    if allDone and participantsCount > 0 then
        print("[Race Engine] All participants completed or DNF. Transitioning to ENDED.")
        exports["spz-races"]:SetRaceState(SPZ.RaceState.ENDED)
    end
end

-- Export for external use (timeouts, lap-skipping kicks, etc)
exports("ProcessDNF", ProcessDNF)
exports("CheckAllFinished", CheckAllFinished)
