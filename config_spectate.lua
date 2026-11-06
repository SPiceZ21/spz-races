-- config_spectate.lua — spectate and the live race board.
-- Moved from spz-spectate/config.lua when it was merged into spz-races. Read as Config.Spectate.<option>.

-- config.lua
Config.Spectate = {}
local Config = Config.Spectate
-- ── Live race board ─────────────────────────────────────────────────────────
-- The passive board shown to everyone OUTSIDE the race: track, leader's lap,
-- and the running order with real time gaps. Racers are excluded — they already
-- carry the full tower in spz-raceUI and a second one would cover the road.
--
-- Lives here rather than in its own resource because it has the same audience
-- as spectating and reuses this resource's flags, fonts and theme bridge.
Config.Board = {
    enabled = true,

    -- Players in the queue still see it by default: they are about to race, and
    -- watching the current one is the point of the wait.
    showToQueued = true,

    -- Rows per view. The field can be 16 cars, but a passive overlay someone
    -- drives past should not own a third of the screen. Anything trimmed is
    -- reported as "+N MORE" rather than silently dropped.
    maxRows  = 8,   -- full view
    miniRows = 3,   -- mini view

    defaultView = "full",   -- "full" | "mini" | "hidden"

    -- Keep the board up through the post-race results window so freeroamers see
    -- the final classification instead of it vanishing at the flag.
    holdAfterFinishMs = 12000,

    -- Defaults only — every binding is rebindable by the player in FiveM's own
    -- key-binding settings. Set a key to "" to register the command with no
    -- default binding; the chat commands work either way.
    -- Registry: Docs/keybinds.md — check it before claiming a key.
    --
    -- NOT F7 (spz-speedcam records) and NOT F8, which FiveM reserves for its own
    -- console: binding it here left the board and the console fighting over
    -- every press.
    keys = {
        cycle = "F9",    -- full → mini → hidden → full
        hide  = "F11",   -- straight to hidden, or back to the last size
    },
}
