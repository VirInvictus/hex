-- hex_gmcp.lua: Discworld GMCP wiring.
--
-- Discworld's GMCP is documented at
-- https://discworld.starturtle.net/lpc/playing/documentation.c?path=/concepts/gmcp
-- and it is NOT standard GMCP naming: registration is one
--   core.supports.set ["char.login", "char.info", "char.vitals",
--                      "room.info", "room.map", "room.writtenmap"]
-- (lowercase, full message names, individually, no version suffix), and the
-- hello is `core.hello {"client": ..., "version": ...}`. blightmud's
-- gmcp.register() wrapper sends "Core.Supports.Add ["Mod 1"]", which
-- Discworld ignores, so the handshake goes out raw via gmcp.send().
--
-- Server push timing: char.login/char.info at login; char.vitals whenever a
-- command is sent (like the prompt); room.* on look/glance/enter.
--
-- blightmud's gmcp.receive hands us the raw JSON body string; decode here.
-- Listeners are registered for the documented lowercase names plus the
-- conventional capitalized spellings as a fallback.
local M = {}

local SUPPORTS = 'core.supports.set ["char.login", "char.info", "char.vitals", "room.info", "room.map", "room.writtenmap"]'
local HELLO = 'core.hello {"client": "hex", "version": "0.1.0"}'

-- message family -> suffix -> handler key. Char.Info and Room.Info both end
-- in "info", so routing uses the family prefix too.
local ROUTES = {
  char = {
    vitals = "on_vitals",
    info = "on_char_info",
    login = "on_char_login",
  },
  room = {
    info = "on_room",
    map = "on_map",
    writtenmap = "on_writtenmap",
  },
}

local probe_on = false
local recent = {} -- last raw incoming GMCP subnegs, newest last

function M.probe()
  probe_on = not probe_on
  gmcp.echo(probe_on)
  return probe_on
end

-- /hexraw: the last raw GMCP payloads, for pinning down real JSON keys.
function M.recent()
  return recent
end

function M.setup(handlers)
  gmcp.on_ready(function()
    gmcp.send(HELLO)
    gmcp.send(SUPPORTS)
  end)

  -- raw tap on telnet option 201 (GMCP) for /hexraw
  core.subneg_recv(function(proto, bytes)
    if proto == 201 then
      local text = bytes_to_string(bytes)
      recent[#recent + 1] = text
      if #recent > 12 then
        table.remove(recent, 1)
      end
    end
  end)

  local function route(name, raw)
    local family = name:match("^(%a+)%.")
    local kind = name:match("%.(%w+)$")
    local key = family and kind and ROUTES[family:lower()] and ROUTES[family:lower()][kind:lower()]
    if not key or not handlers[key] then
      return
    end
    local ok, data = pcall(json.decode, raw)
    if not ok then
      data = raw -- string payloads (room.map may be plain text)
    end
    handlers[key](data, name)
  end

  for family, kinds in pairs(ROUTES) do
    local prefix = family:sub(1, 1):upper() .. family:sub(2)
    for kind in pairs(kinds) do
      for _, name in ipairs({ prefix .. "." .. kind:sub(1, 1):upper() .. kind:sub(2), family .. "." .. kind }) do
        gmcp.receive(name, function(raw)
          route(name, raw)
        end)
      end
    end
  end
end

return M
