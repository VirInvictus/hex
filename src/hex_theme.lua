-- hex_theme.lua: palettes and semantic roles (design: docs/phase-7-feel.md
-- §6). Two palettes: classic (byte-identical to hex_util.ansi's original
-- values, the graceful fallback) and dragon (Kanagawa Dragon 24-bit).
--
-- Re-skin mechanism (deviation from the design's "delete hex_util.ansi"):
-- every module reads hex_util.ansi.X at call time through the shared table,
-- so use(name) MUTATES hex_util.ansi in place — instant re-skin with zero
-- call-site migration, and hex_util.ansi stays the single table. Roles map
-- semantic names to color keys; paint(role, text) wraps.
local util = require("src.hex_util")

local M = {}

M.current = "classic"

-- the ORIGINAL hex_util.ansi values, captured at load: classic restores
-- these byte-for-byte (golden-tested).
M.classic = {
  reset = "\27[0m", bold = "\27[1m",
  red = "\27[31m", green = "\27[32m", yellow = "\27[33m",
  magenta = "\27[35m", cyan = "\27[36m", gray = "\27[90m", white = "\27[37m",
}

-- Kanagawa Dragon as 24-bit SGR (RGB triples from the palette)
local function rgb(r, g, b)
  return ("\27[38;2;%d;%d;%dm"):format(r, g, b)
end

M.dragon = {
  reset = "\27[0m",
  bold = "\27[1m",
  red = rgb(196, 116, 110), -- #c4746e
  green = rgb(135, 169, 135), -- #87a987
  yellow = rgb(196, 178, 138), -- #c4b28a
  magenta = rgb(180, 136, 158), -- #b48dad (nearest Dragon tone)
  cyan = rgb(142, 164, 162), -- #8ea4a2
  gray = rgb(98, 94, 90), -- #625e5a
  white = rgb(197, 201, 197), -- #c5c9c5
}

M.palettes = { classic = M.classic, dragon = M.dragon }

-- semantic role -> color key (classic keeps today's look exactly)
M.roles = {
  label = "white", muted = "gray", accent = "cyan",
  error = "red", notice = "yellow",
  hp_good = "green", hp_warn = "yellow", hp_low = "magenta", hp_crit = "red",
  xp_good = "green", xp_ok = "yellow", xp_neutral = "cyan", xp_poor = "red",
  chat_tell = "magenta",
}

function M.use(name)
  local palette = M.palettes[name]
  if not palette then
    return false
  end
  M.current = name
  for key, value in pairs(palette) do
    util.ansi[key] = value
  end
  return true
end

function M.get(role)
  local key = M.roles[role]
  if not key then
    return ""
  end
  return util.ansi[key] or ""
end

function M.paint(role, text)
  local color = M.get(role)
  if color == "" then
    return tostring(text)
  end
  return color .. tostring(text) .. util.ansi.reset
end

-- restore classic (used by /hexoptions theme classic)
function M.restore_classic()
  M.use("classic")
end

return M
