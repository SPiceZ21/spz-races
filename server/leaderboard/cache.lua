-- server/leaderboard/cache.lua
LBCache = {}
local _data = {}

function LBCache.Get(key)
    local entry = _data[key]
    if not entry then return nil end
    if os.time() > entry.expiry then
        _data[key] = nil
        return nil
    end
    return entry.value
end

function LBCache.Set(key, value, ttl)
    _data[key] = { value = value, expiry = os.time() + (ttl or 30) }
end

function LBCache.Bust(keyPattern)
    if not keyPattern then _data = {}; return end
    for k in pairs(_data) do
        if k:match(keyPattern) then _data[k] = nil end
    end
end
