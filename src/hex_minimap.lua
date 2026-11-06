-- hex_minimap.lua: the ASCII minimap panel (design: docs/phase-5-room.md §1;
-- room.map shapes wire-verified 2026-11-05 — JSON string, real ANSI, two
-- lines for a 2x2 room).
--
-- Render ladder (feature-detected): toprows (blight.add_top_row, always on
-- screen; dev-tree) -> tab (a "map" pane; stock 5.7.1 has working tabs, proven
-- live by the chat tab) -> inline (nothing automatic; /dwmap stays the
-- on-demand fallback). Option hex.map_panel ∈ {auto, tab, inline, off}.
--
-- ANSI mode: option hex.map_ansi (shared with /dwmap) ∈ {strip, ansi},
-- default strip. The tab path strips regardless: output_to joins into a
-- fresh Line, which drops MUD colors anyway.
--
-- Refresh is deduped by (payload, room_id): the MUD pushes on look AND
-- enter, so re-looking the same room must not re-render.
local util = require("src.hex_util")

local M = {}

M.deps = {}
M.last_key = nil

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

-- pure: decode + strip + inspect a room.map payload.
function M.inspect(raw)
  local text = util.strip_ansi(tostring(raw))
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and util.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return {
    text = text,
    lines = lines,
    has_player = text:find("@", 1, true) ~= nil,
    empty = util.trim(text) == "",
  }
end

-- pure: dedupe key
function M.key(raw, room_id)
  return tostring(raw) .. "|" .. tostring(room_id)
end

-- --- runtime glue ---

function M.setup(deps)
  M.deps = deps
  M.has_toprows = blight ~= nil and blight.add_top_row ~= nil
  M.has_tabs = blight ~= nil and blight.create_tab ~= nil
  M.mode = deps.config.get("map_panel", "auto")
  if M.mode == "auto" then
    M.mode = M.has_toprows and "toprows" or (M.has_tabs and "tab" or "inline")
  end
  if M.mode == "tab" and M.has_tabs then
    M.ensure_tab()
  elseif M.mode == "toprows" and M.has_toprows then
    M.ensure_toprows()
  end
end

-- The map tab: created once per session (the session-store gate is the
-- same pattern that fixed the chat tab's reload re-create).
function M.ensure_tab()
  if store.session_read("hex.map_tab_created") == "1" then
    return
  end
  local ok, err = pcall(function()
    blight.create_tab("map")
    if blight.bind and blight.switch_tab then
      blight.bind("F3", function()
        blight.switch_tab("map")
      end)
    end
  end)
  if ok then
    store.session_write("hex.map_tab_created", "1") -- store values are strings
  else
    M.mode = "inline"
    print(gray("[hex] map tab unavailable (" .. tostring(err) .. "); /dwmap stays the view"))
  end
end

function M.ensure_toprows()
  -- wire-verified Rust signature: add_top_row takes ONE opts TABLE
  -- ({name = ..., body = ...}); a bare string errors
  local ok, err = pcall(function()
    blight.add_top_row({ name = "minimap" })
  end)
  if not ok then
    M.mode = "tab"
    print(gray("[hex] top rows unavailable (" .. tostring(err) .. "); minimap falls back to the map tab"))
  end
end

-- on_map hook from main.lua: raw payload + current room id. Deduped.
function M.on_map(raw, room_id)
  local key = M.key(raw, room_id)
  if key == M.last_key then
    return
  end
  M.last_key = key
  local info = M.inspect(raw)
  M.last_info = info
  if info.empty then
    local note = "[no map: you can't see anything here]"
    if M.mode == "toprows" then
      M.render_toprows({ note })
    elseif M.mode == "tab" then
      M.push_tab({ note })
    end
    return
  end
  local hint = info.has_player and "" or gray(" (no @: limited vision?)")
  if M.mode == "toprows" then
    M.render_toprows(info.lines)
  elseif M.mode == "tab" then
    local lines = {}
    for _, l in ipairs(info.lines) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = (info.has_player and "" or "(no @: limited vision?)")
    M.push_tab(lines)
  end
  _ = hint -- tab carries the hint inline; toprows keeps maps clean
end

function M.render_toprows(lines)
  -- body is a single STRING (embedded newlines; the renderer splits them)
  local text = table.concat(lines, "\n")
  pcall(function()
    blight.set_top_row("minimap", { body = text })
  end)
end

function M.push_tab(lines)
  pcall(function()
    blight.output_to("map", unpack(lines))
  end)
end

return M
