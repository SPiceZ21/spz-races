-- server/overtakes.lua
-- Overtake detection → auto-clip. Watches live race positions; when a racer
-- passes another and HOLDS the new position for Config.OvertakeHoldMs, it's a
-- confirmed clean overtake → grab a screenshot from the overtaker's client and
-- post "OVERTAKE: A passed B" to Discord.
--
-- screenshot-basic captures a still (not video). The detection engine here is
-- clip-ready: swap it for a recorder export later and the trigger logic stays.

local HOLD_MS   = (Config and Config.OvertakeHoldMs)   or 5000
local COOLDOWN  = (Config and Config.OvertakeCooldown) or 15000  -- per pair

local LastPos   = {}   -- [src] = position last tick
local Pending   = {}   -- ["A>B"] = { over, under, since }
local LastClip  = {}   -- ["A>B"] = gameTimer of last posted clip

local function pairKey(a, b) return a .. ">" .. b end

local function racerName(src)
    local p = RaceSession.players[src]
    return (p and p.name) or GetPlayerName(src) or ("Racer " .. src)
end

-- ── Screenshot + Discord post ─────────────────────────────────────────────────

local function postClip(overSrc, overName, underName)
    local track = RaceSession.track and RaceSession.track.name or "a track"
    local msg   = ("**%s** overtook **%s** on **%s**"):format(overName, underName, track)

    -- Best-effort screenshot from the overtaker's view, posted to the race
    -- webhook. Falls back to a text-only log if screenshot-basic is absent.
    if GetResourceState("screenshot-basic") == "started"
       and GetResourceState("spz-log") == "started" then
        local ok, webhook = pcall(function() return exports["spz-log"]:GetWebhook("race") end)
        if ok and webhook and webhook ~= "" and not webhook:find("YOUR_WEBHOOK") then
            exports["screenshot-basic"]:requestClientScreenshot(overSrc, {
                fileName    = "overtake",
                encoding    = "jpg",
                quality     = 0.75,
                targetField = "file",
                targetURL   = webhook,
                headers     = {},
                postData    = {
                    payload_json = json.encode({
                        embeds = {{
                            title       = "🏁 OVERTAKE",
                            description = msg,
                            color       = 15844367,   -- gold
                        }},
                    }),
                },
            }, function() end)
            return
        end
    end

    -- Fallback: text-only Discord log
    if GetResourceState("spz-log") == "started" then
        pcall(function()
            exports["spz-log"]:Info("race", "Overtake", msg, {
                { name = "Track", value = track, inline = true },
            })
        end)
    end
end

local function confirmOvertake(overSrc, underSrc)
    local key = pairKey(overSrc, underSrc)
    local now = GetGameTimer()
    if LastClip[key] and (now - LastClip[key]) < COOLDOWN then return end
    LastClip[key] = now

    local overName, underName = racerName(overSrc), racerName(underSrc)
    -- Little in-race flourish for both drivers
    BroadcastToRacers("SPZ:overtake", { over = overName, under = underName })
    postClip(overSrc, overName, underName)
end

-- ── Position watch ────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(700)

        if RaceSession.state == SPZ.RaceState.LIVE then
            -- current position per racer
            local pos = {}
            for src, p in pairs(RaceSession.players) do
                if not p.dnf and not p.finished and p.position and p.position > 0 then
                    pos[src] = p.position
                end
            end

            -- detect A moving ahead of B since last tick (A's number dropped
            -- below B's, having been above it)
            for src, cur in pairs(pos) do
                local prev = LastPos[src]
                if prev and cur < prev then
                    -- src improved: who did it pass? whoever now sits at cur+1
                    for other, oPos in pairs(pos) do
                        if other ~= src and oPos == cur + 1 and (LastPos[other] or 0) <= cur then
                            local key = pairKey(src, other)
                            if not Pending[key] then
                                Pending[key] = { over = src, under = other, since = GetGameTimer() }
                            end
                        end
                    end
                end
            end

            -- confirm holds; drop broken ones
            local nowT = GetGameTimer()
            for key, pd in pairs(Pending) do
                local stillAhead = pos[pd.over] and pos[pd.under]
                                   and pos[pd.over] < pos[pd.under]
                if not stillAhead then
                    Pending[key] = nil
                elseif nowT - pd.since >= HOLD_MS then
                    confirmOvertake(pd.over, pd.under)
                    Pending[key] = nil
                end
            end

            LastPos = pos
        else
            LastPos, Pending = {}, {}
        end
    end
end)
