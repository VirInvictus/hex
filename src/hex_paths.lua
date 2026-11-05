-- hex_paths.lua: shortest paths over the identified-room subgraph (design:
-- docs/phase-2-mapper.md §1-2). Pure Lua 5.4, binary-heap Dijkstra, CSR
-- adjacency (parallel flat arrays + offsets). Dijkstra, not A*: the tintin
-- map stores no coordinates, so no heuristic exists. Weights are
-- max(exit distance, 1) so the map's distance column goes live the day it
-- carries real values; one-way exits are just directed edges. AVOID rooms
-- and AVOID_TMP (water) rooms are blocked unless opts.allow_avoid, but the
-- start room always expands (routing OUT of water must work).
--
-- The graph is built lazily by the caller (first routing command of the
-- session pays the ~100 ms build) from two grouped SQL dumps and cached in
-- module/session state. Rows arrive as util.parse_rows output: arrays of
-- field arrays split on '|'.
local util = require("src.hex_util")

local M = {}

-- Both dumps: identified 40-hex rooms only (shared-instance ids cannot
-- verify position and never route). Node dump is vnum-ordered so dense
-- indexes give deterministic tie-breaks.
M.NODE_QUERY = [[
SELECT vnum || '|' || flags || '|' || room_id || '|' || name || '|' || area
FROM rooms
WHERE room_id GLOB '[0-9a-f]*' AND room_id NOT GLOB '*[^0-9a-f]*'
ORDER BY vnum;
]]

-- Edge dump fields: dest:flag:dir:distance:command (command last: it may
-- contain spaces, e.g. "enter crate"). Edges are kept when BOTH endpoints
-- are identified, which is what makes the subgraph.
M.EDGE_QUERY = [[
SELECT e.from_vnum || '|' || group_concat(e.dest || ':' || e.flag || ':' || e.dir || ':' || e.distance || ':' || e.command, ',')
FROM exits e
JOIN rooms a ON a.vnum = e.from_vnum
JOIN rooms b ON b.vnum = e.dest
WHERE a.room_id GLOB '[0-9a-f]*' AND a.room_id NOT GLOB '*[^0-9a-f]*'
  AND b.room_id GLOB '[0-9a-f]*' AND b.room_id NOT GLOB '*[^0-9a-f]*'
GROUP BY e.from_vnum
ORDER BY e.from_vnum;
]]

local function blocked(flags, allow)
  if allow then
    return false
  end
  -- AVOID = 1, AVOID_TMP = 512 (water/underwater; tintin sets 513 on water)
  local f = math.floor(tonumber(flags) or 0)
  return f % 2 == 1 or f % 1024 >= 512
end

