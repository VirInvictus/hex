-- tests/golden/run_routes.lua: print each route-golden pair's rendered route
-- (docs/phase-8-engineering.md §2). tools/regen_goldens.py shells out to this
-- in the local ritual (the layer needs the real rooms.db) and diffs the
-- output byte-exact against tests/golden/routes/<name>.txt.
--
-- Usage: lua tests/golden/run_routes.lua [rooms_db]

package.path = "src/?.lua;" .. package.path
local util = require("src.hex_util")
local paths = require("src.hex_paths")

local db = arg and arg[1] or (os.getenv("HEX_ROOMS_DB") or (os.getenv("HOME") or "") .. "/.local/share/hex/rooms.db")

local function gold_sql(sql_text)
  local sq = "'" .. sql_text:gsub("'", "'\\''") .. "'"
  local f = io.popen("sqlite3 " .. db .. " " .. sq)
  local out = f:read("*a") or ""
  f:close()
  return out
end

local graph = paths.load(util.parse_rows(gold_sql(paths.NODE_QUERY)), util.parse_rows(gold_sql(paths.EDGE_QUERY)))
local script_dir = (arg and arg[0]:match("^(.*[/\\])")) or "./"
local routes = dofile(script_dir .. "routes.lua")

for _, pair in ipairs(routes) do
  io.write("=== ", pair.name, " ===\n")
  local route = paths.find_route(graph, { pair.from }, pair.to)
  if route then
    for _, line in ipairs(paths.render(route, graph, false)) do
      io.write(line, "\n")
    end
    io.write(route.steps, " steps\n")
  else
    io.write("no route\n")
  end
end
