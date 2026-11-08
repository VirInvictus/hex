-- hex_guild.lua: the guild-pack framework (design: docs/phase-7-feel.md
-- §7; v1 slice shipped v0.15.0).
--
-- The pack selection keys off config.guild — the score-verbose guild
-- clause, wire-verified 2026-11-08 ("you are level 3 in the Assassins'
-- Guild" on Brandon's join). The design's char.info/guildspec autoload is
-- deferred until that field is captured (it pushes at login only; no
-- capture has ever contained it), and config.guild is already the working
-- path for /skillcost primaries and TM gating.
--
-- v1 pack content: assassin/warrior/witch/wizard are primaries-data-only
-- (hex_skilldata + config.guild already deliver it), so they register no
-- triggers. Thief and priest carry the first trigger ports (see
-- hex_guild_data). Changing /hexoptions guild re-runs refresh() via the
-- options hook; v1 registers no handles, so refresh is a state update.
local guild_data = require("src.hex_guild_data")

local M = {}

M.deps = {}
M.pack = nil -- the active guild, or nil for none/unknown

function M.setup(deps)
  M.deps = deps or {}
  M.refresh()
end

-- Re-read config.guild; called by the options hook on /hexoptions guild.
function M.refresh()
  local guild = M.deps.config and M.deps.config.get("guild", "none") or "none"
  if guild == "none" or not guild_data.known[guild] then
    M.pack = nil
    return nil
  end
  M.pack = guild
  return M.pack
end

-- One-line status for /doctor: what the active pack contributes in v1.
function M.status()
  local guild = M.deps.config and M.deps.config.get("guild", "none") or "none"
  if guild == "none" then
    return "no guild (adventurer)"
  end
  local info = guild_data.packs[guild]
  if not info then
    return guild .. " (unknown pack)"
  end
  return guild .. ": " .. info.note
end

return M
