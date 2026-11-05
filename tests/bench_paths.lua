-- Benchmark harness for hex_paths against the real rooms.db (design:
-- docs/phase-2-mapper.md §6.6, keeping §0's measured numbers honest).
-- Standalone, opt-in:  lua tests/bench_paths.lua
-- Uses the sqlite3 CLI via io.popen, same as the golden tests.

local root = (arg and arg[0] and arg[0]:match("^(.*)tests[/\\]bench_paths%.lua$")) or ""
if root == "" then
  root = "./"
end
package.path = root .. "?.lua;" .. root .. "src/?.lua;" .. package.path

local util = require("hex_util")
local paths = require("hex_paths")

local db = os.getenv("HEX_ROOMS_DB") or (os.getenv("HOME") or "") .. "/.local/share/hex/rooms.db"

local function sql(q)
  local sq = "'" .. q:gsub("'", "'\\''") .. "'"
  local f = io.popen("sqlite3 " .. db .. " " .. sq)
  local out = f:read("*a") or ""
  f:close()
  return out
end

local t0 = os.clock()
local node_out = sql(paths.NODE_QUERY)
local edge_out = sql(paths.EDGE_QUERY)
local sql_ms = (os.clock() - t0) * 1000

t0 = os.clock()
local g = paths.load(util.parse_rows(node_out), util.parse_rows(edge_out))
if not g then
  io.write("graph load failed (build rooms.db first)\n")
  os.exit(1)
end
local build_ms = (os.clock() - t0) * 1000

io.write(("rooms: %d  edges: %d\n"):format(#g.vnum, g.edges))
io.write(("sqlite3 dumps: %.1f ms   lua parse+build: %.1f ms\n"):format(sql_ms, build_ms))

local routes = {
  { "AM job market -> BP palace gates", { 3424 }, 5898 },
  { "Drum bar -> BP palace gates", { 4659 }, 5898 },
  { "Drum bar -> Djel institute library", { 4659 }, 12472 },
  { "job market -> Genua (unreachable)", { 3424 }, 11279 },
}
for i, r in ipairs(routes) do
  t0 = os.clock()
  local route = paths.find_route(g, r[2], r[3])
  local ms = (os.clock() - t0) * 1000
  if route then
    io.write(("route %d: %-36s %4d steps  %6.1f ms\n"):format(i, r[1], route.steps, ms))
  else
    io.write(("route %d: %-36s unreachable  %6.1f ms\n"):format(i, r[1], ms))
  end
end

-- warm repeat: same query again (heap arrays and tables are fresh each call,
-- so this measures interpreter warmth, not caching)
t0 = os.clock()
paths.find_route(g, { 3424 }, 5898)
io.write(("warm repeat: %.1f ms\n"):format((os.clock() - t0) * 1000))

-- heap-size report for §0's claim: collect first so build garbage does not
-- inflate the number
collectgarbage("collect")
io.write(("heap after build+routes (collected): %.1f MB\n"):format(collectgarbage("count") / 1024))
