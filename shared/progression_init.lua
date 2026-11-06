-- shared/progression_init.lua — SPZ.Logger / SPZ.Notify helpers.
-- Moved from spz-progression/shared/init.lua when it was merged into spz-races.

-- shared/init.lua
SPZ = SPZ or {}

function SPZ.Logger(moduleName)
    return {
        debug = function(msg, ...) print(("[DEBUG] [%s] %s"):format(moduleName, type(msg) == "string" and msg:format(...) or tostring(msg))) end,
        info  = function(msg, ...) print(("[INFO] [%s] %s"):format(moduleName, type(msg) == "string" and msg:format(...) or tostring(msg))) end,
        warn  = function(msg, ...) print(("[WARN] [%s] %s"):format(moduleName, type(msg) == "string" and msg:format(...) or tostring(msg))) end,
        error = function(msg, ...) print(("[ERROR] [%s] %s"):format(moduleName, type(msg) == "string" and msg:format(...) or tostring(msg))) end,
    }
end

if IsDuplicityVersion() then
    SPZ.Notify = function(source, msg, ntype, duration)
        TriggerClientEvent('ox_lib:notify', source, {
            description = msg, type = ntype or "info", duration = duration,
        })
    end
end
