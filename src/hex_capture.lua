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

local function w(text)
  if M.file then
    M.file:write(text .. "\n")
    M.file:flush()
  end
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
  local bversion = blight and blight.version and blight.version() or "?"
  w("hex-capture session " .. stamp .. " (blightmud " .. tostring(bversion) .. ")")
  if M.deps.gmcp then
    M.deps.gmcp.sink = function(text)
      w("[gmcp] " .. text)
    end
  end
  print(gray("[hex] capture ARMED -> " .. M.path))
  print(gray("[hex] now do the thing yourself, e.g. for the monitor check:"))
  print(gray("  attack pumpkin   (a few rounds; also try 'kill pumpkin' once)"))
  print(gray("  score            (the brief line; vitals arrive via GMCP beside it)"))
  print(gray("  glance           (room info + map + writtenmap push)"))
  print(gray("[hex] then /hexcapture again to stop."))
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
  if M.file then
    w("hex-capture session end")
    M.file:close()
    M.file = nil
  end
  print(gray("[hex] capture DISARMED -> " .. tostring(M.path)))
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
    w((ok and is_prompt and "[prompt] " or "[out] ") .. line:line())
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
