-- hex_queries.lua: Quow database query builders, ported from tt_dw
-- (scripts/quow/items.tin, npc.tin, shop.tin and sql/functions.tin). Pure
-- code: builders return SQL strings, execution happens in hex_commands via
-- blightmud's core.exec, exactly like tt_dw shelling out to sqlite3.
--
-- Conventions kept from tt_dw:
--   * '*' -> '%', '?' -> '_', '^' anchors the start, '$' anchors the end
--   * comma-separated terms each add an OR clause, empty terms are dropped
--   * ORDER BY REPLACE(name, 'an ', 'a ') for article-insensitive ordering
--   * single quotes doubled, '|' stripped (it is the result-field separator)
local util = require("src.hex_util")

local M = {}

-- Zone names by map_id, ported verbatim from tt_dw's quow.tin
-- ($quow[map_names], sourced from QuowMinimap.xml).
M.ZONES = {
  [1] = "Ankh-Morpork",
  [2] = "AM Assassins",
  [3] = "AM Buildings",
  [4] = "AM Cruets",
  [5] = "AM Docks",
  [6] = "AM Guilds",
  [7] = "AM Isle of Gods",
  [8] = "Shades Maze",
  [9] = "Temple of Small Gods",
  [10] = "AM Temples",
  [11] = "AM Thieves",
  [12] = "Unseen University",
  [13] = "AM Warriors",
  [14] = "Pseudopolis Watch House",
  [15] = "Magpyr's Castle",
  [16] = "Bois",
  [17] = "Bes Pelargic",
  [18] = "BP Buildings",
  [19] = "BP Estates",
  [20] = "BP Wizards",
  [21] = "Brown Islands",
  [22] = "Death's Domain",
  [23] = "Djelibeybi",
  [24] = "IIL - DJB Wizards",
  [25] = "Ephebe",
  [26] = "Ephebe Underdocks",
  [27] = "Genua",
  [28] = "Genua Sewers",
  [29] = "GRFLX Caves",
  [30] = "Hashishim Caves",
  [31] = "Klatch Region",
  [32] = "Lancre Region",
  [33] = "Mano Rossa",
  [34] = "Monks of Cool",
  [35] = "Netherworld",
  [37] = "Pumpkin Town",
  [38] = "Ramtops Regions",
  [39] = "Sto-Lat",
  [40] = "Academy of Artificers",
  [41] = "Cabbage Warehouse",
  [42] = "AoA Library",
  [43] = "Sto-Lat Sewers",
  [44] = "Sprite Caves",
  [45] = "Sto Plains Region",
  [46] = "Uberwald Region",
  [47] = "UU Library",
  [48] = "Klatchian Farmsteads",
  [49] = "CTF Arena",
  [50] = "PK Arena",
  [51] = "AM Post Office",
  [52] = "Ninja Guild",
  [53] = "The Travelling Shop",
  [54] = "Slippery Hollow",
  [55] = "House of Magic - Creel",
  [56] = "Special Areas",
  [57] = "Skund Wolf Trail",
  [58] = "Medina",
  [59] = "Copperhead",
  [60] = "The Citadel",
  [61] = "AM Fools' Guild",
  [62] = "Thursday's Island",
  [63] = "SS Unsinkable",
  [64] = "Passage Rooms",
  [99] = "Terrains",
}

function M.zone_name(map_id)
  return M.ZONES[tonumber(map_id)] or "<Unknown>"
end

