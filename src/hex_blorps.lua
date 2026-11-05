-- hex_blorps.lua: blorps and bookmarks in Hex's own hex.db (design:
-- docs/phase-5-room.md §6; ported from tt_dw's blorps.tin/bookmarks.tin).
--
-- hex.db is REAL SQLite (not a JSON blob): user data must survive
-- convert_map.py rebuilds, which delete-and-recreate rooms.db. Writes go
-- through core.exec({"sqlite3", db, sql}) and only inside user-alias
-- handlers; reads are millisecond-scale indexed queries.
--
-- Deviation from tt_dw (noted per the design): blorps drop the hub-room
-- semantics and keep the user-visible ones — steps are plain Phase 2
-- distance, blorp_cost reserved.
--
-- Pure: SQL builders (asserted in tests like the query builders). Runtime
-- glue receives deps {config, room, targets, paths, vnum_of, get_graph}
-- from main.lua/commands at setup.
local util = require("src.hex_util")

local M = {}

M.deps = {}

function M.db()
  return (M.deps.config and M.deps.config.get("hex_db")) or ((os.getenv and os.getenv("HOME")) or "") .. "/.local/share/hex/hex.db"
end

-- --- pure SQL builders ---

function M.init_sql()
  return {
    "CREATE TABLE IF NOT EXISTS blorp (character TEXT NOT NULL, label TEXT NOT NULL, vnum INTEGER NOT NULL, room_id TEXT, PRIMARY KEY (character, label));",
    "CREATE TABLE IF NOT EXISTS bookmark (character TEXT NOT NULL, label TEXT NOT NULL, vnum INTEGER NOT NULL, comment TEXT, room_id TEXT, PRIMARY KEY (character, vnum));",
    "CREATE TABLE IF NOT EXISTS meta (alt TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY (alt, key));",
  }
end

function M.blorp_add_sql(character, label, vnum, room_id)
  return ("INSERT OR REPLACE INTO blorp (character, label, vnum, room_id) VALUES ('%s', '%s', %d, '%s');")
    :format(util.sql_escape(character), util.sql_escape(label), tonumber(vnum) or 0, util.sql_escape(room_id or ""))
end

function M.blorp_delete_sql(character, label)
  return ("DELETE FROM blorp WHERE character = '%s' AND label = '%s';")
    :format(util.sql_escape(character), util.sql_escape(label))
end

function M.blorp_rename_sql(character, old, new)
  return ("UPDATE blorp SET label = '%s' WHERE character = '%s' AND label = '%s';")
    :format(util.sql_escape(new), util.sql_escape(character), util.sql_escape(old))
end

function M.blorp_list_sql(character)
  return ("SELECT label || '|' || vnum FROM blorp WHERE character = '%s' ORDER BY label;"):
    format(util.sql_escape(character))
end

function M.blorp_all_sql()
  return "SELECT character || '|' || label || '|' || vnum FROM blorp ORDER BY character, label;"
end

function M.blorp_goto_sql(character, label)
  return ("SELECT label || '|' || vnum FROM blorp WHERE character = '%s' AND label = '%s';")
    :format(util.sql_escape(character), util.sql_escape(label))
end

function M.bm_add_sql(character, vnum, label, comment, room_id)
  return ("INSERT OR REPLACE INTO bookmark (character, vnum, label, comment, room_id) VALUES ('%s', %d, '%s', '%s', '%s');")
    :format(util.sql_escape(character), tonumber(vnum) or 0, util.sql_escape(label), util.sql_escape(comment or ""), util.sql_escape(room_id or ""))
end

function M.bm_comment_sql(character, vnum, comment)
  return ("UPDATE bookmark SET comment = '%s' WHERE character = '%s' AND vnum = %d;")
    :format(util.sql_escape(comment), util.sql_escape(character), tonumber(vnum) or 0)
end

function M.bm_rename_sql(character, vnum, label)
  return ("UPDATE bookmark SET label = '%s' WHERE character = '%s' AND vnum = %d;")
    :format(util.sql_escape(label), util.sql_escape(character), tonumber(vnum) or 0)
end

function M.bm_delete_sql(character, vnum)
  return ("DELETE FROM bookmark WHERE character = '%s' AND vnum = %d;")
    :format(util.sql_escape(character), tonumber(vnum) or 0)
end

function M.bm_list_sql()
  -- shared visibility: every alt's bookmarks, attribution inline
  return "SELECT character || '|' || label || '|' || vnum || '|' || comment FROM bookmark ORDER BY character, vnum;"
end

