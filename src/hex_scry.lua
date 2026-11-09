-- hex_scry.lua: situational awareness commands (v0.18.0). Read-only
-- investigation of the current room, the surrounding zone, the in-game
-- night, and the last death site:
--   /hexexits   verbose exits: command, destination, gate/swim/climb/journey
--               markers, hidden/unsafe exit-flag bits
--   /hexzone    room + area + Quow zone + graph-component facts (landmark
--               reachability: the BP / Genua / Bad Ass questions)
--   /hexnight   day-part from the weather line + dark-room signals, and the
--               night implications (gates lock, climbs fail, pushes unverified)
--   /hexcorpse  death-site tracker (mark / clear / show; the walk back to
--               your corpse is one command)
--
-- Nothing here ever sends to the MUD: triggers only RECORD signals, and the
-- commands only read rooms.db / Quow / hex.db and print.
--
-- Wire facts behind the triggers (all from Brandon's own session logs at
-- ~/.local/share/blightmud/logs/discworld/, 2026-11-06..09; hundreds of
-- samples each unless noted):
--   weather line: "It is a freezing cold spindlewinter's night with a gentle
--     breeze and dense cloud cover." Outdoor rooms append it to the
--     description; observed day-parts morning / afternoon / evening / night
--     (dawn / dusk / noon / midnight are tolerated extras, unobserved yet).
--   dark room: the description collapses to "Something.  It's dark here,
--     isn't it?"; the map payload becomes "It is too dark to see anything.";
--     a moon line ("...the eerie light of the last quarter moon.") can light
--     the room; dark room.info pushes carry NO identifier (v0.17.2's fact);
--     LIT outdoor rooms carry their own night line ("It is night and the
--     last quarter moon is hidden by the clouds.", 678 samples).
--   death: WIRE-VERIFIED 2026-11-08 20:25 (his own log, the forest clearing
--     death): unseen creatures render as "Something" in the dark; Death
--     appears mid-fight ("Someone says: DARK IN HERE, ISN'T IT?" then "You
--     turn and see Death standing behind you."), quotes random small-caps
--     lines, and leaves ("Death gets back onto Binky and rides away."); the
--     newbie dwarfs hand out the book and a free ride. Anchors below use
--     the two invariant lines.
--   consider: the 13-rung ladder is pinned in the doc mirror (helpdir/
--     consider); live shapes "The rat would be an easy target." and "The
--     feral pigeon is weaker than you." (2026-11-08 log).
--   corpses: floor lines, kill lines and the rats-eating-corpses family all
--     captured in the 2026-11-08/09 logs.
--
-- Pure cores (new_state/observe_*/verdict/night_warning/report/render_*/
-- component_line/death_*/fmt_secs) take no blightmud globals; runtime glue
-- and register() sit below the marker.
local util = require("src.hex_util")
local queries = require("src.hex_queries")
local paths = require("src.hex_paths")

local M = {}

-- Freshness windows (seconds): the weather line speaks for at most an hour
-- (the Discworld day is fast), dark signals speak for ten minutes (you may
-- have moved on).
M.DAYPART_STALE = 3600
M.DARK_FRESH = 600

-- Known-disconnected landmarks (the "can /goto take me there?" set). Ids
-- picked from the 2026-11-09 rooms.db build; name+area recorded so a future
-- rebuild that moves an id is diagnosable. Facts per docs/phase-2-mapper.md
-- plus live confirmation (Bad Ass, 2026-11-09).
M.LANDMARKS = {
  { label = "Bes Pelargic", id = "f6796763504ddc18237e6c543e42fef63f3f766c", name = "middle of Palace Approach", note = "sea gap: boat-only in the identified graph" },
  { label = "Genua", id = "0ebbc916f35c03181af68366e85e7863d4ca5d68", name = "Royal Avenue", note = "directed-unreachable from AM (measured 2026-11-05)" },
  { label = "Bad Ass", id = "1a146e63d6e3a52afca87b52f074688342a5f974", name = "pleasant village lane in Bad Ass", note = "disconnected Ramtops component (confirmed live 2026-11-09)" },
  { label = "Lancre Town", id = "6c8d4449dea568e4ecc2b49c7153f16cf3ada8c6", name = "centre of Lancre Town square", note = "disconnected Ramtops component" },
}

function M.new_state()
  return {
    daypart = nil, daypart_at = nil, moon = nil, moon_at = nil, dark_at = nil,
    kills = {}, corpses = {}, corpse_eaten_at = nil, consider = {},
    carriage = nil,
  }
end

function M.observe_weather(st, daypart, now)
  if not st then
    return
  end
  st.daypart = tostring(daypart or "")
  st.daypart_at = now
end

function M.observe_dark(st, now)
  if not st then
    return
  end
  st.dark_at = now
end

-- An IDENTIFIED room push means the room is lit (dark rooms push without
-- the identifier, v0.17.2's wire fact), so it clears the dark signal and
-- the floor: corpses seen belong to the room you saw them in.
function M.observe_room(st, id)
  if st and id then
    st.dark_at = nil
    st.corpses = {}
    st.corpse_eaten_at = nil
  end
end

-- The map payload's dark line (main.lua feeds every room.map text here).
function M.observe_map(st, text, now)
  if st and type(text) == "string" and text:find("It is too dark to see anything", 1, true) then
    st.dark_at = now
  end
end

function M.observe_moon(st, phase, now)
  if not st then
    return
  end
  st.moon = tostring(phase or "")
  st.moon_at = now
end

-- Best current knowledge. state: night | dusk | dawn | day | unknown.
-- daypart is trusted within DAYPART_STALE; dark within DARK_FRESH.
function M.verdict(st, now)
  st = st or {}
  local out = { state = "unknown", daypart = nil, daypart_age = nil, dark = false, dark_age = nil }
  if st.daypart and st.daypart_at and (now - st.daypart_at) <= M.DAYPART_STALE then
    out.daypart = st.daypart
    out.daypart_age = now - st.daypart_at
    if st.daypart == "night" or st.daypart == "midnight" then
      out.state = "night"
    elseif st.daypart == "dusk" then
      out.state = "dusk"
    elseif st.daypart == "dawn" then
      out.state = "dawn"
    else
      out.state = "day"
    end
  end
  if st.dark_at and (now - st.dark_at) <= M.DARK_FRESH then
    out.dark = true
    out.dark_age = now - st.dark_at
  end
  return out
end

-- The pre-queue warning /goto prints: nil means "nothing to warn about".
function M.night_warning(st, now)
  local v = M.verdict(st, now)
  if v.state == "night" then
    return "it is NIGHT in-game: city gates are locked, climbs fail in the dark, and dark rooms fail queued commands"
  end
  if v.dark then
    return "this room is DARK: queued commands may fail here; a lit torch helps"
  end
  return nil
end

function M.fmt_secs(s)
  s = tonumber(s) or 0
  if s < 0 then
    s = 0
  end
  if s < 60 then
    return math.floor(s) .. "s"
  end
  local m = math.floor(s / 60)
  if m < 60 then
    return m .. "m"
  end
  return math.floor(m / 60) .. "h" .. (m % 60) .. "m"
end

-- The /hexnight report as plain lines (the caller colours them).
function M.report(st, now)
  local v = M.verdict(st, now)
  local lines = {}
  if v.daypart then
    lines[#lines + 1] = ("time: %s (seen %s ago)"):format(v.daypart, M.fmt_secs(v.daypart_age))
  else
    lines[#lines + 1] = "time: unknown (no weather line seen yet; outdoor rooms carry one)"
  end
  if st and st.moon and st.moon_at and (now - st.moon_at) <= M.DAYPART_STALE then
    lines[#lines + 1] = "moon: " .. st.moon
  end
  if v.dark then
    lines[#lines + 1] = ("light: DARK here (seen %s ago); room identifiers are missing in the dark")
      :format(M.fmt_secs(v.dark_age))
  end
  if v.state == "night" then
    lines[#lines + 1] = "night: city gates are LOCKED; climbs fail; dark rooms fail commands"
    lines[#lines + 1] = "night: parcels restock at dawn; sleep in your bed, or hold and light a torch"
  elseif v.state == "dusk" then
    lines[#lines + 1] = "dusk: night is close; finish city trips first and carry a torch"
  elseif v.state == "dawn" then
    lines[#lines + 1] = "dawn: gates open around dawn; parcels restock at dawn"
  elseif v.state == "day" then
    lines[#lines + 1] = "day: gates open; climbs possible (skill-gated)"
  else
    lines[#lines + 1] = "step outside and look: outdoor rooms carry a weather line with the day-part"
  end
  return lines
end

-- --- exits -----------------------------------------------------------------

-- Fields: command|dir|flag|dest_name|dest_area. Gates are a separate set
-- (the gates table has no index; a LEFT JOIN there could duplicate rows).
M.EXITS_QUERY_FMT = "SELECT e.command || '|' || e.dir || '|' || e.flag || '|' || COALESCE(d.name, '') || '|' || COALESCE(d.area, '') AS result "
  .. "FROM exits e LEFT JOIN rooms d ON d.vnum = e.dest "
  .. "WHERE e.from_vnum = %d ORDER BY e.dir, e.command;"

M.GATES_QUERY_FMT = "SELECT exit FROM gates WHERE vnum = %d;"

function M.exits_query(vnum)
  return M.EXITS_QUERY_FMT:format(tonumber(vnum) or 0)
end

function M.gates_query(vnum)
  return M.GATES_QUERY_FMT:format(tonumber(vnum) or 0)
end

-- rows: parse_rows output; gates: set of exit commands that are city gates.
-- Exit flag bits (docs/phase-2-mapper.md 13, from tintin's tintin.h):
-- HIDE=1, AVOID=2 (tt_dw "unsafe"), INVIS=4 (also not shown), BLOCK=8.
function M.render_exits(rows, gates)
  local lines = {}
  for _, f in ipairs(rows or {}) do
    local cmd = util.trim(f[1] or "?")
    local flag = math.floor(tonumber(f[3]) or 0)
    local name = util.trim(f[4] or "")
    local area = util.trim(f[5] or "")
    local marks = {}
    if gates and gates[cmd] then
      marks[#marks + 1] = "gate"
    end
    if cmd:find("^swim") then
      marks[#marks + 1] = "swim"
    end
    if cmd:find("^climb") then
      marks[#marks + 1] = "climb"
    end
    if cmd:find("^journey") then
      marks[#marks + 1] = "journey"
    end
    if flag % 2 == 1 or flag % 8 >= 4 then
      marks[#marks + 1] = "hidden"
    end
    if flag % 4 >= 2 then
      marks[#marks + 1] = "unsafe"
    end
    if cmd:find("^enter ") and cmd:find("carriage") then
      marks[#marks + 1] = "carriage"
    end
    local mark = ""
    if #marks > 0 then
      mark = "  [" .. table.concat(marks, " ") .. "]"
    end
    lines[#lines + 1] = ("  %-16s -> %s%s%s")
      :format(cmd, name ~= "" and name or "?", area ~= "" and (" (" .. area .. ")") or "", mark)
  end
  return lines
end

-- --- zone ------------------------------------------------------------------

-- res: number = steps from here; "unreachable" = ran the check and not
-- connected; nil = landmark id absent from the current graph build.
function M.component_line(lm, res)
  if res == nil then
    return ("  %-14s unmapped in this build (%s)"):format(lm.label, lm.note)
  end
  if res == "unreachable" then
    return ("  %-14s NOT routable from here (%s)"):format(lm.label, lm.note)
  end
  return ("  %-14s routable from here (%d steps)"):format(lm.label, res)
end

-- --- death site (hex.db, per-alt) -------------------------------------------

function M.death_init_sql()
  return "CREATE TABLE IF NOT EXISTS deathsite (alt TEXT PRIMARY KEY, room_id TEXT, name TEXT, area TEXT, at INTEGER);"
end

function M.death_save_sql(alt, site)
  return ("INSERT OR REPLACE INTO deathsite (alt, room_id, name, area, at) VALUES ('%s', '%s', '%s', '%s', %d);")
    :format(
      util.sql_escape(alt or ""),
      util.sql_escape(site.room_id or ""),
      util.sql_escape(site.name or ""),
      util.sql_escape(site.area or ""),
      math.floor(tonumber(site.at) or 0)
    )
end

function M.death_load_sql(alt)
  return "SELECT room_id || '|' || name || '|' || area || '|' || at FROM deathsite WHERE alt = '"
    .. util.sql_escape(alt or "")
    .. "' LIMIT 1;"
end

function M.death_clear_sql(alt)
  return "DELETE FROM deathsite WHERE alt = '" .. util.sql_escape(alt or "") .. "';"
end

-- fields: room_id|name|area|at (parse_rows output row).
function M.death_from_row(f)
  if not f or not f[1] or f[1] == "" then
    return nil
  end
  return { room_id = f[1], name = f[2] or "", area = f[3] or "", at = tonumber(f[4]) }
end

function M.death_report(site, now)
  if not site or not site.room_id or site.room_id == "" then
    return { "no death site recorded; /hexcorpse mark (at the corpse, or wherever you died) sets one" }
  end
  local lines = {}
  local title = "death site: " .. (site.name ~= "" and site.name or "?")
  if site.area and site.area ~= "" then
    title = title .. " (" .. site.area .. ")"
  end
  lines[#lines + 1] = title
  lines[#lines + 1] = "room id " .. site.room_id
  if site.at and now then
    lines[#lines + 1] = "recorded " .. M.fmt_secs(now - site.at) .. " ago"
  end
  lines[#lines + 1] = "/goto " .. site.room_id .. " walks back; /path it first at night (gates lock, climbs fail)"
  return lines
end

-- --- consider (the safe-prey finder; helpdir/consider, pinned) --------------

-- The 13-rung ladder as {phrase, rung} pairs in SCAN order: longer phrases
-- must be checked before their substrings ("a lot weaker" before "weaker").
-- Rung numbers follow the doc's danger order, 1 = too weak, 13 = insane.
-- Wire-verified surface forms (2026-11-08 log): "The rat would be an easy
-- target." (rung 3) and "The feral pigeon is weaker than you." (rung 5);
-- the doc's ladder wording carries a trailing "are", so the phrases below
-- are the shared substring of both forms.
M.CONSIDER_RUNGS = {
  { "too weak to bother attacking", 1 },
  { "someone you look down on", 2 },
  { "would be an easy target", 3 },
  { "a lot weaker than you", 4 },
  { "slightly weaker than you", 6 },
  { "weaker than you", 5 },
  { "about equal with you", 7 },
  { "slightly tougher than you", 8 },
  { "a lot tougher than you", 10 },
  { "tougher than you", 9 },
  { "pretty nasty", 11 },
  { "into the don't think about it region", 12 },
}

function M.consider_rung(text)
  for _, pair in ipairs(M.CONSIDER_RUNGS) do
    if tostring(text):find(pair[1], 1, true) then
      return pair[2]
    end
  end
  if tostring(text):find("utterly insane to attack", 1, true) then
    return 13
  end
  return nil
end

-- One consider output line -> {target, rung, covert} or nil. Handles the
-- normal form, the covert form ("X, considered covertly, is <rung>.") and
-- the inverted rung 13 ("You would have to be utterly insane to attack X!").
function M.consider_classify(line)
  line = tostring(line)
  local name, tail = line:match("^(.+), considered covertly, is (.+)%.$")
  if name then
    local rung = M.consider_rung(tail)
    if rung then
      return { target = (util.trim(name):gsub("^The ", "")), rung = rung, covert = true }
    end
  end
  for _, pair in ipairs(M.CONSIDER_RUNGS) do
    local at = line:find(pair[1], 1, true)
    if at then
      local target = util.trim(line:sub(1, at - 1))
      -- the verb is not part of the stored phrase, so it rides in the prefix
      target = target:gsub("%s+is$", ""):gsub("%s+are$", ""):gsub("%s+would be$", ""):gsub("%s+looks$", "")
      target = target:gsub("^The ", ""):gsub("^A ", ""):gsub("^An ", "")
      if target ~= "" and not target:find("considered covertly", 1, true) then
        return { target = target, rung = pair[2] }
      end
      return nil
    end
  end
  local insane = line:match("^You would have to be utterly insane to attack (.+)!$")
  if insane then
    return { target = insane, rung = 13 }
  end
  return nil
end

-- The verdict colour band for a rung: prey / even / danger.
function M.consider_band(rung)
  if rung <= 5 then
    return "prey"
  elseif rung <= 7 then
    return "even"
  end
  return "danger"
end

-- --- corpses on the floor ----------------------------------------------------

-- Number words seen on the wire ("Four corpses of rats", "Two corpses of
-- large evil looking rats and two corpses of pigeons").
M.NUMBER_WORDS = { one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10 }

-- One floor line -> list of {name, n}. Wire shapes: "The corpse of a large
-- evil looking rat is on the floor.", "A wheat filled sack and the corpse
-- of a rat are on the floor.", "Two corpses of large evil looking rats and
-- two corpses of pigeons are on the floor.", "Four corpses of rats are on
-- the floor."
function M.corpses_from_line(line)
  line = tostring(line)
  local anchors = {}
  local pos = 1
  while true do
    local s, e, count_word = line:find("(%a+) corpses? of", pos)
    if not s then
      break
    end
    anchors[#anchors + 1] = { s = s, e = e, word = count_word }
    pos = e + 1
  end
  local out = {}
  for i, a in ipairs(anchors) do
    -- each body stops at the next corpse segment, the floor clause, or
    -- sentence punctuation, whichever comes first
    local stop = #line + 1
    if anchors[i + 1] then
      stop = anchors[i + 1].s
    end
    for _, term in ipairs({ " are on the floor", " is on the floor", ",", "." }) do
      local t = line:find(term, a.e + 1, true)
      if t and t < stop then
        stop = t
      end
    end
    local body = util.trim(line:sub(a.e + 1, stop - 1)):gsub(" and$", "")
    local n = M.NUMBER_WORDS[a.word:lower()] or tonumber(a.word) or 1
    if body ~= "" then
      out[#out + 1] = { name = body, n = n }
    end
  end
  return out
end

-- The lit-outdoor night line ("It is night and the last quarter moon is
-- hidden by the clouds.", 678 samples): night confirmation even without a
-- weather line, plus the moon phase.
function M.observe_lit_night(st, phase, now)
  if not st then
    return
  end
  M.observe_weather(st, "night", now)
  M.observe_moon(st, phase, now)
end

-- One classified consider line into the session table (latest per target
-- wins, newest first, capped).
function M.observe_consider(st, hit, now)
  if not st or not hit then
    return
  end
  for i, e in ipairs(st.consider) do
    if e.target == hit.target then
      table.remove(st.consider, i)
      break
    end
  end
  table.insert(st.consider, 1, { target = hit.target, rung = hit.rung, covert = hit.covert or false, at = now })
  if #st.consider > 12 then
    table.remove(st.consider)
  end
end

-- --- carriages (the phase-5 travel annotations) ------------------------------

-- Carriage state from the documented arrival set; the two stop/leave lines
-- are also wire-verified (2026-11-08 19:04 log, the Intercontinental Express
-- at the AM carriage stop). Pure observer.
function M.observe_carriage(st, kind, name, place, now)
  if not st then
    return
  end
  st.carriage = { kind = kind, name = name, place = place, at = now }
end

-- --- runtime glue (blightmud globals below this line) -----------------------

M.deps = { config = nil, room = nil, get_graph = nil }
M.state = nil

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function bold(t)
  return util.ansi.bold .. t .. util.ansi.reset
end

local function green(t)
  return util.ansi.green .. t .. util.ansi.reset
end

local function yellow(t)
  return util.ansi.yellow .. t .. util.ansi.reset
end

local function red(t)
  return util.ansi.red .. t .. util.ansi.reset
end

local function sql(db, query)
  local r = core.exec({ "sqlite3", db, query })
  if r:code() ~= 0 then
    print(util.ansi.red .. "[hex] sqlite error: " .. r:stderr() .. util.ansi.reset)
    return nil
  end
  return r:stdout()
end

local function rows(db, query)
  local out = sql(db, query)
  if not out then
    return nil
  end
  return util.parse_rows(out)
end

function M.db()
  return (M.deps.config and M.deps.config.get("hex_db")) or ((os.getenv and os.getenv("HOME")) or "") .. "/.local/share/hex/hex.db"
end

function M.setup(deps)
  M.deps = deps or M.deps
  M.state = M.new_state()
  core.exec({ "sqlite3", M.db(), M.death_init_sql() })
end

-- runtime wrappers fed by main.lua's GMCP hooks
function M.on_room(id)
  M.observe_room(M.state, id)
end

function M.on_map(text)
  M.observe_map(M.state, text, os.time())
end

function M.cmd_exits()
  local room = M.deps.room
  if not room or not room.id then
    print(gray("[hex] current room unidentified (dark rooms push no identifier); /hexnight has the light facts"))
    return
  end
  local db = M.deps.config.get("rooms_db")
  local vrows = rows(db, "SELECT vnum FROM rooms WHERE room_id = '" .. util.sql_escape(room.id) .. "' LIMIT 1;")
  if not vrows or not vrows[1] then
    print(gray("[hex] current room is not in the Hex map database"))
    return
  end
  local vnum = tonumber(vrows[1][1])
  print(bold("exits: ") .. (room.name or "?") .. gray("  vnum " .. tostring(vnum)))
  local erows = rows(db, M.exits_query(vnum))
  if not erows then
    return
  end
  local gates = {}
  local grows = rows(db, M.gates_query(vnum))
  if grows then
    for _, f in ipairs(grows) do
      gates[util.trim(f[1] or "")] = true
    end
  end
  local lines = M.render_exits(erows, gates)
  if #lines == 0 then
    print(gray("  (no exits recorded for this room)"))
    return
  end
  for _, l in ipairs(lines) do
    print(l)
  end
end

function M.cmd_zone()
  local room = M.deps.room
  if not room or not room.id then
    print(gray("[hex] current room unidentified (dark rooms push no identifier); move to a lit room"))
    return
  end
  print(bold("zone: ") .. (room.name or "?") .. gray("  id " .. room.id))
  local db = M.deps.config.get("rooms_db")
  local detail = rows(db, queries.build_where_query(room.id))
  if detail and detail[1] then
    local area = util.trim(detail[1][2] or "")
    local terrain = util.trim(detail[1][3] or "")
    if area ~= "" or terrain ~= "" then
      print(gray("map:  ") .. area .. (terrain ~= "" and gray("  terrain " .. terrain) or ""))
    end
  else
    print(gray("map:  not in the Hex room database"))
  end
  local zone = rows(M.deps.config.get("quow_db"), queries.build_zone_query(room.id))
  if zone and zone[1] then
    print(gray("quow: ") .. queries.zone_name(zone[1][1]))
  end
  local g = M.deps.get_graph and M.deps.get_graph()
  if not g then
    print(gray("component facts skipped (no route graph)"))
    return
  end
  print(bold("component facts") .. gray("  identified graph: " .. #g.vnum .. " rooms, " .. g.edges .. " edges"))
  local targets, label_of = {}, {}
  for _, lm in ipairs(M.LANDMARKS) do
    local dense = g.by_id[lm.id]
    if dense then
      targets[#targets + 1] = g.vnum[dense]
      label_of[g.vnum[dense]] = lm.label
    end
  end
  -- distances takes a SCALAR start (find_route is the one taking a list);
  -- a table here would never start the Dijkstra and every landmark would
  -- read "NOT routable" (caught by the v0.18.0 review pass)
  local dists = paths.distances(g, room.id, targets)
  for _, lm in ipairs(M.LANDMARKS) do
    local dense = g.by_id[lm.id]
    local res = nil
    if dense then
      res = dists[g.vnum[dense]] or "unreachable"
    end
    print(gray(M.component_line(lm, res)))
  end
  print(gray("  (reachability uses the default walk rules: water/avoid rooms blocked; swim/climb/gate options may add steps)"))
end

function M.cmd_night()
  local lines = M.report(M.state, os.time())
  print(bold("night: ") .. gray(lines[1]))
  for i = 2, #lines do
    print(gray(lines[i]))
  end
end

-- /hexscan: the safe-prey finder, cut in v0.18.0 because consider output
-- had never been captured; revived in v0.19.0 once the rung ladder was
-- pinned in the doc mirror and the first two wire shapes landed in the
-- session logs.
function M.cmd_scan()
  local st = M.state or {}
  local now = os.time()
  local room = M.deps.room
  print(bold("scan: ") .. (room and room.name or "?"))
  local corpses = st.corpses or {}
  if #corpses == 0 then
    print(gray("floor: no corpses seen here"))
  else
    print(bold("floor:"))
    for _, c in ipairs(corpses) do
      local noun = c.n > 1 and ("corpses of " .. c.name .. " (" .. c.n .. ")") or ("corpse of " .. c.name)
      print("  " .. noun)
    end
    print(gray("  loot: get all from corpse; bury corpse pays xp and guild points"))
  end
  if st.corpse_eaten_at and (now - st.corpse_eaten_at) <= 120 then
    print(red("a corpse here is being EATEN: get your loot NOW"))
  end
  if st.kills and #st.kills > 0 then
    local names = {}
    for _, k in ipairs(st.kills) do
      names[#names + 1] = k.name
    end
    print(gray("your kills: " .. table.concat(names, ", ")))
  end
  local cons = st.consider or {}
  if #cons == 0 then
    print(gray("consider: nothing yet; consider <target> feeds this table (consider covert <t> stays quiet)"))
  else
    print(bold("consider:"))
    for _, e in ipairs(cons) do
      local band = M.consider_band(e.rung)
      local paint = band == "prey" and green or (band == "even" and yellow or red)
      print(("  %-26s %s"):format(e.target, paint(("rung %2d %s%s"):format(e.rung, band, e.covert and " (covert)" or ""))))
    end
  end
  print(gray("people nearby: /mdt; exits and their markers: /hexexits"))
end

-- /hexcarriage: what the last carriage on the wire is doing, and how to
-- board it (the exit verb comes from /hexexits's [carriage] marker).
function M.cmd_carriage()
  local st = M.state or {}
  local c = st.carriage
  if not c then
    print(gray("no carriage seen yet; carriage stops carry an [carriage] exit in /hexexits"))
    return
  end
  local now = os.time()
  local what = {
    arrived = "pulled to a stop here",
    leaving = "leaving soon for " .. tostring(c.place or "?"),
    halt = "come to a grinding halt",
    nextstop = "next stop: " .. tostring(c.place or "?"),
  }
  local line = (c.name or "?") .. " carriage " .. (what[c.kind] or c.kind)
  print(bold("carriage: ") .. line .. gray("  (seen " .. M.fmt_secs(now - (c.at or now)) .. " ago)"))
  print(gray("board with: enter " .. (c.name or "?") .. " carriage  (check the verb in /hexexits)"))
end

function M.cmd_corpse(sub)
  sub = util.trim(sub or "")
  local config = M.deps.config
  local alt = config.alt and config.alt() or ""
  if sub == "clear" then
    core.exec({ "sqlite3", M.db(), M.death_clear_sql(alt) })
    print(gray("[hex] death site cleared"))
    return
  end
  if sub == "mark" then
    local room = M.deps.room
    if not room or not room.id then
      print(gray("[hex] no identified room to mark (dark rooms push no identifier); mark from the last lit room"))
      return
    end
    local site = { room_id = room.id, name = room.name or "", area = "", at = os.time() }
    core.exec({ "sqlite3", M.db(), M.death_save_sql(alt, site) })
    print(gray("[hex] death site marked: " .. (room.name or "?") .. " (" .. room.id .. ")"))
    return
  end
  if sub ~= "" then
    print(gray("usage: /hexcorpse [mark|clear]"))
    return
  end
  local r = rows(M.db(), M.death_load_sql(alt))
  local site = M.death_from_row(r and r[1])
  if site then
    local w = rows(M.deps.config.get("rooms_db"), queries.build_where_query(site.room_id))
    if w and w[1] then
      if site.name == "" then
        site.name = util.trim(w[1][1] or "")
      end
      site.area = util.trim(w[1][2] or "")
    end
  end
  for _, l in ipairs(M.death_report(site, os.time())) do
    print(gray(l))
  end
end

-- Triggers only RECORD; nothing is ever sent. Called from main.lua with the
-- registry-wrapped trigger_add so /hexreload reaps them.
function M.register(trigger_add, regex)
  trigger_add("^It is a .*'s (morning|afternoon|evening|night|dawn|dusk|noon|midnight) with ", {}, function(matches)
    M.observe_weather(M.state, matches[2], os.time())
  end)
  trigger_add("^Something\\.\\s+It's dark here, isn't it\\?$", {}, function()
    M.observe_dark(M.state, os.time())
  end)
  trigger_add("^The land is lit up by the eerie light of the (.+) moon\\.$", {}, function(matches)
    M.observe_moon(M.state, util.trim(matches[2]), os.time())
  end)
  -- night confirmation from LIT outdoor rooms (678 wire samples, distinct
  -- from the dark-room eerie-light line) + the moon phase
  trigger_add("^It is night and the (.+) moon", {}, function(matches)
    M.observe_lit_night(M.state, util.trim(matches[2]), os.time())
  end)
  -- consider: one phrase-tail trigger classifies in Lua (matches[1] is the
  -- whole line), plus the inverted rung 13. Wire-verified 2026-11-08.
  trigger_add(" (is too weak to bother attacking|is someone you look down on|would be an easy target|is a lot weaker than you|is slightly weaker than you|is weaker than you|is about equal with you|is slightly tougher than you|is a lot tougher than you|is tougher than you|looks pretty nasty|don't think about it region|considered covertly, is)", {}, function(matches)
    M.observe_consider(M.state, M.consider_classify(matches[1]), os.time())
  end)
  trigger_add("^You would have to be utterly insane to attack .+!$", {}, function(matches)
    M.observe_consider(M.state, M.consider_classify(matches[1]), os.time())
  end)
  -- kills and the floor
  trigger_add("^You kill the (.+)\\.$", {}, function(matches)
    if M.state then
      M.state.kills[#M.state.kills + 1] = { name = matches[2], at = os.time() }
      if #M.state.kills > 5 then
        table.remove(M.state.kills, 1)
      end
    end
  end)
  trigger_add("corpses? of [^.]+ (are|is) on the floor\\.$", {}, function(matches)
    if M.state then
      for _, c in ipairs(M.corpses_from_line(matches[1])) do
        M.state.corpses[#M.state.corpses + 1] = c
      end
    end
  end)
  trigger_add(" rips apart the corpse of ", {}, function()
    if M.state then
      M.state.corpse_eaten_at = os.time()
    end
  end)
  -- carriages: the documented arrival set; stop/leave are also wire-verified
  trigger_add("^The (.+) carriage arrives and pulls to a stop\\.$", {}, function(matches)
    M.observe_carriage(M.state, "arrived", matches[2], nil, os.time())
  end)
  trigger_add("^The (.+) carriage will soon be leaving for (.+)\\.$", {}, function(matches)
    M.observe_carriage(M.state, "leaving", matches[2], matches[3], os.time())
  end)
  trigger_add("^The (.+) carriage comes to a grinding halt\\.$", {}, function(matches)
    M.observe_carriage(M.state, "halt", matches[2], nil, os.time())
  end)
  trigger_add("^The (.+) carriage has arrived at (.+)\\.$", {}, function(matches)
    M.observe_carriage(M.state, "nextstop", matches[2], matches[3], os.time())
  end)
  trigger_add("^The (.+)'s next stop is (.+)\\.$", {}, function(matches)
    M.observe_carriage(M.state, "nextstop", matches[2], matches[3], os.time())
  end)
  -- death-room recorder. Wire-VERIFIED 2026-11-08 20:25 (the forest
  -- clearing death, his own log): Death appears mid-fight quoting random
  -- small-caps lines and leaves on Binky; the attacker renders as
  -- "Something" in the dark. Primary anchors are the two invariant lines;
  -- the early conservative guesses stay as harmless extras.
  local record_death = function()
    local room = M.deps.room
    if M.state and room and room.id then
      local site = { room_id = room.id, name = room.name or "", area = "", at = os.time() }
      core.exec({ "sqlite3", M.db(), M.death_save_sql((M.deps.config.alt and M.deps.config.alt()) or "", site) })
    end
  end
  trigger_add("^You turn and see Death standing behind you\\.$", {}, record_death)
  trigger_add("^Death gets back onto Binky and rides away\\.$", {}, record_death)
  trigger_add("^You die\\.$", {}, record_death)
  trigger_add("^You have died\\.$", {}, record_death)
  trigger_add("^You are dead\\.$", {}, record_death)
end

return M
