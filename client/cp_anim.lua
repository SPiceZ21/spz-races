-- client/cp_anim.lua
-- Moving gate panels. GTA's prop shaders cannot scroll a texture, so each gate
-- atlas is rendered live by a small DUI page (html/cp/anim.html) and swapped
-- over the streamed one in spz_checkpoint.ytd with AddReplaceTexture.
--
-- The poles (spz-checkpointprop) use one texture; its colour bands flow up.
--
-- The DUIs exist only while gates are on screen: checkpoints.lua acquires on
-- the first prop it places and releases when it clears them; a short linger
-- avoids rebuilding the pages between back-to-back races.

local TXD    = "spz_checkpoint"
local ATLAS  = { spz_cp_gate = { 256, 1024 } }   -- one texture: [pending | taken | start | finish] columns
local LINGER = 20000

local active   = false
local duis     = {}
local releaseT = 0

local function enabled()
    return not (Config and Config.AnimatedGates == false)
end

local function create()
    if active then return end
    active = true
    local rtxd = CreateRuntimeTxd("spz_cp_anim")
    for name, size in pairs(ATLAS) do
        local url = ("nui://%s/html/cp/anim.html?tex=%s"):format(GetCurrentResourceName(), name)
        local dui = CreateDui(url, size[1], size[2])
        duis[#duis + 1] = dui
        CreateRuntimeTextureFromDuiHandle(rtxd, name, GetDuiHandle(dui))
        AddReplaceTexture(TXD, name, "spz_cp_anim", name)
    end
end

local function destroy()
    if not active then return end
    active = false
    for name in pairs(ATLAS) do RemoveReplaceTexture(TXD, name) end
    for _, d in ipairs(duis) do DestroyDui(d) end
    duis = {}
end

--- A gate prop is being placed.
function SPZ_CpAnimAcquire()
    releaseT = 0
    if enabled() then create() end
end

--- Every gate prop was removed.
function SPZ_CpAnimRelease()
    if not active then return end
    local stamp = GetGameTimer()
    releaseT = stamp
    SetTimeout(LINGER, function()
        if releaseT == stamp then destroy() end
    end)
end

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then destroy() end
end)