function M.bm_find_sql(text)
  -- substring semantics (wildcards * ? still convert); the format adds the
  -- % wraps, so the text itself must not arrive pre-wrapped
  local like = util.sql_escape(util.glob_wildcards(util.trim(text)))
  return ("SELECT character || '|' || label || '|' || vnum || '|' || comment FROM bookmark WHERE label LIKE '%%%s%%' OR comment LIKE '%%%s%%';")
    :format(like, like)
end

-- --- runtime glue ---

local function bold(t)
  return util.ansi.bold .. t .. util.ansi.reset
end

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

function M.setup(deps)
  M.deps = deps
  local db = M.db()
  for _, stmt in ipairs(M.init_sql()) do
    core.exec({ "sqlite3", db, stmt })
  end
end

local function sql(query)
  local r = core.exec({ "sqlite3", M.db(), query })
  if r:code() ~= 0 then
    print(util.ansi.red .. "[hex] sqlite error: " .. r:stderr() .. util.ansi.reset)
    return nil
  end
  return r:stdout()
end

local function character()
  local alt = M.deps.config and M.deps.config.alt()
  if not alt then
    print(gray("[hex] no alt known yet (connect first)"))
    return nil
  end
  return alt
end

local function need_start()
  local start = M.deps.room and M.deps.room.id
  if not start or not M.deps.targets.is_room_id(start) then
    print(gray("[hex] current room not identified; blorp/bookmark navigation needs a known start"))
    return nil
  end
  return start
end

