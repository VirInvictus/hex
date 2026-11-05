-- hex_stats.lua: the per-alt stat store fed by `score verbose stats`
-- (design: docs/phase-3-character.md §4, wire-verified 2026-11-05 against
-- the capture transcript: the block is TWO dot-padded lines, and the same
-- pair tails `score verbose`).
--
-- Live shapes (capture lines 161-164):
--   Constitution ... 13        Intelligence ... 13        Wisdom ......... 13        Weight ......... 80.0 kg
--   Dexterity ...... 13        Strength ....... 13        Height ......... 175 cm
--
-- The stored values are the SHOWN stats; Phase 4's stat-item netting owns
-- raw = shown - boost (contract reserved there). Consumers today: the
-- skills bonus math (skills.stats() reads hex.stats.<alt>), /spellinfo,
-- and /skillcost.
--
-- Pure: parse_lines/stats display; runtime glue owns triggers + commands.
local util = require("src.hex_util")
local notify = require("src.hex_notify")

local M = {}

M.deps = {}
M.state = {} -- { con, dex, int, wis, str, height, weight }

-- RUST patterns for the two dot-padded lines (dot runs vary: 3/6/3/7).
local LINE_A = "^Constitution \\.+ (\\d+)\\s+Intelligence \\.+ (\\d+)\\s+Wisdom \\.+ (\\d+)\\s+Weight \\.+ ([\\d.]+) kg$"
local LINE_B = "^Dexterity \\.+ (\\d+)\\s+Strength \\.+ (\\d+)\\s+Height \\.+ (\\d+) cm$"

-- Lua-pattern twins for the pure parser (tests).
local LUA_LINE_A = "^Constitution %.+ (%d+)%s+Intelligence %.+ (%d+)%s+Wisdom %.+ (%d+)%s+Weight %.+ ([%d.]+) kg$"
local LUA_LINE_B = "^Dexterity %.+ (%d+)%s+Strength %.+ (%d+)%s+Height %.+ (%d+) cm$"

-- --- pure core ---

-- Parse one line; returns "a"/"b" when it matched a stats line.
function M.parse_line(state, line)
  local s = util.trim(tostring(line))
  local con, int, wis, weight = s:match(LUA_LINE_A)
  if con then
    state.con, state.int, state.wis = tonumber(con), tonumber(int), tonumber(wis)
    state.weight = tonumber(weight)
    return "a"
  end
  local dex, str, height = s:match(LUA_LINE_B)
  if dex then
    state.dex, state.str, state.height = tonumber(dex), tonumber(str), tonumber(height)
    return "b"
  end
  return nil
end

-- --- runtime glue ---

function M.setup(deps)
  M.deps = deps
  M.load_if_needed()
end

function M.load_if_needed()
  local alt = M.deps.config and M.deps.config.alt() or nil
  if M.alt_loaded == alt then
    return
  end
  M.alt_loaded = alt
  M.state = {}
  if not alt then
    return
  end
  local raw = store.disk_read("hex.stats." .. alt)
  if raw then
    local ok, saved = pcall(json.decode, raw)
    if ok and type(saved) == "table" then
      M.state = saved
    end
  end
end

function M.save()
  local alt = M.deps.config and M.deps.config.alt() or nil
  if not alt then
    return
  end
  store.disk_write("hex.stats." .. alt, json.encode(M.state))
end

function M.register(trigger_add, Regex)
  trigger_add(Regex.new(LINE_A), {}, function(matches)
    M.load_if_needed()
    M.state.con, M.state.int, M.state.wis = tonumber(matches[2]), tonumber(matches[3]), tonumber(matches[4])
    M.state.weight = tonumber(matches[5])
    M.save()
  end)
  trigger_add(Regex.new(LINE_B), {}, function(matches)
    M.load_if_needed()
    M.state.dex, M.state.str, M.state.height = tonumber(matches[2]), tonumber(matches[3]), tonumber(matches[4])
    M.save()
  end)
end

-- /stats: display. /stats refresh: send (user alias).
function M.cmd_stats(args)
  if util.trim(args) == "refresh" then
    mud.send("score verbose stats")
    print(util.ansi.gray .. "[hex] sent: score verbose stats" .. util.ansi.reset)
    return
  end
  M.load_if_needed()
  local st = M.state
  if not st.con then
    print(util.ansi.gray .. "[hex] no stats yet; /stats refresh reads them (or run: score verbose stats)" .. util.ansi.reset)
    return
  end
  print(
    util.ansi.bold
      .. "Stats"
      .. util.ansi.reset
      .. util.ansi.gray
      .. "  (shown values; item netting lands with Phase 4)"
      .. util.ansi.reset
  )
  print(
    ("  con %d  dex %d  int %d  wis %d  str %d"):format(st.con, st.dex, st.int, st.wis, st.str)
  )
  if st.height or st.weight then
    print(util.ansi.gray .. ("  height %s cm  weight %s kg"):format(tostring(st.height or "?"), tostring(st.weight or "?")) .. util.ansi.reset)
  end
end

return M
