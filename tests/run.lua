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

t("setup: all groups send 8 documented commands", function()
  local cmds = setup_mod.commands("all")
  eq(#cmds, 8)
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
  eq(#setup_mod.commands("options"), 5)
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
  assert(ua:find("^hex/" .. version .. " update script"), "UA shape: " .. ua)
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

io.write(("\n%d/%d passed\n"):format(count - failed, count))
if failed > 0 then
  os.exit(1)
end
