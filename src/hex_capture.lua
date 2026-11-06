-- hex_capture.lua: the debug capture harness. Shipped in v0.5.2-dbg, removed
-- in v0.6.0 per plan, RESURRECTED in v0.12.1-dbg for the combat-monitor
-- verification pass (Brandon asked; the lane is temporary again and comes
-- out of the next feature release, with /doctor staying on as the permanent
-- fixture). Transcripts land in ~/.local/share/hex/captures/ like the
-- originals and remain the wire-shape reference.
--
-- /hexcapture toggles: arm, then do the thing yourself (no probe batch this
-- time -- the sends are yours), then toggle again. While armed, every MUD
-- output line and every raw GMCP payload streams to
-- ~/.local/share/hex/captures/<stamp>.log.
--
-- Everything lives inside the user-alias handler or passive listeners; the
-- harness itself only reads and writes files under Hex's data dir.
local util = require("src.hex_util")

local M = {}

M.deps = {}
M.active = false
M.file = nil
M.path = nil
M.stats = nil -- counters kept while armed; summarised on disarm

-- pure: the capture file path for a timestamp (captures_dir overridable
-- so the unit suite never writes into the real data dir)
function M.captures_dir()
  return M.deps.captures_dir or ((os.getenv and os.getenv("HOME")) or "") .. "/.local/share/hex/captures"
end

function M.path_for(stamp)
  return M.captures_dir() .. "/hex-capture-" .. stamp .. ".log"
end

-- --- runtime glue ---

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

-- pure: fold one captured line into the counters. kind is "out" | "prompt" |
-- "gmcp"; text is the line body (gmcp = the raw payload incl. message name).
function M.count(stats, kind, text)
  if kind == "prompt" then
    stats.prompt = stats.prompt + 1
    return
  end
  if kind == "gmcp" then
    local name = text:match("^(%a+%.[%w%.]+)")
    if name then
      stats.gmcp[name] = (stats.gmcp[name] or 0) + 1
      local id = text:match('"identifier"%s*:%s*"([^"]*)"')
      if id then
        if id == "" then
          stats.empty_ids = stats.empty_ids + 1
        elseif #id ~= 40 then
          stats.symbolic_ids[#stats.symbolic_ids + 1] = id
          stats.rooms[id] = (stats.rooms[id] or 0) + 1
        else
          stats.rooms[id] = (stats.rooms[id] or 0) + 1
        end
      end
    else
      stats.gmcp.other = (stats.gmcp.other or 0) + 1
    end
    return
  end
  stats.out = stats.out + 1
  if text:find("You arrive after having journeyed", 1, true) then
    stats.journey_arrivals = stats.journey_arrivals + 1
  end
  if text:find("DRIFT at step", 1, true) or text:find("walk finished with drift", 1, true) then
    stats.drift_lines = stats.drift_lines + 1
  end
end

local function w(kind, text)
  if M.file then
    M.file:write(kind .. " " .. text .. "\n")
    M.file:flush()
  end
  if M.stats then
    M.count(M.stats, kind, text)
  end
end

-- pure: the summary lines from the stats table
function M.summary_lines(stats)
  local lines = {}
  lines[#lines + 1] = "output lines: " .. tostring(stats.out) .. "  prompts: " .. tostring(stats.prompt)
  local names = {}
  for name in pairs(stats.gmcp) do
    names[#names + 1] = name
  end
  table.sort(names)
  local gmcp_parts = {}
  for _, name in ipairs(names) do
    gmcp_parts[#gmcp_parts + 1] = name .. "=" .. stats.gmcp[name]
  end
  lines[#lines + 1] = "gmcp: " .. (#gmcp_parts > 0 and table.concat(gmcp_parts, " ") or "none")
  local rooms = {}
  for id in pairs(stats.rooms) do
    rooms[#rooms + 1] = id
  end
  table.sort(rooms)
  lines[#lines + 1] = "distinct rooms: " .. #rooms
  for i, id in ipairs(rooms) do
    if i > 12 then
      lines[#lines + 1] = "  ... (" .. #rooms - 12 .. " more)"
      break
    end
    local tag = #id ~= 40 and "  (symbolic)" or ""
    lines[#lines + 1] = "  " .. id .. tag .. " x" .. stats.rooms[id]
  end
  if stats.symbolic_ids and #stats.symbolic_ids > 0 then
    lines[#lines + 1] = "symbolic ids seen: " .. #stats.symbolic_ids
  end
  if stats.empty_ids > 0 then
    lines[#lines + 1] = "EMPTY identifiers seen: " .. stats.empty_ids .. " (mazes? report this)"
  end
  lines[#lines + 1] = "journey arrivals: " .. stats.journey_arrivals
  lines[#lines + 1] = "drift lines: " .. stats.drift_lines
  return lines
end

function M.setup(deps)
  M.deps = deps or {}
end

function M.arm()
  if M.active then
    print(gray("[hex] capture already armed: " .. tostring(M.path)))
    return
  end
  local stamp = os.date("%Y%m%d-%H%M%S")
  M.path = M.path_for(stamp)
  pcall(function()
    core.exec({ "mkdir", "-p", M.captures_dir() })
  end)
  M.file = io.open(M.path, "w")
  if not M.file then
    print(gray("[hex] cannot open capture file: " .. M.path))
    return
  end
  M.active = true
  M.stats = { out = 0, prompt = 0, gmcp = {}, rooms = {}, symbolic_ids = {}, empty_ids = 0, journey_arrivals = 0, drift_lines = 0 }
  local bversion = blight and blight.version and blight.version() or "?"
  M.file:write("hex-capture session " .. stamp .. " (blightmud " .. tostring(bversion) .. ")\n")
  M.file:flush()
  if M.deps.gmcp then
    M.deps.gmcp.sink = function(text)
      w("gmcp", text)
    end
  end
  print(gray("[hex] capture ARMED -> " .. M.path))
  print(gray("[hex] move around: /hexdebug walk <target> runs a verifiable walk,"))
  print(gray("[hex] busy streets feed /mdt, real shops exercise /items sold."))
  print(gray("[hex] /hexcapture again to stop (a summary prints)."))
end

function M.disarm()
  if not M.active then
    print(gray("[hex] capture is not armed"))
    return
  end
  M.active = false
  if M.deps.gmcp then
    M.deps.gmcp.sink = nil
  end
  local lines = {}
  if M.file then
    M.file:write("hex-capture session end\n")
    M.file:close()
    M.file = nil
  end
  print(gray("[hex] capture DISARMED -> " .. tostring(M.path)))
  if M.stats then
    lines = M.summary_lines(M.stats)
    for _, line in ipairs(lines) do
      print(gray("[capture] " .. line))
    end
    M.stats = nil
  end
end

function M.summary()
  if not M.active or not M.stats then
    print(gray("[hex] not armed (or nothing counted yet)"))
    return
  end
  for _, line in ipairs(M.summary_lines(M.stats)) do
    print(gray("[capture] " .. line))
  end
end

function M.toggle()
  if M.active then
    M.disarm()
  else
    M.arm()
  end
end

-- The output listener: armed -> mirror every line into the file. Registered
-- once at setup; it no-ops while disarmed (no removal API to lean on).
function M.listener(line)
  if M.active and M.file and line then
    local ok, is_prompt = pcall(line.prompt, line)
    w(ok and is_prompt and "prompt" or "out", line:line())
  end
  return line
end

function M.status()
  if M.active then
    print(gray("[hex] capture ARMED -> " .. tostring(M.path)))
  else
    print(gray("[hex] capture disarmed. /hexcapture arms it."))
  end
end

return M