-- Load the graph from node and edge dump rows. Returns graph, nil or
-- nil, reason. graph fields: idx (vnum->dense), by_id (room_id->dense),
-- vnum/room_id/name/area/flags (dense->value), offs (CSR offsets),
-- e_to/e_flag/e_dir/e_dist/e_cmd (CSR parallel arrays), edges (count).
function M.load(node_rows, edge_rows)
  local graph = {
    idx = {},
    by_id = {},
    vnum = {},
    room_id = {},
    name = {},
    area = {},
    flags = {},
    offs = { 0 },
    e_to = {},
    e_flag = {},
    e_dir = {},
    e_dist = {},
    e_cmd = {},
    edges = 0,
  }

  for _, f in ipairs(node_rows) do
    local vnum = tonumber(f[1])
    local rid = f[3]
    if vnum and rid and #rid == 40 and rid:match("^[0-9a-f]+$") then
      local d = #graph.vnum + 1
      graph.idx[vnum] = d
      graph.by_id[rid] = d
      graph.vnum[d] = vnum
      graph.room_id[d] = rid
      graph.name[d] = f[4] or "?"
      graph.area[d] = f[5] or ""
      graph.flags[d] = tonumber(f[2]) or 0
    end
  end

  -- bucket edges per from-node, then flatten in dense order (both dumps are
  -- vnum-ordered, so the flatten is one pass)
  local buckets = {}
  for _, f in ipairs(edge_rows) do
    local from = tonumber(f[1])
    local d = from and graph.idx[from]
    if d then
      for edge in (f[2] .. ","):gmatch("([^,]*),") do
        if edge ~= "" then
          -- split the first four ':' fields, remainder is the command
          local pos = 0
          local dest, flag, dir, dist
          for i = 1, 4 do
            local c = edge:find(":", pos + 1, true)
            if not c then
              dest = nil
              break
            end
            local part = edge:sub(pos + 1, c - 1)
            if i == 1 then
              dest = tonumber(part)
            elseif i == 2 then
              flag = tonumber(part) or 0
            elseif i == 3 then
              dir = tonumber(part) or 0
            else
              dist = tonumber(part) or 1.0
            end
            pos = c
          end
          local cmd = edge:sub(pos + 1)
          local td = dest and graph.idx[dest]
          if td and cmd ~= "" then
            local list = buckets[d]
            if not list then
              list = {}
              buckets[d] = list
            end
            list[#list + 1] = { td, flag, dir, dist, cmd }
          end
        end
      end
    end
  end

  local n = #graph.vnum
  for d = 1, n do
    local list = buckets[d] or {}
    graph.offs[d + 1] = graph.offs[d] + #list
    for _, e in ipairs(list) do
      local k = #graph.e_to + 1
      graph.e_to[k] = e[1]
      graph.e_flag[k] = e[2]
      graph.e_dir[k] = e[3]
      graph.e_dist[k] = e[4]
      graph.e_cmd[k] = e[5]
    end
  end
  graph.edges = #graph.e_to
  if n == 0 then
    return nil, "no identified rooms in the node dump"
  end
  return graph
end

-- Attach the city-gate set (tt_dw toggles AVOID on gate exits; Hex keeps
-- them routable by default and blocks them only when /goto's avoid-gates
-- is on). rows: "vnum|exit" pairs from the gates table.
function M.attach_gates(graph, gate_rows)
  graph.gates = {}
  for _, f in ipairs(gate_rows or {}) do
    if f[1] then
      graph.gates[f[1]] = true
    end
  end
  return graph
end

function M.is_gate(graph, from_vnum, cmd)
  return graph.gates ~= nil and graph.gates[tostring(from_vnum) .. "|" .. tostring(cmd)] or false
end

function M.is_swim(cmd)
  return tostring(cmd):find("^swim") ~= nil
end

-- Binary min-heap over (dist, dense) with deterministic tie-break on the
-- dense index; parallel arrays, stale entries skipped by the caller.
local function heap_less(H, i, j)
  return H.d[i] < H.d[j] or (H.d[i] == H.d[j] and H.x[i] < H.x[j])
end

local function heap_push(H, d, x)
  local n = H.n + 1
  H.n = n
  H.d[n], H.x[n] = d, x
  while n > 1 do
    local p = n // 2
    if heap_less(H, p, n) then
      break
    end
    H.d[p], H.d[n] = H.d[n], H.d[p]
    H.x[p], H.x[n] = H.x[n], H.x[p]
    n = p
  end
end

local function heap_pop(H)
  local top_d, top_x = H.d[1], H.x[1]
  local n = H.n
  H.d[1], H.x[1] = H.d[n], H.x[n]
  H.n = n - 1
  local i = 1
  while true do
    local l, r = i * 2, i * 2 + 1
    local m = i
    if l <= H.n and heap_less(H, l, m) then
      m = l
    end
    if r <= H.n and heap_less(H, r, m) then
      m = r
    end
    if m == i then
      break
    end
    H.d[i], H.d[m] = H.d[m], H.d[i]
    H.x[i], H.x[m] = H.x[m], H.x[i]
    i = m
  end
  return top_d, top_x
end

-- Core Dijkstra from one or more start dense indexes. Returns dist, prev,
-- prev_edge, closed (all dense-keyed). opts: { allow_avoid = bool,
-- targets = { dense = true } for early exit }.
local function dijkstra(graph, starts, opts)
  opts = opts or {}
  local allow = opts.allow_avoid
  local dist, prev, prev_edge, closed = {}, {}, {}, {}
  local startset = {}
  local H = { d = {}, x = {}, n = 0 }
  for _, sd in ipairs(starts) do
    if graph.vnum[sd] then
      startset[sd] = true
      dist[sd] = 0
      heap_push(H, 0, sd)
    end
  end
  local found = 0
  local wanted = nil
  if opts.targets then
    local c = 0
    for _ in pairs(opts.targets) do
      c = c + 1
    end
    wanted = c
  end
  while H.n > 0 do
    local d, x = heap_pop(H)
    if not closed[x] then
      closed[x] = true
      if wanted and opts.targets[x] then
        found = found + 1
        if found >= wanted then
          break
        end
      end
      if not (blocked(graph.flags[x], allow) and not startset[x]) then
        for k = graph.offs[x] + 1, graph.offs[x + 1] do
          local y = graph.e_to[k]
          if not closed[y] and not blocked(graph.flags[y], allow) then
            local cmd = graph.e_cmd[k]
            if opts.exclude_swim and cmd:find("^swim") then
              -- swim edges stay out of /goto routes unless allowed or wet
            elseif opts.avoid_gates and graph.gates and graph.gates[tostring(graph.vnum[x]) .. "|" .. cmd] then
              -- city gates lock at night; /goto avoids when asked
            else
            local nd = d + math.max(graph.e_dist[k], 1)
            if dist[y] == nil or nd < dist[y] then
              dist[y] = nd
              prev[y] = x
              prev_edge[y] = k
              heap_push(H, nd, y)
            end
            end
          end
        end
      end
    end
  end
  return dist, prev, prev_edge, closed
end

-- find_route(graph, start_vnums, target_vnum, opts) -> route | nil, reason.
-- route = { steps, from, to, dist, path = { {from,to,cmd,dir,eflag,room_id,name,area} } }
function M.find_route(graph, start_vnums, target_vnum, opts)
  opts = opts or {}
  local starts = {}
  for _, v in ipairs(start_vnums or {}) do
    local sd = graph.idx[v]
    if sd then
      starts[#starts + 1] = sd
    end
  end
  if #starts == 0 then
    return nil, "start is not in the routable graph"
  end
  local t = graph.idx[target_vnum]
  if not t then
    return nil, "target is not in the routable graph"
  end
  if blocked(graph.flags[t], opts.allow_avoid) then
    return nil, "target is avoid-flagged (water or AVOID); /path any includes it"
  end
  local dist, prev, prev_edge, closed = dijkstra(graph, starts, opts)
  if not closed[t] then
    return nil, "unreachable"
  end
  local path = {}
  local cur = t
  while prev[cur] ~= nil do
    local k = prev_edge[cur]
    local from_d = prev[cur]
    local cmd = graph.e_cmd[k]
    path[#path + 1] = {
      from = graph.vnum[from_d],
      to = graph.vnum[cur],
      cmd = cmd,
      dir = graph.e_dir[k],
      eflag = graph.e_flag[k],
      dist = graph.e_dist[k],
      gate = M.is_gate(graph, graph.vnum[from_d], cmd),
      swim = M.is_swim(cmd),
      room_id = graph.room_id[cur],
      name = graph.name[cur],
      area = graph.area[cur],
    }
    cur = from_d
  end
  for i = 1, #path // 2 do
    path[i], path[#path + 1 - i] = path[#path + 1 - i], path[i]
  end
  return { steps = #path, from = graph.vnum[cur], to = target_vnum, dist = dist[t], path = path }
end

-- One Dijkstra, many targets: map of vnum -> step count for the targets
-- that were reached (missing = unreachable). opts.allow_avoid passthrough.
function M.distances(graph, start_vnum, target_vnums, opts)
  local targets, starts = {}, {}
  local sd = graph.idx[start_vnum]
  if sd then
    starts[1] = sd
  end
  for _, v in ipairs(target_vnums or {}) do
    local d = graph.idx[v]
    if d then
      targets[d] = true
    end
  end
  local dist, _, _, closed = dijkstra(graph, starts, { allow_avoid = opts and opts.allow_avoid, targets = targets })
  local out = {}
  for d in pairs(targets) do
    if closed[d] then
      out[graph.vnum[d]] = dist[d]
    end
  end
  return out
end

-- Render a route into display lines. Compact mode groups consecutive
-- same-command steps ("[3 north]", "[enter crate]"), wrapped at ~78
-- columns; full mode lists every room on the way.
function M.render(route, graph, full)
  local function node_name(vnum)
    local d = graph.idx[vnum]
    return d and graph.name[d] or ("room " .. vnum)
  end
  local lines = {}
  lines[#lines + 1] = ("route: %s -> %s   %d steps"):format(node_name(route.from), node_name(route.to), route.steps)
  if full then
    for i, st in ipairs(route.path) do
      lines[#lines + 1] = (" %3d. %-12s %s%s"):format(i, st.cmd, st.name, st.area ~= "" and ("  (" .. st.area .. ")") or "")
    end
    return lines
  end
  local parts = {}
  for _, st in ipairs(route.path) do
    local last = parts[#parts]
    if last and last.cmd == st.cmd and not last.journey then
      last.n = last.n + 1
    else
      parts[#parts + 1] = { cmd = st.cmd, dir = st.dir, n = 1, journey = st.cmd:find("^journey ") ~= nil, swim = st.cmd:find("^swim") ~= nil, dist = st.dist }
    end
  end
  local out = {}
  local width = 78
  for _, sg in ipairs(parts) do
    -- journey steps render their mile count (the edge distance IS miles)
    local piece
    if sg.journey then
      piece = "[journey: " .. math.floor(sg.dist + 0.5) .. " miles " .. sg.cmd:match("^journey (%w+)") .. "]"
    elseif sg.n == 1 and sg.dir == 0 then
      piece = "[" .. sg.cmd .. "]"
    elseif sg.swim then
      piece = "[~ " .. sg.n .. " " .. sg.cmd .. "]"
    else
      piece = "[" .. sg.n .. " " .. sg.cmd .. "]"
    end
    if #out > 0 and #out[#out] + 1 + #piece <= width then
      out[#out] = out[#out] .. " " .. piece
    else
      out[#out + 1] = piece
    end
  end
  for _, l in ipairs(out) do
    lines[#lines + 1] = "  " .. l
  end
  return lines
end

return M
