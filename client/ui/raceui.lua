-- client/ui/raceui.lua — race HUD page: countdown, overlay, standings, results, flourish.
-- Moved from spz-raceUI/client/main.lua when it was merged into spz-races. Its page is still
-- the "spz-raceUI" app in spz-hud; these locals send to that page only.
local SendNUIMessage, SetNuiFocus, SetNuiFocusKeepInput = SpzHudApp('spz-raceUI')

-- Base theme (server.cfg spz_theme_* convars via spz-core).
-- A message sent before the page has loaded is dropped, and the theme can
-- arrive before or after that — so remember the last one and re-send it when
-- the page reports ready (uiReady below).
local lastTheme = nil
local function pushRaceUITheme(theme)
    if theme and next(theme) then
        lastTheme = theme
        SendNUIMessage({ action = 'theme', theme = theme })
    end
end
local function pullTheme()
    local ok, theme = pcall(function() return exports['spz-core']:GetTheme() end)
    if ok and theme and next(theme) then pushRaceUITheme(theme) end
    return lastTheme ~= nil
end
CreateThread(function()
    -- spz-core may not have the theme yet right after a restart: keep asking.
    for _ = 1, 30 do
        if pullTheme() then return end
        Wait(1000)
    end
end)
AddEventHandler('SPZ:themeUpdated', function(theme) pushRaceUITheme(theme) end)

local isRaceOverlayVisible = false

-- HUD State Cache
local hudCache = {
    lapNum = 1,
    totalLaps = '?',
    raceType = nil,   -- 'circuit' | 'sprint', from the countdown
    checkpoint = 1,
    totalCheckpoints = '?',
    myPosition = '1',
    bestLapTime = 0,
    allTimeBest = 0
}

---@param data table { number: number, isGo: boolean, track: string, class: string, laps: number, gridPos: number, total: number }
local function ShowCountdown(data)
    if data.laps then hudCache.totalLaps = data.laps end
    if data.raceType then hudCache.raceType = data.raceType end
    if data.totalCheckpoints then hudCache.totalCheckpoints = data.totalCheckpoints end
    if data.total then hudCache.myPosition = data.gridPos or hudCache.myPosition end

    SendNUIMessage({
        action = 'countdown',
        data = data
    })
end

---@param data table { positions: table, mySource: number, lapNum: number, totalLaps: number, checkpoint: number, totalCheckpoints: number, bestLapTime: number, allTimeBest: number }
local function UpdateRaceOverlay(data)
    -- Update cache first regardless of visibility so we don't miss initialization telemetry
    if data.lapNum then hudCache.lapNum = data.lapNum end
    if data.totalLaps then hudCache.totalLaps = data.totalLaps end
    if data.checkpoint then hudCache.checkpoint = data.checkpoint end
    if data.totalCheckpoints then hudCache.totalCheckpoints = data.totalCheckpoints end
    if data.bestLapTime then hudCache.bestLapTime = data.bestLapTime end
    if data.allTimeBest then hudCache.allTimeBest = data.allTimeBest end

    if not isRaceOverlayVisible then return end
    
    if data.positions then
        for i, racer in ipairs(data.positions) do
            local p = Player(racer.source).state
            -- racer.name comes from the SERVER (always valid). Statebag name is
            -- only an override once it has replicated; never downgrade to
            -- "**INVALID**" or a stale local-index lookup.
            local stateName = p['spz:name'] or p['username']
            if stateName == "" or stateName == "**INVALID**" then stateName = nil end
            if (not racer.name) or racer.name == "" or racer.name == "**INVALID**" then
                local localIdx = GetPlayerFromServerId(racer.source)
                racer.name = (localIdx ~= -1 and GetPlayerName(localIdx)) or "Racer"
                if racer.name == "**INVALID**" then racer.name = "Racer" end
            end
            racer.name = stateName or racer.name
            racer.avatar = p['spz:avatar'] or racer.avatar
                or "https://raw.githubusercontent.com/SPiceZ21/spz-core-media-kit/main/Extra/nametag_profile.png"

            -- Statebag FIRST, then whatever the server already sent — never the
            -- other way round, and never an unconditional assignment.
            --
            -- These were being overwritten with the local statebag whatever it
            -- held, and a player statebag is only replicated to clients that
            -- have that player in SCOPE. Mid-race the field is spread across the
            -- map, so most racers are out of scope on most clients and every one
            -- of those reads nil — which wiped the nation and race number the
            -- server had already put in the payload (positions.lua reads the
            -- same statebags server-side, where they are always available).
            --
            -- The result was a tower with no flags and no numbers for anybody
            -- except the cars near you. This is the same downgrade the name
            -- handling above goes out of its way to avoid.
            racer.licenseClass = p['spz:licenseClass'] or racer.licenseClass or "D"
            -- Both spellings, then the server's value. See positions.lua.
            racer.nation     = p['spz:nation'] or p['nation'] or racer.nation
            racer.raceNumber = p['spz:raceNumber'] or p['raceNumber'] or racer.raceNumber
            
            if racer.source == (data.mySource or GetPlayerServerId(PlayerId())) then
                hudCache.myPosition = racer.position
            end
        end
    end

    SendNUIMessage({
        action = 'raceOverlay',
        data = {
            visible = true,
            positions = data.positions,
            mySource = data.mySource or GetPlayerServerId(PlayerId()),
            lapNum = hudCache.lapNum,
            totalLaps = hudCache.totalLaps,
            raceType = hudCache.raceType,
            checkpoint = hudCache.checkpoint,
            totalCheckpoints = hudCache.totalCheckpoints,
            bestLapTime = hudCache.bestLapTime,
            allTimeBest = hudCache.allTimeBest,
            myPosition = hudCache.myPosition,
        }
    })
