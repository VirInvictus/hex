-- Hex unit suite for the pure modules. Zero dependencies: plain asserts,
-- run with the system Lua (5.4, same major version blightmud embeds).
-- Run from the repo root:  lua tests/run.lua

local root = (arg and arg[0] and arg[0]:match("^(.*)tests[/\\]run%.lua$")) or ""
if root == "" then
  root = "./"
end
package.path = root .. "src/?.lua;" .. package.path

local util = require("hex_util")
local vitals_mod = require("hex_vitals")
local queries = require("hex_queries")
local rooms_mod = require("hex_rooms")
local gags = require("hex_gags")
local status = require("hex_status")

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

io.write(("\n%d/%d passed\n"):format(count - failed, count))
if failed > 0 then
  os.exit(1)
end
