-- hex_gmcp.lua: Discworld GMCP wiring.
--
-- Discworld documents six lowercase commands (char.login, char.info,
-- char.vitals, room.info, room.map, room.writtenmap) while GMCP convention
-- capitalizes; blightmud dispatches gmcp.receive by exact module name, so
-- Hex registers and listens on both casings until the wire format is
-- confirmed live (/hexprobe echoes raw GMCP).
--
-- blightmud's gmcp.receive hands us the raw JSON body string; decode here.
-- Registration waits for gmcp.on_ready per the documented pattern
-- (gmcp.send/register push bytes unconditionally, on_ready is the safe gate).
local M = {}

-- message suffix -> handler key. Char.Info carries identity, Room.Info the
-- room; both end in "info", so routing uses the family prefix too.
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

function M.probe()
  probe_on = not probe_on
  gmcp.echo(probe_on)
  return probe_on
end

function M.setup(handlers)
  gmcp.on_ready(function()
    gmcp.register("Char")
    gmcp.register("char")
    gmcp.register("Room")
    gmcp.register("room")
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
    local lower = family
    for kind in pairs(kinds) do
      local upper = prefix .. "." .. kind:sub(1, 1):upper() .. kind:sub(2)
      gmcp.receive(upper, function(raw)
        route(upper, raw)
      end)
      gmcp.receive(lower .. "." .. kind, function(raw)
        route(lower .. "." .. kind, raw)
      end)
    end
  end
end

return M
