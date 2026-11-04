-- hex_commands.lua: user-facing aliases and result rendering.
-- Spec invariant: every mud-bound action is behind a user alias; these
-- commands only read local databases and blightmud state, and never send
-- anything to the MUD.
local util = require("src.hex_util")
local queries = require("src.hex_queries")

local M = {}

local function a(name, text)
  return util.ansi[name] .. text .. util.ansi.reset
end

local function sql(db, query)
  local r = core.exec({ "sqlite3", db, query })
  if r:code() ~= 0 then
    print(a("red", "[hex] sqlite error: ") .. r:stderr())
    return nil
  end
  return r:stdout()
end

local function width()
  local w = blight.terminal_dimensions()
  return w or 80
end

local function rows(db, query)
  local out = sql(db, query)
  if not out then
    return nil
  end
  return util.parse_rows(out)
end

local function show_item_line(fields)
  local name, value, description, appraise, weight = fields[1], fields[2], fields[3], fields[4], fields[5]
  print(a("bold", util.trim(name)) .. a("gray", "  A$" .. value .. "  " .. weight))
  for _, line in ipairs(util.wrap(util.trim(description or ""), width() - 2)) do
    print("  " .. a("gray", line))
  end
  if appraise and appraise ~= "" then
    for _, line in ipairs(util.wrap("appraise: " .. util.trim(appraise), width() - 2)) do
      print("  " .. a("gray", line))
    end
  end
end

local function cmd_item(args)
  local exact = false
  local search = args
  local head, rest = args:match("^(%S+)%s+(.+)$")
  if head == "exact" then
    exact = true
    search = rest
  end
  local result = rows(M.deps.config.get("quow_db"), queries.build_item_query(search, exact))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] no items match: " .. search))
    return
  end
  for _, fields in ipairs(result) do
    show_item_line(fields)
  end
end

local function cmd_item_sources(args)
  local flag = nil
  local search = args
  local head, rest = args:match("^(%S+)%s+(.+)$")
  if head == "sold" or head == "free" or head == "loot" then
    flag = head
    search = rest or ""
  end
  local result = rows(M.deps.config.get("quow_db"), queries.build_item_sources_query(search, flag))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] no sources found" .. (flag and (" (" .. flag .. ")") or "") .. ": " .. search))
    return
  end
  for _, fields in ipairs(result) do
    local kind, seller, price, room_short = fields[1], fields[2], fields[3], fields[4]
    local line = a("cyan", string.format("%-5s", kind)) .. a("bold", util.trim(seller ~= "" and seller or room_short))
    if price and price ~= "" then
      line = line .. a("gray", "  " .. price)
    end
    print(line)
  end
end

local function cmd_npc(args)
  local result = rows(M.deps.config.get("quow_db"), queries.build_npc_query(args))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] no npcs match: " .. args))
    return
  end
  for _, fields in ipairs(result) do
    local name, room_id, room_short = fields[1], fields[2], fields[3]
    print(a("bold", util.trim(name)) .. a("gray", "  " .. (room_short ~= "" and room_short or room_id)))
  end
end

local function cmd_shop(args)
  local room_id = util.trim(args)
  if room_id == "" then
    room_id = M.deps.room.id
  end
  if not room_id then
    print(a("red", "[hex] no room known yet; enter a room or pass an identifier"))
    return
  end
  local result = rows(M.deps.config.get("quow_db"), queries.build_shop_query(room_id))
  if not result then
    return
  end
  if #result == 0 then
    print(a("gray", "[hex] nothing listed for room " .. room_id))
    return
  end
  for _, fields in ipairs(result) do
    print(a("bold", util.trim(fields[1])) .. a("gray", "  " .. fields[2]))
  end
end

local function cmd_where()
  local room = M.deps.room
  if not room.id then
    print(a("gray", "[hex] no room info yet (GMCP not received?)"))
    return
  end
  print(a("bold", "room: ") .. (room.name or "?") .. a("gray", "  id " .. room.id))
  local detail = rows(M.deps.config.get("rooms_db"), queries.build_where_query(room.id))
  if detail and detail[1] then
    local name, area, terrain, note = detail[1][1], detail[1][2], detail[1][3], detail[1][4]
    print(a("gray", "map:  ") .. name .. (area ~= "" and a("cyan", "  " .. area) or "") .. (terrain ~= "" and a("gray", "  " .. terrain) or ""))
    if note and note ~= "" then
      print(a("gray", "note: ") .. note)
    end
  else
    print(a("gray", "map:  not in the Hex room database (identified rooms only)"))
  end
  local zone = rows(M.deps.config.get("quow_db"), queries.build_zone_query(room.id))
  if zone and zone[1] then
    print(a("gray", "quow: ") .. queries.zone_name(zone[1][1]))
  end
end

local function cmd_show_map(which)
  local text = which == "wmap" and M.deps.maps.written or M.deps.maps.ascii
  if not text or text == "" then
    print(a("gray", "[hex] no " .. (which == "wmap" and "written map" or "room map") .. " received yet"))
    return
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    print(line)
  end
end

function M.setup(deps)
  M.deps = deps

  alias.add("^item\\s+(.+)$", function(matches)
    cmd_item(matches[2])
  end)
  alias.add("^items\\s+(.+)$", function(matches)
    cmd_item_sources(matches[2])
  end)
  alias.add("^npc\\s+(.+)$", function(matches)
    cmd_npc(matches[2])
  end)
  alias.add("^shop\\s*(.*)$", function(matches)
    cmd_shop(matches[2])
  end)
  alias.add("^where$", function()
    cmd_where()
  end)
  alias.add("^wmap$", function()
    cmd_show_map("wmap")
  end)
  alias.add("^dwmap$", function()
    cmd_show_map("dwmap")
  end)
  alias.add("^hexprobe$", function()
    local on = deps.gmcp.probe()
    print(a("gray", "[hex] gmcp echo " .. (on and "ON" or "OFF")))
  end)
  alias.add("^hexset\\s+(\\S+)\\s+(.+)$", function(matches)
    local value = deps.config.set(matches[2], matches[3])
    print(a("gray", "[hex] " .. matches[2] .. " = " .. tostring(value)))
  end)
  alias.add("^hexhelp$", function()
    print(a("bold", "Hex commands") .. a("gray", "  (data: Quow db + Hex rooms.db)"))
    print("  /item [exact] <search>   /items [sold|free|loot] <search>")
    print("  /npc <search>            /shop [room id]")
    print("  /where                   /wmap, /dwmap")
    print("  /hexprobe (gmcp echo)    /hexset <key> <value>")
  end)
end

return M
