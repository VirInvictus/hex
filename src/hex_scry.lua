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
--     the room; dark room.info pushes carry NO identifier (v0.17.2's fact).
--   death: WIRE-PENDING. No death sequence was ever captured (tt_dw has no
--     death triggers to port), so the death-room triggers below are
--     conservative anchors that may never fire; /hexcorpse mark is the
--     reliable path until a capture fixes them.
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
  return { daypart = nil, daypart_at = nil, moon = nil, moon_at = nil, dark_at = nil }
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
-- the identifier, v0.17.2's wire fact), so it clears the dark signal.
function M.observe_room(st, id)
  if st and id then
    st.dark_at = nil
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

-- --- runtime glue (blightmud globals below this line) -----------------------

M.deps = { config = nil, room = nil, get_graph = nil }
M.state = nil

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function bold(t)
  return util.ansi.bold .. t .. util.ansi.reset
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
  -- death-room recorder, WIRE-PENDING (see the header): conservative
  -- anchors that may never fire; /hexcorpse mark is the reliable path.
  local record_death = function()
    local room = M.deps.room
    if M.state and room and room.id then
      local site = { room_id = room.id, name = room.name or "", area = "", at = os.time() }
      core.exec({ "sqlite3", M.db(), M.death_save_sql((M.deps.config.alt and M.deps.config.alt()) or "", site) })
    end
  end
  trigger_add("^You die\\.$", {}, record_death)
  trigger_add("^You have died\\.$", {}, record_death)
  trigger_add("^You are dead\\.$", {}, record_death)
end

return M
