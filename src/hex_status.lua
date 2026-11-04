-- hex_status.lua: the 3-row status area. render() is pure (unit-tested);
-- apply() is the only blightmud-bound part. Layout, ported from tt_dw's
-- status panel concept:
--   row 0 (bar): HP bar + GP bar + XP
--   row 1:       current room
--   row 2 (bar): XP rate + burden + alignment
local util = require("src.hex_util")
local vitals_mod = require("src.hex_vitals")

local M = {}

local BAR_W = 16

local function colored(name, text)
  return util.ansi[name] .. text .. util.ansi.reset
end

local function points_bar(label, cur, max)
  local r = util.ratio(cur, max)
  local bar = util.bar(BAR_W, r)
  return colored(util.hp_color_name(r), label .. bar) .. " " .. tostring(cur or "?") .. "/" .. tostring(max or "?")
end

function M.render(st, room, width)
  local c = st.cur
  local m = st.max

  local line1 = points_bar("HP", c.hp, m.hp)
    .. "  "
    .. points_bar("GP", c.gp, m.gp)
    .. "  "
    .. colored("cyan", "XP " .. util.comma(c.xp or 0))

  local room_text = room.name or "waiting for room info..."
  if room.id then
    room_text = room_text .. colored("gray", " #" .. room.id:sub(1, 10))
  end
  if c.burden then
    room_text = room_text .. colored("gray", "  burden " .. tostring(c.burden) .. "%")
  end
  local line2 = room_text

  local line3 = "XP/h "
  local rate = st.rate
  if rate then
    line3 = line3 .. colored(vitals_mod.xp_rate_name(rate), util.comma(rate))
  else
    line3 = line3 .. colored("gray", "-")
  end
  if c.alignment then
    line3 = line3 .. colored("gray", "  " .. tostring(c.alignment))
  end
  return { line1, line2, line3 }
end

function M.setup()
  blight.status_height(3)
end

function M.apply(lines)
  blight.status_line(0, lines[1])
  blight.status_line(1, lines[2])
  blight.status_line(2, lines[3])
end

return M
