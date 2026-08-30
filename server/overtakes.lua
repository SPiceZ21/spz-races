-- server/overtakes.lua
-- Overtake detection → auto-clip (VIDEO). Watches live race positions; when a
-- racer passes another, it records a short video from the overtaker's screen
-- via `screencapture`, uploads it to FiveManage, and posts the link to Discord.
--
-- Recording starts the INSTANT the pass is detected (not after a hold) so the
-- clip actually contains the overtake. A per-pair cooldown stops a back-and-
-- forth battle from spamming clips. Server owns the FiveManage token — it is
-- never sent to the client.
--
-- Fallback chain: screencapture video → screenshot-basic still → text-only.

local COOLDOWN = (Config and Config.OvertakeCooldown) or 20000   -- per pair
local CLIP     = (Config and Config.Clip) or {}

local LastPos  = {}   -- [src] = position last tick
local LastClip = {}   -- ["A>B"] = gameTimer of last clip

local function pairKey(a, b) return a .. ">" .. b end

local function racerName(src)
    local p = RaceSession.players[src]
    return (p and p.name) or GetPlayerName(src) or ("Racer " .. src)
end

local function raceWebhook()
    if GetResourceState("spz-log") ~= "started" then return nil end
    local ok, wh = pcall(function() return exports["spz-log"]:GetWebhook("race") end)
    if ok and wh and wh ~= "" and not wh:find("YOUR_WEBHOOK") then return wh end
    return nil
end

-- ── Discord posts ─────────────────────────────────────────────────────────────

local function postEmbed(webhook, title, description, videoUrl)
    if not webhook then return end
    local embed = { title = title, description = description, color = 15844367 }
    if videoUrl then embed.description = description .. "\n" .. videoUrl end
    PerformHttpRequest(webhook, function() end, "POST",
        json.encode({ embeds = { embed } }), { ["Content-Type"] = "application/json" })
end

-- ── Capture ───────────────────────────────────────────────────────────────────

local function captureVideo(overSrc, msg, webhook)
    local url   = CLIP.fivemanageUrl
    local token = CLIP.fivemanageToken
    if not url or not token or token == "" then return false end

    exports["screencapture"]:startVideoCaptureUpload(overSrc, url, {
        duration  = CLIP.durationS or 10,
        filename  = "overtake",
        maxWidth  = CLIP.maxWidth  or 1280,
        maxHeight = CLIP.maxHeight or 720,
        headers   = { ["Authorization"] = token },
    }, function(result)
        if result and result.status == "success" and result.response
           and result.response.data and result.response.data.url then
            postEmbed(webhook, "🏁 OVERTAKE", msg, result.response.data.url)
        else
            -- upload failed → at least post the text
            postEmbed(webhook, "🏁 OVERTAKE", msg, nil)
        end
    end)
    return true
end

local function captureStill(overSrc, msg, webhook)
    if GetResourceState("screenshot-basic") ~= "started" or not webhook then return false end
    exports["screenshot-basic"]:requestClientScreenshot(overSrc, {
        encoding    = "jpg",
        quality     = 0.75,
        targetField = "file",
        targetURL   = webhook,
        postData    = {
            payload_json = json.encode({
                embeds = {{ title = "🏁 OVERTAKE", description = msg, color = 15844367 }},
            }),
        },
    }, function() end)
    return true
end

local function fireClip(overSrc, underSrc, overName, underName)
    local track   = RaceSession.track and RaceSession.track.name or "a track"
    local msg     = ("**%s** overtook **%s** on **%s**"):format(overName, underName, track)
    local webhook = raceWebhook()

    -- In-race flourish for everyone. The source ids ride along so a client can
    -- tell whether IT made the pass — names are not identity (two racers can
    -- share one), and the overtaker's car plays the nitrous effect.
    BroadcastToRacers("SPZ:overtake", {
        over     = overName,
        under    = underName,
        overSrc  = overSrc,
        underSrc = underSrc,
    })

    -- video → still → text, first that works wins
    if CLIP.enabled and GetResourceState("screencapture") == "started"
       and captureVideo(overSrc, msg, webhook) then return end
    if captureStill(overSrc, msg, webhook) then return end
    postEmbed(webhook, "🏁 OVERTAKE", msg, nil)
end

local function tryClip(overSrc, underSrc)
    local key = pairKey(overSrc, underSrc)
    local now = GetGameTimer()
    if LastClip[key] and (now - LastClip[key]) < COOLDOWN then return end
    LastClip[key] = now
    fireClip(overSrc, underSrc, racerName(overSrc), racerName(underSrc))
end

-- ── Position watch ────────────────────────────────────────────────────────────
-- Poll fast so the clip starts as close to the pass as possible.

CreateThread(function()
    while true do
        Wait(500)

        if RaceSession.state == SPZ.RaceState.LIVE then
            local pos = {}
            for src, p in pairs(RaceSession.players) do
                if not p.dnf and not p.finished and p.position and p.position > 0 then
                    pos[src] = p.position
                end
            end

            -- A moved ahead of B since last tick → the pass just happened.
            for src, cur in pairs(pos) do
                local prev = LastPos[src]
                if prev and cur < prev then
                    for other, oPos in pairs(pos) do
                        if other ~= src and oPos == cur + 1 and (LastPos[other] or 0) <= cur then
                            tryClip(src, other)   -- record NOW, at the moment of the pass
                        end
                    end
                end
            end

            LastPos = pos
        else
            LastPos = {}
        end
    end
end)
