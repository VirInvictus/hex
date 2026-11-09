-- hex_commands.lua: user-facing aliases and result rendering.
-- Spec invariant: every mud-bound action is behind a user alias; these
-- commands only read local databases and blightmud state, and never send
-- anything to the MUD.
local util = require("src.hex_util")
local queries = require("src.hex_queries")
local targets = require("src.hex_targets")
local paths = require("src.hex_paths")
local missiondata = require("src.hex_missiondata")
local skilldata = require("src.hex_skilldata")
local blorps = require("src.hex_blorps")

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

local function cmd_item(args)
  local exact = false
  local search = args
  local head, rest = args:match("^(%S+)%s+(.+)$")
  -- "/item sold <thing>" is the natural typo of "/items sold <thing>";
  -- redirect instead of searching for an item literally named "sold"
  if head == "sold" and rest and rest ~= "" then
    return cmd_item_sources(rest)
  end
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
  -- the sibling query answers the question this output always raises
  print(a("gray", "/items sold <thing> shows who sells it and where"))
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
local function resolve_targets(input, g, opts)
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
      -- /near drops the candidate cap: distance-sorting must see every
      -- match (the alphabetical 15 once hid AM's Job Market entirely)
      local r = rows(db, targets.build_name_query(step.term, step.area, opts and opts.all_matches))
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

-- Shared by /path and /goto: resolve a SINGLE routable target, printing the
-- outcome itself (multi-match candidate list, refusals, no-match). Returns
-- the candidate or nil. allow = /path any (route through avoid/water rooms).
local function resolve_single(args, g, start, allow)
  -- all matches, distance-ranked: the alphabetical cap once buried the real
  -- target ("foyer of the Assassins Guild" lost a 15-way lottery to three
  -- identical "foyer (Ankh-Morpork)" rows). Reachable sorts first.
  local cands, err = resolve_targets(args, g, { all_matches = true })
  if not cands then
    print(a("gray", "[hex] " .. err))
    return nil
  end
  if #cands == 0 then
    print(a("gray", "[hex] no rooms match: " .. args))
    return nil
  end
  if #cands > 1 then
    local vnums = {}
    for _, c in ipairs(cands) do
      vnums[#vnums + 1] = c.vnum
    end
    local dists = paths.distances(g, start, vnums, { allow_avoid = allow })
    table.sort(cands, function(x, y)
      local dx, dy = dists[x.vnum], dists[y.vnum]
      if dx and dy then
        return dx < dy
      end
      return dx ~= nil
    end)
    M.deps.paths_cache.candidates = cands
    print(a("bold", #cands .. " matches") .. a("gray", "  (/path #<n> or /goto #<n> routes one; nearest first)"))
    for i, c in ipairs(cands) do
      if i > 15 then
        print(a("gray", "  ... (" .. #cands - 15 .. " more, nearest first; /goto #<n> still routes any)"))
        break
      end
      local d = dists[c.vnum]
      print((" %2d. %s (%s)%s"):format(i, c.name, c.area, d and a("gray", "  " .. d .. " steps") or a("gray", "  unreachable")))
    end
    return nil
  end
  local c = cands[1]
  local refusal = route_refusal(c)
  if refusal then
    print(a("gray", "[hex] " .. refusal))
    return nil
  end
  return c
end

local function route_or_message(g, start, c, allow, exclude_swim, avoid_gates, exclude_climb)
  local route, rerr = paths.find_route(g, { start }, c.vnum, { allow_avoid = allow, exclude_swim = exclude_swim, avoid_gates = avoid_gates, exclude_climb = exclude_climb })
  if not route then
    if rerr:find("avoid", 1, true) then
      print(a("gray", "[hex] " .. c.name .. ": " .. rerr))
    else
      local where = c.area ~= "" and c.area or "unknown area"
      print(a("gray", "[hex] no route to " .. c.name .. " (" .. where .. "): not connected in the identified map graph"))
    end
    return nil
  end
  return route
end

local function cmd_path(args)
  local full = false
  local allow = false
  local rest = args
  local f1 = rest:match("^%-%-full%s+(.+)$")
  local f2 = rest:match("^(.+)%s+%-%-full$")
  if f1 then
    full, rest = true, f1
  elseif f2 then
    full, rest = true, f2
  end
  local any = rest:match("^any%s+(.+)$")
  if any then
    allow, rest = true, any
  end
  if util.trim(rest) == "" then
    print(a("gray", "usage: /path [--full] [any] <target>   target: name, id, @area, #n, vnum"))
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
  local c = resolve_single(rest, g, start, allow)
  if not c then
    return
  end
  local route = route_or_message(g, start, c, allow)
  if not route then
    return
  end
  for _, l in ipairs(paths.render(route, g, full)) do
    print(l)
  end
end

-- /goto: the ONE-SHOT batch speedwalk (docs/phase-2-mapper.md §4). One user
-- invocation sends the packed alias and its invocation; the MUD's own queue
-- runs the walk and `stop` (or /stopwalk) is the only abort. Hex never
-- sends anything again and never re-routes; room.info drives drift display.
local function cmd_goto(args)
  if util.trim(args) == "" then
    print(a("gray", "usage: /goto <target>   one-batch speedwalk; `stop` or /stopwalk aborts"))
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
  if M.deps.walk.active() then
    print(a("gray", "[hex] a walk is already running; `stop` in-game or /stopwalk first"))
    return
  end
  local c = resolve_single(args, g, start)
  if not c then
    return
  end
  local exclude_swim = not (M.deps.config.get("allow_swim", false) or (M.deps.room.terrain == "underwater"))
  -- climbs are opt-in: night + untrained + rooftops stranded the first player
  -- who trusted a route (v0.17.0); ground routes are longer but survivable
  local exclude_climb = not M.deps.config.get("allow_climb", false)
  local route = route_or_message(g, start, c, false, exclude_swim, M.deps.config.get("avoid_gates", false), exclude_climb)
  if not route then
    return
  end
  if route.steps == 0 then
    print(a("gray", "[hex] you are already at " .. c.name))
    return
  end
  for _, l in ipairs(paths.render(route, g, false)) do
    print(l)
  end
  -- the night facts before the queue, not after (the Hubwards Gate incident:
  -- a night walk queued fine and drained at the locked gate with "What?" spam)
  if M.deps.scry then
    local night_note = M.deps.scry.night_warning(M.deps.scry.state, os.time())
    if night_note then
      print(a("yellow", "[hex] warning: " .. night_note))
    end
  end
  print(a("gray", "sending as one batch (" .. route.steps .. " commands); `stop` or /stopwalk aborts once queued"))
  if M.deps.walk.should_warn(route) then
    print(a("yellow", "[hex] warning: this route is long; the MUD aborts queues that run past 5 minutes"))
  end
  M.deps.walk.launch(route, c.name)
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
  local cands, err = resolve_targets(args, g, { all_matches = true })
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

-- missions surface (design: docs/phase-3-character.md §5): /missions and
-- /quota never send; /apply, /dl and /quota refresh are user-alias sends.

local function cmd_missions(args)
  local ms = M.deps.missions
  local q = M.deps.quota
  local pending = args:match("^pending%s+(%S+)")
  if pending then
    pending = pending:upper()
    local short = ms.board_market(pending)
    if not short then
      local letter = pending:match("^DL([A-I])$")
      short = letter and ms.session.next_letter
    end
    if short then
      ms.session.market_apply = short
      print(a("gray", "[hex] pending fixup: next job-market writ completes " .. ms.label("market_" .. short)))
    else
      print(a("gray", "[hex] no board id " .. pending .. " on the current board (read the board first)"))
    end
    return
  end
  if util.trim(args) ~= "" then
    -- one mission: stats + resets (tt_dw /show_mission's display rules)
    local short = util.trim(args):lower():gsub("%s+", "_")
    local st = ms.state[short]
    if not st then
      print(a("gray", "[hex] no data for " .. args .. " yet; names look like market_dogwalker, letter_close_vague, plain_sausages"))
      return
    end
    local learned = short == "letter_difficult" and ms.learned or nil
    local xp = ms.xp_for(short, ms.count(short), learned)
    local tilde = short:find("_sausages$") or short == "letter_difficult" and "~" or ""
    print(a("bold", ms.label(short)) .. a("gray", tilde .. "  xp " .. xp .. "  rate " .. ms.rate_for(short, ms.state, learned) .. "/hr"))
    if st.resets and #st.resets > 0 then
      local now = os.time()
      local parts = {}
      for _, t in ipairs(st.resets) do
        if t > now then
          parts[#parts + 1] = ms.fmt_dur(t - now)
        end
      end
      print(a("gray", "resets in " .. (#parts > 0 and table.concat(parts, ", ") or "-")))
    end
    if st.est_time then
      print(a("gray", ("done %d times: est %s, avg %s, min %s, max %s"):format(st.total_count or 0, ms.fmt_dur(st.est_time), ms.fmt_dur(st.avg_time), ms.fmt_dur(st.min_time), ms.fmt_dur(st.max_time))))
    end
    return
  end
  -- the table: every mission sorted by the comparator
  local rows = {}
  for short, _ in pairs(missiondata.xp) do
    local learned = short == "letter_difficult" and ms.learned or nil
    local count = ms.count(short)
    local xp = ms.xp_for(short, count, learned)
    rows[#rows + 1] = {
      short = short,
      xp = xp,
      rate = ms.rate_for(short, ms.state, learned),
      count = count,
    }
  end
  table.sort(rows, ms.compare)
  print(a("bold", "Missions") .. a("gray", "  xp halves per pending reset; /missions <name> for details"))
  for _, r in ipairs(rows) do
    local pending = r.count > 0 and (" (" .. r.count .. ")") or ""
    local rate = r.rate > 0 and (util.comma(r.rate) .. "/hr") or "-"
    print(("  %-34s %12s xp  %14s%s"):format(ms.label(r.short), util.comma(r.xp), rate, a("gray", pending)))
  end
  local chip = ms.chip(ms.state, os.time())
  if chip then
    print(a("gray", "next reset " .. chip))
  end
end

local function cmd_apply(args)
  local ms = M.deps.missions
  local id = util.trim(args):upper()
  if not id:match("^[BMH][A-F]$") then
    print(a("gray", "usage: /apply <board id>   e.g. /apply MB (ids come from the job board)"))
    return
  end
  if M.deps.room.id ~= missiondata.JOB_MARKET_ID then
    print(a("gray", "[hex] not at the job market"))
    return
  end
  local short = ms.board_market(id)
  if not short then
    print(a("gray", "[hex] no job " .. id .. " on the current board; read the board first"))
    return
  end
  ms.session.market_apply = short
  mud.send("apply for " .. id)
end

local function cmd_dl(args)
  local ms = M.deps.missions
  local letter = util.trim(args):upper()
  if not letter:match("^[A-H]$") then
    print(a("gray", "usage: /dl <A-H>   (I, the difficult customer, is typed in full on purpose)"))
    return
  end
  if M.deps.room.id ~= missiondata.DEAD_LETTER_ID then
    print(a("gray", "[hex] not at the dead letter office (/goto dead letter office)"))
    return
  end
  if not ms.session.board.letters[letter] then
    print(a("gray", "[hex] pigeonhole " .. letter .. " has no letter waiting; check holes first"))
    return
  end
  ms.session.next_letter = ms.session.board.letters[letter]
  mud.send("offer to deliver DL" .. letter)
end

local function cmd_quota(args)
  local q = M.deps.quota
  if util.trim(args) == "refresh" then
    mud.send("check quota brief")
    print(a("gray", "[hex] sent: check quota brief"))
    return
  end
  local st = q.state
  if not st.max then
    print(a("gray", "[hex] no quota data yet; /quota refresh reads the licence (you can also run: check quota brief)"))
    return
  end
  print(a("bold", "Quota") .. q.chip(st, os.time()))
  local lines = {
    ("receipts %s / min %s / max %s"):format(q.fmt_num(st.rcpt or 0), q.fmt_num(st.min or 0), q.fmt_num(st.max)),
    ("owed %s / paid %s"):format(q.fmt_num(st.owed or 0), q.fmt_num(st.paid or 0)),
    ("resets in " .. q.fmt_remaining((st.deadline or os.time()) - os.time())),
  }
  for _, l in ipairs(lines) do
    print(a("gray", l))
  end
end

-- skills surface (design: docs/phase-3-character.md §3, §5): /skills
-- refresh is the sanctioned listing round-trip; the rest never send.

local function cmd_skills(args)
  local sk = M.deps.skills
  args = util.trim(args)
  if args == "refresh" then
    sk.refresh()
    return
  end
  local stats = sk.stats()
  if args == "" then
    local n = 0
    for _ in pairs(sk.state) do
      n = n + 1
    end
    print(
      a("bold", "Skills")
        .. a("gray", "  stored: " .. n .. "  /skills refresh to re-read (all-13 stats until the stats batch)")
    )
    local guild = M.deps.config.get("guild")
    local spec = M.deps.config.get("guildspec")
    if guild then
      local points = skilldata.GUILD_POINTS[guild] or "?.points"
      print(a("gray", "guild " .. guild .. (spec and ("/" .. spec) or "") .. "  points skill: " .. points .. " level " .. tostring(sk.level_of(points) or "?")))
    else
      print(a("gray", "guild unset: /hexset guild <wizards|witches|priests|thieves|assassins|warriors|fools|adventurers> enables primary-cost accuracy"))
    end
    return
  end
  -- search: prefix matches with level + bonus
  local found = {}
  for skill in pairs(skilldata.skill_stats) do
    if skill:find(args:lower(), 1, true) then
      found[#found + 1] = skill
    end
  end
  table.sort(found)
  if #found == 0 then
    print(a("gray", "[hex] no skills match: " .. args))
    return
  end
  for _, skill in ipairs(found) do
    local level = sk.level_of(skill)
    local deps = sk.deps_for(skill)
    local bonus = level and sk.bonus_for(level, deps, stats) or nil
    print(("  %-44s %s"):format(skill, a("gray", "level " .. tostring(level or "?") .. (bonus and ("  bonus " .. bonus) or ""))))
  end
end

local function cmd_bonus(args)
  local sk = M.deps.skills
  local skill_spec, target_spec = args:match("^(%S+)%s*(%S*)$")
  if not skill_spec then
    print(a("gray", "usage: /bonus <skill> [target]   targets: 120, l120, +10, b200, r180"))
    return
  end
  local skill, err = sk.resolve_skill(skill_spec)
  if not skill then
    print(a("gray", "[hex] " .. err))
    return
  end
  local stats = sk.stats()
  local level = sk.level_of(skill) or 0
  local deps = sk.deps_for(skill)
  local bonus = sk.bonus_for(level, deps, stats)
  print(a("bold", skill) .. a("gray", "  level " .. level .. "  bonus " .. bonus .. "  (deps " .. deps .. ", raw " .. sk.raw_level_bonus(level) .. ")"))
  if target_spec ~= "" then
    local num, kind = sk.parse_target(target_spec, { level = level, bonus = bonus, raw_bonus = sk.raw_level_bonus(level) })
    if not num then
      print(a("gray", "[hex] " .. kind))
      return
    end
    if kind ~= "level" then
      num = sk.level_for_bonus(num, deps, stats, kind == "raw")
      if num < 0 then
        print(a("gray", "[hex] that bonus is unreachable with your current stats"))
        return
      end
    end
    print(a("gray", "target level " .. num .. "  bonus " .. sk.bonus_for(num, deps, stats)))
  end
end

local function cmd_skillcost(args)
  local sk = M.deps.skills
  local etb = tonumber(args:match("etb%s+(%d+)"))
  args = args:gsub("etb%s+%d+", ""):gsub("%s+", " ")
  local skill_spec, target_spec = args:match("^(%S+)%s*(%S*)$")
  if not skill_spec then
    print(a("gray", "usage: /skillcost <skill|prefix> [target] [etb N]   targets like /bonus; * = primary"))
    return
  end
  local target_num, kind = 300, "level"
  if target_spec ~= "" then
    local level = 0
    target_num, kind = sk.parse_target(target_spec, { level = level, bonus = 0, raw_bonus = 0 })
    if not target_num then
      print(a("gray", "[hex] " .. kind))
      return
    end
  end
  -- prefix scope: exact one skill, or every known skill sharing the prefix
  local matches = {}
  for skill in pairs(skilldata.skill_stats) do
    if skill:find(skill_spec:lower(), 1, true) then
      matches[#matches + 1] = skill
    end
  end
  table.sort(matches)
  if #matches == 0 then
    print(a("gray", "[hex] unknown skill: " .. skill_spec))
    return
  end
  if #matches > 8 then
    print(a("gray", "[hex] " .. #matches .. " skills match '" .. skill_spec .. "'; narrow it (e.g. fighting.melee)"))
    return
  end
  local guild = M.deps.config.get("guild")
  local spec = M.deps.config.get("guildspec")
  local stats = sk.stats()
  print(a("bold", "Skill costs") .. a("gray", "  target " .. target_num .. " (" .. kind .. ")" .. (etb and ("  etb " .. etb) or "")))
  for _, skill in ipairs(matches) do
    local from = sk.level_of(skill) or 0
    local primary = sk.is_primary(skill, guild, spec)
    local to = kind == "level" and target_num or sk.level_for_bonus(target_num, sk.deps_for(skill), stats, kind == "raw")
    local cost = sk.skill_cost(skill, from, to, etb, primary, stats)
    local flag = primary and a("cyan", "*") or " "
    print((" %s %-43s %12s xp"):format(flag, skill, util.comma(cost)))
  end
  print(a("gray", "caveat: teach-cost numbers are tt_dw's approximation; the official ETB formula differs (documented in docs/phase-3-character.md)"))
  print(a("gray", "costs cap primary levels at 300 (the skillcap)" .. (guild == nil and "; set /hexset guild <name> for primary accuracy" or "")))
end

local function cmd_goals_list()
  local sk = M.deps.skills
  if #sk.goals == 0 then
    print(a("gray", "no goals; /goal add <skill> <target>"))
    return
  end
  print(a("bold", "Goals"))
  for _, goal in ipairs(sk.goals) do
    local left, total = sk.goal_xp_left(goal, M.deps.config.get("guild"), M.deps.config.get("guildspec"), sk.stats())
    print(("  %-40s %s  %s"):format(goal.skill .. " -> " .. goal.target, sk.goal_bar(left, total), a("gray", util.comma(left) .. " xp left")))
  end
end

local function cmd_goal(args)
  local sk = M.deps.skills
  local action, rest = args:match("^(%S+)%s*(.*)$")
  if action == "add" or action == "update" then
    local skill_spec, target_spec = rest:match("^(%S+)%s+(%S+)$")
    if not skill_spec then
      print(a("gray", "usage: /goal add <skill> <target>   target like 120, +10, b200"))
      return
    end
    local skill, err = sk.resolve_skill(skill_spec)
    if not skill then
      print(a("gray", "[hex] " .. err))
      return
    end
    local num, kind = sk.parse_target(target_spec, { level = sk.level_of(skill) or 0, bonus = 0, raw_bonus = 0 })
    if not num then
      print(a("gray", "[hex] " .. kind))
      return
    end
    if kind ~= "level" then
      num = sk.level_for_bonus(num, sk.deps_for(skill), sk.stats(), kind == "raw")
    end
    print(a("gray", "[hex] goal " .. sk.goal_add(skill, num) .. ": " .. skill .. " -> level " .. num))
  elseif action == "remove" then
    if sk.goal_remove(util.trim(rest)) then
      print(a("gray", "[hex] goal removed: " .. util.trim(rest)))
    else
      print(a("gray", "[hex] no goal for " .. util.trim(rest)))
    end
  else
    cmd_goals_list()
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
  alias_add("^/path\\s+(.+)$", function(matches)
    cmd_path(matches[2])
  end)
  alias_add("^/path$", function()
    cmd_path("")
  end)
  alias_add("^/near\\s+(.+)$", function(matches)
    cmd_near(matches[2])
  end)
  alias_add("^/near$", function()
    cmd_near("")
  end)
  alias_add("^/goto\\s+(.+)$", function(matches)
    cmd_goto(matches[2])
  end)
  alias_add("^/goto$", function()
    cmd_goto("")
  end)
  alias_add("^/stopwalk$", function()
    M.deps.walk.stop()
  end)
  alias_add("^/missions$", function()
    cmd_missions("")
  end)
  alias_add("^/missions\\s+(.+)$", function(matches)
    cmd_missions(matches[2])
  end)
  alias_add("^/apply\\s+(.+)$", function(matches)
    cmd_apply(matches[2])
  end)
  alias_add("^/dl\\s+(\\S+)$", function(matches)
    cmd_dl(matches[2])
  end)
  alias_add("^/quota$", function()
    cmd_quota("")
  end)
  alias_add("^/quota\\s+(\\S+)$", function(matches)
    cmd_quota(matches[2])
  end)
  alias_add("^/skills$", function()
    cmd_skills("")
  end)
  alias_add("^/skills\\s+(.+)$", function(matches)
    cmd_skills(matches[2])
  end)
  alias_add("^/bonus\\s+(.+)$", function(matches)
    cmd_bonus(matches[2])
  end)
  alias_add("^/skillcost\\s+(.+)$", function(matches)
    cmd_skillcost(matches[2])
  end)
  alias_add("^/goal\\s*(.*)$", function(matches)
    cmd_goal(matches[2])
  end)
  alias_add("^/goals$", function()
    cmd_goals_list()
  end)
  alias_add("^/stats\\s*(.*)$", function(matches)
    deps.stats.cmd_stats(matches[2])
  end)
  alias_add("^/hexoptions\\s*(.*)$", function(matches)
    deps.options.cmd(matches[2])
  end)
  alias_add("^/hexsay\\s+(.+)$", function(matches)
    deps.tts_mod.cmd_say(matches[2])
  end)
  alias_add("^/hexsound\\s*(.*)$", function(matches)
    if util.trim(matches[2]) == "test" then
      deps.sound.test()
    else
      print(a("gray", "usage: /hexsound test   (sound options live in /hexoptions)"))
    end
  end)
  alias_add("^/chat\\s*(\\S*)\\s*(\\d*)$", function(matches)
    deps.chat.cmd_chat(util.trim((matches[2] .. " " .. matches[3]):gsub("%s+", " ")))
  end)
  alias_add("^/chatset\\s+(.+)$", function(matches)
    deps.chat.cmd_chatset(matches[2])
  end)
  alias_add("^/chatnpc\\s*(.*)$", function(matches)
    deps.chat.cmd_chatnpc(matches[2])
  end)
  alias_add("^/chattab\\s+(on|off)$", function(matches)
    deps.config.set("chat_tab", matches[2] == "on")
    print(a("gray", "[hex] chat tab " .. matches[2] .. " (restart blightmud to apply)"))
  end)
  alias_add("^/combat\\s*(.*)$", function(matches)
    deps.combat.cmd_level(matches[2])
  end)
  alias_add("^/combatstat$", function()
    deps.combat.cmd_combatstat()
  end)
  alias_add("^/urls\\s*(.*)$", function(matches)
    deps.urls.cmd_list(matches[2])
  end)
  alias_add("^/url\\s+(.+)$", function(matches)
    deps.urls.cmd_open(matches[2])
  end)
  alias_add("^/spellinfo\\s+(.+)$", function(matches)
    deps.spells.cmd_spellinfo(matches[2])
  end)
  alias_add("^/spellcheck\\s+(.+)$", function(matches)
    deps.spells.cmd_spellcheck(matches[2])
  end)
  alias_add("^/tm\\s+(.+)$", function(matches)
    local method, limit = matches[2]:match("^(%S+)%s*(%d*)$")
    deps.spells.cmd_tm(method, limit)
  end)
  alias_add("^/spells\\s*(.*)$", function(matches)
    deps.spells.cmd_spells(matches[2])
  end)
  alias_add("^/blorp\\s*(.*)$", function(matches)
    deps.blorps.cmd_blorp(matches[2])
  end)
  alias_add("^/bookmark\\s*(.*)$", function(matches)
    deps.blorps.cmd_bookmark(matches[2])
  end)
  alias_add("^/bookmarks$", function()
    deps.blorps.cmd_bookmark("")
  end)
  alias_add("^/mdt\\s*(.*)$", function(matches)
    deps.mdt.cmd_mdt(matches[2])
  end)
  alias_add("^/hexexits$", function()
    deps.scry.cmd_exits()
  end)
  alias_add("^/hexzone$", function()
    deps.scry.cmd_zone()
  end)
  alias_add("^/hexnight$", function()
    deps.scry.cmd_night()
  end)
  alias_add("^/hexscan$", function()
    deps.scry.cmd_scan()
  end)
  alias_add("^/hexcorpse\\s*(.*)$", function(matches)
    deps.scry.cmd_corpse(matches[2] or "")
  end)
  alias_add("^/hunt\\s*(.*)$", function(matches)
    deps.mdt.cmd_hunt(matches[2])
  end)
  alias_add("^/unhunt\\s+(.+)$", function(matches)
    deps.mdt.cmd_unhunt(matches[2])
  end)
  alias_add("^/hexcapture\\s*(\\S*)$", function()
    print(a("gray", "[hex] the debug capture lane was removed in v0.15.0 (transcripts consumed); /doctor remains"))
  end)
  alias_add("^/hexdebug\\s*(.*)$", function()
    print(a("gray", "[hex] the debug lane was removed in v0.15.0; /doctor remains"))
  end)
  alias_add("^/doctor$", function()
    deps.doctor.run()
  end)
  alias_add("^/map$", function()
    -- on-demand minimap view: same render as /dwmap (the auto ladder
    -- covers top rows / the map tab; /map is the explicit inline view)
    cmd_show_map("dwmap")
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
  -- blorps/bookmarks and the scry commands need the graph builder, the
  -- identifier->vnum lookup, and the module deps; all live here (see
  -- hex_blorps / hex_scry deps)
  deps.blorps.get_graph = get_graph
  deps.scry.get_graph = get_graph
  deps.blorps.vnum_of = function(id)
    local r = rows(M.deps.config.get("rooms_db"), "SELECT vnum FROM rooms WHERE room_id = '" .. util.sql_escape(id) .. "';")
    return r and r[1] and tonumber(r[1][1]) or nil
  end
  deps.blorps.targets = targets
  deps.blorps.paths = paths
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
    print("  /where                   /wmap, /dwmap, /map")
    print("  /path [--full] <target>  /near <search>  (route graph, identified rooms)")
    print("  /goto <target>           one-batch speedwalk; /stopwalk aborts")
    print("  /missions [name]         mission table, resets, rates; /missions pending <id>")
    print("  /apply <id>              /dl <A-H>       /quota [refresh]")
    print("  /skills [refresh|search] /bonus <skill> [target]")
    print("  /skillcost <skill> [target] [etb N]      /goal add|remove, /goals")
    print("  /chat [family] [n]        /chatset <family> on|off   /chattab on|off")
    print("  /chatnpc [name]           silence an NPC's tells (remove to undo)")
    print("  /combat [level]           /combatstat       /urls, /url <n>")
    print("  /spellinfo <nick|name>    /spellcheck <n>   /tm <method>, /spells")
    print("  /stats [refresh]          read your stats into the bonus math")
    print("  /hexoptions [key] [value] /hexsound test     /hexsay <text>")
    print("  /blorp add|goto|list|all  /bookmark add|find|goto|list")
    print("  /hexexits /hexzone        verbose exits; zone + component facts")
    print("  /hexnight /hexcorpse      day/night facts; death-site mark/clear")
    print("  /hexscan                  corpses on the floor + your consider table")
    print("  /hexsetup [what]         game-side options (prompt, aliases, options)")
    print("  /hexupdate               Quow db + CC0 sounds into Hex's data dir")
    print("  /hexgag, /gaglog         user gags as data; /hexungag <n|text> removes")
    print("  /doctor                  self-test everything, writes a report file")
    print("  /hexprobe (gmcp echo)    /hexraw (last raw gmcp)")
    print("  /hexreload               /hexset <key> <value>")
  end)
end

return M
