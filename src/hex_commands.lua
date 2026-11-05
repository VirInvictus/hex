-- hex_commands.lua: user-facing aliases and result rendering.
-- Spec invariant: every mud-bound action is behind a user alias; these
-- commands only read local databases and blightmud state, and never send
-- anything to the MUD.
local util = require("src.hex_util")
local queries = require("src.hex_queries")
local targets = require("src.hex_targets")
local paths = require("src.hex_paths")

local M = {}

local function a(name, text)
  return util.ansi[name] .. text .. util.ansi.reset
end

local function sql(db, query)
  local r = core.exec({ "sqlite3", db, query })
  if r:code() ~= 0 then
    print(a("red", "[hex] sqlite error: ") .. r:stderr())
    return nil
  end
  return r:stdout()
end

local function width()
  local w = blight.terminal_dimensions()
  return w or 80
end

local function rows(db, query)
  local out = sql(db, query)
  if not out then
    return nil
  end
  return util.parse_rows(out)
end

local function show_item_line(fields)
  -- every column is nil-guarded: Quow rows carry empty fields (cabbage has
  -- no weight), and a missing trailing field must not crash the command
  local name = fields[1] or "?"
  local value = fields[2] or "?"
  local description = fields[3] or ""
  local appraise = fields[4] or ""
  local weight = fields[5] or ""
  print(a("bold", util.trim(name)) .. a("gray", "  A$" .. value .. "  " .. weight))
  for _, line in ipairs(util.wrap(util.trim(description), width() - 2)) do
    print("  " .. a("gray", line))
  end
  if appraise ~= "" then
    for _, line in ipairs(util.wrap("appraise: " .. util.trim(appraise), width() - 2)) do
      print("  " .. a("gray", line))
    end
  end
end

local function cmd_item(args)
  local exact = false
  local search = args
  local head, rest = args:match("^(%S+)%s+(.+)$")
  if head == "exact" then
    exact = true
    search = rest
  end
  local result = rows(M.deps.config.get("quow_db"), queries.build_item_query(search, exact))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] no items match: " .. search))
    return
  end
  for _, fields in ipairs(result) do
    show_item_line(fields)
  end
end

local function cmd_item_sources(args)
  local flag = nil
  local search = args
  local head, rest = args:match("^(%S+)%s+(.+)$")
  if head == "sold" or head == "free" or head == "loot" then
    flag = head
    search = rest or ""
  end
  local result = rows(M.deps.config.get("quow_db"), queries.build_item_sources_query(search, flag))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] no sources found" .. (flag and (" (" .. flag .. ")") or "") .. ": " .. search))
    return
  end
  for _, fields in ipairs(result) do
    local kind = fields[1] or "?"
    local seller = fields[2] or ""
    local price = fields[3] or ""
    local room_short = fields[4] or ""
    local line = a("cyan", string.format("%-5s", kind)) .. a("bold", util.trim(seller ~= "" and seller or room_short))
    if price and price ~= "" then
      line = line .. a("gray", "  " .. price)
    end
    print(line)
  end
end

local function cmd_npc(args)
  local result = rows(M.deps.config.get("quow_db"), queries.build_npc_query(args))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] no npcs match: " .. args))
    return
  end
  for _, fields in ipairs(result) do
    local name = fields[1] or "?"
    local room_id = fields[2] or ""
    local room_short = fields[3] or ""
    print(a("bold", util.trim(name)) .. a("gray", "  " .. (room_short ~= "" and room_short or room_id)))
  end
end

local function cmd_shop(args)
  local room_id = util.trim(args)
  if room_id == "" then
    room_id = M.deps.room.id
  end
  if not room_id then
    print(a("red", "[hex] no room known yet; enter a room or pass an identifier"))
    return
  end
  local result = rows(M.deps.config.get("quow_db"), queries.build_shop_query(room_id))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] nothing listed for room " .. room_id))
    return
  end
  for _, fields in ipairs(result) do
    print(a("bold", util.trim(fields[1] or "?")) .. a("gray", "  " .. (fields[2] or "")))
  end
end

local function cmd_where()
  local room = M.deps.room
  if not room.id then
    print(a("gray", "[hex] no room info yet (GMCP not received?)"))
    return
  end
  print(a("bold", "room: ") .. (room.name or "?") .. a("gray", "  id " .. room.id))
  local detail = rows(M.deps.config.get("rooms_db"), queries.build_where_query(room.id))
  if detail and detail[1] then
    local name = detail[1][1] or "?"
    local area = detail[1][2] or ""
    local terrain = detail[1][3] or ""
    local note = detail[1][4] or ""
    print(a("gray", "map:  ") .. name .. (area ~= "" and a("cyan", "  " .. area) or "") .. (terrain ~= "" and a("gray", "  " .. terrain) or ""))
    if note and note ~= "" then
      print(a("gray", "note: ") .. note)
    end
  else
    print(a("gray", "map:  not in the Hex room database (identified rooms only)"))
  end
  local zone = rows(M.deps.config.get("quow_db"), queries.build_zone_query(room.id))
  if zone and zone[1] then
    print(a("gray", "quow: ") .. queries.zone_name(zone[1][1]))
  end
