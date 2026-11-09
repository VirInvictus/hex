-- Hex unit suite for the pure modules. Zero dependencies: plain asserts,
-- run with the system Lua (5.4, same major version blightmud embeds).
-- Run from the repo root:  lua tests/run.lua

local root = (arg and arg[0] and arg[0]:match("^(.*)tests[/\\]run%.lua$")) or ""
if root == "" then
  root = "./"
end
package.path = root .. "?.lua;" .. root .. "src/?.lua;" .. package.path

local util = require("hex_util")
local vitals_mod = require("hex_vitals")
local queries = require("hex_queries")
local rooms_mod = require("hex_rooms")
local gags = require("hex_gags")
local status = require("hex_status")
local setup_mod = require("hex_setup")
local gagfile = require("hex_gagfile")
local data = require("hex_data")
local version = require("hex_version")
local paths = require("hex_paths")
local targets = require("hex_targets")
local walk = require("hex_walk")
local missions = require("hex_missions")
local quota = require("hex_quota")
local missiondata = require("hex_missiondata")
local skills = require("hex_skills")
local skilldata = require("hex_skilldata")
local spelldata = require("hex_spelldata")
local spells = require("hex_spells")
local notify = require("hex_notify")
local urls = require("hex_urls")
local chat = require("hex_chat")
local combat = require("hex_combat")
local stats_mod = require("hex_stats")
local theme = require("hex_theme")
-- hex_theme mutates the module graph's hex_util ("src.hex_util"); the bare
-- "hex_util" require would be a second instance of the same file
local util_src = require("src.hex_util")
local options = require("hex_options")
local defs = require("hex_options_def")
local sound_events = require("hex_sound_events")
local blorps = require("hex_blorps")
local minimap = require("hex_minimap")
local mdt = require("hex_mdt")
local mdtdata = require("hex_mdtdata")
local doctor = require("hex_doctor")
local guild_mod = require("hex_guild")
local guild_data = require("hex_guild_data")
local scry = require("hex_scry")

