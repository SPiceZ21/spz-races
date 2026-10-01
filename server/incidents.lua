-- server/incidents.lua
-- Accumulates client-reported world impacts per racer. The count flows into
-- results (pData.incidents) → spz-progression, which applies the SR penalty
-- and gates the clean-race bonus.
--
-- The client is trusted only to REPORT an impact, never to score it: the server
-- validates the race state, sanity-checks the payload, and enforces the same
-- per-race cap independently of the client.

RegisterNetEvent("SPZ:reportIncident", function(payload)
    local src = source
    local pData = RaceSession.players[src]

    if not pData then return end
    if pData.finished or pData.dnf then return end
    if RaceSession.state ~= SPZ.RaceState.LIVE then return end

    local cfg = Config.Incidents or {}
    local cap = cfg.maxPerRace or 20
    if #pData.incidents >= cap then return end

    -- Sanity-check the reported speed so a modded client can't inflate severity.
    local speed = tonumber(payload and payload.speed) or 0
    if speed ~= speed or speed < (cfg.minImpactSpeed or 30) or speed > 600 then return end
    local drop = tonumber(payload and payload.drop) or 0
    if drop ~= drop then drop = 0 end
    drop = math.max(0, math.min(drop, 600))

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end
    local pos = GetEntityCoords(ped)
    if not pos or pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z then return end

    pData.incidents[#pData.incidents + 1] = {
        speed = math.floor(speed),
        drop  = math.floor(drop),
        at    = GetGameTimer() - (RaceSession.startTime or 0),
        x     = pos.x,
        y     = pos.y,
        z     = pos.z,
    }
end)