end

-- The lap / total clocks are owned by the NUI's own interval. This resource
-- used to also push GetGameTimer() deltas (in this payload and from a 10Hz
-- thread), which ran off a different epoch than the NUI clock — the two
-- disagreed by a fraction of a second and the seconds digit flickered back and
-- forth between them. Lua sends lap *events*; the UI does the counting.

local function SetRaceOverlayVisible(visible)
    isRaceOverlayVisible = visible
    if not visible then
        SendNUIMessage({ action = 'hideAll' })
    else
        SendNUIMessage({
            action = 'raceOverlay',
            data = { visible = true }
        })
    end
end

local function HideAll()
    isRaceOverlayVisible = false
    SendNUIMessage({ action = 'hideAll' })
end

-- Post-race results are NON-BLOCKING: no NUI focus, so the player keeps full
-- control and can drive off immediately. Backspace-to-dismiss is handled here
-- in Lua (a focusless NUI can't receive keyboard input).
local _statsActive = false

local function HidePostRaceStats()
    _statsActive = false
    SendNUIMessage({ action = 'dismissStats' })
end

local function ShowPostRaceStats(data)
    _statsActive = true
    -- NO SetNuiFocus — player stays in control
    SendNUIMessage({
        action = 'postRaceStats',
        data = data
    })

    -- [Enter] full results: the leaderboard opened on this race
    -- (spz-leaderboard). Only offered when the leaderboard is running.
    local canOpenBoard = GetResourceState("spz-races") == "started"

    CreateThread(function()
        while _statsActive do
            if canOpenBoard then
                BeginTextCommandDisplayHelp("STRING")
                AddTextComponentSubstringPlayerName("~INPUT_FRONTEND_ACCEPT~ Full results   ~INPUT_FRONTEND_DELETE~ Close")
                EndTextCommandDisplayHelp(0, false, false, -1)
            end
            -- 177 = INPUT_FRONTEND_DELETE (Backspace)
            if IsControlJustPressed(0, 177) then
                HidePostRaceStats()
                break
            end
            -- 201 = INPUT_FRONTEND_ACCEPT (Enter)
            if canOpenBoard and IsControlJustPressed(0, 201) then
                HidePostRaceStats()
                pcall(function() exports["spz-races"]:OpenLastRaceResults() end)
                break
            end
            Wait(0)
        end
    end)
end

local function TT_Hide()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'tt_hide' })
end

