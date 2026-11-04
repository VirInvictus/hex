-- Hex: a Discworld MUD plugin suite for Blightmud.
-- Entry point. Every require MUST stay at this top level: blightmud resolves
-- plugin-local modules only while this chunk itself is executing
-- (lua_script.rs prepends <plugindir>/?.lua to package.path around the load).
local util = require("hex_util")
local vitals_mod = require("hex_vitals")
local rooms_mod = require("hex_rooms")
local gags = require("hex_gags")
local gmcp_wire = require("hex_gmcp")
local status = require("hex_status")
local config = require("hex_config")
local commands = require("hex_commands")

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
gags.register(trigger.add, Regex)

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
trigger.add("^You advance your skill in .+ from .+ to .+ for ([\\d,]+) xp", {}, function(matches)
  local amount = tonumber((matches[2]:gsub(",", ""))) or 0
  vitals_mod.add_spent(vitals, amount)
  refresh_status()
end)

mud.on_connect(function()
  -- Client-side logging only; nothing is ever sent to the MUD on connect.
  log.start("discworld")
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
})

print(util.ansi.gray .. "[hex] loaded: /hexhelp for commands" .. util.ansi.reset)
