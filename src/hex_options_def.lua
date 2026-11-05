-- hex_options_def.lua: the /hexoptions schema (design:
-- docs/phase-7-feel.md §4). Pure ordered data: key, type, default, scope,
-- choices/min/max, aliases, desc, apply-key (the hooks table lives in
-- main.lua wiring; absent apply = config write only).
--
-- Deliberately absent (deviations noted): combat_spam (per-alt combat has
-- its own /combat command — two writers to one key invites drift), gags
-- on/off (no module flag exists yet), walker_confirm (no such feature).
local M = {}

M.schema = {
  {
    key = "sound", type = "bool", default = false, scope = "global",
    desc = "play sound effects (defaults off; opt in with sound on)",
    apply = "sound",
  },
  {
    key = "sound_dir", type = "path", default = nil, scope = "global", hidden = true,
    desc = "where the CC0 mp3 set lives",
  },
  {
    key = "sound_volume", type = "number", default = 1.0, min = 0.1, max = 3.0,
    scope = "global", desc = "sfx amplification",
  },
  {
    key = "tts", type = "bool", default = false, scope = "global", aliases = { "speech" },
    desc = "speak event notices (needs a TTS-enabled blightmud build)",
    apply = "tts",
  },
  {
    key = "theme", type = "enum", default = "classic", choices = { "classic", "dragon" },
    scope = "global", desc = "classic is today's look; dragon is Kanagawa 24-bit",
    apply = "theme",
  },
  {
    key = "chat_tab", type = "bool", default = true, scope = "global",
    desc = "create the chat tab on start (mirror mode unaffected)",
    apply = "chat_tab",
  },
  {
    key = "map_ansi", type = "enum", default = "strip", choices = { "strip", "ansi" },
    scope = "global", desc = "/dwmap: strip the MUD's color codes or keep them",
  },
  {
    key = "map_panel", type = "enum", default = "auto",
    choices = { "auto", "toprows", "tab", "inline", "off" },
    scope = "global", desc = "minimap render ladder (applies at next start)",
  },
  {
    key = "allow_swim", type = "bool", default = false, scope = "global",
    desc = "/goto may route through swim edges",
  },
  {
    key = "avoid_gates", type = "bool", default = false, scope = "global",
    desc = "/goto routes around city gates (they lock at night)",
  },
  {
    key = "mission_travel_time", type = "number", default = 60, min = 10, max = 600,
    scope = "global", aliases = { "travel" },
    desc = "seconds of travel assumed per mission XP/hour estimate",
  },
  {
    key = "quow_stale_days", type = "number", default = 60, min = 7, max = 365,
    scope = "global", desc = "age at which the connect-time Quow warning fires",
  },
  {
    key = "guild", type = "enum", scope = "global",
    default = "none", choices = { "none", "adventurers", "warriors", "assassins", "thieves", "priests", "witches", "wizards", "fools" },
    desc = "drives TM gating and /skillcost primary flags (auto-detected from score)",
    apply = "guild",
  },
  { key = "quow_db", type = "path", default = nil, scope = "global", hidden = true },
  { key = "rooms_db", type = "path", default = nil, scope = "global", hidden = true },
}

function M.find(key)
  for _, entry in ipairs(M.schema) do
    if entry.key == key then
      return entry
    end
    for _, alias in ipairs(entry.aliases or {}) do
      if alias == key then
        return entry
      end
    end
  end
  return nil
end

return M
