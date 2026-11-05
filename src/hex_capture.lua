-- hex_capture.lua: the debug capture harness (DEBUG LANE -- slated for
-- removal in v0.6.0 once the wire transcripts are in; see roadmap).
-- Enabled only when /hexset debug_capture on.
--
-- /hexcapture on   arm: every MUD output line + every raw GMCP payload
--                  streams to ~/.local/share/hex/captures/<stamp>.log
-- /hexcapture probes  run the read-only probe batch with frimble markers
--                  (options shapes, score layouts, the skills round-trip,
--                  spells listing, glance/look room pushes, hskills feed,
--                  say/soul as negative controls)
-- /hexcapture off  disarm and print the file path
--
-- Everything lives inside the user-alias handler (the sends are the user's
-- own capture action); the harness itself only reads and writes files.
-- Manual probes it cannot send for you are printed as instructions at
-- disarm: a short /goto (walker echoes), combat (monitor lines), tells or
-- a club line (chat shapes), and reconnecting with the capture armed
-- (login GMCP: char.login/char.info).
local util = require("src.hex_util")

local M = {}

M.deps = {}
M.active = false
M.file = nil
M.path = nil

-- The read-only probe batch, grouped by section (pure data: tests assert
-- the key probes are present and nothing game-state-changing slipped in).
-- Sections are bracketed with frimble markers whose echoes land in the
-- capture file between the outputs.
M.PROBE_GROUPS = {
  { "hex-capture: options section", { "options output", "brief exits", "options set output brief exits on", "options terminal automatic rows = off", "options output map plain = on", 'options set output map all "off"', "options terminal rows=999", "term xterm256" } },
  { "hex-capture: score section", { "score brief", "score verbose", "score verbose stats", "score stats" } },
  { "hex-capture: skills listing section", { "options output skills = list", "skills", "options output skills = branched" } },
  { "hex-capture: spells section", { "spells" } },
  { "hex-capture: misc feeds", { "hskills brief", "check quota brief" } },
  { "hex-capture: room push section", { "glance", "look" } },
  { "hex-capture: negative controls (say/soul)", { "say hex capture probe", "bow" } },
}

-- pure: the capture file path for a timestamp
function M.path_for(stamp)
  local home = (os.getenv and os.getenv("HOME")) or ""
  return home .. "/.local/share/hex/captures/hex-capture-" .. stamp .. ".log"
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
  M.deps = deps
end

function M.arm()
  if M.active then
    print(gray("[hex] capture already armed: " .. tostring(M.path)))
    return
  end
  local stamp = os.date("%Y%m%d-%H%M%S")
  M.path = M.path_for(stamp)
  core.exec({ "mkdir", "-p", util.trim(M.path:match("^(.+)/[^/]+$")) })
  M.file = io.open(M.path, "w")
  if not M.file then
    print(gray("[hex] cannot open capture file: " .. M.path))
    return
  end
  M.active = true
  w("hex-capture session " .. stamp .. " (blightmud " .. tostring(blight.version and blight.version() or "?") .. ")")
  if M.deps.gmcp then
    M.deps.gmcp.sink = function(text)
      w("[gmcp] " .. text)
    end
  end
  print(gray("[hex] capture ARMED -> " .. M.path))
  print(gray("[hex] reconnecting now catches the login GMCP (char.login/char.info);"))
  print(gray("[hex] then /hexcapture probes for the batch, and the manual items printed"))
  print(gray("[hex] by /hexcapture off. Keep it armed while you play."))
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
  print(gray("[hex] manual items (do these with a fresh /hexcapture on when convenient):"))
  print(gray("  - a short /goto out-and-back: walker echoes, travel-option lines,"))
  print(gray("    'Removed queue.', the frimble marker echo, Added-alias shape"))
  print(gray("  - attack something weak for a few rounds: live monitor lines"))
  print(gray("  - someone tells you, or a club line if you join one: chat shapes"))
  print(gray("  - cast a spell if you have one: 'You prepare to cast' shapes"))
  print(gray("  - arm BEFORE your next login: char.login/char.info GMCP payloads"))
end

-- The probe batch: frimble markers bracket each section, one send per
-- line, all inside this alias handler.
function M.run_probes()
  if not M.active then
    print(gray("[hex] arm first: /hexcapture on"))
    return
  end
  local commands = M.build_probe_commands()
  for _, cmd in ipairs(commands) do
    w("[sent] " .. cmd)
    mud.send(cmd)
  end
  print(gray("[hex] probe batch sent (" .. #commands .. " lines, frimble-bracketed)"))
end

-- pure: marker + probe groups, flattened in order.
function M.build_probe_commands()
  local out = {}
  for _, group in ipairs(M.PROBE_GROUPS) do
    out[#out + 1] = "frimble " .. group[1]
    for _, cmd in ipairs(group[2]) do
      out[#out + 1] = cmd
    end
  end
  out[#out + 1] = "frimble hex-capture: probe batch end"
  return out
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
    print(gray("[hex] capture disarmed. Enable the lane with /hexset debug_capture on if the command is missing."))
  end
end

return M