local function TT_Broadcast(action, data)
    SendNUIMessage({ action = action, data = data })
end

-- 3D-billboard waypoint for the next CP: screen-projected position + distance.
-- data = { dist, onScreen, x, y }  (x/y are 0..1 screen coords)
local function UpdateCPWaypoint(data)
    if not isRaceOverlayVisible then return end
    SendNUIMessage({ action = 'cpWaypoint', data = data or {} })
end

-- Sector strip — data = { sector = 1..3, time, colour = 'purple'|'green'|'yellow', delta }
-- No isRaceOverlayVisible guard: time trials never call SetRaceOverlayVisible,
-- and the NUI only renders the strip while an overlay is on screen anyway.
local function UpdateSector(data)
    SendNUIMessage({ action = 'sector', data = data or {} })
end

-- Clear the strip for a new lap.
local function ResetSectors()
    SendNUIMessage({ action = 'sectorReset', data = {} })
end

-- Warmup tile panel — data = { remaining, total, track, class, gridPos }
local function ShowWarmup(data)
    SendNUIMessage({ action = 'warmup', data = data or {} })
end

local function HideWarmup()
    SendNUIMessage({ action = 'warmupEnd', data = {} })
end

-- ── Race intro ───────────────────────────────────────────────────────────────
--
-- The cover that hides the grid teleport, the sweep that opens onto the start
-- camera, and the card naming the race. Driven by spz-races: see
-- server/countdown.lua for the sequence and client/nui_bridge.lua for the relay.
--
-- THE WATCHDOG IS THE IMPORTANT PART. This puts an opaque full-screen element
-- over a live game, and every way a race can go wrong between the warmup
-- ending and the lights — a cancel, a crash in the state machine, a dropped
-- event, spz-races restarting mid-sequence — would otherwise leave the player
-- staring at it with no way to clear it. So the cover carries its own deadline
-- and lifts itself, whatever else happens. Nothing about the sequence depends
-- on this firing; it exists for when the sequence does not.
local INTRO_COVER_MAX_MS = 20000
local INTRO_CARD_MAX_MS  = 45000

local _introToken = 0

local function HideRaceIntro()
    _introToken = _introToken + 1
    SendNUIMessage({ action = 'raceIntro', data = { phase = 'end' } })
end

--- phase = 'cover' | 'reveal' | 'end'
--- reveal also carries { track, type, laps, vehicle, class, cops, traffic }
local function ShowRaceIntro(data)
    data = data or {}
    local phase = data.phase or 'cover'

    if phase == 'end' then
        HideRaceIntro()
        return
    end

    _introToken = _introToken + 1
    local token = _introToken

    SendNUIMessage({ action = 'raceIntro', data = data })

    local deadline = (phase == 'cover') and INTRO_COVER_MAX_MS or INTRO_CARD_MAX_MS
    SetTimeout(deadline, function()
        if _introToken ~= token then return end   -- superseded; not our problem
        print(("^3[spz-raceUI] race intro '%s' timed out after %dms — clearing.^7")
            :format(phase, deadline))
        HideRaceIntro()
    end)
end

-- ── Key hints ────────────────────────────────────────────────────────────────
-- The HUD prints the in-race keys so a driver never has to leave the race to
-- find out how to recover. Each hint is backed by its COMMAND, and the key shown
-- is the player's LIVE binding (spz-core KeyFor), re-read every second — so a
-- rebind in Settings → Key Bindings → FiveM shows up on the HUD.
--
-- Other resources add their keys with SetKeyHints:
--   SetKeyHints({ flip = { cmd = "spz_flip_car", default = "K" } })
-- A plain string still works (shown as-is, never re-read).
-- NOT Z for standings: ox_lib's radial menu is bound to Z.
-- Registry: Docs/keybinds.md
local KEY_STANDINGS = "N"

local HintSrc = { standings = { cmd = "standingstoggle", default = KEY_STANDINGS, pad = "LDOWN_INDEX" } }
local lastSent = nil

