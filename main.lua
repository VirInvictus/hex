-- Hex: a Discworld MUD plugin suite for Blightmud.
-- Entry point. Every require MUST stay at this top level: blightmud resolves
-- plugin-local modules only while this chunk itself is executing
-- (lua_script.rs prepends <plugindir>/?.lua to package.path around the load).
local util = require("src.hex_util")
local vitals_mod = require("src.hex_vitals")
local rooms_mod = require("src.hex_rooms")
local registry = require("src.hex_registry")
local gags = require("src.hex_gags")
local gagfile = require("src.hex_gagfile")
local setup_cmd = require("src.hex_setup")
local data = require("src.hex_data")
local gmcp_wire = require("src.hex_gmcp")
local status = require("src.hex_status")
local config = require("src.hex_config")
local commands = require("src.hex_commands")

-- remove exactly the triggers/aliases the previous load registered (the
-- handle list lives in the session store and survives /script reset)
registry.reap()

-- all registrations go through the registry so /hexreload can reap them
local trigger_add = function(re, opts, cb)
  return registry.record("trigger", trigger.add(re, opts, cb))
end

local vitals = vitals_mod.new()
local room = rooms_mod.new()
local maps = { written = nil, ascii = nil }

-- Pull a displayable string out of room.map / room.writtenmap payloads,
-- which may be JSON objects ({map: ...} / {text: ...}) or plain strings.
local function map_text(data)
  if type(data) == "string" then
    return data
  elseif type(data) == "table" then
    return data.map or data.text or data.writtenmap or ""
  end
  return ""
end

local function refresh_status()
  vitals.rate = vitals_mod.xp_rate(vitals)
  status.apply(status.render(vitals, room, select(1, blight.terminal_dimensions())))
end

status.setup()
refresh_status() -- draw the placeholder bars immediately, not on first data
gags.register(trigger_add, regex)

-- user gags as data: loaded additively after the built-ins (a bad entry
-- skips only itself; the file degrades to built-in gags only if unloadable)
gagfile.activate(trigger_add, regex, function(id)
  trigger.remove(id)
end, config.get("gags_file", data.hex_dir() .. "/gags.lua"))

-- Hex-owned data paths (quow_db ladder, /hexupdate, staleness)
data.setup(config)

gmcp_wire.setup({
  on_vitals = function(data)
    vitals_mod.apply(vitals, data)
    refresh_status()
  end,
  on_char_info = function(data)
    if type(data) == "table" and (data.capname or data.name) then
      config.set_alt(data.capname or data.name)
      print(util.ansi.gray .. "[hex] alt: " .. (data.capname or data.name) .. util.ansi.reset)
    end
  end,
  on_char_login = function(data)
    if type(data) == "table" and data.name then
      config.set_alt(data.name)
    end
  end,
  on_room = function(data)
    rooms_mod.update(room, data)
    refresh_status()
  end,
  on_map = function(data)
    maps.ascii = map_text(data)
  end,
  on_writtenmap = function(data)
    maps.written = map_text(data)
  end,
})

-- XP spent on skill advances feeds the xp-rate model (tt_dw counts the same
-- line: "You advance your skill in X from A to B for N xp").
trigger_add("^You advance your skill in .+ from .+ to .+ for ([\\d,]+) xp", {}, function(matches)
  local amount = tonumber((matches[2]:gsub(",", ""))) or 0
  vitals_mod.add_spent(vitals, amount)
  refresh_status()
end)

-- never log a password: while a password prompt is on screen, the next sent
-- line is marked skip_log so it stays out of the session log file
local password_armed = false
registry.record("trigger", trigger.add("^Enter password:", { gag = false }, function()
  password_armed = true
end))
mud.add_input_listener(function(line)
  if password_armed then
    password_armed = false
    line:skip_log(true)
  end
  return line
end)

mud.on_connect(function()
  -- Client-side logging only; nothing is ever sent to the MUD on connect.
  log.start("discworld")
  data.on_connect() -- migration hints + Quow staleness, once per session
  refresh_status()
end)

blight.on_dimensions_change(function()
  refresh_status()
end)

commands.setup({
  vitals = vitals,
  room = room,
  maps = maps,
  config = config,
  gmcp = gmcp_wire,
  registry = registry,
  gags = gags,
  gagfile = gagfile,
  setup = setup_cmd,
  data = data,
})

print(util.ansi.gray .. "[hex] loaded: /hexhelp for commands" .. util.ansi.reset)
