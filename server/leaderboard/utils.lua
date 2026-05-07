-- server/leaderboard/utils.lua
function LB_FormatTime(ms)
    if not ms or ms <= 0 then return "--:--.---" end
    local minutes      = math.floor(ms / 60000)
    local seconds      = math.floor((ms % 60000) / 1000)
    local milliseconds = ms % 1000
    return string.format("%d:%02d.%03d", minutes, seconds, milliseconds)
end
