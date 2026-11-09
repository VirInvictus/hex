-- hex_walk.lua: the /goto ONE-SHOT batch speedwalk (design:
-- docs/phase-2-mapper.md §4, ported from tt_dw's paths.tin:195-285).
--
-- Compliance shape (concepts/automation's sanctioned "fast" kind): one user
-- invocation packs the travel option, every route command, an optional
-- journey restore, and a frimble end-marker into ONE MUD-side alias, then
-- defines it and invokes it in two sends. Nothing is ever sent again: the
-- MUD's own queue executes the walk, `stop` aborts it (or /stopwalk, a
-- user-alias send). room.info pushes are compared against the planned
-- identifiers purely for display: an advance counter, one drift report on
-- the first mismatch, a completion summary. Hex never re-sends, never
-- re-routes, and keeps no timer.
--
-- Pure core: new_state/build_queue/on_room/is_done_marker take no blightmud
-- globals; start/stop/on_room_runtime are the runtime glue.
local util = require("src.hex_util")

local M = {}

-- The frimble marker is the last item in the alias queue: when its echo
-- reaches us, the MUD has drained every command.
M.DONE_MARKER = "hex: walk done"
M.ALIAS_NAME = "hex_goto_walk"
-- The MUD aborts queues that run past 5 minutes; at roughly one command a
-- second, warn before ~4 minutes of commands.
M.WARN_STEPS = 240

function M.new_state(route, label)
  local ids = {}
  for _, st in ipairs(route.path) do
    ids[#ids + 1] = st.room_id
  end
  return { ids = ids, total = #ids, index = 0, label = label, drifted_at = nil, complete = false }
end

-- The lines to send, in order: the alias definition (travel option, route,
-- optional journey restore, frimble marker, semicolon-joined) then the alias
-- invocation. default_travel is config's "travel_mode" ("walk" | "journey");
-- tt_dw restores journey only when the user's default is not walk.
function M.build_queue(route, default_travel)
  local parts = { "noalias options personal travel = walk" }
  for _, st in ipairs(route.path) do
    parts[#parts + 1] = st.cmd
  end
  if default_travel == "journey" then
    parts[#parts + 1] = "noalias options personal travel = journey"
  end
  parts[#parts + 1] = "frimble " .. M.DONE_MARKER
  local alias = "alias " .. M.ALIAS_NAME .. " " .. table.concat(parts, ";")
  return { alias, M.ALIAS_NAME }
end

function M.should_warn(route)
  return route.steps > M.WARN_STEPS
end

-- The status chip for an active walk: progress, or the drift mark. Pure.
function M.chip(state)
  if not state or state.complete then
    return nil
  end
  local mark = state.drifted_at and "!drift" .. state.drifted_at .. "/" or "»"
  return mark .. state.index .. "/" .. state.total
end

-- The walk's completion line: the frimble echo arriving means the queue is
-- drained.
function M.is_done_marker(line)
  return tostring(line):match("^" .. M.DONE_MARKER:gsub("%W", "%%%0") .. "%s*$") ~= nil
end

-- One room.info push against the plan (pure transition; the runtime wrapper
-- is M.on_room below). Returns an event table:
--   { kind = "advance"|"milestone"|"mismatch"|"drifted"|"complete", ... }
-- "drifted" = a mismatch already happened, later rooms are counted silently
-- so one wrong turn does not spam the whole tail of the route. Every event
-- carries total: the mismatch print concatenates it, and the field's absence
-- crashed the first live walk (found 2026-11-08, night rooftop walk).
--
-- id == nil = an UNVERIFIABLE room: dark rooms push room.info without the
-- identifier (you can't identify a room you can't see — found live the same
-- night, when a 38-step walk through dark countryside counted 0/38 while
-- successfully moving Brandon the whole way). Unverified pushes advance the
-- counter optimistically and mark the walk so the finish line reports it.
function M.transition(state, id)
  if state.complete then
    return { kind = "idle" }
  end
  state.index = state.index + 1
  if id == nil then
    state.unverified = (state.unverified or 0) + 1
    if state.index >= state.total then
      state.complete = true
      return { kind = "complete", index = state.index, total = state.total, drifted_at = state.drifted_at, unverified = true }
    end
    if state.index % 25 == 0 then
      return { kind = "milestone", index = state.index, total = state.total, unverified = true }
    end
    return { kind = "advance", index = state.index, total = state.total, unverified = true }
  end
  local expected = state.ids[state.index]
  if state.index >= state.total and (expected == id or state.drifted_at) then
    state.complete = true
    return { kind = "complete", index = state.index, total = state.total, drifted_at = state.drifted_at, early = false }
  end
  if expected == id then
    if state.index % 25 == 0 then
      return { kind = "milestone", index = state.index, total = state.total }
    end
    return { kind = "advance", index = state.index, total = state.total }
  end
  if state.drifted_at then
    return { kind = "drifted", index = state.index, total = state.total, expected = expected, actual = id }
  end
  state.drifted_at = state.index
  return { kind = "mismatch", index = state.index, total = state.total, expected = expected, actual = id }
end

-- The frimble marker can arrive after a drift, or early: failed commands
-- drain the queue much faster than the route assumed (found live: night
-- climbs on a dark rooftop failed, the queue emptied, and the marker made
-- the finish print "arrived" three steps into a 32-step walk). An early
-- marker reports honestly instead.
function M.on_done_line(state)
  if state.complete then
    return { kind = "idle" }
  end
  state.complete = true
  return {
    kind = "complete",
    index = state.index,
    total = state.total,
    drifted_at = state.drifted_at,
    early = state.index < state.total,
  }
end

-- --- runtime glue (blightmud globals below this line) ---

M.state = nil
M.handles = {} -- walk-duration trigger handles (queued-echo catch-all, Removed queue note)

local function gray(text)
  return util.ansi.gray .. text .. util.ansi.reset
end

local function red(text)
  return util.ansi.red .. text .. util.ansi.reset
end

-- Called from main.lua with the registry-wrapped trigger_add and a raw
-- trigger remover.
function M.init(trigger_add, trigger_remove, config)
  M.trigger_add = trigger_add
  M.trigger_remove = trigger_remove
  M.config = config
end

local function finish(event)
  local state = M.state
  M.state = nil
  for _, h in ipairs(M.handles) do
    pcall(M.trigger_remove, h.id)
  end
  M.handles = {}
  if state then
    if event.drifted_at then
      print(red("[hex] walk finished with drift at step " .. event.drifted_at .. "/" .. event.total .. ": " .. state.label))
      print(gray("[hex] the queue was never altered; check where you ended up with /where"))
    elseif event.early then
      print(red("[hex] walk ended early at step " .. (event.index or "?") .. "/" .. (event.total or "?") .. ": " .. state.label))
      print(gray("[hex] the queue drained before the route finished (failed commands drain fast); /where shows where you are"))
    else
      local tag = event.unverified and " (some steps unverified — dark rooms)" or ""
      print(gray("[hex] arrived: " .. state.label .. " (" .. event.index .. " steps)" .. tag))
    end
  end
end

local function on_event(event)
  if event.kind == "advance" then
    return -- silent per-room; milestones and the chip carry progress
  elseif event.kind == "milestone" then
    print(gray("» " .. event.index .. "/" .. event.total .. "  " .. (M.state and M.state.label or "")))
  elseif event.kind == "mismatch" then
    print(red("[hex] DRIFT at step " .. event.index .. "/" .. event.total .. ": expected " .. tostring(event.expected) .. ", saw " .. tostring(event.actual)))
    print(gray("[hex] the queue keeps running (Hex never alters it); `stop` aborts it"))
  elseif event.kind == "complete" then
    finish(event)
  end
end

-- room.info hook from main.lua; also fed the frimble done-marker line? No:
-- markers arrive as regular MUD output, so main.lua registers a trigger for
-- it at walk start (see start()).
function M.on_room(id)
  if not M.state or id == nil then
    return
  end
  on_event(M.transition(M.state, id))
end

function M.active()
  return M.state ~= nil
end

-- Send the walk (alias handler only). Sends two lines: the alias definition
-- and the invocation. Everything after that is the MUD's queue.
function M.launch(route, label)
  local default_travel = "walk"
  if M.config then
    default_travel = M.config.get("travel_mode", "walk")
  end
  -- walk-duration triggers: the queued-command echo catch-all and the
  -- MUD's queue-cleared notice, both informational, removed on completion
  M.handles = {}
  M.handles[#M.handles + 1] = M.trigger_add("^Queued command:", { gag = true }, function() end)
  M.handles[#M.handles + 1] = M.trigger_add("^Removed queue\\.$", {}, function()
    print(gray("[hex] the MUD cleared the walk queue (Removed queue.)"))
  end)
  -- the trigger pattern is RUST: escape with backslashes (the Lua-side
  -- is_done_marker keeps its own %W form); %-escapes would silently never
  -- match in Rust
  local rust_marker = "^" .. M.DONE_MARKER:gsub("%W", "\\%0") .. "\\s*$"
  M.handles[#M.handles + 1] = M.trigger_add(rust_marker, {}, function()
    if M.state then
      on_event(M.on_done_line(M.state))
    end
  end)
  M.state = M.new_state(route, label)
  local queue = M.build_queue(route, default_travel)
  mud.send(queue[1])
  mud.send(queue[2])
end

-- /stopwalk: the sanctioned user-alias send of `stop`, plus cleanup. The
-- MUD may print its own queue-cleared lines afterwards; those are its own.
function M.stop()
  local had = M.state ~= nil
  M.state = nil
  for _, h in ipairs(M.handles) do
    pcall(M.trigger_remove, h.id)
  end
  M.handles = {}
  mud.send("stop")
  if had then
    print(gray("[hex] walk stopped"))
  end
end

return M