-- goto via the Phase 2 pathfinder, showing the route (the actual queue is
-- the user's own /goto vnum, keeping one-shot walks single-invocation)
local function goto_vnum(vnum, label)
  local g = M.deps.get_graph()
  if not g then
    return
  end
  local start = need_start()
  if not start then
    return
  end
  if not g.idx[vnum] then
    print(gray("[hex] " .. label .. " is not in the routable graph"))
    return
  end
  local route = M.deps.paths.find_route(g, { start }, vnum)
  if not route then
    print(gray("[hex] no route to " .. label .. " (" .. vnum .. ")"))
    return
  end
  for _, l in ipairs(M.deps.paths.render(route, g, false)) do
    print(l)
  end
  print(gray("[hex] " .. route.steps .. " steps to " .. label .. "; /goto " .. vnum .. " queues it"))
end

-- distance-sorted listing via one multi-target Dijkstra
local function list_sorted(rows, start)
  local vnums, entries = {}, {}
  for _, f in ipairs(rows) do
    local vnum = tonumber(f[2])
    entries[#entries + 1] = { label = f[1], vnum = vnum }
    vnums[#vnums + 1] = vnum
  end
  local dists = M.deps.paths.distances(M.deps.get_graph(), start, vnums)
  for _, e in ipairs(entries) do
    e.dist = dists[e.vnum]
  end
  table.sort(entries, function(x, y)
    if x.dist and y.dist then
      return x.dist < y.dist
    end
    return x.dist ~= nil
  end)
  for _, e in ipairs(entries) do
    local d = e.dist and ("  " .. e.dist .. " steps") or "  unreachable"
    print(("  %-24s %8d%s"):format(e.label, e.vnum, gray(d)))
  end
end

function M.cmd_blorp(args)
  args = util.trim(args or "")
  local character = character()
  if not character then
    return
  end
  local action, rest = args:match("^(%S+)%s*(.*)$")
  action = action or "list"
  if action == "add" then
    local label = util.trim(rest)
    if label == "" then
      print(gray("usage: /blorp add <label>   labels the room you are standing in"))
      return
    end
    local room = M.deps.room
    if not room.id or not M.deps.targets.is_room_id(room.id) then
      print(gray("[hex] current room has no 40-hex identifier; cannot blorp here"))
      return
    end
    local vnum = M.deps.vnum_of(room.id)
    if not vnum then
      print(gray("[hex] identifier not in the map database; cannot blorp here"))
      return
    end
    sql(M.blorp_add_sql(character, label, vnum, room.id))
    print(gray("[hex] blorp " .. label .. " saved (vnum " .. vnum .. ")"))
  elseif action == "delete" then
    if util.trim(rest) == "" then
      print(gray("usage: /blorp delete <label>"))
      return
    end
    sql(M.blorp_delete_sql(character, util.trim(rest)))
    print(gray("[hex] blorp deleted: " .. util.trim(rest)))
  elseif action == "rename" then
    local old, new = rest:match("^(%S+)%s+(%S+)$")
    if not old then
      print(gray("usage: /blorp rename <old> <new>"))
      return
    end
    sql(M.blorp_rename_sql(character, old, new))
    print(gray("[hex] blorp renamed: " .. old .. " -> " .. new))
  elseif action == "all" then
    local rows = util.parse_rows(sql(M.blorp_all_sql()))
    print(bold("Blorps, all alts"))
    for _, f in ipairs(rows) do
      print(("  %-16s %-24s %8d"):format(f[1], f[2], tonumber(f[3]) or 0))
    end
  elseif action == "goto" then
    local out = sql(M.blorp_goto_sql(character, util.trim(rest)))
    local f = out and util.parse_rows(out)[1]
    if not f then
      print(gray("[hex] no blorp: " .. util.trim(rest)))
      return
    end
    goto_vnum(tonumber(f[2]), f[1])
  else
    local rows = util.parse_rows(sql(M.blorp_list_sql(character)))
    print(bold("Blorps") .. gray("  /blorp goto <label>; /blorp add <label> here; /blorp all"))
    local start = need_start()
    if start and #rows > 0 then
      list_sorted(rows, start)
    else
      for _, f in ipairs(rows) do
        print(("  %-24s %8d"):format(f[1], tonumber(f[2]) or 0))
      end
    end
  end
end

function M.cmd_bookmark(args)
  args = util.trim(args or "")
  local character = character()
  if not character then
    return
  end
  local action, rest = args:match("^(%S+)%s*(.*)$")
  action = action or "list"
  if action == "add" then
    local label, comment = rest:match("^(.-):%s*(.+)$")
    label = util.trim(label or rest)
    if label == "" then
      print(gray("usage: /bookmark add <label>[: comment]   labels the room you are standing in"))
      return
    end
    local room = M.deps.room
    if not room.id or not M.deps.targets.is_room_id(room.id) then
      print(gray("[hex] current room has no 40-hex identifier; cannot bookmark here"))
      return
    end
    local vnum = M.deps.vnum_of(room.id)
    if not vnum then
      print(gray("[hex] identifier not in the map database; cannot bookmark here"))
      return
    end
    sql(M.bm_add_sql(character, vnum, label, comment, room.id))
    print(gray("[hex] bookmark saved: " .. label .. " (vnum " .. vnum .. ")"))
  elseif action == "comment" then
    local vnum, comment = rest:match("^(%d+)%s+(.+)$")
    if not vnum then
      print(gray("usage: /bookmark comment <vnum> <comment>"))
      return
    end
    sql(M.bm_comment_sql(character, vnum, comment))
    print(gray("[hex] comment updated on vnum " .. vnum))
  elseif action == "rename" then
    local vnum, label = rest:match("^(%d+)%s+(.+)$")
    if not vnum then
      print(gray("usage: /bookmark rename <vnum> <label>"))
      return
    end
    sql(M.bm_rename_sql(character, vnum, util.trim(label)))
    print(gray("[hex] bookmark renamed: vnum " .. vnum .. " -> " .. util.trim(label)))
  elseif action == "delete" then
    local vnum = rest:match("^(%d+)$")
    if not vnum then
      print(gray("usage: /bookmark delete <vnum>"))
      return
    end
    sql(M.bm_delete_sql(character, vnum))
    print(gray("[hex] bookmark deleted: vnum " .. vnum))
  elseif action == "find" then
    if util.trim(rest) == "" then
      print(gray("usage: /bookmark find <text>"))
      return
    end
    local rows = util.parse_rows(sql(M.bm_find_sql(util.trim(rest))))
    print(bold("Bookmarks matching") .. gray("  " .. util.trim(rest)))
    for _, f in ipairs(rows) do
      print(("  [%s] %-24s %8d  %s"):format(f[1], f[2], tonumber(f[3]) or 0, f[4]))
    end
  elseif action == "goto" then
    local query = util.trim(rest)
    local rows = util.parse_rows(sql(M.bm_list_sql()))
    local chosen
    for _, f in ipairs(rows) do
      if f[2] == query or f[3] == query then
        chosen = f
        break
      end
    end
    if not chosen then
      print(gray("[hex] no bookmark: " .. query))
      return
    end
    goto_vnum(tonumber(chosen[3]), chosen[2] .. " [" .. chosen[1] .. "]")
  else
    local rows = util.parse_rows(sql(M.bm_list_sql()))
    print(bold("Bookmarks") .. gray("  shared across alts; [alt] attribution"))
    for _, f in ipairs(rows) do
      print(("  [%s] %-24s %8d  %s"):format(f[1], f[2], tonumber(f[3]) or 0, f[4]))
    end
  end
end

return M