local function liveKey(src)
    if type(src) == "string" then return src end
    local ok, k = pcall(function() return exports["spz-core"]:KeyFor(src.cmd, src.default, src.pad) end)
    return (ok and k) or src.default
end

-- The hint that fits the moment, or nil.
local stuckSince = nil
local function suggestion()
    local st = LocalPlayer.state
    if not (st.inRace or st.inTimeTrial) then stuckSince = nil; return nil end
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh == 0 then return nil end
    if IsEntityUpsidedown(veh) or math.abs(GetEntityRoll(veh)) > 100.0 then return "flip" end
    if GetEntitySpeed(veh) < 1.5 and not IsEntityPositionFrozen(veh) then
        stuckSince = stuckSince or GetGameTimer()
        if GetGameTimer() - stuckSince > 6000 then return "respawn" end
    else
        stuckSince = nil
    end
    return nil
end

local function PushKeyHints(force)
    local data = {}
    for id, src in pairs(HintSrc) do
        -- the time-trial restart only means something during a time trial
        if id ~= "restart" or LocalPlayer.state.inTimeTrial then data[id] = liveKey(src) end
    end
    data.suggest = suggestion()
    local key = json.encode(data)
    if force or key ~= lastSent then
        lastSent = key
        SendNUIMessage({ action = 'keyhints', data = data })
    end
end

