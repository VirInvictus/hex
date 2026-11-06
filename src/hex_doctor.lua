-- hex_doctor.lua: /doctor, the in-client self-test (PERMANENT fixture).
-- Runs the pure machinery against known-good fixtures inside the live
-- client, inventories state (config, databases, GMCP liveness, wiring,
-- feature detection), and writes a report to Hex's data dir so a
-- screenshot of the summary plus the report file covers a bug report.
--
-- Boundary, stated in the output: registration and pure functions are
-- exercised; commands are NOT auto-executed because a slice of them send
-- to the MUD, and sends stay behind the user's own keystrokes (spec
-- invariant 1). Database reads go through core.exec and stay
-- millisecond-scale (indexed lookups and small counts only).
--
-- deps (main.lua): config, vitals, room, maps, gmcp, data, mdt, minimap,
-- sound, tts_mod, self_test (suite runs set this: file probes and DB
-- checks degrade to "skip" instead of touching the real data dir).
-- Everything else is required directly (same package.loaded instances
-- the client runs).
local util = require("src.hex_util")
local vitals_mod = require("src.hex_vitals")
local rooms_mod = require("src.hex_rooms")
local status = require("src.hex_status")
local stats_mod = require("src.hex_stats")
local queries = require("src.hex_queries")
local paths = require("src.hex_paths")
local targets = require("src.hex_targets")
local spelldata = require("src.hex_spelldata")
local skilldata = require("src.hex_skilldata")
local missiondata = require("src.hex_missiondata")
local sound_events = require("src.hex_sound_events")
local spells = require("src.hex_spells")
local blorps = require("src.hex_blorps")

local M = {}

M.deps = {}

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function colored(name, t)
  return util.ansi[name] .. t .. util.ansi.reset
end

-- every check returns status, detail; statuses: ok, warn, fail, skip
M.checks = {}

