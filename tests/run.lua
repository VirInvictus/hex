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
  assert(curl:find("^curl %-fsSL %-A 'hex/0%.2%.0 update script %(https://github%.com/VirInvictus/hex%)' %-o '/h/quow%.db%.part'"), "curl form: " .. curl)
  assert(curl:find("quow%.co%.uk/maps/_quowmap_database%.db"), "quow URL missing")
  assert(curl:find(" && mv %-f '/h/quow%.db%.part' '/h/quow%.db'$"), "atomic mv missing: " .. curl)
  local wget = data.download_inner("wget", ua, "/h/quow.db.part", "/h/quow.db")
  assert(wget:find("^wget %-q %-U 'hex/0%.2%.0"), "wget form: " .. wget)
  local outer = data.download_outer(curl, "/h/quow-update.log")
  -- the inner's single quotes come back POSIX-escaped ('\''') inside the
  -- sh -c wrapper; assert shape, not a full equality
  assert(outer:find("^nohup sh %-c '.+' > '/h/quow%-update%.log' 2>&1 &$"), "outer form: " .. outer)
  assert(outer:find("mv -f", 1, true), "inner missing from outer: " .. outer)
end)

io.write(("\n%d/%d passed\n"):format(count - failed, count))
if failed > 0 then
  os.exit(1)
end
