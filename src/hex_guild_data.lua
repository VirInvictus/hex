-- hex_guild_data.lua: the guild-pack registry (design:
-- docs/phase-7-feel.md §7). Pure data. The primaries themselves live in
-- hex_skilldata (ported in Phase 3 and already feeding /skillcost and the
-- TM gating through config.guild) -- this table describes what each pack
-- REGISTERS beyond that.
--
-- The tt_dw reality (§7): guild behavior concentrates in magic/ (witch,
-- wizard), faith/ (priest), quota + daggers (thief); assassin and warrior
-- have primaries rows only, so their v1 packs are data-only and register
-- nothing. Thief and priest carry the only trigger content and are the
-- next ports (sources: items/daggers.tin for the two tingle lines +
-- DAG chip; faith totem triggers + /hextotem and the find-ritual
-- movement-word decoder per the design's v1 list).
local M = {}

M.packs = {
  adventurers = { content = "primaries", note = "no guild-specific behavior" },
  warriors = { content = "primaries", note = "tt_dw has no warrior triggers" },
  assassins = { content = "primaries", note = "tt_dw has no assassin triggers" },
  witches = { content = "primaries", note = "tea brewing does not exist (§7)" },
  wizards = { content = "primaries", note = "spell tracking is guild-agnostic (Phase 4)" },
  thieves = { content = "planned", note = "dagger tingle triggers + DAG chip (items/daggers.tin)" },
  priests = { content = "planned", note = "rod-charge gags, totem triggers + /hextotem, find-ritual decoder" },
  fools = { content = "primaries", note = "no tt_dw content" },
}

-- config.guild accepts "none" (the options default); it registers nothing.
M.known = { adventurers = true, warriors = true, assassins = true, witches = true, wizards = true, thieves = true, priests = true, fools = true, none = true }

return M