local function add(group, name, fn)
  M.checks[#M.checks + 1] = { group = group, name = name, fn = fn }
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function build_checks()
  local deps = M.deps
  local C = {}

  -- environment -----------------------------------------------------------
  add("environment", "lua version", function()
    return "ok", tostring(_VERSION)
  end)
  add("environment", "blightmud version", function()
    if blight and blight.version then
      return "ok", tostring(blight.version())
    end
    return "warn", "blight.version unavailable (older build)"
  end)
  add("environment", "terminal", function()
    if blight and blight.terminal_dimensions then
      local w, h = blight.terminal_dimensions()
      return "ok", w .. "x" .. h
    end
    return "skip", "no terminal dimensions"
  end)

  -- gmcp liveness ---------------------------------------------------------
  add("gmcp", "handshake", function()
    if deps.gmcp and deps.gmcp.handshake_done then
      return "ok", "core.hello + supports.set sent"
    end
    return "fail", "handshake not sent: this is the M1 dead-vitals bug class"
  end)
  add("gmcp", "vitals feed", function()
    local st = deps.vitals
    if not st or not st.cur or st.cur.hp == nil then
      return "fail", "no vitals received this session"
    end
    if st.last_gmcp then
      local age = os.time() - st.last_gmcp
      if age <= 120 then
        return "ok", "hp " .. tostring(st.cur.hp) .. "/" .. tostring(st.max and st.max.hp or "?") .. " (fresh, " .. age .. "s)"
      end
      return "warn", "hp " .. tostring(st.cur.hp) .. " but stale (" .. age .. "s since last push)"
    end
    return "ok", "hp " .. tostring(st.cur.hp) .. " (no timestamp)"
  end)
  add("gmcp", "room feed", function()
    local r = deps.room
    if not r or not r.id then
      return "fail", "no room.info received this session"
    end
    if targets.is_room_id(r.id) then
      return "ok", tostring(r.name) .. " (identified)"
    end
    return "warn", tostring(r.name) .. " (symbolic id: " .. r.id .. ")"
  end)
  add("gmcp", "map payloads", function()
    local m = deps.maps or {}
    if m.written and m.ascii then
      return "ok", "written + ascii stored"
    elseif m.written or m.ascii then
      return "warn", "only one of written/ascii present"
    end
    return "warn", "no room.map/writtenmap payload yet (look around)"
  end)

  -- config ----------------------------------------------------------------
  add("config", "alt", function()
    local alt = deps.config.alt()
    if alt then
      return "ok", alt
    end
    return "warn", "no alt detected yet (connect once)"
  end)
  add("config", "stored options validate", function()
    local defs = require("src.hex_options_def")
    local options = require("src.hex_options")
    local stored, bad = 0, nil
    for _, entry in ipairs(defs.schema) do
      local value = deps.config.explicit(entry.key)
      if value ~= nil then
        stored = stored + 1
        local ok = options.validate(entry, value)
        if ok == false then
          bad = (bad and (bad .. ", ") or "") .. entry.key
        end
      end
    end
    if bad then
      return "fail", stored .. " stored; invalid: " .. bad
    end
    return "ok", stored .. " stored override(s), all valid"
  end)
  add("config", "gag registry file", function()
    local path = deps.config.get("gags_file", deps.data.hex_dir() .. "/gags.lua")
    if file_exists(path) then
      return "ok", path
    end
    return "warn", "not created yet (" .. path .. ")"
  end)

  -- databases (skip in the suite: no core, no real files) -----------------
  add("databases", "quow db", function()
    if core == nil or deps.self_test then
      return "skip", "suite/self-test"
    end
    local path = deps.config.get("quow_db") or deps.data.owned_quow()
    if not file_exists(path) then
      path = deps.data.legacy_quow()
    end
    if file_exists(path) then
      return "ok", path
    end
    return "fail", "no Quow database found (run /hexupdate)"
  end)
  add("databases", "rooms db", function()
    if core == nil or deps.self_test then
      return "skip", "suite/self-test"
    end
    local path = deps.config.get("rooms_db") or deps.data.hex_dir() .. "/rooms.db"
    if not file_exists(path) then
      return "fail", "missing: " .. path .. " (rebuild with tools/convert_map.py)"
    end
    local r = core.exec({ "sqlite3", path, "SELECT COUNT(*) FROM rooms;" })
    local n = tonumber(util.trim(r:stdout())) or 0
    local detail = n .. " rooms"
    local rid = deps.room and deps.room.id
    if rid and targets.is_room_id(rid) then
      local v = core.exec({ "sqlite3", path, "SELECT vnum FROM rooms WHERE room_id = '" .. util.sql_escape(rid) .. "' LIMIT 1;" })
      local vnum = util.trim(v:stdout())
      detail = detail .. "; current room " .. (vnum ~= "" and ("-> vnum " .. vnum) or "unmapped")
    end
    return "ok", detail
  end)
  add("databases", "hex db", function()
    if core == nil or deps.self_test then
      return "skip", "suite/self-test"
    end
    local path = deps.config.get("hex_db") or deps.data.hex_dir() .. "/hex.db"
    if not file_exists(path) then
      return "warn", "not created yet (first /blorp or /hunt creates it)"
    end
    local counts = {}
    for _, table in ipairs({ "blorp", "bookmark", "meta", "mdt_match", "mdt_category" }) do
      local r = core.exec({ "sqlite3", path, "SELECT COUNT(*) FROM " .. table .. ";" })
      counts[#counts + 1] = table .. "=" .. util.trim(r:stdout())
    end
    return "ok", table.concat(counts, " ")
  end)

  -- data modules in memory ------------------------------------------------
  add("data", "spelldata", function()
    local n = 0
    for _ in pairs(spelldata.spells) do
      n = n + 1
    end
    if n == 117 then
      return "ok", n .. " spells"
    end
    return "fail", n .. " spells (expected 117)"
  end)
  add("data", "skill stats table", function()
    local n = 0
    for _ in pairs(skilldata.skill_stats) do
      n = n + 1
    end
    return "ok", n .. " skills covered"
  end)
  add("data", "mission xp table", function()
    local n = 0
    for _ in pairs(missiondata.xp) do
      n = n + 1
    end
    return "ok", n .. " missions"
  end)
  add("data", "mdt defaults", function()
    return #deps.mdt.defaults >= 70 and "ok" or "fail",
      #deps.mdt.defaults .. " default rows, " .. #require("src.hex_mdtdata").colors .. " colours"
  end)
  add("data", "zones", function()
    local n = 0
    for _ in pairs(queries.ZONES) do
      n = n + 1
    end
    return "ok", n .. " zone names"
  end)
  add("data", "sound events", function()
    return "ok", #sound_events.events .. " mapped events"
  end)

  -- pure parser mini-suite (the suite's fixtures, run live) ---------------
  add("parsers", "vitals apply", function()
    local st = vitals_mod.new()
    vitals_mod.apply(st, { hp = 500, maxhp = 500, gp = 50, maxgp = 50, xp = 5356, burden = 3, alignment = "neutral" })
    if st.cur.hp == 500 and st.max.hp == 500 then
      return "ok", "fixture applied"
    end
    return "fail", "fixture keys did not land"
  end)
  add("parsers", "status render", function()
    local st = vitals_mod.new()
    vitals_mod.apply(st, { hp = 500, maxhp = 500, gp = 50, maxgp = 50, xp = 5356, burden = 3 })
    local lines = status.render(st, rooms_mod.new(), 80, {})
    if lines[1]:find("500/500", 1, true) then
      return "ok", "bar row renders"
    end
    return "fail", "no 500/500 in row 1"
  end)
  add("parsers", "stats lines", function()
    local st = {}
    stats_mod.parse_line(st, "Constitution ... 13        Intelligence ... 13        Wisdom ......... 13        Weight ......... 80.0 kg")
    stats_mod.parse_line(st, "Dexterity ...... 13        Strength ....... 13        Height ......... 175 cm")
    if st.con == 13 and st.str == 13 and st.dex == 13 then
      return "ok", "two-line layout parsed"
    end
    return "fail", "stat fixture did not parse"
  end)
  add("parsers", "guild clause", function()
    local line = "Your current experience is 6361 and you are level 0 in the Adventurers' Guild; your overall rating is 64."
    local guild = line:match(" in the ([%w' ]+) Guild")
    if guild == "Adventurers'" then
      return "ok", "clause extracts"
    end
    return "fail", "clause pattern broken"
  end)
  add("parsers", "query escaping", function()
    if queries.build_item_query("it's"):find("it''s", 1, true)
      and queries.build_npc_query("room:abc it's"):find("it''s", 1, true)
      and queries.build_item_query("it's", true):find("it''s", 1, true) then
      return "ok", "apostrophes doubled in every builder path (LIKE and exact)"
    end
    return "fail", "escaping regression"
  end)
  add("parsers", "pathfinder", function()
    -- rows in the sqlite pipe-row shape paths.load consumes
    local nodes = {
      { "1", "0", string.rep("1", 40), "room one", "Test" },
      { "2", "0", string.rep("2", 40), "room two", "Test" },
      { "3", "0", string.rep("3", 40), "room three", "Test" },
      { "4", "0", string.rep("4", 40), "room four", "Test" },
    }
    local edges = {
      { "1", "2:0:1:1:north" },
      { "2", "3:0:1:1:north" },
      { "3", "4:0:1:1:north" },
      { "2", "" },
      { "3", "" },
      { "4", "" },
    }
    local g = paths.load(nodes, edges)
    local r = paths.find_route(g, { 1 }, 4)
    if r and r.steps == 3 then
      return "ok", "synthetic 4-node route"
    end
    return "fail", "pathfinder broken"
  end)
  add("parsers", "mdt", function()
    -- snapshot the live state; the checks run against a clean store
    local saved_matches, saved_categories = deps.mdt.state.matches, deps.mdt.state.categories
    deps.mdt.state.matches, deps.mdt.state.categories = {}, {}
    local ok1 = #deps.mdt.parse("A door north of here and the limit of your vision is here.\n") == 0
    local ok2 = deps.mdt.match("giant rat").score == 0
    local ok3 = deps.mdt.clean("city guard") == "guard"
    deps.mdt.state.matches, deps.mdt.state.categories = saved_matches, saved_categories
    if ok1 and ok2 and ok3 then
      return "ok", "live sample parses; defaults and cleanup live"
    end
    return "fail", "parser/match/clean smoke failed"
  end)
  add("parsers", "spells resolve", function()
    local spell = spells.resolve("ahsb")
    if spell then
      return "ok", "nick resolution through spelldata"
    end
    return "fail", "nick resolution broken"
  end)
  add("parsers", "notify bus", function()
    local fired = false
    local id = require("src.hex_notify").subscribe("doctor.probe", function()
      fired = true
    end)
    require("src.hex_notify").emit("doctor.probe", {})
    require("src.hex_notify").unsubscribe(id)
    if fired then
      return "ok", "subscribe/emit/unsubscribe"
    end
    return "fail", "bus did not fire"
  end)
  add("parsers", "sql builders", function()
    if blorps.blorp_add_sql("a", "b", 1, "c"):find("INSERT OR REPLACE", 1, true) then
      return "ok", "blorp builder shapes"
    end
    return "fail", "builder broken"
  end)

  -- wiring ----------------------------------------------------------------
  add("wiring", "alias fleet", function()
    if store == nil or json == nil then
      return "skip", "no client store (suite)"
    end
    local raw = store.session_read("hex.handles")
    if not raw then
      return "fail", "no handle list in the session store"
    end
    local ok, list = pcall(json.decode, raw)
    if not ok or type(list) ~= "table" then
      return "fail", "handle list unreadable"
    end
    local kinds = {}
    for _, h in ipairs(list) do
      kinds[h.kind] = (kinds[h.kind] or 0) + 1
    end
    local detail = (kinds.alias or 0) .. " aliases, " .. (kinds.trigger or 0) .. " triggers, " .. (kinds.timer or 0) .. " timers"
    if (kinds.alias or 0) >= 30 then
      return "ok", detail
    end
    return "fail", detail .. " (fleet looks amputated: /hexreload and check)"
  end)
  add("wiring", "command execution", function()
    return "skip", "commands are never auto-run: sends stay behind your keystrokes"
  end)

  -- feature surfaces ------------------------------------------------------
  add("features", "minimap mode", function()
    return "ok", tostring(deps.minimap.mode or "?")
  end)
  add("features", "map tab", function()
    if store == nil then
      return "skip", "no client store (suite)"
    end
    if store.session_read("hex.map_tab_created") == "1" then
      return "ok", "created this session (F3)"
    end
    return "warn", "not created (map_panel setting or older build)"
  end)
  add("features", "audio", function()
    if audio ~= nil then
      return "ok", "audio module present (sound " .. (deps.config.get("sound", false) and "on" or "off, default") .. ")"
    end
    return "warn", "no audio module in this build"
  end)
  add("features", "tts", function()
    if deps.tts_mod and deps.tts_mod.available() then
      return "ok", "available (tts " .. (deps.config.get("tts", false) and "on" or "off, default") .. ")"
    end
    return "warn", "not available in this build"
  end)
  add("features", "hex dir writable", function()
    if deps.self_test then
      return "skip", "suite/self-test"
    end
    local probe = deps.data.hex_dir() .. "/.doctor-probe"
    local f = io.open(probe, "w")
    if not f then
      return "fail", "cannot write " .. deps.data.hex_dir()
    end
    f:write("probe\n")
    f:close()
    os.remove(probe)
    return "ok", deps.data.hex_dir()
  end)

  return C
end

-- pure-ish: run the battery, return the results list
-- { group, name, status, detail }
function M.run_checks()
  local results = {}
  build_checks()
  for _, check in ipairs(M.checks) do
    local ok, status, detail = pcall(check.fn)
    if not ok then
      status, detail = "fail", "check errored: " .. tostring(status)
    end
    results[#results + 1] = { group = check.group, name = check.name, status = status, detail = tostring(detail) }
  end
  M.checks = {}
  return results
end

local function render(results)
  local lines = {}
  local counts = { ok = 0, warn = 0, fail = 0, skip = 0 }
  local group = nil
  for _, r in ipairs(results) do
    counts[r.status] = (counts[r.status] or 0) + 1
    if r.group ~= group then
      group = r.group
      lines[#lines + 1] = gray("-- " .. group .. " --")
    end
    local mark = r.status == "ok" and colored("green", "[ok] ")
      or r.status == "warn" and colored("yellow", "[WARN] ")
      or r.status == "fail" and colored("red", "[FAIL] ")
      or gray("[skip] ")
    lines[#lines + 1] = mark .. r.name .. gray("  " .. r.detail)
  end
  lines[#lines + 1] = colored("green", tostring(counts.ok) .. " ok")
    .. "  " .. colored("yellow", tostring(counts.warn) .. " warn")
    .. "  " .. colored("red", tostring(counts.fail) .. " fail")
    .. "  " .. gray(tostring(counts.skip) .. " skip")
  return lines, counts
end

-- full run: print the report and write it to Hex's data dir
function M.run()
  local results = M.run_checks()
  local lines, counts = render(results)
  print(gray("hex doctor " .. tostring(require("src.hex_version"))))
  for _, line in ipairs(lines) do
    print(line)
  end
  local report_path
  if not M.deps.self_test then
    report_path = M.deps.data.hex_dir() .. "/doctor-" .. os.date("%Y%m%d-%H%M%S") .. ".log"
    local f = io.open(report_path, "w")
    if f then
      f:write("hex doctor report " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
      for _, line in ipairs(lines) do
        f:write(line:gsub("\27%[[%d;]*%a", "") .. "\n")
      end
      f:close()
      print(gray("[hex] report: " .. report_path))
    end
  end
  if counts.fail > 0 then
    print(colored("red", "[hex] " .. counts.fail .. " check(s) failed: screenshot this plus the report file"))
  elseif counts.warn > 0 then
    print(gray("[hex] no failures, " .. counts.warn .. " warning(s)"))
  else
    print(gray("[hex] all green"))
  end
  return results
end

function M.setup(deps)
  M.deps = deps or {}
end

return M
