-- server/bots.lua
-- Ghost-bots: fill a thin race with replayed real human lines so a near-empty
-- server still feels alive — the cold-start fix. Bots are simulated purely
-- server-side (progress derived from the recorded per-CP split times) and
-- rendered client-side as solid replayed cars synced to the GO clock.
--
-- Scoring rule: bots occupy the LIVE standings and push a human's visible
-- position, but they are NOT written into results.finishers and carry no
-- rewards — spz-progression only ever sees real player sources. Humans are
-- scored against humans; bots are presence, not competition for rating.

local B = Config.Bots or {}

local function humanCount()
    local n = 0
    for _ in pairs(RaceSession.players or {}) do n = n + 1 end
    return n
end

-- ── Field construction (called at GO from countdown.lua) ─────────────────────
function SpawnRaceBots()
    RaceSession.bots = nil
    if B.enabled == false then return end

    local track = RaceSession.track
    if not track then return end

    local humans = humanCount()
    if B.onlyWhenSolo and humans > 1 then return end

    local need = (B.targetField or 6) - humans
    if need <= 0 then return end

    local ok, lines = pcall(function()
        return exports["spz-raceline"]:GetBotLines(track.name, need)
    end)
    if not ok or type(lines) ~= "table" or #lines == 0 then return end

    local laps   = (track.type == "sprint") and 1 or (track.laps or 1)
    local numCPs = (track.checkpoints and #track.checkpoints) or 1
    local go     = RaceSession.startTime or GetGameTimer()

    RaceSession.bots = {}
    local payload = {}

    for i, ln in ipairs(lines) do
        local lapMs = (ln.ms and ln.ms > 1000) and ln.ms or 90000

        -- Normalise CP splits to numCPs cumulative ms. Synthesise an even
        -- schedule when the stored line predates split capture.
        local splits = {}
        if type(ln.splits) == "table" and #ln.splits >= numCPs then
            for c = 1, numCPs do splits[c] = ln.splits[c] end
        else
            for c = 1, numCPs do splits[c] = math.floor(lapMs * c / numCPs) end
        end

        local id = "bot_" .. i
        RaceSession.bots[id] = {
            id = id, name = ln.name or ("Ghost " .. i),
            lapMs = lapMs, splits = splits, laps = laps, numCPs = numCPs,
            go = go, finished = false, finish_time = nil,
            lap = 1, cp = 1, last_cp_time = go, within = 0,
        }

        payload[#payload + 1] = {
            id = id, name = ln.name, model = ln.model,
            points = ln.points, lapMs = lapMs, laps = laps,
        }
    end

    if not next(RaceSession.bots) then return end

    -- Clients render solid cars locally, in sync with the shared GO clock.
    BroadcastToRacers("SPZ:bots:spawn", payload)
    print(("[Bots] Backfilled %d ghost-bot(s) on %s (%d human%s)")
        :format(#payload, track.name, humans, humans == 1 and "" or "s"))
end

function ClearRaceBots()
    RaceSession.bots = nil
    BroadcastToRacers("SPZ:bots:clear")
end

-- ── Progress simulation ──────────────────────────────────────────────────────
local function simulate(now)
    local bots = RaceSession.bots
    if not bots then return end
    for _, b in pairs(bots) do
        if not b.finished then
            local e     = now - b.go
            local total = b.lapMs * b.laps
            if e >= total then
                b.finished    = true
                b.finish_time = total
                b.lap         = b.laps
                b.cp          = b.numCPs
                b.last_cp_time = b.go + total
                b.within      = b.lapMs
            else
                b.lap = math.floor(e / b.lapMs) + 1
                local within = e % b.lapMs
                local cp = 1
                for c = 1, b.numCPs do
                    if within >= b.splits[c] then cp = c + 1 else break end
                end
                if cp > b.numCPs then cp = b.numCPs end
                b.cp    = cp
                b.within = within
                b.last_cp_time = b.go + (b.lap - 1) * b.lapMs + (b.splits[math.max(1, cp - 1)] or 0)
            end
        end
    end
end

-- Standings rows for the live tower merge (positions.lua).
function GetBotStandings(now)
    now = now or GetGameTimer()
    simulate(now)
    local rows = {}
    for _, b in pairs(RaceSession.bots or {}) do
        rows[#rows + 1] = {
            bot = true, id = b.id, name = b.name,
            lap = b.lap, cp = b.cp, finished = b.finished,
            finish_time  = b.finish_time or 0,
            last_cp_time = b.last_cp_time,
        }
    end
    return rows
end

-- Final ordered bot list for the results grid (display only).
function GetBotResults()
    local rows = GetBotStandings(GetGameTimer())
    table.sort(rows, function(a, b)
        if a.finished ~= b.finished then return a.finished end
        if a.finished and b.finished then return a.finish_time < b.finish_time end
        if a.lap ~= b.lap then return a.lap > b.lap end
        if a.cp  ~= b.cp  then return a.cp  > b.cp  end
        return (a.last_cp_time or 0) < (b.last_cp_time or 0)
    end)
    return rows
end