-- One WHERE condition for an item search term, ported from tt_dw's
-- item_sql_test including the desc:/app:/mat:/sheat: field prefixes.
-- exact=true switches to equality (tt_dw's 'exact' modifier).
function M.item_test(term, exact)
  local kind = "name"
  local search = term
  local prefix = term:match("^(%a+):%s*(.+)$")
  if prefix then
    local p = prefix:lower()
    if p:sub(1, 4) == "desc" then
      kind, search = "describe", term:match("^%a+:%s*(.+)$")
    elseif p:sub(1, 3) == "app" then
      kind, search = "appraise", term:match("^%a+:%s*(.+)$")
    elseif p:sub(1, 3) == "mat" then
      kind, search = "material", term:match("^%a+:%s*(.+)$")
    elseif p:sub(1, 5) == "sheat" or p:sub(1, 4) == "scab" then
      kind, search = "scabbard", term:match("^%a+:%s*(.+)$")
    end
  end

  if exact then
    return "(i.item_name = '" .. util.sql_escape(search) .. "')"
  end

  local like = util.glob_wildcards(util.glob_to_like(search))
  if kind == "describe" then
    return "(i.description LIKE '" .. like .. "')"
  elseif kind == "appraise" then
    return "(i.appraise_text LIKE '" .. like .. "')"
  elseif kind == "material" then
    return "(i.appraise_text LIKE 'it is made of " .. like .. "')"
  elseif kind == "scabbard" then
    return ("(i.item_name LIKE '%s scabbard' OR i.description LIKE '%%it could sheathe a %s')"):format(like, like)
  end
  return "(i.item_name LIKE '" .. like .. "')"
end

-- /item: ported from tt_dw's item_query.
function M.build_item_query(input, exact)
  local where = " (0"
  for _, term in ipairs(util.split_terms(input)) do
    where = where .. " OR " .. M.item_test(term, exact)
  end
  where = where .. " )"
  return "SELECT item_name || '~' || dollar_value || '~' || description || '~' || appraise_text || '~' || weight AS result "
    .. "FROM items i WHERE"
    .. where
    .. " ORDER BY REPLACE (item_name, 'an ', 'a ') LIMIT 31;"
end

-- /npc: ported from tt_dw's npc query; 'room:<identifier>' narrows to one
-- room. Adds the room short name via a join (tt_dw resolves it through its
-- mapper instead).
function M.build_npc_query(input)
  local room_id = input:match("^room:%s*(%S+)")
  local search = input
  if room_id then
    -- everything after the room: prefix token
    search = input:match("^room:%s*%S+%s+(.+)$") or ""
  end
  local conds = {}
  if room_id then
    conds[#conds + 1] = "n.room_id = '" .. util.sql_escape(room_id) .. "'"
  end
  for _, term in ipairs(util.split_terms(search)) do
    local like = util.sql_escape(util.glob_wildcards(util.glob_to_like(term)))
    conds[#conds + 1] = "(n.npc_name LIKE '" .. like .. "')"
  end
  if #conds == 0 then
    conds[1] = "(1)"
  end
  return "SELECT n.npc_name || '~' || n.room_id || '~' || COALESCE(r.room_short, '') AS result "
    .. "FROM npc_info n LEFT JOIN rooms r ON r.room_id = n.room_id WHERE "
    .. table.concat(conds, " AND ")
    .. " ORDER BY REPLACE (npc_name, 'an ', 'a ') LIMIT 31;"
end

-- /shop: everything sold in one room (shops and NPC vendors), ported from
-- tt_dw's shop query union.
function M.build_shop_query(room_id)
  local id = util.sql_escape(room_id)
  return "SELECT result FROM ( "
    .. "SELECT si.item_name || '~' || si.sale_price AS result FROM shop_items si "
    .. "WHERE si.room_id = '"
    .. id
    .. "' AND si.sale_price NOT IN ('found','loot','') "
    .. "UNION "
    .. "SELECT ni.item_name || '~' || ni.sale_price AS result FROM npc_items ni "
    .. "JOIN npc_info n ON n.npc_id = ni.npc_id "
    .. "WHERE n.room_id = '"
    .. id
    .. "' AND ni.sale_price NOT IN ('found','loot','') "
    .. ") ORDER BY result LIMIT 61;"
end

-- /items: where an item comes from. flag is nil, "sold", "free" or "loot",
-- ported from tt_dw's item_source_query price filters; the Shonky Shop is
-- excluded from the sold filter (it sells everything, pure noise).
function M.build_item_sources_query(input, flag)
  local like = util.sql_escape(util.glob_wildcards(util.glob_to_like(util.trim(input))))
  local conds = { "u.iname LIKE '" .. like .. "'" }
  if flag == "sold" then
    conds[#conds + 1] = "u.price GLOB '*[0-9]*'"
    conds[#conds + 1] = "u.room_id NOT IN (SELECT room_id FROM rooms WHERE room_short = 'Shonky Shop')"
  elseif flag == "free" then
    conds[#conds + 1] = "u.price NOT GLOB '*[0-9]*' AND u.price != ''"
  elseif flag == "loot" then
    conds[#conds + 1] = "u.price = 'loot'"
  end
  -- the union gets an explicit alias: a bare room_id here was ambiguous
  -- against r.room_id after the join and broke every /items sold query
  -- (found by the synthetic goldens)
  return "SELECT kind || '~' || COALESCE(seller, '') || '~' || COALESCE(price, '') || '~' || COALESCE(r.room_short, '') AS result "
    .. "FROM ( "
    .. "SELECT 'shop' AS kind, si.room_id AS room_id, si.sale_price AS price, si.item_name AS iname, '' AS seller FROM shop_items si "
    .. "UNION ALL "
    .. "SELECT 'npc' AS kind, n.room_id AS room_id, ni.sale_price AS price, ni.item_name AS iname, n.npc_name AS seller "
    .. "FROM npc_items ni JOIN npc_info n ON n.npc_id = ni.npc_id "
    .. "UNION ALL "
    .. "SELECT 'found' AS kind, '' AS room_id, i.special_find_note AS price, i.item_name AS iname, '' AS seller "
    .. "FROM items i WHERE i.special_find_note != '' "
    .. ") AS u LEFT JOIN rooms r ON r.room_id = u.room_id WHERE "
    .. table.concat(conds, " AND ")
    .. " ORDER BY result LIMIT 41;"
end

-- Room detail lookup in Hex's own rooms.db (built by tools/convert_map.py).
function M.build_where_query(room_id)
  return "SELECT name || '~' || area || '~' || terrain || '~' || note FROM rooms WHERE room_id = '"
    .. util.sql_escape(room_id)
    .. "' LIMIT 1;"
end

-- Quow zone lookup for a room identifier (map_id -> zone name).
function M.build_zone_query(room_id)
  return "SELECT map_id FROM rooms WHERE room_id = '" .. util.sql_escape(room_id) .. "' LIMIT 1;"
end

return M
