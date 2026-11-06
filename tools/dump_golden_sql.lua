-- tools/dump_golden_sql.lua: print each golden case's builder SQL as
-- "name<TAB>sql" lines (docs/phase-8-engineering.md §2). tools/regen_goldens.py
-- shells out to this so the Python side never re-implements the builders.
--
-- Usage: lua tools/dump_golden_sql.lua            (from the repo root)

package.path = "src/?.lua;" .. package.path
local queries = require("src.hex_queries")
local cases = dofile("tests/golden/cases.lua")

for _, case in ipairs(cases) do
  local sql
  if case.kind == "item" then
    sql = queries.build_item_query(case.input, case.exact)
  elseif case.kind == "npc" then
    sql = queries.build_npc_query(case.input)
  elseif case.kind == "shop" then
    sql = queries.build_shop_query(case.room_id)
  elseif case.kind == "sources" then
    sql = queries.build_item_sources_query(case.input, case.flag)
  elseif case.kind == "where" then
    sql = queries.build_where_query(case.room_id)
  elseif case.kind == "zone" then
    sql = queries.build_zone_query(case.room_id)
  else
    error("unknown case kind: " .. tostring(case.kind))
  end
  -- db tag: which database the case targets in production (regen_goldens.py
  -- routes the recorded layer by it; the synthetic layer has every table)
  local db = case.db or "quow"
  io.write(case.name, "\t", db, "\t", sql, "\n")
end