local function SetKeyHints(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if (type(v) == "string" and v ~= "") or (type(v) == "table" and v.cmd) then HintSrc[k] = v end
    end
    PushKeyHints(true)
end

-- Re-read bindings + suggestion every second; only sends when something changed.
-- The first sends also cover the NUI page not listening yet at start.
CreateThread(function()
    Wait(2000)
    PushKeyHints(true)
    while true do
        Wait(1000)
        PushKeyHints(false)
    end
end)

RegisterKeyMapping("standingstoggle", "Race: Toggle Standings List", "keyboard", KEY_STANDINGS)
RegisterKeyMapping("standingstoggle", "Race: Toggle Standings List (controller)", "PAD_DIGITALBUTTON", "LDOWN_INDEX")

-- Lobby pill — data = { mode = 'hidden'|'join'|'queued'|'intermission',
--                       queueCount, queuePos, seconds }
local function UpdateLobby(data)
    SendNUIMessage({ action = 'lobby', data = data or {} })
end

-- Wanted level — data = { stars = 0..max, max, escape = seconds left on the
--                         "losing them" countdown, or nil }
-- stars = 0 hides it. spz-core hides the vanilla star HUD every frame, so this
-- is the only star readout on screen.
local function UpdateWanted(data)
    SendNUIMessage({ action = 'wanted', data = data or {} })
end

-- Rewind — data = { active, secondsBack, fraction (0..1), bufferSeconds,
--                   creditMs = clock credit so far in this scrub }
--
-- THE SCRUB BAR THIS FED IS GONE. These are kept, and spz-races must keep
-- calling them, because the payload was never only a picture: `creditMs` is the
-- real time a rewind hands back, and the race/lap clocks are a local interval
-- in the page. Stop sending it and the displayed times run straight through a
-- scrub and stay wrong by its length for the rest of the race.
--
-- `secondsBack`, `fraction` and `bufferSeconds` are now ignored by the page.
-- They are left in the signature rather than dropped: spz-races builds them
-- anyway, and a narrower signature here would be one more thing to change if a
-- readout ever comes back.
local function UpdateRewind(data)
    SendNUIMessage({ action = 'rewind', data = data or {} })
end

-- End of a scrub: resets the page's credit baseline so the next one starts from
-- zero. Still required.
local function HideRewind()
    SendNUIMessage({ action = 'rewind', data = { active = false } })
end

-- The page announcing itself on load. If this prints a build that is not the
-- one in fxmanifest.lua, the client is serving a CACHED copy of the UI and no
-- amount of restarting the resource will change what is on screen — the cache
-- has to be cleared, or the player has to rejoin.
RegisterNUICallback('uiReady', function(data, cb)
    print(("^2[spz-raceUI] UI build %s loaded^7"):format(tostring(data and data.build)))
    cb('ok')
    -- The page just (re)loaded with default colours: give it the theme now.
    if not pullTheme() and lastTheme then SendNUIMessage({ action = 'theme', theme = lastTheme }) end
end)

-- Exports
exports('SetKeyHints', SetKeyHints)
exports('ShowCountdown', ShowCountdown)
exports('UpdateRaceOverlay', UpdateRaceOverlay)
exports('UpdateCPWaypoint', UpdateCPWaypoint)
exports('UpdateSector', UpdateSector)
exports('ResetSectors', ResetSectors)
exports('ShowWarmup', ShowWarmup)
exports('HideWarmup', HideWarmup)
exports('ShowRaceIntro', ShowRaceIntro)
exports('HideRaceIntro', HideRaceIntro)
exports('UpdateLobby', UpdateLobby)
exports('UpdateWanted', UpdateWanted)
exports('UpdateRewind', UpdateRewind)
exports('HideRewind', HideRewind)
exports('SetRaceOverlayVisible', SetRaceOverlayVisible)
exports('HideAll', HideAll)
exports('ShowPostRaceStats', ShowPostRaceStats)
exports('TT_Hide', TT_Hide)
exports('TT_Broadcast', TT_Broadcast)

-- One-shot UI sound. `name` keys the clip table in ui/src/sfx.ts (files live
-- in ui/public/aud/); `volume` is 0..1 and defaults to full.
-- Used for the checkpoint chimes, which are custom clips rather than
-- PlaySoundFrontend game audio and so have to go through the NUI page.
local function PlaySound(name, volume)
    SendNUIMessage({ action = 'sound', data = { name = name, volume = volume } })
end
exports('PlaySound', PlaySound)

-- Finish window countdown ("cross the line or DNF"). The NUI counts down itself
-- from `seconds`; this only starts and stops it.
local function ShowFinishWindow(seconds)
    SendNUIMessage({ action = 'finishWindow', data = { seconds = tonumber(seconds) or 0 } })
end
local function HideFinishWindow()
    SendNUIMessage({ action = 'finishWindowEnd', data = {} })
end
exports('ShowFinishWindow', ShowFinishWindow)
exports('HideFinishWindow', HideFinishWindow)

-- Fastest lap banner — data = { name, ms, mine }
local function ShowFastestLap(data)
    SendNUIMessage({ action = 'fastestLap', data = data or {} })
end
exports('ShowFastestLap', ShowFastestLap)

-- Split delta tower — data = { cp, total, split, delta }
local function ShowSplitDelta(data)
    SendNUIMessage({ action = 'splitDelta', data = data or {} })
end
exports('ShowSplitDelta', ShowSplitDelta)

-- Event Listeners for Race Bridge

RegisterNUICallback("tt_dismissResults", function(_, cb)
    _statsActive = false           -- stop the backspace poll if it's still running
    SetNuiFocus(false, false)
    TriggerEvent("SPZ:tt:nuiDismissResults")
    cb("ok")
end)

-- ── Proximity radar (ACC-style) ─────────────────────────────────────────────
-- While the race overlay is up, other players' cars within RADAR_RANGE are sent
-- to the NUI in MY car's frame (x = metres right, y = metres ahead, h = their
-- heading relative to mine). The NUI draws them round my car and lights the
-- side a car is overlapping on. 20 Hz while someone is close, 4 Hz scanning
-- otherwise, and one empty message when the last car leaves (no spam).
local RADAR_RANGE = 9.5   -- matches the NUI hexagon (9 m centre-to-corner)

local function dims(veh)
    local mn, mx = GetModelDimensions(GetEntityModel(veh))
    return mx.x - mn.x, mx.y - mn.y
end