end

local function cmd_show_map(which)
  local text = which == "wmap" and M.deps.maps.written or M.deps.maps.ascii
  if not text or text == "" then
    print(a("gray", "[hex] no " .. (which == "wmap" and "written map" or "room map") .. " received yet"))
    return
  end
  -- room.map carries real ANSI; strip at render time by default (a stray
  -- unclosed colour fragment reads as broken output). The stored payload
  -- stays raw so Phase 5's panel can render the colours. /wmap is plain text.
  local strip = which == "dwmap" and M.deps.config.get("map_ansi", "strip") ~= "ansi"
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    print(strip and util.strip_ansi(line) or line)
  end
end

-- pathfinding: /path and /near (design: docs/phase-2-mapper.md §2-3). The
-- graph builds lazily on first use inside a user-invoked command (the spec's
-- millisecond rule constrains line-triggered work, not commands) and caches
-- in the session via deps.paths_cache.

local function row_to_cand(f)
  return { vnum = tonumber(f[1]), name = f[2] or "?", area = f[3] or "", room_id = f[4] or "" }
end

local function get_graph()
  local cache = M.deps.paths_cache
  if cache.graph then
    return cache.graph
  end
  local db = M.deps.config.get("rooms_db")
  local node_out = db and sql(db, paths.NODE_QUERY)
  local edge_out = node_out and sql(db, paths.EDGE_QUERY)
  if not edge_out then
    return nil
  end
  local t0 = os.clock()
  local g, err = paths.load(util.parse_rows(node_out), util.parse_rows(edge_out))
  if not g then
    print(a("red", "[hex] graph build failed: ") .. tostring(err))
    return nil
  end
  g.build_ms = (os.clock() - t0) * 1000
  cache.graph = g
  print(a("gray", ("[hex] route graph built: %d rooms, %d edges (%.0f ms)"):format(#g.vnum, g.edges, g.build_ms)))
  return g
end

local function need_start()
  local start = M.deps.room.id
  if not start or not targets.is_room_id(start) then
    print(a("gray", "[hex] current room not identified (GMCP room.info gave no identifier here); routing needs a known start"))
    return nil
  end
  return start
end

-- Run the resolution plan from hex_targets; returns a candidate list
-- (possibly empty) or nil + reason.
local function resolve_targets(input, g)
  local cache = M.deps.paths_cache
  local plan = targets.parse(input)
  if not plan then
    return nil, "nothing to search"
  end
  local db = M.deps.config.get("rooms_db")
  for _, step in ipairs(plan.steps) do
    if step.kind == "ref" then
      local c = cache.candidates and cache.candidates[step.n]
      if c then
        return { c }
      end
      return nil, "no candidate list yet (search first), or #" .. step.n .. " is out of range"
    elseif step.kind == "id" then
      local r = rows(db, targets.build_id_query(step.term))
      if r and r[1] then
        return { row_to_cand(r[1]) }
      end
    elseif step.kind == "origin" then
      local o = rows(db, targets.build_origin_query(step.area))
      if o and o[1] then
        local r = rows(db, targets.build_origin_room_query(o[1][2], o[1][1]))
        if r and r[1] then
          return { row_to_cand(r[1]) }
        end
      end
    elseif step.kind == "name" then
      local r = rows(db, targets.build_name_query(step.term, step.area))
      if r and #r > 0 then
        local cands = {}
        for _, f in ipairs(r) do
          cands[#cands + 1] = row_to_cand(f)
        end
        return cands
      end
    elseif step.kind == "vnum" then
      local r = rows(db, targets.build_vnum_query(step.n))
      if r and r[1] then
        local c = row_to_cand(r[1])
        if g.idx[c.vnum] then
          return { c }
        end
      end
    end
  end
  return {}
end

-- Reasons a resolved single target must not be routed (docs §5).
local function route_refusal(c)
  if c.room_id == targets.TSHOP_ID then
    return "the travelling shop moves around; there is no route to it"
  end
  if not targets.is_room_id(c.room_id) then
    return c.name .. " is a shared-instance room (" .. c.room_id .. "); Hex routes only 40-hex identified rooms"
  end
  return nil
end

local function cmd_path(args)
  local full = false
  local rest = args
  local f1 = rest:match("^%-%-full%s+(.+)$")
  local f2 = rest:match("^(.+)%s+%-%-full$")
  if f1 then
    full, rest = true, f1
  elseif f2 then
    full, rest = true, f2
  end
  if util.trim(rest) == "" then
    print(a("gray", "usage: /path [--full] <target>   target: name, id, @area, #n, vnum"))
    return
  end
  local start = need_start()
  if not start then
    return
  end
  local g = get_graph()
  if not g then
    return
  end
  local cands, err = resolve_targets(rest, g)
  if not cands then
    print(a("gray", "[hex] " .. err))
    return
  end
  if #cands == 0 then
    print(a("gray", "[hex] no rooms match: " .. rest))
    return
  end
  if #cands > 1 then
    M.deps.paths_cache.candidates = cands
    local vnums = {}
    for _, c in ipairs(cands) do
      vnums[#vnums + 1] = c.vnum
    end
    local dists = paths.distances(g, start, vnums)
    print(a("bold", #cands .. " matches") .. a("gray", "  (/path #<n> routes one)"))
    for i, c in ipairs(cands) do
      local d = dists[c.vnum]
      print((" %2d. %s (%s)%s"):format(i, c.name, c.area, d and a("gray", "  " .. d .. " steps") or a("gray", "  unreachable")))
    end
    return
  end
  local c = cands[1]
  local refusal = route_refusal(c)
  if refusal then
    print(a("gray", "[hex] " .. refusal))
    return
  end
  local route, rerr = paths.find_route(g, { start }, c.vnum)
  if not route then
    if rerr:find("avoid", 1, true) then
      print(a("gray", "[hex] " .. c.name .. ": " .. rerr))
    else
      local where = c.area ~= "" and c.area or "unknown area"
      print(a("gray", "[hex] no route to " .. c.name .. " (" .. where .. "): not connected in the identified map graph"))
    end
    return
  end
  for _, l in ipairs(paths.render(route, g, full)) do
    print(l)
  end
end

local function cmd_near(args)
  if util.trim(args) == "" then
    print(a("gray", "usage: /near <search>   nearest matches to your room by path length"))
    return
  end
  local start = need_start()
  if not start then
    return
  end
  local g = get_graph()
  if not g then
    return
  end
  local cands, err = resolve_targets(args, g)
  if not cands then
    print(a("gray", "[hex] " .. err))
    return
  end
  if #cands == 0 then
    print(a("gray", "[hex] no rooms match: " .. args))
    return
  end
  local filtered = {}
  for _, c in ipairs(cands) do
    if c.room_id ~= start then
      filtered[#filtered + 1] = c
    end
  end
  if #filtered == 0 then
    print(a("gray", "[hex] the only match is the room you are standing in"))
    return
  end
  local vnums = {}
  for _, c in ipairs(filtered) do
    vnums[#vnums + 1] = c.vnum
  end
  local dists = paths.distances(g, start, vnums)
  local ranked = {}
  for _, c in ipairs(filtered) do
    ranked[#ranked + 1] = { c = c, d = dists[c.vnum] }
  end
  table.sort(ranked, function(x, y)
    if x.d and y.d then
      return x.d < y.d
    end
    return x.d ~= nil
  end)
  print(a("bold", "nearest to " .. (M.deps.room.name or "you")))
  for i = 1, math.min(5, #ranked) do
    local r = ranked[i]
    print((" %2d. %s (%s)%s"):format(i, r.c.name, r.c.area, r.d and a("gray", "  " .. r.d .. " steps") or a("gray", "  unreachable")))
  end
end

local function cmd_gag_list()
  local gf = M.deps.gagfile
  print(
    a("bold", "Gags")
      .. a(
        "gray",
        "  built-ins: "
          .. #M.deps.gags.patterns
          .. ", user file: "
          .. #gf.state.entries
          .. "  ("
          .. tostring(gf.state.path)
          .. ")"
      )
  )
  for i, e in ipairs(gf.state.entries) do
    print(gf.render_entry(i, e))
  end
  print(a("gray", "add: /hexgag [-i] <pattern> [-> <substitution>]   remove: /hexungag <n|pattern-text>"))
end

local function cmd_gag_add(args)
  local gf = M.deps.gagfile
  local case_insensitive = false
  local rest = args
  if rest:match("^%-i%s+") then
    case_insensitive = true
    rest = rest:gsub("^%-i%s+", "", 1)
  end
  local pattern, sub = rest:match("^(.-)%s*->%s*(.+)$")
  if pattern then
    pattern = util.trim(pattern)
    sub = util.trim(sub)
  else
    pattern = util.trim(rest)
  end
  if pattern == "" then
    print(a("gray", "[hex] empty pattern"))
    return
  end
  if not pcall(regex.new, pattern) then
    print(a("red", "[hex] regex rejected") .. a("gray", " (the Rust engine has no lookaround/lookbehind)"))
    return
  end
  local entry = { re = pattern }
  if case_insensitive then
    entry.i = true
  end
  if sub then
    entry.sub = sub
  end
  local n, err = gf.add(entry)
  if not n then
    print(a("red", "[hex] gag not saved: ") .. tostring(err))
    return
  end
  print(a("gray", "[hex] gag added (user entry " .. n .. "); live now, saved to " .. tostring(gf.state.path)))
end

local function cmd_gag_remove(args)
  local gf = M.deps.gagfile
  local selector = tonumber(util.trim(args))
  if not selector then
    selector = util.trim(args)
  end
  local removed, err = gf.remove(selector)
  if not removed then
    print(a("red", "[hex] gag not removed: ") .. tostring(err))
    return
  end
  if removed == 0 then
    print(a("gray", "[hex] no user gag matches: " .. args))
    return
  end
  print(a("gray", "[hex] removed " .. removed .. " user gag(s); live now, saved to " .. tostring(gf.state.path)))
end

function M.setup(deps)
  M.deps = deps
  -- every alias goes through the registry so /hexreload can reap exactly
  -- what this load created
  local alias_add = function(re, cb)
    return deps.registry.record("alias", alias.add(re, cb))
  end

  alias_add("^/item\\s+(.+)$", function(matches)
    cmd_item(matches[2])
  end)
  alias_add("^/items\\s+(.+)$", function(matches)
    cmd_item_sources(matches[2])
  end)
  alias_add("^/npc\\s+(.+)$", function(matches)
    cmd_npc(matches[2])
  end)
  alias_add("^/shop\\s*(.*)$", function(matches)
    cmd_shop(matches[2])
  end)
  alias_add("^/where$", function()
    cmd_where()
  end)
  alias_add("^/path%s+(.+)$", function(matches)
    cmd_path(matches[2])
  end)
  alias_add("^/path$", function()
    cmd_path("")
  end)
  alias_add("^/near%s+(.+)$", function(matches)
    cmd_near(matches[2])
  end)
  alias_add("^/near$", function()
    cmd_near("")
  end)
  alias_add("^/wmap$", function()
    cmd_show_map("wmap")
  end)
  alias_add("^/dwmap$", function()
    cmd_show_map("dwmap")
  end)
  alias_add("^/hexprobe$", function()
    local on = deps.gmcp.probe()
    print(a("gray", "[hex] gmcp echo " .. (on and "ON" or "OFF")))
  end)
  alias_add("^/hexraw$", function()
    local recent = deps.gmcp.recent()
    if #recent == 0 then
      print(a("gray", "[hex] no raw GMCP received yet"))
      return
    end
    for _, line in ipairs(recent) do
      print(a("gray", line))
    end
  end)
  alias_add("^/hexreload$", function()
    deps.registry.reap()
    for key in pairs(package.loaded) do
      if key:find("hex_") then
        package.loaded[key] = nil
      end
    end
    script.load(blight.data_dir() .. "/plugins/hex/main.lua")
    print(a("gray", "[hex] reloaded"))
  end)
  deps.setup.register(alias_add)
  alias_add("^/hexupdate$", function()
    deps.data.update()
  end)
  alias_add("^/hexgag$", function()
    cmd_gag_list()
  end)
  alias_add("^/gaglog$", function()
    cmd_gag_list()
  end)
  alias_add("^/hexgag\\s+(.+)$", function(matches)
    cmd_gag_add(matches[2])
  end)
  alias_add("^/hexungag\\s+(.+)$", function(matches)
    cmd_gag_remove(matches[2])
  end)
  alias_add("^/hexset\\s+(\\S+)\\s+(.+)$", function(matches)
    local value = deps.config.set(matches[2], matches[3])
    print(a("gray", "[hex] " .. matches[2] .. " = " .. tostring(value)))
  end)
  alias_add("^/hexhelp$", function()
    print(a("bold", "Hex commands") .. a("gray", "  (data: Quow db + Hex rooms.db)"))
    print("  /item [exact] <search>   /items [sold|free|loot] <search>")
    print("  /npc <search>            /shop [room id]")
    print("  /where                   /wmap, /dwmap")
    print("  /path [--full] <target>  /near <search>  (route graph, identified rooms)")
    print("  /hexsetup [what]         game-side options (prompt, aliases, options)")
    print("  /hexupdate               Quow db + CC0 sounds into Hex's data dir")
    print("  /hexgag, /gaglog         user gags as data; /hexungag <n|text> removes")
    print("  /hexprobe (gmcp echo)    /hexraw (last raw gmcp)")
    print("  /hexreload               /hexset <key> <value>")
  end)
end

return M