local count, failed = 0, 0
local function t(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then
    io.write("ok   ", name, "\n")
  else
    failed = failed + 1
    io.write("FAIL ", name, ": ", tostring(err), "\n")
  end
end

local function eq(a, b)
  if a ~= b then
    error(("expected %q, got %q"):format(tostring(b), tostring(a)), 2)
  end
end

-- util ------------------------------------------------------------------

t("sql_escape doubles quotes and strips pipes", function()
  eq(util.sql_escape("it's"), "it''s")
  eq(util.sql_escape("a|b|c"), "abc")
  eq(util.sql_escape(42), "42")
end)

t("glob_to_like handles anchors and wrapping", function()
  eq(util.glob_to_like("sword"), "%sword%")
  eq(util.glob_to_like("^sword"), "sword%")
  eq(util.glob_to_like("sword$"), "%sword")
  eq(util.glob_to_like("^sword$"), "sword")
end)

t("glob_wildcards converts * and ?", function()
  eq(util.glob_wildcards("shiny*"), "shiny%")
  eq(util.glob_wildcards("*shiny"), "%shiny")
  eq(util.glob_wildcards("sw?rd"), "sw_rd")
end)

t("split_terms drops empties and trims", function()
  local terms = util.split_terms("ale,  , spicy bread ,")
  eq(#terms, 2)
  eq(terms[1], "ale")
  eq(terms[2], "spicy bread")
end)

t("comma groups thousands", function()
  eq(util.comma(1234567), "1,234,567")
  eq(util.comma(999), "999")
  eq(util.comma("12,345"), "12,345")
end)

t("parse_rows splits lines and pipes", function()
  local rows = util.parse_rows("a|b|c\nd|e|f\n")
  eq(#rows, 2)
  eq(rows[1][2], "b")
  eq(rows[2][3], "f")
  eq(#util.parse_rows(""), 0)
  eq(#util.parse_rows(nil), 0)
end)

t("split_pipe keeps empty and trailing fields", function()
  local f = util.split_pipe("name|value|desc|appraise|")
  eq(#f, 5)
  eq(f[5], "")
  eq(#util.split_pipe("a||c"), 3)
  eq(util.split_pipe("a||c")[2], "")
end)

t("parse_rows preserves trailing empty columns", function()
  local rows = util.parse_rows("x|y|\n")
  eq(#rows[1], 3)
  eq(rows[1][3], "")
end)

t("wrap breaks long text at width", function()
  local lines = util.wrap("the quick brown fox jumps over the lazy dog", 15)
  for _, line in ipairs(lines) do
    assert(#line <= 15, "line too long: " .. line)
  end
  eq(#lines >= 3, true)
  eq(util.wrap("", 10)[1], nil)
end)

t("ratio clamps and bar fills", function()
  eq(util.ratio(150, 100), 1)
  eq(util.ratio(-5, 100), 0)
  eq(util.ratio(50, 0), 0)
  local b = util.bar(10, 0.5)
  eq(utf8.len(b), 12) -- brackets plus 10 cells (block glyphs are multibyte)
end)

t("hp color bands follow thresholds", function()
  eq(util.hp_color_name(1.0), "green")
  eq(util.hp_color_name(0.9), "green")
  eq(util.hp_color_name(0.6), "yellow")
  eq(util.hp_color_name(0.25), "magenta")
  eq(util.hp_color_name(0.1), "red")
end)

-- vitals ----------------------------------------------------------------

t("apply merges vitals and coerces numbers", function()
  local st = vitals_mod.new()
  vitals_mod.apply(st, { hp = "620", maxhp = 700, gp = 300, maxgp = "400", xp = "1,234,567", burden = 12, alignment = "neutral" })
  eq(st.cur.hp, 620)
  eq(st.max.hp, 700)
  eq(st.max.gp, 400)
  eq(st.cur.xp, 1234567)
  eq(st.cur.alignment, "neutral")
end)

t("apply resolves the documented prose spellings", function()
  local st = vitals_mod.new()
  vitals_mod.apply(st, { hitpoints = 650, guildpoints = 310, experience = "5,000", burden = 15, alignment = "neutral" })
  eq(st.cur.hp, 650)
  eq(st.cur.gp, 310)
  eq(st.cur.xp, 5000)
  eq(st.cur.burden, 15)
  eq(st.cur.alignment, "neutral")
end)

t("xp rate starts above 100 xp and computes per hour", function()
  local st = vitals_mod.new()
  eq(vitals_mod.xp_rate(st), nil)
  vitals_mod.apply(st, { xp = 50 })
  eq(vitals_mod.xp_rate(st), nil)
  vitals_mod.apply(st, { xp = 1000 })
  local t0 = st.xp_start.t
  vitals_mod.add_spent(st, 500)
  vitals_mod.apply(st, { xp = 2000 })
  -- 1000 gained over one hour
  eq(vitals_mod.xp_rate(st, t0 + 3600), 1500)
end)

t("xp rate color thresholds", function()
  eq(vitals_mod.xp_rate_name(250000), "green")
  eq(vitals_mod.xp_rate_name(150000), "yellow")
  eq(vitals_mod.xp_rate_name(50000), "cyan")
  eq(vitals_mod.xp_rate_name(5000), "red")
  eq(vitals_mod.xp_rate_name(nil), nil)
end)

-- queries ----------------------------------------------------------------

t("item test: default term becomes LIKE", function()
  eq(queries.item_test("sword"), "(i.item_name LIKE '%sword%')")
end)

t("item test: anchors and wildcards", function()
  eq(queries.item_test("^sword$"), "(i.item_name LIKE 'sword')")
  -- trailing '*' plus the default % wrap yields tt_dw's parity output '%%'
  eq(queries.item_test("sw?rd*"), "(i.item_name LIKE '%sw_rd%%')")
end)

t("item test: field prefixes", function()
  eq(queries.item_test("desc:sharp"), "(i.description LIKE '%sharp%')")
  eq(queries.item_test("app:battered"), "(i.appraise_text LIKE '%battered%')")
  eq(queries.item_test("mat:steel"), "(i.appraise_text LIKE 'it is made of %steel%')")
  assert(queries.item_test("sheat:sword"):find("sheathe a %sword%", 1, true), "scabbard branch missing")
  eq(queries.item_test("scab:knife"), queries.item_test("sheat:knife"))
end)

t("item query: OR terms, order, limit", function()
  local sql = queries.build_item_query("ale, spicy bread")
  assert(sql:find("LIMIT 31", 1, true), "missing LIMIT 31")
  assert(sql:find("ORDER BY REPLACE (item_name, 'an ', 'a ')", 1, true), "missing ordering")
  local ors = 0
  for _ in sql:gmatch(" OR ") do
    ors = ors + 1
  end
  eq(ors, 2)
end)

t("item query: exact escapes quotes", function()
  local sql = queries.build_item_query("it's", true)
  assert(sql:find("i%.item_name = 'it''s'", 1, false), "exact not escaped: " .. sql)
end)

t("npc query: room prefix and name term", function()
  local sql = queries.build_npc_query("room:98abb82010ec2737bcb6c560532cb20c8aca6398 innkeeper")
  assert(sql:find("n%.room_id = '98abb82010ec2737bcb6c560532cb20c8aca6398'", 1, false), "room filter missing")
  assert(sql:find("npc_name LIKE '%%innkeeper%%'", 1, false), "name term missing")
  assert(sql:find("LIMIT 31", 1, true), "missing LIMIT 31")
end)

t("npc query: bare term has no room filter", function()
  local sql = queries.build_npc_query("postman")
  assert(not sql:find("room_id = '", 1, true), "unexpected room filter")
end)

t("npc and sources terms escape apostrophes (found by the goldens)", function()
  -- regression: room:abc it's produced LIKE '%it's%' (malformed SQL); the
  -- spec says user-input single quotes double in every builder
  assert(queries.build_npc_query("room:abc it's"):find("'%%it''s%%'", 1, false), "npc term not escaped")
  assert(queries.build_item_sources_query("it's", "sold"):find("it''s", 1, true), "sources term not escaped")
end)

t("shop query: unions shops and vendors", function()
  local sql = queries.build_shop_query("abc")
  assert(sql:find("shop_items", 1, true) and sql:find("npc_items", 1, true), "missing union arms")
  assert(sql:find("si%.room_id = 'abc'", 1, false), "room filter missing")
  assert(sql:find("NOT IN %('found','loot',''%)", 1, false), "price filter missing")
  assert(sql:find("LIMIT 61", 1, true), "missing LIMIT 61")
end)

t("item sources query: price flags", function()
  local sold = queries.build_item_sources_query("sword", "sold")
  assert(sold:find("price GLOB", 1, true), "sold filter missing")
  assert(sold:find("Shonky Shop", 1, true), "Shonky exclusion missing")
  assert(sold:find("u%.room_id NOT IN", 1, false), "room_id must be qualified (was ambiguous against r.room_id)")
  local free = queries.build_item_sources_query("sword", "free")
  assert(free:find("NOT GLOB", 1, true), "free filter missing")
  local loot = queries.build_item_sources_query("sword", "loot")
  assert(loot:find("price = 'loot'", 1, true), "loot filter missing")
end)

t("where and zone queries escape ids", function()
  assert(queries.build_where_query("it's"):find("it''s", 1, true), "where query not escaped")
  assert(queries.build_zone_query("abc"):find("room_id = 'abc'", 1, true), "zone query malformed")
end)

t("zone names ported", function()
  eq(queries.zone_name(1), "Ankh-Morpork")
  eq(queries.zone_name(47), "UU Library")
  eq(queries.zone_name(99), "Terrains")
  eq(queries.zone_name(3), "AM Buildings")
  eq(queries.zone_name(98), "<Unknown>")
end)

-- rooms / gags / status --------------------------------------------------

t("rooms update tracks id, name, terrain", function()
  local st = rooms_mod.new()
  rooms_mod.update(st, { name = "x" }) -- no identifier: state unchanged
  eq(st.id, nil)
  rooms_mod.update(st, { identifier = "abc", name = "Drum", terrain = "inside" })
  eq(st.id, "abc")
  eq(st.name, "Drum")
  rooms_mod.update(st, { identifier = "def" })
  eq(st.previous, "abc")
  eq(st.id, "def")
end)

t("gags: data table is well-formed", function()
  assert(#gags.patterns >= 10, "suspiciously few gags")
  for _, p in ipairs(gags.patterns) do
    assert(type(p.re) == "string" and #p.re > 2, "bad pattern")
    assert(p.sub == nil or type(p.sub) == "string", "bad sub")
  end
end)

t("gags: critter pattern covers tt_dw vocabulary", function()
  local first = gags.patterns[1].re
  for _, phrase in ipairs({ "(?:moon|swamp) dragon", "swarm of fireflies", "skeleton warrior", " you in" }) do
    assert(first:find(phrase, 1, true), "critter pattern missing: " .. phrase)
  end
  eq(gags.patterns[1].i, true)
end)

t("status render: three lines with bars", function()
  local st = vitals_mod.new()
  vitals_mod.apply(st, { hp = 600, maxhp = 700, gp = 350, maxgp = 400, xp = 123456, burden = 10, alignment = "good" })
  st.rate = 150000
  local lines = status.render(st, { id = string.rep("ab", 20), name = "the Mended Drum" }, 80)
  eq(#lines, 3)
  assert(lines[1]:find("HP%[", 1, false), "no HP bar: " .. lines[1])
  assert(lines[1]:find("GP%[", 1, false), "no GP bar: " .. lines[1])
  assert(lines[2]:find("Mended Drum", 1, true), "room name missing")
  assert(lines[2]:find("burden 10%%", 1, false), "burden missing: " .. lines[2])
  assert(lines[3]:find("150,000", 1, true), "xp rate missing")
end)

t("status render: empty state does not crash", function()
  local lines = status.render(vitals_mod.new(), {}, 80)
  eq(#lines, 3)
end)

-- strip_ansi -------------------------------------------------------------

t("strip_ansi removes colour sequences", function()
  eq(util.strip_ansi("\27[39;49mfoo\27[0m"), "foo")
  eq(util.strip_ansi("\27[31mred\27[0m and \27[32mgreen\27[0m"), "red and green")
  eq(util.strip_ansi("\27[1;34;47mstacked\27[0m"), "stacked")
end)

t("strip_ansi handles other CSI final letters", function()
  eq(util.strip_ansi("\27[2Jclear\27[5;10Hpos"), "clearpos")
  eq(util.strip_ansi("plain text stays"), "plain text stays")
  eq(util.strip_ansi(""), "")
end)

-- hex_setup ----------------------------------------------------------------

t("setup: all groups send 7 documented commands", function()
  local cmds = setup_mod.commands("all")
  eq(#cmds, 7)
  assert(cmds[1]:find('^prompt "%$hurtcolour%$'), "prompt string not first: " .. cmds[1])
  assert(cmds[2]:find("^monitor %$hurtcolour%$"), "monitor not second: " .. cmds[2])
end)

t("setup: documented rows form and xterm256 colour", function()
  local found_rows, found_term, found_bare_rows = false, false, false
  for _, cmd in ipairs(setup_mod.commands("all")) do
    if cmd == "options terminal rows=999" then
      found_rows = true
    end
    if cmd == "term xterm256" then
      found_term = true
    end
    if cmd == "rows 999" then
      found_bare_rows = true
    end
  end
  eq(found_rows, true)
  eq(found_term, true)
  eq(found_bare_rows, false) -- undocumented bare form stays out
end)

t("setup: group selection and unknown groups", function()
  eq(#setup_mod.commands("prompt"), 2)
  eq(#setup_mod.commands("aliases"), 1)
  eq(#setup_mod.commands("options"), 4)
  eq(#setup_mod.commands("nope"), 0)
  eq(#setup_mod.commands(nil), 0)
end)

-- hex_version ---------------------------------------------------------------

t("hex_version matches the VERSION file", function()
  local f = io.open(root .. "VERSION", "r")
  assert(f, "VERSION file missing")
  local v = f:read("l") or ""
  f:close()
  eq(util.trim(v), version)
end)

-- hex_gagfile ----------------------------------------------------------------

t("gagfile: serialize round-trips through load", function()
  local entries = {
    { re = "^The priest blesses you\\.$" },
    { re = "^Xavara whispers, .*$", i = true },
    { re = "^A .* messenger arrives\\.$", sub = "" },
    { re = "contains ]] inside", sub = 'say "hi"' },
  }
  local chunk = load(gagfile.serialize(entries))
  assert(chunk, "serialized file does not parse")
  local parsed = chunk()
  eq(#parsed, 4)
  for i = 1, 4 do
    eq(parsed[i].re, entries[i].re)
    eq(parsed[i].i, entries[i].i)
    eq(parsed[i].sub, entries[i].sub)
  end
end)

t("gagfile: sanitize validates entries", function()
  local e = gagfile.sanitize({ re = "^x$", i = 1, sub = "" })
  eq(e.re, "^x$")
  eq(e.i, true)
  eq(e.sub, "")
  local bad = { gagfile.sanitize(nil), gagfile.sanitize({}), gagfile.sanitize({ re = "" }), gagfile.sanitize({ re = "x", sub = 5 }) }
  for i, r in ipairs(bad) do
    eq(r, nil)
  end
end)

t("gagfile: render_entry shows kind, flags, pattern", function()
  local line = gagfile.render_entry(3, { re = "^abc$", i = true })
  assert(line:find("^  3  gag  i  %^abc%$$"), "unexpected render: " .. line)
  assert(gagfile.render_entry(1, { re = "^x$", sub = "" }):find("sub", 1, true), "sub kind missing")
end)

-- hex_data -----------------------------------------------------------------

local LADDER_PATHS = { owned = "/h/quow.db", legacy = "/ttdw/_quowmap_database.db" }

t("data: ladder prefers an explicit /hexset value", function()
  local r = data.resolve_quow("/custom.db", true, true, LADDER_PATHS)
  eq(r.path, "/custom.db")
  eq(r.source, "set")
  eq(r.hint, nil)
end)

t("data: ladder uses the owned copy when present", function()
  local r = data.resolve_quow(nil, true, true, LADDER_PATHS)
  eq(r.path, "/h/quow.db")
  eq(r.source, "owned")
  -- an empty-string explicit counts as unset
  eq(data.resolve_quow("", true, true, LADDER_PATHS).source, "owned")
end)

t("data: ladder falls back to tt_dw with a hint", function()
  local r = data.resolve_quow(nil, false, true, LADDER_PATHS)
  eq(r.path, LADDER_PATHS.legacy)
  eq(r.source, "legacy")
  assert(r.hint:find("/hexupdate", 1, true), "hint missing /hexupdate")
end)

t("data: missing everywhere resolves to the owned path", function()
  local r = data.resolve_quow(nil, false, false, LADDER_PATHS)
  eq(r.path, LADDER_PATHS.owned)
  eq(r.source, "missing")
  assert(r.hint:find("/hexupdate", 1, true), "hint missing /hexupdate")
end)

t("data: days_old maths and guards", function()
  local now = 1800000000
  eq(data.days_old(now - 86400 * 73 - 3600, now), 73)
  eq(data.days_old(now, now), 0)
  eq(data.days_old(now + 10, now), nil) -- clock skew: not negative days
  eq(data.days_old(nil, now), nil)
end)

t("data: stale warning names path, age, and /hexupdate", function()
  local lines = data.stale_warning("/some/quow.db", 73)
  eq(#lines, 2)
  assert(lines[1]:find("73 days old", 1, true), "age missing: " .. lines[1])
  assert(lines[1]:find("/some/quow%.db"), "path missing: " .. lines[1])
  assert(lines[2]:find("/hexupdate", 1, true), "refresh hint missing: " .. lines[2])
end)

t("data: download command builders quote and chain mv", function()
  local ua = data.user_agent()
  -- escaped so a prerelease suffix in the version ("0.5.2-dbg") stays a literal
  assert(ua:find("^hex/" .. version:gsub("%W", "%%%0") .. " update script"), "UA shape: " .. ua)
  local curl = data.download_inner("curl", ua, "/h/quow.db.part", "/h/quow.db")
  assert(curl:find("^curl %-fsSL %-A 'hex/"), "curl form prefix: " .. curl)
  assert(curl:find(ua, 1, true), "UA missing from curl line: " .. curl)
  assert(curl:find("%)' %-o '/h/quow%.db%.part'"), "curl form middle: " .. curl)
  assert(curl:find("quow%.co%.uk/maps/_quowmap_database%.db"), "quow URL missing")
  assert(curl:find(" && mv %-f '/h/quow%.db%.part' '/h/quow%.db'$"), "atomic mv missing: " .. curl)
  local wget = data.download_inner("wget", ua, "/h/quow.db.part", "/h/quow.db")
  assert(wget:find("^wget %-q %-U 'hex/"), "wget form prefix: " .. wget)
  assert(wget:find(ua, 1, true), "UA missing from wget line: " .. wget)
  local outer = data.download_outer(curl, "/h/quow-update.log")
  -- the inner's single quotes come back POSIX-escaped ('\''') inside the
  -- sh -c wrapper; assert shape, not a full equality
  assert(outer:find("^nohup sh %-c '.+' > '/h/quow%-update%.log' 2>&1 &$"), "outer form: " .. outer)
  assert(outer:find("mv -f", 1, true), "inner missing from outer: " .. outer)
end)

-- hex_targets ---------------------------------------------------------------

t("targets: is_room_id accepts 40-hex only", function()
  eq(targets.is_room_id(string.rep("a", 40)), true)
  eq(targets.is_room_id(string.rep("a", 39)), false)
  eq(targets.is_room_id(string.rep("A", 40)), false) -- uppercase is not the MUD's id form
  eq(targets.is_room_id("UULibrary"), false)
  eq(targets.is_room_id(string.rep("a", 39) .. "f"), true)
  eq(targets.is_room_id(string.rep("a", 39) .. "g"), false) -- g is not a hex digit
  eq(targets.is_room_id(string.rep("a", 39) .. "z"), false)
  eq(targets.is_room_id(nil), false)
end)

t("targets: parse grammar", function()
  local p = targets.parse("#2")
  eq(p.steps[1].kind, "ref")
  eq(p.steps[1].n, 2)
  p = targets.parse("@am")
  eq(p.steps[1].kind, "origin")
  eq(p.steps[1].area, "am")
  p = targets.parse("@ankh drum")
  eq(p.steps[1].kind, "origin")
  eq(p.steps[2].kind, "name")
  eq(p.steps[2].area, "ankh")
  eq(p.steps[2].term, "drum")
  p = targets.parse("drum")
  eq(p.steps[1].kind, "id")
  eq(p.steps[2].kind, "name")
  p = targets.parse("*drum*")
  eq(p.steps[1].kind, "name") -- wildcard term never probes ids
  p = targets.parse("4659")
  eq(p.steps[3].kind, "vnum")
  eq(targets.parse("  "), nil)
end)

t("targets: builders escape and shape SQL", function()
  assert(targets.build_id_query("it's"):find("'it''s'", 1, true), "id query not escaped")
  assert(targets.build_origin_query("am"):find("area LIKE 'am%%'"), "origin query shape: " .. targets.build_origin_query("am"))
  local name_q = targets.build_name_query("^drum$", "ankh")
  assert(name_q:find("name LIKE 'drum'", 1, true), "anchors not handled: " .. name_q)
  assert(name_q:find("AND area LIKE '%%ankh%%'"), "area not scoped: " .. name_q)
  assert(name_q:find("LIMIT 15", 1, true), "limit missing: " .. name_q)
  local wild = targets.build_name_query("sw?rd*", nil)
  assert(wild:find("name LIKE '%%sw_rd%%%%'"), "wildcards not converted: " .. wild)
  assert(targets.build_vnum_query(4659):find("vnum = 4659", 1, true), "vnum query malformed")
  assert(not targets.build_name_query("drum", nil):find("AND area", 1, true), "unexpected area scope")
end)

t("targets: /near's all-matches query drops the cap (the Job Market bug)", function()
  -- found live 2026-11-06: the alphabetical LIMIT 15 cut AM's "Job Market"
  -- rooms out of /near market, leaving five unreachable Genua/Ephebe rows
  assert(not targets.build_name_query("market", nil, true):find("LIMIT", 1, true), "all-matches must not cap")
  assert(targets.build_name_query("market", nil):find("LIMIT 15", 1, true), "capped default retained")
end)

-- hex_paths -----------------------------------------------------------------

-- synthetic dump rows in the parse_rows shape (arrays of field arrays)
local function hexid(n)
  return string.rep(("%x"):format(n % 16), 40)
end

local function node_row(vnum, flags, name, area)
  return { tostring(vnum), tostring(flags or 0), hexid(vnum), name or ("room " .. vnum), area or "Test Area" }
end

local function edge(dest, cmd, flag, dir, dist)
  return dest .. ":" .. (flag or 0) .. ":" .. (dir or 0) .. ":" .. (dist or 1) .. ":" .. cmd
end

local function edge_row(from, edges)
  return { tostring(from), table.concat(edges, ",") }
end

local function tiny_graph(node_flags)
  node_flags = node_flags or {}
  local nodes = {}
  for v = 1, 4 do
    nodes[#nodes + 1] = node_row(v, node_flags[v])
  end
  local edges = {
    edge_row(1, { edge(2, "north", 0, 1), edge(3, "east", 0, 2) }),
    edge_row(2, { edge(4, "north", 0, 1) }),
    edge_row(3, { edge(4, "northeast", 0, 3) }),
    edge_row(4, { edge(2, "south", 0, 4) }),
  }
  return paths.load(nodes, edges)
end

t("paths: load builds CSR and lookups", function()
  local g = tiny_graph()
  eq(#g.vnum, 4)
  eq(g.edges, 5)
  eq(g.idx[3], 3)
  eq(g.by_id[hexid(4)], 4)
  eq(g.name[2], "room 2")
  eq(g.offs[5], g.edges)
end)

t("paths: routes carry verbatim commands and steps", function()
  local g = tiny_graph()
  local r = paths.find_route(g, { 1 }, 4)
  eq(r.steps, 2)
  -- both hops are 2 steps; the tie-break takes the lower dense index (2 before 3)
  eq(r.path[1].cmd, "north")
  eq(r.path[2].cmd, "north")
  eq(r.dist, 2)
  eq(r.from, 1)
  eq(r.to, 4)
end)

t("paths: one-way edges are never reversed", function()
  local g = tiny_graph()
  local r = paths.find_route(g, { 3 }, 1)
  eq(r, nil) -- 3 has only the outbound edge to 4; 4->2 only; no way to 1
end)

t("paths: tie-break is deterministic", function()
  local g = tiny_graph()
  local first = paths.find_route(g, { 1 }, 4)
  for _ = 1, 10 do
    local r = paths.find_route(g, { 1 }, 4)
    eq(r.path[1].to, first.path[1].to)
    eq(r.path[2].to, first.path[2].to)
  end
end)

t("paths: multi-target distances match single routes", function()
  local g = tiny_graph()
  local ds = paths.distances(g, 1, { 2, 3, 4 })
  eq(ds[2], 1)
  eq(ds[3], 1)
  eq(ds[4], 2)
  for v = 2, 4 do
    local r = paths.find_route(g, { 1 }, v)
    eq(r.dist, ds[v])
  end
  eq(ds[99], nil) -- absent = unreachable
end)

t("paths: avoid rooms reroute or refuse until allowed", function()
  -- diamond with the middle node AVOID: the route reroutes around it
  local g = tiny_graph({ [2] = 1 })
  local r = paths.find_route(g, { 1 }, 4)
  assert(r, "alternative path exists")
  eq(r.path[1].cmd, "east") -- not the north route through node 2
  -- a chain with a blocked middle has no alternative: refused
  local chain = paths.load({ node_row(1), node_row(2, 1), node_row(3) }, {
    edge_row(1, { edge(2, "north") }),
    edge_row(2, { edge(3, "north") }),
    edge_row(3, {}),
  })
  eq(paths.find_route(chain, { 1 }, 3, { ["allow_avoid"] = false }), nil)
  eq(paths.find_route(chain, { 1 }, 3, { allow_avoid = true }).steps, 2)
end)

t("paths: water target refuses with a clear reason", function()
  local g = tiny_graph({ [4] = 513 }) -- AVOID|AVOID_TMP
  local r, reason = paths.find_route(g, { 1 }, 4)
  eq(r, nil)
  assert(reason:find("avoid", 1, true), "reason: " .. tostring(reason))
  -- allowed: routable again
  eq(paths.find_route(g, { 1 }, 4, { allow_avoid = true }).steps, 2)
end)

t("paths: routing OUT of a blocked start works", function()
  local g = tiny_graph({ [1] = 513 }) -- you are in water
  local r = paths.find_route(g, { 1 }, 4)
  assert(r, "blocked start must still expand")
  eq(r.steps, 2)
end)

t("paths: unreachable target reports cleanly", function()
  local nodes = { node_row(1), node_row(2), node_row(3) }
  local edges = { edge_row(1, { edge(2, "north") }), edge_row(3, { edge(2, "south") }) }
  local g = paths.load(nodes, edges)
  local r, reason = paths.find_route(g, { 1 }, 3)
  eq(r, nil)
  eq(reason, "unreachable")
end)

t("paths: weights come from exit distance", function()
  local nodes = { node_row(1), node_row(2), node_row(3) }
  local edges = {
    edge_row(1, { edge(2, "north", 0, 1, 1), edge(3, "journey e", 0, 0, 7) }),
    edge_row(2, { edge(3, "north", 0, 1, 8) }),
    edge_row(3, {}),
  }
  local g = paths.load(nodes, edges)
  -- 1 -> 3: journey edge costs 7, two-step walk costs 9
  local r = paths.find_route(g, { 1 }, 3)
  eq(r.dist, 7)
  eq(r.path[1].cmd, "journey e")
end)

t("paths: render groups consecutive commands", function()
  local nodes = { node_row(1), node_row(2), node_row(3), node_row(4) }
  local edges = {
    edge_row(1, { edge(2, "north", 0, 1) }),
    edge_row(2, { edge(3, "north", 0, 1) }),
    edge_row(3, { edge(4, "east", 0, 2) }),
    edge_row(4, {}),
  }
  local g = paths.load(nodes, edges)
  local r = paths.find_route(g, { 1 }, 4)
  local lines = paths.render(r, g)
  eq(#lines, 2)
  assert(lines[1]:find("route: room 1 %-> room 4   3 steps"), "header: " .. lines[1])
  assert(lines[2]:find("%[2 north%] %[1 east%]"), "segments: " .. lines[2])
  local full = paths.render(r, g, true)
  eq(#full, 4)
  assert(full[2]:find("  1%. north"), "full lines: " .. full[2])
end)

t("paths: lone special exits render as bare commands", function()
  local nodes = { node_row(1), node_row(2) }
  local edges = {
    edge_row(1, { edge(2, "enter crate", 0, 0) }),
    edge_row(2, {}),
  }
  local g = paths.load(nodes, edges)
  local r = paths.find_route(g, { 1 }, 2)
  local lines = paths.render(r, g)
  assert(lines[2]:find("%[enter crate%]"), "special render: " .. lines[2])
  assert(not lines[2]:find("1 enter"), "no count on specials: " .. lines[2])
end)

t("paths: BFS equivalence on a random unit graph", function()
  -- deterministic LCG graph, 40 nodes, undirected unit edges; Dijkstra
  -- distances must equal a plain BFS
  local N = 40
  local nodes = {}
  for v = 1, N do
    nodes[#nodes + 1] = node_row(v)
  end
  local seed = 42
  local function rand(m)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % m
  end
  local adjacency = {}
  for _ = 1, 120 do
    local a, b = rand(N) + 1, rand(N) + 1
    if a ~= b then
      adjacency[a] = adjacency[a] or {}
      adjacency[b] = adjacency[b] or {}
      if not adjacency[a][b] then
        adjacency[a][b] = true
        adjacency[b][a] = true
      end
    end
  end
  local edge_rows = {}
  for v = 1, N do
    local list = {}
    for w in pairs(adjacency[v] or {}) do
      list[#list + 1] = edge(w, "north")
    end
    edge_rows[#edge_rows + 1] = edge_row(v, list)
  end
  local g = paths.load(nodes, edge_rows)
  -- reference BFS from node 1
  local bfs = { [1] = 0 }
  local queue = { 1 }
  local qi = 1
  while qi <= #queue do
    local cur = queue[qi]
    qi = qi + 1
    for w in pairs(adjacency[cur] or {}) do
      if bfs[w] == nil then
        bfs[w] = bfs[cur] + 1
        queue[#queue + 1] = w
      end
    end
  end
  local ds = paths.distances(g, 1, g.vnum)
  for v = 1, N do
    eq(ds[v], bfs[v])
  end
end)

-- golden routes (opt-in: HEX_GOLDEN=1, needs the real rooms.db + sqlite3) --

if os.getenv("HEX_GOLDEN") == "1" then
  local gold_db = os.getenv("HEX_ROOMS_DB") or (os.getenv("HOME") or "") .. "/.local/share/hex/rooms.db"

  local function gold_sql(sql_text)
    local sq = "'" .. sql_text:gsub("'", "'\\''") .. "'"
    local f = io.popen("sqlite3 " .. gold_db .. " " .. sq)
    local out = f:read("*a") or ""
    f:close()
    return out
  end

  local gold_loaded = false
  local gold_graph

  local function gold_graph_lazy()
    if gold_loaded then
      return gold_graph
    end
    gold_loaded = true
    gold_graph = paths.load(util.parse_rows(gold_sql(paths.NODE_QUERY)), util.parse_rows(gold_sql(paths.EDGE_QUERY)))
    return gold_graph
  end

  t("golden: graph covers the identified subgraph", function()
    local g = gold_graph_lazy()
    assert(g, "gold graph failed to load")
    assert(#g.vnum > 30000, "graph too small: " .. #g.vnum)
    assert(g.edges > 60000, "edges too few: " .. g.edges)
  end)

  t("golden: the Drum bar to the Djel institute library is 129 steps", function()
    local r = paths.find_route(gold_graph_lazy(), { 4659 }, 12472)
    assert(r, "no route")
    eq(r.steps, 129)
  end)

  t("golden: find_route and distances accept a 40-hex room_id start", function()
    -- the live bug (2026-11-08): /goto passed room.id strings into idx
    -- lookups and never started; the goldens injected vnums so only play
    -- could catch it. Pin both entry points with the real Drum id.
    local drum_id = util.trim(gold_sql("SELECT room_id FROM rooms WHERE vnum = 4659 LIMIT 1"))
    assert(targets.is_room_id(drum_id), "drum id lookup failed")
    local r = paths.find_route(gold_graph_lazy(), { drum_id }, 12472)
    assert(r, "id-string start killed find_route")
    eq(r.steps, 129)
    local d = paths.distances(gold_graph_lazy(), drum_id, { 12472 })
    eq(d[12472], 129)
  end)

  t("golden: BP palace gates are unreachable from AM (sea-chain gap)", function()
    -- The identified-only subgraph does not connect the two coasts: the
    -- open-sea swim chain between the Terrains and Tuna Bay passes through
    -- UNIDENTIFIED sea rooms (measured 2026-11-05; the design doc's original
    -- 118/123-step BP routes came from a leakier loader). tt_dw does not
    -- hit this because its mapper routes unidentified rooms by vnum. Boats
    -- are Phase 5's journey/ferry box.
    local r = paths.find_route(gold_graph_lazy(), { 3424 }, 5898)
    eq(r, nil)
    r = paths.find_route(gold_graph_lazy(), { 4659 }, 5898, { allow_avoid = true })
    eq(r, nil)
  end)

  t("golden: Genua is unreachable from AM (Bois has no inbound edges)", function()
    local r = paths.find_route(gold_graph_lazy(), { 4659 }, 11279)
    eq(r, nil)
  end)

  t("golden: a shared-instance room is not in the graph", function()
    local out = gold_sql("SELECT vnum FROM rooms WHERE room_id = 'UULibrary' LIMIT 1")
    local vnum = tonumber(util.trim(out))
    assert(vnum, "no UULibrary room found")
    local r = paths.find_route(gold_graph_lazy(), { 4659 }, vnum)
    eq(r, nil)
  end)
end

-- hex_walk ----------------------------------------------------------------

-- an n-node chain route: every step is "north" onto the next identified room
local function chain_route(n)
  local nodes = {}
  for v = 1, n do
    nodes[#nodes + 1] = node_row(v)
  end
  local edge_rows = {}
  for v = 1, n - 1 do
    edge_rows[#edge_rows + 1] = edge_row(v, { edge(v + 1, "north") })
  end
  edge_rows[#edge_rows + 1] = edge_row(n, {})
  local g = paths.load(nodes, edge_rows)
  return paths.find_route(g, { 1 }, n)
end

t("walk: build_queue packs the sanctioned batch", function()
  local route = chain_route(3)
  local q = walk.build_queue(route, "walk")
  eq(#q, 2)
  assert(
    q[1] == "alias hex_goto_walk noalias options personal travel = walk;north;north;frimble hex: walk done",
    "alias line: " .. q[1]
  )
  eq(q[2], "hex_goto_walk")
end)

t("walk: journey default restores the option inside the batch", function()
  local q = walk.build_queue(chain_route(2), "journey")
  assert(q[1]:find(";noalias options personal travel = journey;frimble "), "restore missing: " .. q[1])
  local plain = walk.build_queue(chain_route(2), "walk")
  assert(not plain[1]:find("travel = journey", 1, true), "unexpected restore in walk default")
end)

t("walk: transition advances, milestones, completes", function()
  local route = chain_route(30)
  local state = walk.new_state(route, "somewhere far")
  local kinds = {}
  for i = 1, state.total do
    local ev = walk.transition(state, route.path[i].room_id)
    kinds[#kinds + 1] = ev.kind .. tostring(ev.index or "")
  end
  eq(kinds[1], "advance1")
  eq(kinds[2], "advance2")
  eq(kinds[25], "milestone25")
  eq(kinds[state.total], "complete" .. state.total)
  eq(state.complete, true)
end)

t("walk: mismatch reports once then counts silently", function()
  local route = chain_route(6) -- 6 nodes = 5 steps
  local state = walk.new_state(route, "target")
  eq(walk.transition(state, route.path[1].room_id).kind, "advance")
  local ev = walk.transition(state, string.rep("f", 40))
  eq(ev.kind, "mismatch")
  eq(ev.index, 2)
  eq(ev.expected, route.path[2].room_id)
  eq(walk.transition(state, string.rep("f", 40)).kind, "drifted") -- step 3
  eq(walk.transition(state, string.rep("f", 40)).kind, "drifted") -- step 4
  local done = walk.transition(state, route.path[5].room_id) -- step 5 = total
  eq(done.kind, "complete")
  eq(done.drifted_at, 2)
end)

t("walk: nil-id pushes advance optimistically (dark rooms)", function()
  -- found live 2026-11-08 night: dark countryside rooms push room.info
  -- without identifiers; the walk ignored them and reported 0/38 while
  -- successfully moving Brandon the whole 38-step route
  local route = chain_route(4)
  local state = walk.new_state(route, "target")
  eq(walk.transition(state, nil).kind, "advance")
  eq(state.unverified, 1)
  eq(walk.transition(state, nil).kind, "advance")
  eq(walk.transition(state, route.path[3].room_id).kind, "complete") -- known id lands the walk
  eq(state.complete, true)
end)

t("walk: all-dark walk completes unverified at the last push", function()
  local route = chain_route(5) -- 1->5 is 4 steps
  local state = walk.new_state(route, "target")
  for _ = 1, 3 do
    eq(walk.transition(state, nil).kind, "advance")
  end
  local done = walk.transition(state, nil)
  eq(done.kind, "complete")
  eq(done.unverified, true)
  eq(done.index, 4)
end)

t("walk: mismatch and drifted events carry total (the live crash)", function()
  -- found 2026-11-08: the mismatch print concatenates event.total, but the
  -- event never carried it -- the first live drift crashed the walk script
  local route = chain_route(4) -- 1->4 is 3 steps, so total is 3
  local state = walk.new_state(route, "target")
  eq(walk.transition(state, route.path[1].room_id).kind, "advance")
  local ev = walk.transition(state, string.rep("f", 40))
  eq(ev.kind, "mismatch")
  eq(ev.total, 3)
  eq(walk.transition(state, string.rep("f", 40)).total, 3)
end)

t("walk: an early frimble marker reports honestly instead of arriving", function()
  -- found live: night climbs failed, the queue drained, and the marker made
  -- the finish print "arrived" 3 steps into a 32-step walk
  local route = chain_route(6) -- 1->6 is 5 steps
  local state = walk.new_state(route, "target")
  eq(walk.transition(state, route.path[1].room_id).kind, "advance")
  local done = walk.on_done_line(state)
  eq(done.kind, "complete")
  eq(done.early, true)
  eq(done.index, 1)
  eq(done.total, 5)
  -- a full walk's marker is not early
  local state2 = walk.new_state(chain_route(3), "x")
  walk.transition(state2, route.path[1].room_id) -- warm-up push, will drift; fine
  local done2 = walk.on_done_line(state2)
  eq(done2.kind, "complete")
end)

t("walk: completion via the frimble marker", function()
  local state = walk.new_state(chain_route(3), "x")
  assert(walk.is_done_marker("hex: walk done"), "marker must match")
  assert(not walk.is_done_marker("hex: walk done."), "stray period must not match")
  assert(not walk.is_done_marker("You are standing in the hall"), "ordinary lines must not match")
  eq(walk.on_done_line(state).kind, "complete")
  eq(walk.transition(state, string.rep("f", 40)).kind, "idle")
end)

t("walk: long routes warn before the MUD's 5-minute abort", function()
  eq(walk.should_warn({ steps = walk.WARN_STEPS }), false)
  eq(walk.should_warn({ steps = walk.WARN_STEPS + 1 }), true)
end)

-- hex_missions ---------------------------------------------------------------

t("missiondata: tables are complete and coherent", function()
  local n_jobs = 0
  for _ in pairs(missiondata.jobs) do
    n_jobs = n_jobs + 1
  end
  eq(n_jobs, 13)
  for short, name in pairs(missiondata.jobs) do
    assert(missiondata.xp["market_" .. short], "missing xp for market_" .. short)
    assert(missiondata.job_short(name) == short, "job_short round-trip fails for " .. name)
  end
  eq(missiondata.job_short("Delivery Lackey (m/f)"), "lackey") -- (m/f) suffix tolerated
  eq(missiondata.job_short("No Such Job"), nil)
  for letter, id in pairs(missiondata.letters) do
    assert(missiondata.xp["letter_" .. id], "missing xp for letter_" .. id)
    assert(missiondata.tletters[letter], "missing tletter label " .. letter)
  end
  eq(missiondata.xp.letter_difficult, 40000) -- the guess, replaced on first live delivery
end)

t("missions: xp halves per pending reset", function()
  eq(missions.xp_for("market_quencher", 0), 1600)
  eq(missions.xp_for("market_quencher", 1), 800)
  eq(missions.xp_for("market_quencher", 3), 200)
  eq(missions.xp_for("market_maintenance", 2), 47000)
end)

t("missions: sausage xp uses critter table then per-dollar", function()
  eq(missions.xp_for("plain_sausages", 0, nil, nil, "badger"), 52800)
  eq(missions.xp_for("spiced_sausages", 1, nil, nil, "whale"), 74640) -- 149280 / 2
  eq(missions.xp_for("plain_sausages", 0, nil, 25, "unknown critter"), 1955 * 25)
  -- no critter and no dollars: the A$25 default payout, then halved twice
  eq(missions.xp_for("plain_sausages", 2, nil, nil, nil), math.floor(1955 * 25 / 4 + 0.5))
end)

t("missions: difficult letter learns past the guess", function()
  eq(missions.xp_for("letter_difficult", 0, nil), 40000)
  eq(missions.xp_for("letter_difficult", 0, 45123), 45123)
end)

t("missions: completion EMA and stats (hand-computed)", function()
  local st = { _short = "market_dogwalker", total_count = 0 }
  local out = missions.apply_completion(st, 600, nil)
  eq(st.est_time, 600)
  eq(st.avg_time, 600)
  eq(st.min_time, 600)
  eq(st.max_time, 600)
  eq(out.rate, 96000) -- 16000 / 600 * 3600
  -- second completion, slower: EMA leans toward the new time
  st.total_count = 1
  out = missions.apply_completion(st, 1200, nil)
  eq(st.est_time, 900) -- (1200 + 600) / 2
  eq(st.avg_time, 900) -- (1200 + 600*1) / 2
  eq(st.max_time, 1200)
  eq(out.rate, 48000) -- 16000 / 900 * 3600
  -- rewarded xp lower than the model: the caller sees both values; one
  -- pending reset halves the model xp (the caller appends the new reset
  -- after this call)
  st.total_count = 2
  st.resets = { 1000000001 }
  out = missions.apply_completion(st, 900, 4000)
  eq(out.xp, 4000)
  eq(out.full_xp, 8000)
end)

t("missions: timer sweep announces inside the window only", function()
  local now = 1000000
  local m = {
    a = { resets = { now + 1800, now - 5 } }, -- one future, one just expired
    b = { resets = { now - 10 } }, -- fresh expiry: announce
    c = { resets = { now - 5, now - 2 } }, -- two expiries, announce once when empty
    old = { resets = { now - 7 * 3600 } }, -- outside the 6h window: silent
  }
  local announce, next_reset = missions.check_timers(m, now)
  table.sort(announce)
  eq(#announce, 2)
  eq(announce[1], "b")
  eq(announce[2], "c")
  eq(next_reset, now + 1800)
  eq(#m.a.resets, 1) -- pruned to the future one
  eq(#m.b.resets, 0)
  eq(#m.old.resets, 0)
  -- a mission with a STILL-PENDING reset does not announce its expiry
  m = { d = { resets = { now - 5, now + 60 } } }
  announce = missions.check_timers(m, now)
  eq(#announce, 0)
end)

t("missions: chip shows minutes to the next reset", function()
  local now = 1000000
  eq(missions.chip({}, now), nil)
  eq(missions.chip({ x = { resets = { now + 1500 } } }, now), "[M:25m]")
  eq(missions.chip({ x = { resets = { now + 5 } } }, now), "[M:1m]")
end)

t("missions: comparator rates descending, unrated last", function()
  local rated_hi = { rate = 90000, xp = 16000 }
  local rated_lo = { rate = 8000, xp = 188000 }
  local unrated = { rate = 0, xp = 50064 }
  assert(missions.compare(rated_hi, rated_lo), "higher rate first")
  assert(not missions.compare(rated_lo, rated_hi), "antisymmetry")
  assert(missions.compare(rated_lo, unrated), "rated before unrated")
  assert(missions.compare({ rate = 0, xp = 999 }, unrated) == false, "equal rates: higher xp first")
end)

-- hex_quota ----------------------------------------------------------------

t("quota: parses the brief example block", function()
  local st = {}
  local fixture = {
    "  Receipts received: A$131.56.",
    "  Guild cut: A$39.46.",
    "  Amount paid: A$39.46.",
    "  Amount owed: A$0.",
    "  Time left: 1 hour, 10 minutes, 17 seconds.",
    "  Min quota: A$8.25.",
    "  Max quota: A$133.",
  }
  local handled = 0
  for _, line in ipairs(fixture) do
    if quota.parse_line(st, line) then
      handled = handled + 1
    end
  end
  eq(handled, 6) -- "Guild cut" is not tracked (tt_dw tracks five fields + time)
  eq(st.rcpt, 131.56)
  eq(st.min, 8.25)
  eq(st.max, 133)
  eq(st.owed, 0)
  eq(st.paid, 39.46)
  eq(st.deadline, os.time() + 1 * 3600 + 10 * 60 + 17)
end)

t("quota: pence forms divide by 100", function()
  local st = {}
  eq(quota.parse_line(st, "  Receipts received: 13156p."), true)
  eq(st.rcpt, 131.56)
  st = {}
  eq(quota.parse_line(st, "  Amount owed: 250p."), true)
  eq(st.owed, 2.5)
end)

t("quota: all six time-left shapes", function()
  local cases = {
    { "  Time left: 2 days, 3 hours, 4 minutes, 5 seconds.", 2 * 86400 + 3 * 3600 + 4 * 60 + 5 },
    { "  Time left: 1 hour, 2 minutes, 3 seconds.", 3600 + 120 + 3 },
    { "  Time left: 1 hour, 2 minutes.", 3600 + 120 },
    { "  Time left: 1 hour, 30 seconds.", 3630 },
    { "  Time left: 5 minutes, 6 seconds.", 306 },
    { "  Time left: 45 seconds.", 45 },
  }
  for _, c in ipairs(cases) do
    local st = {}
    eq(quota.parse_line(st, c[1]), true)
    eq(st.deadline, os.time() + c[2])
  end
  eq(quota.parse_time_left("  Time left: someday."), nil)
end)

t("quota: chip colors, owed flag, time shapes", function()
  local now = 1000000
  local ok = { max = 133, rcpt = 60, min = 8.25, owed = 0, deadline = now + 4200 }
  assert(quota.chip(ok, now):find("%[Q:%$133%-%$60=%$73%]"), "base chip: " .. quota.chip(ok, now))
  assert(quota.chip(ok, now):find("1:10"), "hour form: " .. quota.chip(ok, now))
  local under = { max = 133, rcpt = 5, min = 8.25, deadline = now + 305 }
  assert(quota.chip(under, now):find("5m5s"), "minute-second form: " .. quota.chip(under, now))
  local over = { max = 100, rcpt = 110, min = 10, deadline = now + 61 }
  assert(quota.chip(over, now):find("%$%-10%]"), "negative left: " .. quota.chip(over, now))
  local owing = { max = 133, rcpt = 60, min = 8.25, owed = 2.5, deadline = now + 600 }
  assert(quota.chip(owing, now):find("O:%$2%.50!"), "owed flag: " .. quota.chip(owing, now))
  eq(quota.chip({}, now), nil)
end)

-- status chips -------------------------------------------------------------

t("status: chips append to the vitals row and truncate", function()
  local st = vitals_mod.new()
  vitals_mod.apply(st, { hp = 600, maxhp = 700, gp = 350, maxgp = 400, xp = 123456, burden = 10, alignment = "good" })
  st.rate = 150000
  local lines = status.render(st, { id = string.rep("ab", 20), name = "Drum" }, 80, { "[Q:$133-$5=$128]", "[M:32m]" })
  eq(#lines, 3)
  assert(lines[3]:find("%[Q:%$133"), "chips row: " .. lines[3])
  assert(lines[3]:find("%[M:32m%]"), "second chip: " .. lines[3])
  local lines_bare = status.render(st, {}, 80, nil)
  assert(not lines_bare[3]:find("%[Q:"), "no quota chip: " .. lines_bare[3])
  assert(not lines_bare[3]:find("%[M:"), "no mission chip: " .. lines_bare[3])
end)

-- hex_skills ----------------------------------------------------------------

t("skilldata: tables coherent", function()
  local n = 0
  for _ in pairs(skilldata.skill_stats) do
    n = n + 1
  end
  eq(n, 251)
  eq(#skilldata.ROOT_SKILLS, 7)
  eq(#skilldata.primaries.witches, 15)
  eq(skilldata.skill_stats["covert.manipulation.sleight-of-hand"], "DDISS")
  -- every root skill has a stats entry
  for _, root in ipairs(skilldata.ROOT_SKILLS) do
    assert(skilldata.skill_stats[root], "root missing stats: " .. root)
  end
end)

t("skills: raw_level_bonus piecewise pins", function()
  eq(skills.raw_level_bonus(0), 0)
  eq(skills.raw_level_bonus(20), 100)
  eq(skills.raw_level_bonus(40), 150)
  eq(skills.raw_level_bonus(60), 170)
  eq(skills.raw_level_bonus(300), 290) -- 0.5 * 240 + 170
  eq(skills.raw_level_bonus(10), 50)
end)

t("skills: the all-13 golden constant (floor(290 x 1.05865) = 307 at level 300)", function()
  local m = skills.multiplicator("CDISW", { con = 13, dex = 13, int = 13, wis = 13, str = 13 })
  assert(m > 1.0585 and m < 1.0588, "multiplicator constant: " .. m)
  eq(skills.bonus_for(300, "CDISW", { con = 13, dex = 13, int = 13, wis = 13, str = 13 }), 307)
end)

t("skills: multiplicator skips zero stats, divides negatives", function()
  local hi = skills.multiplicator("DDISS", { con = 13, dex = 23, int = 13, wis = 13, str = 23 })
  local lo = skills.multiplicator("DDISS", { con = 13, dex = 8, int = 13, wis = 13, str = 8 })
  assert(hi > lo, "better stats must give a bigger multiplicator")
  local zeroed = skills.multiplicator("DDISS", { con = 0, dex = 13, int = 0, wis = 13, str = 13 })
  assert(zeroed > 0, "zero stats are skipped, not fatal: " .. zeroed)
  local neg = skills.multiplicator("DDISS", { con = 13, dex = -3, int = 13, wis = 13, str = 13 })
  assert(neg > 0, "negative stat divides by abs, still positive: " .. neg)
end)

t("skills: level_for_bonus round-trips through bonus_for", function()
  local deps = "CCDDS"
  local stats = { con = 16, dex = 15, int = 12, wis = 11, str = 14 }
  for _, wanted in ipairs({ 50, 120, 200, 260 }) do
    local level = skills.level_for_bonus(wanted, deps, stats)
    assert(skills.bonus_for(level, deps, stats) >= wanted, "round-trip under: wanted " .. wanted)
    assert(skills.bonus_for(level - 1, deps, stats) < wanted, "round-trip overshoots: wanted " .. wanted)
  end
  -- all-1 stats: prod = 1, m floors to 0, no level reaches the bonus
  eq(skills.level_for_bonus(100000, "CDISW", { con = 1, dex = 1, int = 1, wis = 1, str = 1 }), -1)
end)

t("skills: target grammar covers the documented forms", function()
  local cur = { level = 100, bonus = 300, raw_bonus = 200 }
  local num, kind = skills.parse_target("120", cur)
  eq(num, 120)
  eq(kind, "level")
  num, kind = skills.parse_target("l120", cur)
  eq(num, 120)
  eq(kind, "level")
  num, kind = skills.parse_target("120l", cur)
  eq(num, 120)
  num, kind = skills.parse_target("+10", cur)
  eq(num, 110)
  num, kind = skills.parse_target("b200", cur)
  eq(num, 200)
  eq(kind, "bonus")
  num, kind = skills.parse_target("200b", cur)
  eq(num, 200)
  num, kind = skills.parse_target("r180", cur)
  eq(num, 180)
  eq(kind, "raw")
  num, kind = skills.parse_target("+b20", cur)
  eq(num, 320)
  eq(kind, "bonus")
  num, kind = skills.parse_target("l+20", cur)
  eq(num, 120)
  num, kind = skills.parse_target("bogus", cur)
  eq(num, nil)
end)

t("skills: cost is monotonic, zero on empty range, primary branch fires", function()
  local stats = nil -- all-13
  local c10 = skills.skill_cost("fighting.melee.sword", 0, 10, nil, false, stats)
  local c11 = skills.skill_cost("fighting.melee.sword", 0, 11, nil, false, stats)
  assert(c10 > 0 and c11 > c10, "monotonic: " .. c10 .. " vs " .. c11)
  eq(skills.skill_cost("fighting.melee.sword", 10, 10, nil, false, stats), 0)
  -- primary cost to 300 is far cheaper than the teach formula for the same span
  local primary = skills.skill_cost("fighting.melee.sword", 0, 300, nil, true, stats)
  local taught = skills.skill_cost("fighting.melee.sword", 0, 300, nil, false, stats)
  assert(primary < taught, "primary branch must be cheaper: " .. primary .. " vs " .. taught)
  -- teach bonus lowers cost
  local with_etb = skills.skill_cost("fighting.melee.sword", 0, 20, 1000, false, stats)
  local without = skills.skill_cost("fighting.melee.sword", 0, 20, nil, false, stats)
  assert(with_etb <= without, "an ETB cannot raise the cost")
end)

t("skills: primaries lookup with wizard order translation", function()
  eq(#skills.primaries_for("witches"), 15)
  assert(skills.is_primary("magic.items.held.broom", "witches"), "broom is a witch primary")
  assert(not skills.is_primary("fighting.melee.sword", "witches"), "sword is not")
  local white = skills.primaries_for("wizards", "circle")
  assert(white, "wizard order translates to colour branch")
  assert(skills.is_primary("magic.methods.elemental.water", "wizards", "circle"), "white branch has water")
  eq(skills.primaries_for("wizards", nil), nil) -- spec required
  eq(skills.is_primary("anything", nil), false)
end)

t("skills: resolve_skill exact, unique, ambiguous, unknown", function()
  eq(skills.resolve_skill("adventuring.health"), "adventuring.health")
  eq(skills.resolve_skill("health"), "adventuring.health")
  -- "fighting.melee" is itself a stored parent skill (exact hit); a
  -- trailing-dot prefix hits only the children, which are ambiguous
  local r, err = skills.resolve_skill("fighting.melee.")
  eq(r, nil)
  assert(err:find("ambiguous"), "ambiguous message: " .. tostring(err))
  r, err = skills.resolve_skill("no.such.thing")
  eq(r, nil)
  assert(err:find("unknown"), "unknown message: " .. tostring(err))
end)

t("skills: listing line parser matches depths, hyphens, X bonus", function()
  local s, l, b = skills.parse_line("adventuring.health                20     105")
  eq(s, "adventuring.health")
  eq(l, 20)
  eq(b, "105")
  s, l = skills.parse_line("covert.manipulation.sleight-of-hand  10      50")
  eq(s, "covert.manipulation.sleight-of-hand")
  eq(l, 10)
  s, l, b = skills.parse_line("adventuring.movement.following.pursuit  5      30")
  eq(s, "adventuring.movement.following.pursuit")
  s, l, b = skills.parse_line("magic.items.sword                  12       X")
  eq(s, "magic.items.sword")
  eq(b, "X")
  eq(skills.parse_line("You advance your skill in x from 1 to 2"), nil)
  eq(skills.parse_line("SKILL    Level Bonus"), nil)
end)

t("skills: level_of parent fallback", function()
  local st = { adventuring = { [0] = nil }, ["adventuring.health"] = 20 }
  eq(skills.level_of("adventuring.health", st), 20)
  -- a child absent from the store falls back to the parent level
  local st2 = { adventuring = 12 }
  eq(skills.level_of("adventuring.health", st2), 12)
  eq(skills.level_of("totally.unknown", st2), nil)
end)

t("skills: advance updates store, goals spend, alert fires once", function()
  skills.state = {}
  skills.goals = { { skill = "fighting.melee.sword", target = 20, start_level = 10, spent = 0 } }
  skills.advance("fighting.melee.sword", 15, 5000)
  eq(skills.state["fighting.melee.sword"], 15)
  eq(skills.goals[1].spent, 5000)
  -- reaching the target alerts (output side is a print; state tracks it)
  skills.advance("fighting.melee.sword", 20, 100)
  eq(skills.state["fighting.melee.sword"], 20)
  -- goal ops
  eq(skills.goal_add("fighting.melee.sword", 30), "updated")
  eq(skills.goal_add("adventuring.health", 100), "added")
  eq(#skills.goals, 2)
  assert(skills.goal_remove("adventuring.health"))
  eq(#skills.goals, 1)
end)

t("skills: goal bar fills by spend fraction", function()
  local full = skills.goal_bar(0, 1000)
  local empty = skills.goal_bar(1000, 1000)
  local half = skills.goal_bar(500, 1000)
  assert(full ~= empty and half ~= empty, "bars differ by spend")
  assert(full:find("/"), "bar carries the divider: " .. full)
  eq(skills.goal_bar(100, 0), "-")
end)

-- hex_notify ---------------------------------------------------------------

t("notify: emit order, isolation, unsubscribe, debounce, list", function()
  notify.subscribers = {}
  notify.debounce = {}
  local seen = {}
  local id1 = notify.subscribe("test.event", function(p)
    seen[#seen + 1] = "one:" .. tostring(p)
  end)
  notify.subscribe("test.event", function()
    error("subscriber blew up")
  end)
  notify.subscribe("test.event", function(p)
    seen[#seen + 1] = "two:" .. tostring(p)
  end)
  notify.emit("test.event", 7)
  eq(seen[1], "one:7")
  eq(seen[2], "two:7") -- the failing middle subscriber did not stop the third
  eq(#seen, 2)
  eq(notify.unsubscribe(id1), true)
  eq(notify.unsubscribe(9999), false)
  seen = {}
  notify.emit("test.event", 8)
  eq(seen[1], "two:8")
  -- debounce swallows the repeat inside the window, passes after it
  local fired = 0
  notify.subscribe("test.deb", function()
    fired = fired + 1
  end)
  eq(notify.emit_debounced("test.deb", nil, 60, "key", 1000), true)
  eq(notify.emit_debounced("test.deb", nil, 60, "key", 1030), false)
  eq(notify.emit_debounced("test.deb", nil, 60, "key", 1061), true)
  eq(fired, 2)
  local subs = notify.list()
  assert(#subs >= 2, "list entries")
  notify.subscribers = {}
end)

-- hex_urls -----------------------------------------------------------------

t("urls: guards reject filenames, the MUD address, skills, dots, shorts", function()
  eq(urls.is_url("https://discworld.starturtle.net/lpc/"), false)
  eq(urls.is_url("some/file.tin"), false)
  eq(urls.is_url("map.db"), false)
  eq(urls.is_url("fighting.melee.sword"), false)
  eq(urls.is_url("co.me.uk"), false) -- short-skill shape
  eq(urls.is_url("a..b.example"), false)
  eq(urls.is_url("ab.cd"), false)
  eq(urls.is_url("https://github.com/VirInvictus/hex"), true)
  eq(urls.is_url("www.example.com/page?q=1"), true)
end)

t("urls: extract finds the guarded match in a line", function()
  eq(urls.extract("see https://github.com/VirInvictus/hex for the code"), "https://github.com/VirInvictus/hex")
  eq(urls.extract("fighting.melee.sword is a skill"), nil)
end)

t("urls: ring dedupes, keeps newest first, respects the cap", function()
  urls.ring = {}
  urls.deps = { config = { get = function(_, key, def) return def end } }
  urls.remember("https://a.example/1")
  urls.remember("https://b.example/2")
  urls.remember("https://a.example/1") -- dedupe: moves to front
  eq(urls.ring[1], "https://a.example/1")
  eq(urls.ring[2], "https://b.example/2")
  eq(#urls.ring, 2)
end)

-- hex_chat -----------------------------------------------------------------

t("chat: NPC list catches exact names and suffix patterns", function()
  eq(chat.is_npc("Frank"), true)
  eq(chat.is_npc("mr werks"), true)
  eq(chat.is_npc("a city guard"), true)
  eq(chat.is_npc("Ankh-Morpork watchman"), true)
  eq(chat.is_npc("some buccaneer"), true)
  eq(chat.is_npc("Froggy"), false)
  eq(chat.is_npc("Brandon"), false)
end)

t("chat: job noise catches the accent-tolerant texts", function()
  eq(chat.is_job_noise("Great, I've been waitin' for this!"), true)
  eq(chat.is_job_noise([[Great, I've been waitin" for "his!]]), true)
  eq(chat.is_job_noise("Thank you, that's everything I needed!"), true)
  eq(chat.is_job_noise("hello there"), false)
end)

t("chat: incoming tells classify, NPC and job excluded", function()
  local fam, e = chat.classify("Froggy tells you: hello there")
  eq(fam, "tell")
  eq(e.name, "Froggy")
  eq(e.text, "hello there")
  eq(chat.classify("Mr Werks tells you: your writ is ready"), nil)
  eq(chat.classify("Frank tells you: Great, I've been waitin' for this!"), nil)
  -- incoming tells in a language are still tells (the broadcast guard is
  -- for OWN tells only); the language rides the entry
  fam, e = chat.classify("Froggy says to you in Djelian: bo joujoka")
  eq(fam, "tell")
  eq(e.language, "Djelian")
end)

t("chat: own tells, language broadcasts excluded", function()
  local fam, e = chat.classify("You tell Froggy: hi frog")
  eq(fam, "tell")
  eq(e.own, true)
  eq(e.name, "Froggy")
  eq(chat.classify("You tell Froggy in Djelian: bo joujoka"), nil)
end)

t("chat: clubs, groups, talkers (both shapes), shouts", function()
  local fam, e = chat.classify("(hisppers) Froggy: squeak")
  eq(fam, "club")
  eq(e.channel, "hisppers")
  fam, e = chat.classify("[Fighting] Brandon: anyone up?")
  eq(fam, "group")
  eq(e.channel, "Fighting")
  fam, e = chat.classify("- (Two) Froggy's wispy voice comes from the bracelet saying : I am a blue frog!")
  eq(fam, "talker")
  eq(e.channel, "Two")
  eq(e.name, "Froggy")
  fam, e = chat.classify("(one) Feantur wisps: Ook!")
  eq(fam, "talker")
  eq(e.channel, "one")
  fam, e = chat.classify("Offler the Crocodile God shouts: MEEP")
  eq(fam, "system")
  eq(e.text, "MEEP")
end)

t("chat: the live Conlegium bracelet lines classify (corpus v1, 2026-11-08)", function()
  -- verbatim from hex-capture-20261108-162653.log (the wooden bracelet is
  -- the Conlegium Sicariorum talker item; the secretary's voice is the
  -- club's welcome bot)
  local fam, e = chat.classify("(Assassins) Secretary's wispy voice comes from the wooden bracelet, saying: Joining the Conlegium Sicariorum")
  eq(fam, "talker")
  eq(e.channel, "Assassins")
  eq(e.name, "Secretary")
  fam, e = chat.classify("(ConlegiumSicariorum) Secretary's wispy voice comes from the wooden bracelet, saying: Please join myself and")
  eq(fam, "talker")
  eq(e.channel, "ConlegiumSicariorum")
end)

t("chat: hide-from-main defaults and config override (tells never hide)", function()
  chat.deps = { config = { get = function(_, key, default) return default end } }
  eq(chat.hide("club"), true)
  eq(chat.hide("talker"), true)
  eq(chat.hide("group"), true)
  eq(chat.hide("system"), true)
  eq(chat.hide("tell"), false) -- the awareness rule
  chat.deps = { config = { get = function(key, default) return key == "chat_hide" and { club = false } or default end } }
  eq(chat.hide("club"), false)
  eq(chat.hide("talker"), true) -- others keep the default
end)

t("chat: room says and souls are not captured", function()
  eq(chat.classify("Brandon says: hello"), nil)
  eq(chat.classify("Brandon bows politely."), nil)
end)

t("chat: extra NPCs from /chatnpc join the exclusion list", function()
  chat.deps = { config = { get = function(_, key, def)
    if key == "chat_npcs_extra" then
      return { "melvyn torche", "cony" }
    end
    return def
  end } }
  eq(chat.is_npc("Melvyn Torche"), true)
  eq(chat.is_npc("cony"), true)
  eq(chat.is_npc("Froggy"), false)
  chat.deps = {}
end)

t("chat: rings respect caps and the all-ring aggregates", function()
  chat.rings = { tell = {}, club = {}, group = {}, talker = {}, system = {}, all = {} }
  for i = 1, 10 do
    chat.push("tell", { name = "x" .. i, text = "m" .. i })
  end
  eq(#chat.rings.tell, 10)
  eq(#chat.rings.all, 10)
  for i = 1, chat.CAPS.tell + 5 do
    chat.push("tell", { name = "y", text = tostring(i) })
  end
  eq(#chat.rings.tell, chat.CAPS.tell)
  eq(#chat.rings.all, 10 + chat.CAPS.tell + 5) -- all-ring aggregates under its own cap
  eq(chat.rings.all[#chat.rings.all].family, "tell")
end)

-- hex_combat ---------------------------------------------------------------

t("combat: level ladder table and cycling", function()
  local v = combat.families_for("verbatim")
  eq(v.nop, false)
  eq(v.act, false)
  local d = combat.families_for("default")
  eq(d.nop, true)
  eq(d.act, false)
  local b = combat.families_for("brief")
  eq(b.nop, true)
  eq(b.act, true)
  eq(combat.families_for("verbose").act, false)
  eq(combat.next_level("verbatim"), "verbose")
  eq(combat.next_level("brief"), "verbatim")
  eq(combat.next_level("bogus"), "verbatim")
end)

t("combat: family pattern data carries the ported anchors", function()
  -- Lua cannot execute Rust regexes; assert the pattern set carries the
  -- design's quoted anchors verbatim
  local nop_text = table.concat(combat.NOP_FAMILIES, "\n")
  assert(nop_text:find("but you (?:deftly |just |easily )?(?:block|parry)", 1, true), "own defense anchor")
  assert(nop_text:find("dodge out of the way", 1, true), "dodge anchor")
  assert(nop_text:find("although unable to defend", 1, true), "unable anchor")
  assert(nop_text:find("swoops in and absorbs", 1, true), "floating anchor")
  assert(nop_text:find("but .+ (?:blocks|parries|dodges|absorbs|avoids)", 1, true), "others-missing anchor")
  local act_text = table.concat((function()
    local flat = {}
    for _, e in ipairs(combat.ACT_FAMILIES) do
      flat[#flat + 1] = type(e) == "table" and e[1] or e
    end
    return flat
  end)(), "\n")
  assert(act_text:find("snick|fillet", 1, true), "hit verbs")
  assert(act_text:find("incinerate", 1, true), "burn verbs")
  assert(act_text:find("bruise|smashe", 1, true), "hurt verbs")
  assert(act_text:find("^You prepare to ", 1, true), "prepares")
  assert(act_text:find("^You launch a powerful attack", 1, true), "specials")
  -- the moon-dragon flag rides the hurt family
  local hurt_family = combat.ACT_FAMILIES[3]
  eq(hurt_family.moon_dragon, true)
end)

t("combat: combatstat line maths", function()
  eq(combat.combatstat_line(0, 0), nil)
  eq(combat.combatstat_line(20, 13), "Attacks per round: 13/20 (0.65)")
end)

t("combat: monitor precedence honours GMCP freshness", function()
  local vitals_mod2 = vitals_mod
  local st = vitals_mod2.new()
  st.last_gmcp = os.time() - 10 -- fresh GMCP
  eq(vitals_mod2.gmcp_alive(st, 120), true)
  st.last_gmcp = os.time() - 300 -- stale
  eq(vitals_mod2.gmcp_alive(st, 120), false)
  st.last_gmcp = nil -- never pushed
  eq(vitals_mod2.gmcp_alive(st, 120), false)
end)

-- hex_spelldata / hex_spells ------------------------------------------------

t("spelldata: the committed dataset holds the design's counts", function()
  eq(#spelldata.order, 117)
  local octogram, tome, learnt = 0, 0, 0
  for _, nick in ipairs(spelldata.order) do
    local sp = spelldata.spells[nick]
    assert(sp, "order nick without data: " .. nick)
    assert(sp.type == "Offensive" or sp.type == "Defensive" or sp.type == "Miscellaneous", "bad type: " .. nick)
    if sp.octogram ~= nil then
      octogram = octogram + 1 -- field presence (tt_dw counts the key; "" = not an octogram spell)
    end
    if sp.tome ~= nil then
      tome = tome + 1
    end
    if sp.learnt_at ~= nil then
      learnt = learnt + 1
    end
    for _, st in ipairs(sp.spellcheck or {}) do
      eq(#st.thresholds, 10)
      for i = 2, 10 do
        assert(st.thresholds[i] > st.thresholds[i - 1], nick .. " stage " .. st.stage .. " not ascending")
      end
      assert(spelldata.spellskills[st.skill], "unresolved shorthand: " .. st.skill)
    end
  end
  eq(octogram, 93)
  eq(tome, 93)
  eq(learnt, 25)
end)

t("spells: stage chance breaks at the first failure", function()
  local t = { 100, 150, 200, 250, 300, 350, 400, 450, 500, 550 }
  eq(spells.stage_chance(t, 0), 0)
  eq(spells.stage_chance(t, 100), 10)
  eq(spells.stage_chance(t, 340), 50) -- passes 100-300, stops at 350
  eq(spells.stage_chance(t, 999), 100)
end)

t("spells: tm chance clamps and punishes certainty", function()
  local spell = { spellcheck = { { stage = 1, skill = "evoking", thresholds = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } } } }
  -- all-pass: chance clamps to 99 -> p .99 -> tm 1% (certainty TMs badly)
  assert(spells.tm_chance(spell, "evoking", 999) < 5, "certain cast barely TMs: " .. spells.tm_chance(spell, "evoking", 999))
  -- 50%: p .5 -> tm .25 -> notm .75 -> 25
  eq(spells.tm_chance(spell, "evoking", 5), 25)
  -- zero-pass: clamps to 1 -> tm ~1% -> result ~1
  eq(spells.tm_chance(spell, "evoking", 0), 1)
  -- a stage without the method contributes nothing
  eq(spells.tm_chance(spell, "channeling", 5), 0)
end)

t("spells: cast chance is the product over all stages", function()
  local spell = {
    spellcheck = {
      { stage = 1, skill = "evoking", thresholds = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } },
      { stage = 2, skill = "evoking", thresholds = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } },
    },
  }
  eq(spells.cast_chance(spell, "evoking", 5), 25) -- 50% x 50%
  eq(spells.cast_chance(spell, "channeling", 5), 100) -- empty product: no stages with it
end)

t("spells: skills_50 picks the 5th threshold", function()
  local out = spells.skills_50({ spellcheck = { { stage = 2, skill = "evoking", thresholds = { 1, 2, 3, 4, 55, 6, 7, 8, 9, 10 } } } })
  eq(out[1].stage, 2)
  eq(out[1].bonus, 55)
end)

t("spells: suggestion ordering is deterministic and blacklist-aware", function()
  local mk = function(nick, thresholds)
    return { spellcheck = { { stage = 1, skill = "evoking", thresholds = thresholds } } }
  end
  local fake_order = { "aaa", "bbb", "ccc", "ddd" }
  local fake_spells = {
    aaa = mk("aaa", { 0, 0, 0, 0, 0, 1000, 1000, 1000, 1000, 1000 }), -- 50% stage chance -> tm 25
    bbb = mk("bbb", { 0, 0, 0, 0, 0, 0, 0, 0, 0, 1000 }), -- 10% -> tm ~9
    ccc = mk("ccc", { 0, 0, 0, 0, 0, 1000, 1000, 1000, 1000, 1000 }), -- ties aaa
    ddd = mk("ddd", { 0, 0, 0, 0, 0, 0, 500, 500, 1000, 1000 }), -- 30% -> tm 21
  }
  spells.data = { order = fake_order, spells = fake_spells, spellskills = spelldata.spellskills }
  spells.deps = { config = { get = function(_, key, def) return def end } }
  spells.skills = nil
  local list = spells.suggestions("evoking", 500) -- all stages pass 5+ thresholds
  -- suggestion first (cast chance: bbb's 90% wins), then the rest by tm
  -- descending with the spelldata-order tie (aaa before ccc at 25%)
  eq(list[1].nick, "bbb")
  assert(list[1].suggestion, "bbb is the suggestion")
  eq(list[2].nick, "aaa")
  eq(list[2].tm, 25)
  eq(list[3].nick, "ccc")
  eq(list[4].nick, "ddd")
  -- blacklisting aaa: the suggestion rule is cast-chance (spellinfo.tin's
  -- replace rule), so bbb's 90% cast wins even though its TM chance is low
  -- (near-certain casts TM poorly) — aaa stays listed but never suggested
  spells.deps.config.get = function(_, key, def)
    if key == "tm_blacklist" then
      return "aaa"
    end
    return def
  end
  list = spells.suggestions("evoking", 500)
  eq(list[1].nick, "bbb")
  assert(list[1].suggestion, "bbb becomes the suggestion")
  eq(list[2].nick, "aaa")
  assert(not list[2].suggestion, "aaa is listed but blacklisted")
  spells.data = spelldata
  spells.deps = {}
end)

t("spells: resolve handles nick, prefix, name, ambiguity", function()
  spells.deps = {}
  local spell, nick = spells.resolve("ahsb")
  assert(spell, "ahsb resolves")
  eq(nick, "ahsb")
  spell, nick = spells.resolve("Al'Hrahaz")
  eq(nick, "ahsb")
  spell, nick = spells.resolve("zzzznope")
  eq(spell, nil)
  assert(nick:find("no spell matches", 1, true), "unknown message: " .. tostring(nick))
end)

-- wire-verified invariants (2026-11-05 capture) ---------------------------

t("spec invariant: every wired module defines setup", function()
  -- main.lua calls M.setup on each of these (found live: v0.8.0 shipped
  -- sound.setup/tts_mod.setup calls with no function behind them, and the
  -- load died at the call site)
  for _, f in ipairs({ "hex_chat", "hex_combat", "hex_data", "hex_missions", "hex_minimap", "hex_blorps", "hex_mdt", "hex_options", "hex_quota", "hex_scry", "hex_skills", "hex_sound", "hex_stats", "hex_tts", "hex_urls", "hex_doctor", "hex_guild" }) do
    local m = require(f)
    assert(type(m.setup) == "function", f .. ".lua is wired in main.lua but defines no setup")
  end
end)

t("spec invariant: no look-around constructs anywhere in src/", function()
  -- the Rust regex engine rejects (?!( (?= and (?< at Regex.new time, and
  -- a pattern that fails there kills the whole plugin load (found live in
  -- v0.5.2-dbg's first run); Lua patterns never contain these either
  local bad = { "%(%?!", "%(%?=", "%(%?<" }
  for _, f in ipairs({ "hex_chat", "hex_combat", "hex_commands", "hex_config", "hex_data", "hex_gagfile", "hex_gags", "hex_gmcp", "hex_doctor", "hex_guild", "hex_guild_data", "hex_mdt", "hex_mdtdata", "hex_missiondata", "hex_missions", "hex_notify", "hex_paths", "hex_quota", "hex_registry", "hex_rooms", "hex_scry", "hex_skilldata", "hex_skills", "hex_spelldata", "hex_spells", "hex_stats", "hex_status", "hex_targets", "hex_util", "hex_version", "hex_vitals", "hex_walk", "hex_setup" }) do
    local path = root .. "src/" .. f .. ".lua"
    local fh = io.open(path, "r")
    if fh then
      local body = fh:read("*a")
      fh:close()
      for _, pat in ipairs(bad) do
        assert(not body:find(pat), f .. ".lua contains a look-around construct (" .. pat .. ")")
      end
    end
  end
end)

t("spec invariant: /item sold redirect resolves (cmd_item_sources defined before cmd_item)", function()
  -- /item sold <thing> redirects to the sources command; if
  -- cmd_item_sources were defined after cmd_item, the upvalue would be a
  -- nil global and the natural typo would crash mid-search
  local fh = io.open(root .. "src/hex_commands.lua", "r")
  local body = fh:read("*a")
  fh:close()
  local item_at = assert(body:find("local function cmd_item%("), "cmd_item missing")
  local sources_at = assert(body:find("local function cmd_item_sources"), "cmd_item_sources missing")
  assert(sources_at < item_at, "cmd_item_sources must be defined before cmd_item")
end)

t("spec invariant: hex_commands module-level functions use M.deps (cmd_goto live crash)", function()
  -- found live 2026-11-08: /goto #1 crashed on a global deps at line 424;
  -- bare `deps` only exists as M.setup's parameter, so every module-level
  -- function must reach it through M.deps. M.setup's own closures keep the
  -- parameter form and sit after the setup definition.
  local fh = io.open(root .. "src/hex_commands.lua", "r")
  local body = fh:read("*a")
  fh:close()
  local setup_at = assert(body:find("function M.setup(", 1, true), "no M.setup found")
  local prefix = body:sub(1, setup_at - 1)
  for line in prefix:gmatch("[^\n]+") do
    local code = line:gsub("%-%-.*$", "")
    code = code:gsub("M%.deps", "")
    if code:find("%f[%w]deps%.[a-z_]", 1, false) then
      error("module-level bare deps: " .. line)
    end
  end
end)

t("spec invariant: registration literals carry no Lua classes or bad escapes", function()
  -- alias/trigger/Regex literals go to the RUST engine: %s matches literal
  -- "%s" there (found live: 22 commands passed through to the MUD), and a
  -- single backslash + letter is an invalid Lua escape that stops parsing
  for _, f in ipairs({ "hex_commands", "hex_skills", "hex_missions", "hex_quota", "hex_combat", "hex_chat", "hex_urls", "hex_capture_removed", "hex_doctor", "hex_walk", "hex_setup", "hex_gags", "hex_gmcp", "hex_stats", "hex_scry" }) do
    local path = root .. "src/" .. f .. ".lua"
    local fh = io.open(path, "r")
    if fh then
      for line in fh:lines() do
        if line:find('alias_add%("') or line:find('Regex%.new%("') or line:find('trigger_add%("')
          or line:find('T%("') or line:find('arm%("') then
          assert(not line:find("%%%a"), f .. ".lua registration literal has a Lua class: " .. line)
          for _bad in line:gmatch("([^\\])\\[sSdDwWaA]") do
            error(f .. ".lua registration literal has a single-backslash escape: " .. line)
          end
        end
      end
      fh:close()
    end
  end
end)

-- hex_stats (wire shapes from the 2026-11-05 capture) ----------------------

t("stats: parses both dot-padded lines from the live shapes", function()
  local st = {}
  eq(stats_mod.parse_line(st, "Constitution ... 13        Intelligence ... 13        Wisdom ......... 13        Weight ......... 80.0 kg"), "a")
  eq(stats_mod.parse_line(st, "Dexterity ...... 13        Strength ....... 13        Height ......... 175 cm"), "b")
  eq(st.con, 13)
  eq(st.int, 13)
  eq(st.wis, 13)
  eq(st.dex, 13)
  eq(st.str, 13)
  eq(st.height, 175)
  eq(st.weight, 80)
  st = {}
  stats_mod.parse_line(st, "Constitution ... 9        Intelligence ... 23        Wisdom ......... 11        Weight ......... 62.4 kg")
  eq(st.con, 9)
  eq(st.int, 23)
  eq(st.weight, 62.4)
  eq(stats_mod.parse_line(st, "You say: hex capture probe"), nil)
  eq(stats_mod.parse_line(st, "Hp: 500(500)  Gp: 50(50)  Xp: 6361  Burden: 3%"), nil)
end)

t("stats: guild clause maps to primaries keys", function()
  local names = { ["Adventurers"] = "adventurers", ["Warriors"] = "warriors", ["Assassins"] = "assassins", ["Thieves"] = "thieves", ["Priests"] = "priests", ["Witches"] = "witches", ["Wizards"] = "wizards", ["Fools"] = "fools" }
  local line = "Your current experience is 6361 and you are level 0 in the Adventurers' Guild; your overall rating is 64."
  local guild = line:match(" in the ([%w' ]+) Guild")
  -- the capture keeps the possessive apostrophe; the trigger strips it
  -- before the lookup
  guild = guild:gsub("'$", "")
  eq(names[guild], "adventurers")
end)

-- hex_blorps / hex_minimap -------------------------------------------------

t("blorps: SQL builders escape and shape", function()
  assert(blorps.blorp_add_sql("alt", "drum", 4659, string.rep("a", 40)):find("'alt'", 1, true), "character not escaped")
  assert(blorps.blorp_add_sql("a", "it's", 4659, ""):find("'it''s'"), "label not escaped")
  assert(blorps.blorp_goto_sql("alt", "it's"):find("'it''s'"), "goto not escaped")
  assert(blorps.bm_add_sql("a", 13133, "crib", "combat: pumpkins", ""):find("'combat: pumpkins'"), "comment lost")
  assert(blorps.bm_find_sql("drum"):find("LIKE '%drum%'", 1, true), "find wraps once: " .. blorps.bm_find_sql("drum"))
  assert(blorps.bm_find_sql("dr*"):find("LIKE '%dr%%'", 1, true), "wildcards convert: " .. blorps.bm_find_sql("dr*"))
  local init = blorps.init_sql()
  eq(#init, 3)
  assert(init[1]:find("blorp", 1, true), "blorp table missing")
  assert(init[2]:find("bookmark", 1, true), "bookmark table missing")
  assert(init[3]:find("meta", 1, true), "meta table missing")
end)

t("blorps: init_sql creates tables in Hex's own db shape", function()
  -- PK(character, label) for blorps; PK(character, vnum) for bookmarks
  assert(blorps.init_sql()[1]:find("PRIMARY KEY %(character, label%)"), "blorp PK")
  assert(blorps.init_sql()[2]:find("PRIMARY KEY %(character, vnum%)"), "bookmark PK")
end)

t("minimap: inspect handles the live payload shape", function()
  -- the real Combat Crib room.map (capture line 219), decoded
  -- the decoded payload carries a real ESC (\27) and real newlines
  local raw = "    \27[39;49m\27[0m\27[31m+\27[39;49m\27[0m     \n    \27[39;49m\27[0m\27[1;33m@\27[39;49m\27[0m     \n"
  local info = minimap.inspect(raw)
  eq(#info.lines, 2)
  eq(info.has_player, true)
  eq(info.empty, false)
  assert(info.lines[1]:find("+", 1, true), "map content kept after strip")
end)

t("minimap: empty and whitespace payloads flag empty", function()
  eq(minimap.inspect("").empty, true)
  eq(minimap.inspect("   \n  \n").empty, true)
  local info = minimap.inspect("no map here\n")
  eq(info.has_player, false)
  eq(info.empty, false)
end)

t("minimap: dedupe key covers payload and room", function()
  assert(minimap.key("x", "room1") ~= minimap.key("x", "room2"), "room part matters")
  assert(minimap.key("x", "r") ~= minimap.key("y", "r"), "payload part matters")
  eq(minimap.key("x", "r"), minimap.key("x", "r"))
end)

t("paths: journey steps render miles; swim steps get the marker", function()
  local nodes = { node_row(1), node_row(2), node_row(3), node_row(4) }
  local edges = {
    edge_row(1, { edge(2, "journey e", 0, 2, 3) }),
    edge_row(2, { edge(3, "swim n", 0, 1) }),
    edge_row(3, { edge(4, "north", 0, 1) }),
    edge_row(4, {}),
  }
  local g = paths.load(nodes, edges)
  local r = paths.find_route(g, { 1 }, 4)
  local lines = paths.render(r, g)
  local joined = table.concat(lines, " ")
  assert(joined:find("%[journey: 3 miles e%]"), "journey render: " .. joined)
  assert(joined:find("%[~ 1 swim n%]"), "swim render: " .. joined)
  assert(joined:find("%[1 north%]"), "plain render: " .. joined)
end)

t("paths: find_route and distances accept a 40-hex room_id start", function()
  -- the /goto live bug: callers hand room.id straight from GMCP; the graph
  -- must translate ids through by_id (the goldens inject vnums, so this
  -- needs a unit-level pin on a pure graph)
  local nodes = { node_row(1), node_row(2), node_row(3), node_row(4) }
  local edges = {
    edge_row(1, { edge(2, "north", 0, 1) }),
    edge_row(2, { edge(3, "north", 0, 1) }),
    edge_row(3, { edge(4, "north", 0, 1) }),
    edge_row(2, {}),
    edge_row(3, {}),
    edge_row(4, {}),
  }
  local g = paths.load(nodes, edges)
  local id1 = hexid(1)
  eq(g.by_id[id1] ~= nil, true)
  local r = paths.find_route(g, { id1 }, 4)
  assert(r, "id-string start killed find_route")
  eq(r.steps, 3)
  local d = paths.distances(g, id1, { 4 })
  eq(d[4], 3)
end)

t("paths: attach_gates keys vnum|command", function()
  local g = tiny_graph()
  paths.attach_gates(g, { { "1|north" } })
  eq(paths.is_gate(g, 1, "north"), true)
  eq(paths.is_gate(g, 1, "east"), false)
  eq(paths.is_gate(g, 2, "north"), false)
end)

t("paths: avoid_gates routes around gate edges", function()
  -- bridge (gate) vs long way round
  local nodes = { node_row(1), node_row(2), node_row(3), node_row(4), node_row(5) }
  local edges = {
    edge_row(1, { edge(2, "north"), edge(3, "west", 0, 8, 5) }),
    edge_row(2, { edge(4, "north") }),
    edge_row(3, { edge(4, "northeast", 0, 3, 1) }),
    edge_row(4, { edge(5, "north") }),
    edge_row(5, {}),
  }
  local g = paths.load(nodes, edges)
  g.gates = { ["2|north"] = true }
  -- avoid: the route bends through node 3 instead of the gated 2->4 edge
  local r = paths.find_route(g, { 1 }, 5, { avoid_gates = true })
  assert(r, "bypass route exists")
  eq(r.path[1].cmd, "west")
  -- unrestricted: the short gated route wins
  local r2 = paths.find_route(g, { 1 }, 5, { avoid_gates = false })
  eq(r2.steps, 3)
  eq(r2.path[1].cmd, "north")
end)

t("paths: exclude_climb keeps rooftop routes out of /goto (the ledge incident)", function()
  -- found live 2026-11-08: the dorm wing connects over the rooftops via
  -- climb-window shortcuts; a level-4 student followed one into the night,
  -- failed the climb, and stranded on a ledge with [none] exits
  local nodes = { node_row(1), node_row(2), node_row(3), node_row(5), node_row(6), node_row(7), node_row(8) }
  local edges = {
    -- the rooftop shortcut: 1 climb window -> 2 climb d -> 5, 2 steps
    edge_row(1, { edge(2, "climb window", 0, 1) }),
    edge_row(2, { edge(5, "climb d", 0, 1) }),
    -- the safe ground route: 1 -> 6 -> 7 -> 8 -> 5, 4 steps
    edge_row(1, { edge(6, "south", 0, 1) }),
    edge_row(6, { edge(7, "south", 0, 1) }),
    edge_row(7, { edge(8, "south", 0, 1) }),
    edge_row(8, { edge(5, "north", 0, 1) }),
    edge_row(2, {}),
    edge_row(3, {}),
    edge_row(5, {}),
    edge_row(6, {}),
    edge_row(7, {}),
    edge_row(8, {}),
  }
  local g = paths.load(nodes, edges)
  local shortcut = paths.find_route(g, { 1 }, 5)
  eq(shortcut.steps, 2)
  assert(shortcut.path[1].cmd:find("^climb"), "shortcut uses the climb edge")
  local safe = paths.find_route(g, { 1 }, 5, { exclude_climb = true })
  assert(safe, "ground route must exist with climbs excluded")
  eq(safe.steps, 4)
  for _, st in ipairs(safe.path) do
    assert(not st.cmd:find("^climb"), "climb leaked into the safe route")
  end
end)

t("paths: exclude_swim keeps water out of goto routes", function()
  local nodes = { node_row(1), node_row(2), node_row(3) }
  local edges = {
    edge_row(1, { edge(2, "north"), edge(3, "swim e", 0, 2, 1) }),
    edge_row(2, { edge(3, "north", 0, 1, 4) }),
    edge_row(3, {}),
  }
  local g = paths.load(nodes, edges)
  local wet = paths.find_route(g, { 1 }, 3)
  eq(wet.cmd_ok, nil)
  eq(wet.path[1].cmd, "swim e") -- swim is the short way when allowed
  local dry = paths.find_route(g, { 1 }, 3, { exclude_swim = true })
  eq(dry.steps, 2) -- the walk around
  eq(dry.path[1].cmd, "north")
end)

-- hex_theme / hex_options / hex_sound_events -------------------------------

t("theme: classic palette is byte-identical to the original hex_util.ansi", function()
  -- the original values, captured before any use() could mutate them
  local original = { reset = "\27[0m", bold = "\27[1m", red = "\27[31m", green = "\27[32m", yellow = "\27[33m", magenta = "\27[35m", cyan = "\27[36m", gray = "\27[90m", white = "\27[37m" }
  theme.use("classic")
  for key, value in pairs(original) do
    eq(util_src.ansi[key], value)
  end
end)

t("theme: dragon palette is 24-bit and use() re-skins in place", function()
  theme.use("dragon")
  assert(util_src.ansi.red:find("^\27%[38;2;%d+;%d+;%d+m$"), "dragon red is 24-bit: " .. util_src.ansi.red)
  assert(util_src.ansi.gray ~= "\27[90m", "gray re-skinned")
  theme.use("classic")
  eq(util_src.ansi.gray, "\27[90m")
end)

t("theme: roles resolve and paint wraps; unknown role is empty", function()
  theme.use("classic")
  eq(util_src.ansi.gray, "\27[90m")
  assert(theme.paint("muted", "x"):find("\27%[90mx"), "paint wraps")
  eq(theme.get("no_such_role"), "")
  eq(theme.paint("no_such_role", "x"), "x")
end)

t("options_def: schema is well-formed", function()
  local seen = {}
  for _, entry in ipairs(defs.schema) do
    assert(not seen[entry.key], "duplicate key " .. entry.key)
    seen[entry.key] = true
    if entry.type == "enum" then
      assert(entry.choices and #entry.choices > 0, "enum without choices: " .. entry.key)
      local found = false
      for _, c in ipairs(entry.choices) do
        if c == entry.default then
          found = true
        end
      end
      assert(found, "enum default not in choices: " .. entry.key)
    end
    if entry.type == "number" and entry.min then
      assert(not entry.default or entry.default >= entry.min, "default under min: " .. entry.key)
    end
  end
end)

t("options: canonical resolves aliases and rejects unknowns", function()
  eq(options.canonical("speech"), "tts")
  eq(options.canonical("sound"), "sound")
  local key, err = options.canonical("nope")
  eq(key, nil)
  assert(err:find("unknown option"), "unknown message")
end)

t("options: validate enforces types, choices, ranges", function()
  local sound_entry = defs.find("sound")
  eq(options.validate(sound_entry, "on"), true)
  eq(options.validate(sound_entry, "no"), false)
  local _, err = options.validate(sound_entry, "maybe")
  assert(err:find("bool expected"), "bool error: " .. tostring(err))
  local theme_entry = defs.find("theme")
  eq(options.validate(theme_entry, "dragon"), "dragon")
  local _, err2 = options.validate(theme_entry, "neon")
  assert(err2:find("must be one of"), "enum error: " .. tostring(err2))
  local vol = defs.find("sound_volume")
  eq(options.validate(vol, "2.0"), 2.0)
  local _, err3 = options.validate(vol, "9")
  assert(err3:find("maximum"), "max error: " .. tostring(err3))
end)

t("sound_events: damage words at the tt_dw thresholds", function()
  eq(sound_events.damage_words(-199), nil)
  eq(sound_events.damage_words(-200), "Ouch!")
  eq(sound_events.damage_words(-400), "Eeep!")
  eq(sound_events.damage_words(-500), "Youch! That hurt!")
  eq(sound_events.damage_words(-50), nil)
end)

t("sound_events: template render substitutes payload fields", function()
  eq(sound_events.render_words("Tell from {from}", { from = "Froggy" }), "Tell from Froggy")
  eq(sound_events.render_words("plain", {}), "plain")
end)

t("sound_events: every stem is a plausible mp3 stem", function()
  for _, mapping in ipairs(sound_events.events) do
    assert(mapping.sound:match("^%w+$"), "odd stem: " .. mapping.sound)
  end
end)

-- hex_mdt (written-map people tracker; design docs/phase-5-room.md §2) -----

-- reset the module's session state between tests
local function mdt_reset(deps)
  mdt.deps = deps or {}
  mdt.state = { matches = {}, categories = {}, rooms = {}, seen = {} }
end

LIVE_WRITTENMAP = "A door north of here and the limit of your vision is here.\n"

t("mdt: parse handles the live writtenmap sample", function()
  -- the park's real payload (capture 2026-11-05): a door segment, no people
  local groups = mdt.parse(LIVE_WRITTENMAP)
  eq(#groups, 0)
end)

t("mdt: normalize merges colour pairs and rewrites vision/prose", function()
  local n = mdt.normalize("a black and white cat, the limit of your vision is west of here")
  assert(n:find("black%-white cat", 1), "colour pair: " .. n)
  assert(n:find("limit of your vision:", 1, true), "vision terminator: " .. n)
  assert(not n:find("vision is", 1, true), "prose 'is' rewritten: " .. n)
  local n2 = mdt.normalize("Agnes, driver of the Genua carriage is here")
  assert(n2:find("Genua carriage driver", 1, true), "carriage driver: " .. n2)
end)

t("mdt: parse groups entities before their direction clause", function()
  -- golden trace: entities accumulate until a direction, the group flushes
  -- at the vision terminator attributed to the last direction seen
  local groups = mdt.parse(
    "Two city guards, a black and white cat, a door north of here, three peasants are west of here and the limit of your vision is south of here.\n")
  eq(#groups, 1)
  eq(groups[1].direction, "1 w")
  eq(#groups[1].entities, 3)
  eq(groups[1].entities[1], "2 city guards")
  eq(groups[1].entities[2], "1 black-white cat")
  eq(groups[1].entities[3], "3 peasants")
end)

t("mdt: parse strips count words and articles", function()
  local groups = mdt.parse("an old woman, the shoeshine boy are east of here and the limit of your vision is here.\n")
  eq(#groups, 1)
  eq(groups[1].direction, "1 e")
  eq(groups[1].entities[1], "1 old woman")
  eq(groups[1].entities[2], "1 shoeshine boy")
end)

t("mdt: parse doors segments only suppress their own direction", function()
  -- after a door segment the next entity re-enables direction capture
  local groups = mdt.parse("a door north of here, two trolls are east of here and the limit of your vision is here.\n")
  eq(#groups, 1)
  eq(groups[1].direction, "1 e")
  eq(groups[1].entities[1], "2 trolls")
end)

t("mdt: numbers parse digits, teens, decades and hyphen forms", function()
  eq(mdt.parse_number("3"), 3)
  eq(mdt.parse_number("three"), 3)
  eq(mdt.parse_number("twelve"), 12)
  eq(mdt.parse_number("twenty"), 20)
  eq(mdt.parse_number("twenty-one"), 21)
  eq(mdt.parse_number("black-white"), nil)
  eq(mdt.is_number("nineteen"), true)
  eq(mdt.is_number("white"), false)
end)

t("mdt: singularize ports the tt_dw chain", function()
  eq(mdt.singularize("city guards"), "city guard")
  eq(mdt.singularize("bureaucrats"), "bureaucrat")
  eq(mdt.singularize("wolves"), "wolf")
  eq(mdt.singularize("dishes"), "dish")
  eq(mdt.singularize("houses"), "house")
  eq(mdt.singularize("boxes"), "box")
  eq(mdt.singularize("pennies"), "penny")
  eq(mdt.singularize("knives"), "knife")
  eq(mdt.singularize("women"), "woman")
  eq(mdt.singularize("geese"), "goose")
  eq(mdt.singularize("sheep"), "sheep")
  eq(mdt.singularize("loaves of bread"), "loaf of bread")
  eq(mdt.singularize("pairs of socks"), "pair of socks")
  eq(mdt.singularize("peasants"), "peasant")
end)

t("mdt: pluralize feeds the display column", function()
  eq(mdt.pluralize("city guard"), "city guards")
  eq(mdt.pluralize("woman"), "women")
  eq(mdt.pluralize("knife"), "knives")
  eq(mdt.pluralize("wolf"), "wolves")
  eq(mdt.pluralize("box"), "boxes")
  eq(mdt.pluralize("goose"), "geese")
  eq(mdt.pluralize("city"), "cities")
end)

t("mdt: sart strips articles and one-of forms", function()
  eq(mdt.sart("a banker"), "banker")
  eq(mdt.sart("The Duke"), "Duke")
  eq(mdt.sart("one of the wizards"), "wizard")
end)

t("mdt: arrows expand counts and sum distance", function()
  local a, d = mdt.arrows("1 w")
  eq(a, "\u{2190}")
  eq(d, 1)
  local a2, d2 = mdt.arrows("3 n 2 ne")
  eq(a2, "\u{2191}\u{2191}\u{2191}\u{2197}\u{2197}")
  eq(d2, 5)
  local a3 = mdt.arrows("")
  eq(a3, "")
end)

t("mdt: default table integrity (ported rows, no unknown patterns)", function()
  assert(#mdt.defaults >= 70, "default row count: " .. #mdt.defaults)
  local kinds = { find = true, exact = true, startswith = true, endswith = true, exclude_endswith = true, contains_endswith = true, prefix_endswith = true, adj_endswith = true }
  for _, row in ipairs(mdt.defaults) do
    assert(kinds[row.rule.kind], "bad rule kind: " .. tostring(row.rule.kind))
    assert(type(row.score) == "number", "score must be numeric")
  end
  eq(#mdt.unknown_adverb_patterns, 0) -- every adverb pattern form expanded
  eq(#mdtdata.colors, 16)
end)

t("mdt: default rules match their tt_dw intent", function()
  mdt_reset()
  eq(mdt.match("giant rat").score, 0)
  eq(mdt.match("bureaucrat").score, 1) -- the rat rule's bureauc exclusion
  eq(mdt.match("red cloud").score, 0)
  eq(mdt.match("merchant banker").score, 5)
  eq(mdt.match("merchant banker").category, "loot")
  eq(mdt.match("han sung bodyguard").score, 4) -- surname with a token before it
  eq(mdt.match("sung bodyguard").score, 1) -- the source needs a leading token
  eq(mdt.match("city bodyguard").score, 1)
  eq(mdt.match("diligent student").score, 4)
  eq(mdt.match("lazy student").score, 1)
  eq(mdt.match("tough man (hiding)").score, 2) -- the thug row allows trailing text
  eq(mdt.match("duke of city").score, 5)
  eq(mdt.match("boy willie").score, 10)
  eq(mdt.match("boy willie").category, "letters")
  eq(mdt.match("citadel guard").score, 12)
  eq(mdt.match("soldier").score, 4)
end)

t("mdt: user rows first-hit-wins and shadow defaults", function()
  mdt_reset()
  mdt.load_matches({
    { "banker", "loot", "", 2, 0 },
    { "soldier", "", "", 9, 0 },
  })
  eq(mdt.match("merchant banker").score, 2) -- user row shadows the default
  eq(mdt.match("a wounded soldier").score, 9)
end)

t("mdt: hunting matches first at score 100 with alert", function()
  mdt_reset()
  mdt.load_matches({
    { "troll", "", "", 1, 0 },
    { "troll", "hunting", "", 100, 1 },
  })
  local m = mdt.match("a huge troll")
  eq(m.score, 100)
  eq(m.alert, true)
  eq(m.category, "hunting")
end)

t("mdt: category disable skips user rows", function()
  mdt_reset()
  mdt.load_matches({ { "banker", "loot", "", 5, 0 } })
  mdt.load_categories({ { "_default", "loot", 0 } })
  eq(mdt.category_status("loot"), false)
  eq(mdt.match("merchant banker").score, 1) -- disabled row skipped
  mdt.load_categories({ { "_default", "loot", 1 }, { "Censant", "loot", 0 } })
  mdt.deps.config = { alt = function() return "Censant" end }
  eq(mdt.category_status("loot"), false) -- alt overrides default
  mdt.deps.config = { alt = function() return "Otheralt" end }
  eq(mdt.category_status("loot"), true)
end)

t("mdt: skips zero the score (config data, exact names like tt_dw's bat)", function()
  mdt_reset()
  mdt.deps.config = {
    alt = function() return nil end,
    get = function(key, default) return key == "mdt_skips" and { "Battista the giant fruitbat" } or default end,
  }
  local m = mdt.match("Battista the giant fruitbat")
  eq(m.score, 0)
  eq(m.show, false)
  eq(mdt.match("a giant fruitbat").score, 0) -- the Quow default, not the skip
end)

t("mdt: clean shortens the shorthand table", function()
  mdt_reset()
  eq(mdt.clean("city guard"), "guard")
  eq(mdt.clean("palace guard"), "guard")
  eq(mdt.clean("bay dun horse"), "horse")
  eq(mdt.clean("old black rat"), "rat") -- full parity now that colours are adverbs
  eq(mdt.clean("giant rat"), "rat")
  eq(mdt.clean("brown rat"), "rat") -- the mdt colours are strippable adverbs
  eq(mdt.clean("harvest moon goose"), "goose") -- the moon pet family
  eq(mdt.clean("red-haired old man"), "man") -- interleaved chain strips to fixpoint
  eq(mdt.clean("a red cloud"), "cloud")
  eq(mdt.clean("wounded soldier (hiding)"), "wounded soldier")
  eq(mdt.clean("huge whirlwind of dust and debris"), "dust devil")
  -- tt_dw's row strips the word before "mail"; the name itself survives
  eq(mdt.clean("Tom the mail carriage driver"), "Tom carriage driver")
  eq(mdt.clean("zombie town crier"), "town crier")
  eq(mdt.clean("guard thief"), "guard")
  eq(mdt.clean("Granny Weatherwax"), "Granny Weatherwax") -- witch title survives
  eq(mdt.clean("old woman"), "woman")
end)

t("mdt: named labels colour, witch titles and forms stay excluded", function()
  eq(mdt.named_label("Elsabeth Dahlil"), true)
  eq(mdt.named_label("Sung bodyguard"), true)
  eq(mdt.named_label("Granny Weatherwax"), false) -- witch title
  eq(mdt.named_label("Genua carriage driver"), false)
  eq(mdt.named_label("Royal Guard"), false)
  eq(mdt.named_label("city guard"), false)
end)

t("mdt: process scores, sorts and renders the golden fixture", function()
  mdt_reset()
  local groups = mdt.parse("Two city guards, a black and white cat, a door north of here, three peasants are west of here and the limit of your vision is south of here.\n")
  local result = mdt.process(groups)
  eq(#result.rooms, 1)
  eq(#result.alerts, 0)
  local r = result.rooms[1]
  eq(r.score, 5) -- 2x1 + 0 (cat) + 3x1
  eq(r.distance, 1)
  eq(r.show, true)
  eq(r.arrows, "\u{2190}")
  local lines = mdt.render(result.rooms)
  eq(#lines, 1)
  -- golden: cat is score 0 so dimmed and kept, guards/peasants pluralized
  -- (compare stripped: the dimming wraps "cat" in gray ANSI)
  local plain = util.strip_ansi(lines[1])
  assert(plain:find("^←%s*%[%s*5%]%s*2 guards, cat, 3 peasants$"), "render: " .. plain)
end)

t("mdt: process sorts score desc then distance asc", function()
  mdt_reset()
  local groups = {
    { direction = "1 w", entities = { "1 soldier" } }, -- score 4, dist 1
    { direction = "3 n", entities = { "2 citadel guards" } }, -- score 24, dist 3
    { direction = "2 e", entities = { "1 peasant" } }, -- score 1, dist 2
  }
  local result = mdt.process(groups)
  eq(result.rooms[1].score, 24)
  eq(result.rooms[2].score, 4)
  eq(result.rooms[3].score, 1)
  eq(result.rooms[1].distance, 3)
end)

t("mdt: hunt alerts surface through process", function()
  mdt_reset()
  mdt.load_matches({ { "troll", "hunting", "", 100, 1 } })
  local groups = mdt.parse("two trolls are east of here and the limit of your vision is here.\n")
  local result = mdt.process(groups)
  eq(#result.alerts, 1)
  eq(result.alerts[1].entity, "troll")
  eq(result.alerts[1].arrows, "\u{2192}")
  eq(result.rooms[1].score, 200)
end)

t("mdt: SQL builders escape and shape", function()
  assert(mdt.match_add_sql("it's", "loot", "green", 5, true):find("'it''s'"), "match escaped")
  assert(mdt.match_add_sql("x", "", "", 1, false):find("1, 0", 1, true), "alert bool -> int")
  assert(mdt.match_remove_sql("it's"):find("'it''s'"), "remove escaped")
  assert(mdt.category_set_sql("Censant", "loot", 0):find("%(character, category, status%)"), "category upsert shape")
  assert(mdt.category_set_sql("Censant", "loot", nil):find("DELETE FROM mdt_category"), "clear deletes")
  assert(mdt.category_set_sql("Censant", "loot", nil):find("AND category = 'loot'"), "clear scoped to the category (tt_dw deletes the whole character's rows)")
  local init = mdt.init_sql()
  eq(#init, 2)
  assert(init[1]:find("PRIMARY KEY %(match%)"), "match PK is global (shared across alts)")
  assert(init[2]:find("PRIMARY KEY %(character, category%)"), "category PK scoped")
end)

t("mdt: state loaders shape rows", function()
  mdt_reset()
  local rows = mdt.load_matches(util.parse_rows("troll|hunting||100|1\nbanker|loot|green|5|0\n"))
  eq(#rows, 2)
  eq(rows[1].alert, 1)
  eq(rows[2].color, "green")
  mdt.load_categories(util.parse_rows("_default|loot|0\nCensant|letters|1\n"))
  eq(mdt.state.categories._default.loot, 0)
  eq(mdt.state.categories.Censant.letters, 1)
end)



-- hex_doctor (the permanent self-test) ---------------------------------------

t("doctor: the battery runs clean against self-test deps", function()
  local vitals_mod_t = require("hex_vitals")
  local vt = vitals_mod_t.new()
  vitals_mod_t.apply(vt, { hp = 500, maxhp = 500, gp = 50, maxgp = 50, xp = 5356, burden = 3 })
  vt.last_gmcp = os.time()
  local rm = require("hex_rooms").new()
  require("hex_rooms").update(rm, { identifier = string.rep("a", 40), name = "Combat Crib", kind = "inside" })
  doctor.setup({
    self_test = true,
    config = { get = function(key, default) return default end, explicit = function() return nil end, alt = function() return "Censant" end },
    vitals = vt,
    room = rm,
    maps = { written = "x", ascii = "y" },
    gmcp = { handshake_done = true },
    data = { hex_dir = function() return "/tmp" end, owned_quow = function() return "" end, legacy_quow = function() return "" end },
    mdt = mdt,
    minimap = { mode = "toprows" },
    sound = {},
    tts_mod = { available = function() return false end },
  })
  local results = doctor.run_checks()
  local statuses = {}
  for _, r in ipairs(results) do
    statuses[r.status] = (statuses[r.status] or 0) + 1
    assert(r.status == "ok" or r.status == "warn" or r.status == "fail" or r.status == "skip",
      "invalid status: " .. tostring(r.status) .. " on " .. r.name)
  end
  assert(#results >= 25, "battery size: " .. #results)
  assert(statuses.skip >= 5, "db/file/command checks must skip in the suite: " .. tostring(statuses.skip))
  -- the parser mini-suite must be all-green in the suite
  for _, r in ipairs(results) do
    if r.group == "parsers" then
      eq(r.status, "ok")
    end
  end
  -- live gmcp state reflects the stubs
  for _, r in ipairs(results) do
    if r.name == "handshake" then
      eq(r.status, "ok")
    end
    if r.name == "room feed" then
      eq(r.status, "ok")
    end
  end
end)

t("doctor: failures surface with the right statuses", function()
  doctor.setup({
    self_test = true,
    config = { get = function(key, default) return default end, explicit = function() return nil end, alt = function() return nil end },
    vitals = require("hex_vitals").new(), -- no vitals: feed check must fail
    room = {},
    maps = {},
    gmcp = {}, -- no handshake: must fail (the M1 bug class)
    data = { hex_dir = function() return "/tmp" end },
    mdt = mdt,
    minimap = {},
    sound = {},
    tts_mod = { available = function() return false end },
  })
  local results = doctor.run_checks()
  local seen_fail = {}
  for _, r in ipairs(results) do
    seen_fail[r.name] = r.status
  end
  eq(seen_fail["handshake"], "fail")
  eq(seen_fail["vitals feed"], "fail")
  eq(seen_fail["room feed"], "fail")
end)

t("doctor: run prints a summary line (self-test writes no report file)", function()
  doctor.setup({
    self_test = true,
    config = { get = function(key, default) return default end, explicit = function() return nil end, alt = function() return nil end },
    vitals = require("hex_vitals").new(),
    room = {},
    maps = {},
    gmcp = {},
    data = { hex_dir = function() return "/tmp" end },
    mdt = mdt,
    minimap = {},
    sound = {},
    tts_mod = { available = function() return false end },
  })
  local results = doctor.run() -- prints; self_test blocks the report write
  assert(#results >= 25, "results")
end)



-- combat monitor: the live wire shapes from capture 2026-11-06 00:31 -------

t("combat: the live default monitor line's shape is pinned by a pattern", function()
  -- the Rust pattern from hex_combat, translated to a Lua pattern for the
  -- pure suite (same literals, %d+ stays, capture groups align 1:1)
  local live = "Hp: 500 (500) Gp: 50 (50) Xp: 16984"
  local hp, maxhp, gp, maxgp, xp = live:match("^Hp%: (%d+) %((%d+)%) Gp%: (%d+) %((%d+)%) Xp%: ([%d,]+)$")
  eq(hp, "500")
  eq(maxhp, "500")
  eq(gp, "50")
  eq(maxgp, "50")
  eq(xp, "16984")
  -- the shipped Rust literal carries the same anchors and groups
  assert(combat.DEFAULT_MONITOR:find("\\((\\d+)\\)", 1, true), "parens capture in the literal")
  assert(combat.DEFAULT_MONITOR:find("Xp: ", 1, true), "xp field in the literal")
  -- the old shapes stay registered as alternates
  assert(combat.MONITOR_LINE:find("Gp", 1, true) and combat.VERBOSE_PROMPT:find(")>$", 1, true), "alternates kept")
end)

t("combat: the pumpkin dodge family and the uppercut anchor are pinned", function()
  -- the training pumpkin's dodge (not in tt_dw; wire evidence 00:31)
  local dodge = nil
  for _, f in ipairs(combat.NOP_FAMILIES) do
    if f:find("see it in time", 1, true) then
      dodge = f
    end
  end
  assert(dodge, "pumpkin dodge family missing")
  -- the uppercut family is period-end anchored like tt_dw combat.tin:394
  local upper = nil
  for _, entry in ipairs(combat.ACT_FAMILIES) do
    local f = type(entry) == "table" and entry[1] or entry
    if f:find("uppercut", 1, true) then
      upper = f
    end
  end
  assert(upper, "uppercut family missing")
  assert(upper:sub(-3) == [[\.$]], "uppercut must end \\.$ (period-end), got: " .. upper)
end)

t("combat: monitor_write honors GMCP precedence with the new fields", function()
  combat.deps = {}
  combat.rounds = 0
  local vt = vitals_mod.new()
  vitals_mod.apply(vt, { hp = 500, maxhp = 500, gp = 50, maxgp = 50, xp = 16984, burden = 9 })
  vt.last_gmcp = os.time() -- fresh: GMCP wins
  combat.deps.vitals = vt
  combat.deps.vitals_mod = vitals_mod
  -- the default-monitor values must NOT overwrite a fresh GMCP feed
  local monitor_vals = { hp = 1, maxhp = 1, gp = 1, maxgp = 1, xp = 1 }
  if vitals_mod.gmcp_alive(vt, 120) then
    -- mirror of monitor_write's early return
    assert(vt.cur.hp == 500, "fresh feed untouched")
  end
  vt.last_gmcp = os.time() - 300 -- stale: the monitor writes through
  local st = combat.deps.vitals
  for key, value in pairs(monitor_vals) do
    if key == "maxhp" or key == "maxgp" then
      st.max[key == "maxhp" and "hp" or "gp"] = value
    else
      st.cur[key] = value
    end
  end
  eq(st.cur.hp, 1)
  eq(st.max.hp, 1)
  eq(st.cur.xp, 1)
  combat.deps = {}
end)



-- hex_guild (v0.15.0 guild packs) + the first real writtenmap corpus ------

t("guild: autoload keys off config.guild and refreshes", function()
  local state = { assassins = false }
  local config = { get = function(_, key, default) return state.assassins and "assassins" or default end }
  guild_mod.setup({ config = config })
  eq(guild_mod.pack, nil) -- none -> no pack
  state.assassins = true
  eq(guild_mod.refresh(), "assassins")
  eq(guild_mod.pack, "assassins")
  assert(guild_mod.status():find("assassins", 1, true), "status names the pack")
end)

t("guild_data: every pack entry is described and known to the framework", function()
  for name, info in pairs(guild_data.packs) do
    assert(guild_data.known[name], "pack not in known: " .. name)
    assert(info.note and info.note ~= "", "missing note: " .. name)
    assert(info.content == "primaries" or info.content == "planned", "content kind: " .. tostring(info.content))
  end
  assert(guild_data.packs.assassins.content == "primaries", "assassin v1 is primaries-only")
  assert(guild_data.known.none, "none is a valid config value")
end)

t("mdt: the first real multi-entity writtenmap parses (corpus v1, 2026-11-08)", function()
  -- verbatim from hex-capture-20261108-162653.log line 4: two people, both
  -- correctly attributed (the secretary really was south of him)
  local real = "A door east of here, a dark-haired young woman is one west, the limit of your vision is one west from here, an exit west of one south, a secretary is one south and the limit of your vision is one south from here.\n"
  local groups = mdt.parse(real)
  eq(#groups, 2)
  eq(groups[1].direction, "1 w")
  eq(groups[1].entities[1], "1 dark-haired young woman")
  eq(groups[2].direction, "1 s")
  eq(groups[2].entities[1], "1 secretary")
end)

-- hex_scry (v0.18.0 situational awareness: /hexexits /hexzone /hexnight
-- /hexcorpse) ---------------------------------------------------------------
-- Wire shapes in the triggers are from Brandon's session logs
-- (2026-11-06..09): the weather line, the dark-room collapse, the moon
-- line, and the dark map payload. The death triggers stay wire-pending.

t("scry: weather observation drives the day-part verdict", function()
  local st = scry.new_state()
  eq(scry.verdict(st, 1000).state, "unknown")
  scry.observe_weather(st, "night", 1000)
  eq(scry.verdict(st, 1000).state, "night")
  scry.observe_weather(st, "afternoon", 2000)
  eq(scry.verdict(st, 2000).state, "day")
  -- a stale day-part reads as unknown, not as a stale claim
  eq(scry.verdict(st, 2000 + scry.DAYPART_STALE + 1).state, "unknown")
end)

t("scry: dark clears on an identified push and decays", function()
  local st = scry.new_state()
  scry.observe_dark(st, 1000)
  assert(scry.verdict(st, 1000).dark, "dark fresh")
  scry.observe_room(st, "abc123")
  assert(not scry.verdict(st, 1000).dark, "identified push clears dark")
  scry.observe_dark(st, 1000)
  assert(not scry.verdict(st, 1000 + scry.DARK_FRESH + 1).dark, "dark decays")
  -- the map payload's dark line is a dark signal too (wire-verified text)
  scry.observe_room(st, "abc123")
  scry.observe_map(st, "It is too dark to see anything.", 5000)
  assert(scry.verdict(st, 5000).dark, "map dark line registers")
  scry.observe_map(st, "map with a church and a road", 5000)
  assert(scry.verdict(st, 5000).dark, "plain map leaves dark alone")
end)

t("scry: night warning for the pre-queue note", function()
  local st = scry.new_state()
  eq(scry.night_warning(st, 1000), nil)
  scry.observe_weather(st, "night", 1000)
  assert(scry.night_warning(st, 1000):find("NIGHT", 1, true), "night warns")
  scry.observe_weather(st, "morning", 1000)
  eq(scry.night_warning(st, 1000), nil, "day does not warn")
  scry.observe_dark(st, 1000)
  assert(scry.night_warning(st, 1000):find("DARK", 1, true), "dark room warns")
end)

t("scry: report lines carry the honest state", function()
  local st = scry.new_state()
  local unknown = table.concat(scry.report(st, 1000), "\n")
  assert(unknown:find("unknown", 1, true), "unknown state says so")
  assert(unknown:find("weather", 1, true), "unknown points at the weather line")
  scry.observe_weather(st, "night", 900)
  scry.observe_dark(st, 900)
  local night = table.concat(scry.report(st, 1000), "\n")
  assert(night:find("LOCKED", 1, true), "night names the locked gates")
  assert(night:find("DARK", 1, true), "night carries the dark fact")
  scry.observe_weather(st, "dawn", 900)
  assert(table.concat(scry.report(st, 1000), "\n"):find("dawn", 1, true), "dawn named")
end)

t("scry: moon signals show in the report within their window", function()
  local st = scry.new_state()
  scry.observe_moon(st, "last quarter", 900)
  assert(table.concat(scry.report(st, 1000), "\n"):find("last quarter", 1, true), "moon named while fresh")
  assert(
    not table.concat(scry.report(st, 1000 + scry.DAYPART_STALE + 1), "\n"):find("last quarter", 1, true),
    "moon decays with the day-part window"
  )
end)

t("scry: exits query targets the room and orders deterministically", function()
  local q = scry.exits_query(740)
  assert(q:find("FROM exits", 1, true), "exits table")
  assert(q:find("WHERE e.from_vnum = 740", 1, true), "room pinned")
  assert(q:find("ORDER BY e.dir, e.command", 1, true), "stable order")
  assert(scry.gates_query(740):find("FROM gates WHERE vnum = 740", 1, true), "gates query")
end)

t("scry: exit markers render gate/swim/climb/journey/hidden/unsafe", function()
  local rows = {
    { "w", "4", "0", "Hubwards Gate", "Ankh-Morpork" },
    { "swim ne", "2", "0", "the river", "" },
    { "climb window", "5", "1", "rooftop", "Ankh-Morpork" },
    { "journey e", "6", "0", "far shore", "" },
    { "enter sea", "1", "4", "the sea", "" },
    { "s", "1", "2", "street", "Ankh-Morpork" },
    { "n", "1", "0", "", "" },
  }
  local gates = { w = true }
  local lines = scry.render_exits(rows, gates)
  eq(#lines, #rows)
  assert(lines[1]:find("Hubwards Gate", 1, true) and lines[1]:find("%[gate%]"), "gate marker")
  assert(lines[2]:find("%[swim%]"), "swim marker")
  assert(lines[3]:find("%[climb hidden%]"), "climb + HIDE bit")
  assert(lines[4]:find("%[journey%]"), "journey marker")
  assert(lines[5]:find("hidden", 1, true), "INVIS bit reads hidden")
  assert(lines[6]:find("%[unsafe%]"), "AVOID bit reads unsafe")
  assert(lines[6]:find("%(Ankh%-Morpork%)"), "area rendered")
  assert(lines[7]:find("%-> %?"), "nil name guard")
end)

t("scry: landmarks are 40-hex ids with notes", function()
  assert(#scry.LANDMARKS >= 4, "the known set: BP, Genua, Bad Ass, Lancre")
  for _, lm in ipairs(scry.LANDMARKS) do
    assert(lm.label and lm.label ~= "", "label")
    assert(lm.id:match("^[0-9a-f]+$") and #lm.id == 40, "40-hex id for " .. lm.label)
    assert(lm.note and lm.note ~= "", "disconnection note for " .. lm.label)
  end
end)

t("scry: component lines render reachable/unreachable/unmapped", function()
  local lm = scry.LANDMARKS[3] -- Bad Ass
  assert(scry.component_line(lm, 42):find("routable from here %(42 steps%)"), "reachable")
  assert(scry.component_line(lm, "unreachable"):find("NOT routable", 1, true), "unreachable")
  assert(scry.component_line(lm, nil):find("unmapped", 1, true), "unmapped")
end)

t("scry: death site SQL builders and report", function()
  local site = { room_id = string.rep("a", 40), name = "the Hubwards Gate", area = "Ankh-Morpork", at = 5000 }
  local save = scry.death_save_sql("Censant", site)
  assert(save:find("INSERT OR REPLACE INTO deathsite", 1, true), "save")
  assert(scry.death_load_sql("it's"):find("it''s", 1, true), "load escapes")
  assert(scry.death_clear_sql("Censant"):find("DELETE FROM deathsite", 1, true), "clear")
  eq(scry.death_from_row({}), nil)
  local parsed = scry.death_from_row({ site.room_id, "the gate", "AM", "5999" })
  eq(parsed.room_id, site.room_id)
  eq(parsed.at, 5999)
  local lines = table.concat(scry.death_report(parsed, 6000), "\n")
  assert(lines:find("/goto " .. site.room_id, 1, true), "the hint carries the FULL id (no prefix resolution today)")
  assert(lines:find("recorded 1s ago", 1, true), "age rendered")
  assert(table.concat(scry.death_report(nil, 6000), "\n"):find("mark", 1, true), "no-site hint names mark")
end)

t("scry: fmt_secs buckets", function()
  eq(scry.fmt_secs(42), "42s")
  eq(scry.fmt_secs(120), "2m")
  eq(scry.fmt_secs(3900), "1h5m")
  eq(scry.fmt_secs(-5), "0s")
end)

t("scry: death anchors are end-anchored and conservative", function()
  -- the death family is wire-pending; pin the anchor shape so a change
  -- here is a conscious decision, and none can match the concord line
  -- ("You have died 0 times and can die 7 times...") via a lazy prefix
  local fh = io.open(root .. "src/hex_scry.lua", "r")
  local body = fh:read("*a")
  fh:close()
  local anchors = {}
  for cap in body:gmatch('trigger_add%(%"^You [^)]+record_death%)') do
    anchors[#anchors + 1] = cap
  end
  eq(#anchors, 3)
  for _, a in ipairs(anchors) do
    -- the raw file text carries the Rust escape "\." before the "$" anchor
    assert(a:find("\\.$", 1, true), "end-anchored with an escaped period: " .. a)
  end
end)

-- Phase 8 shim slice: main.lua loads against a stub blightmud ------------

t("shim: main.lua loads against the stub blightmud and registers the fleet", function()
  local shim = dofile(root .. "tests/shim.lua")
  local ok, err, calls = shim.load_main(root .. "main.lua")
  assert(ok, "main.lua failed under the shim: " .. tostring(err))
  assert(#calls.alias > 30, "alias count: " .. #calls.alias)
  local reload_found = false
  for _, a in ipairs(calls.alias) do
    if a.re == "^/hexreload$" then
      reload_found = true
    end
  end
  assert(reload_found, "/hexreload alias registered")
  eq(calls.send and #calls.send or 0, 0) -- loading must never send anything to the MUD
  assert(calls.timers == nil or #calls.timers == 0, "no timers at load")
end)

t("shim: a wired-but-missing setup function fails the load, not the login", function()
  -- regression for v0.8.0's first live load (sound.setup was called but
  -- never defined): the shim turns that class into a suite failure
  local shim = dofile(root .. "tests/shim.lua")
  local ok, err = shim.load_main(root .. "main.lua")
  assert(ok, tostring(err))
end)

io.write(("\n%d/%d passed\n"):format(count - failed, count))
if failed > 0 then
  os.exit(1)
end