CreateThread(function()
    local wasEmpty = true
    while true do
        local sleep = 250
        local ped = PlayerPedId()
        local me = GetVehiclePedIsIn(ped, false)
        local cars = {}
        if isRaceOverlayVisible and me ~= 0 then
            local myPos, myHead = GetEntityCoords(me), GetEntityHeading(me)
            for _, pid in ipairs(GetActivePlayers()) do
                if pid ~= PlayerId() then
                    local veh = GetVehiclePedIsIn(GetPlayerPed(pid), false)
                    if veh ~= 0 and veh ~= me and #(GetEntityCoords(veh) - myPos) < RADAR_RANGE then
                        local o = GetOffsetFromEntityGivenWorldCoords(me, GetEntityCoords(veh))
                        local w, l = dims(veh)
                        cars[#cars + 1] = {
                            x = math.floor(o.x * 100) / 100, y = math.floor(o.y * 100) / 100,
                            h = math.floor(GetEntityHeading(veh) - myHead), w = w, l = l,
                        }
                    end
                end
            end
            if #cars > 0 then sleep = 50 end
        end
        if #cars > 0 or not wasEmpty then
            local myW, myL = 2.0, 4.5
            if me ~= 0 then myW, myL = dims(me) end
            SendNUIMessage({ action = 'radar', data = { cars = cars, w = myW, l = myL } })
            wasEmpty = #cars == 0
        end
        Wait(sleep)
    end
end)

-- ── Freeroam HUD (top-right): licence class, credits, rank, crew, rating ─────
-- Read from the player's profile statebag (same fields the pause menu shows).
-- Hidden in races, minigames, time trials and whenever a menu has focus.
-- PAGE DOWN (rebindable) hides / shows it.
local frHidden, frSig = false, ""
local CLASS = { [0] = "D", [1] = "C", [2] = "B", [3] = "A", [4] = "S" }

-- GTA's own cash / bank pop-ups (top-right) never show on this server.
CreateThread(function()
    while true do
        HideHudComponentThisFrame(3)    -- cash
        HideHudComponentThisFrame(4)    -- MP cash
        HideHudComponentThisFrame(13)   -- cash change
        Wait(0)
    end
end)

RegisterCommand("spz_freeroamhud", function() frHidden = not frHidden; frSig = "" end, false)
RegisterKeyMapping("spz_freeroamhud", "HUD: show / hide freeroam info", "keyboard", "PAGEDOWN")

CreateThread(function()
    while true do
        Wait(500)
        local st = LocalPlayer.state
        local p  = type(st.profile) == "table" and st.profile or {}
        local show = not frHidden and not st.inRace and not st.inMinigame and not st.inTimeTrial
            and not st.spawnMenuOpen and not IsNuiFocused() and not IsPauseMenuActive()
            and not _G.SPZ_InTimeTrial and next(p) ~= nil
        local data = { visible = show }
        if show then
            local tier = tonumber(st.licenseTier or p.license_tier)
            data.license = st["spz:licenseClass"] or (tier and CLASS[tier]) or "D"
            data.credits = tonumber(p.credits) or 0
            data.rank    = st.rank or p.rank
            data.crew    = st.crewTag or p.crew_tag
            data.rating  = tonumber(st.iRating or p.i_rating)
            -- Discord avatar, set by spz-identity once the profile is fetched.
            data.avatar  = st["spz:avatar"] or st.avatarUrl or p.avatar_url
            -- The toggle key is on spz-hud's key strip, not repeated here.
        end
        local sig = json.encode(data)
        if sig ~= frSig then
            frSig = sig
            SendNUIMessage({ action = "freeroam", data = data })
        end
    end
end)


-- ── Flourish: big centre-screen moment (icon, title, value) ──────────────────
-- data = { title, value?, icon? (timer|crown|coins|overtake|down), color?, ms? }
-- Other resources: exports["spz-races"]:ShowFlourish(data), or
-- TriggerEvent / TriggerClientEvent("spz-raceUI:flourish", data).
local function ShowFlourish(data)
    if type(data) ~= "table" or not data.title then return end
    SendNUIMessage({ action = "flourish", data = data })
end
exports("ShowFlourish", ShowFlourish)
RegisterNetEvent("spz-raceUI:flourish", ShowFlourish)
