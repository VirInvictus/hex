-- hex_targets.lua: /path and /near target resolution (design:
-- docs/phase-2-mapper.md §3, ported from tt_dw's find.tin:27-61).
-- Pure module: search-grammar parsing and SQL builders; the caller executes
-- the queries through core.exec and keeps the session candidate list that
-- "#<n>" references. Name searches stay 40-hex-identified-only (the 29,631
-- unidentified rooms would flood every result); direct identifier lookup
-- still accepts shared-instance ids so /path can refuse them with a clear
-- message instead of silently searching.
local util = require("src.hex_util")

local M = {}

-- The travelling shop moves around the map; tt_dw's find.tin:371-374 refuses
-- to route to it, and so does Hex.
M.TSHOP_ID = "04fd563a7f8d4ccfc83661bbec60971ac9aa72ca"

-- Candidate cap for name searches (tt_dw's find lists all matches; a cap
-- keeps a one-word search from printing a hundred Terrains road tiles).
M.NAME_LIMIT = 15

function M.is_room_id(s)
  return type(s) == "string" and #s == 40 and s:match("^[0-9a-f]+$") ~= nil
end

-- Parse one target expression into an ordered plan of resolution steps
-- (docs §3: identifier direct lookup, #n reference, @area origin, name
-- search, bare vnum). Returns { steps = {...} } or nil for empty input.
function M.parse(input)
  local s = util.trim(tostring(input or ""))
  if s == "" then
    return nil
  end
  local ref = s:match("^#(%d+)$")
  if ref then
    return { steps = { { kind = "ref", n = tonumber(ref) } } }
  end
  local steps = {}
  local area, rest = s:match("^@(%S+)%s+(.+)$")
  if not area then
    area = s:match("^@(%S+)$")
  end
  if area then
    if rest then
      -- @area scoped name search; the origin lookup still runs first (it is
      -- the area's canonical "start here" room and often what was meant)
      steps[#steps + 1] = { kind = "origin", area = area }
      steps[#steps + 1] = { kind = "name", term = util.trim(rest), area = area }
    else
      steps[#steps + 1] = { kind = "origin", area = area }
    end
    return { steps = steps }
  end
  -- a whitespace-free, wildcard-free term is worth a direct room_id probe
  -- before the name search (40-hex ids, and shared-instance names like
  -- UULibrary, land here)
  if not s:find("%s", 1, true) and not s:find("[%*%?]") then
    steps[#steps + 1] = { kind = "id", term = s }
  end
  steps[#steps + 1] = { kind = "name", term = s, area = nil }
  local vnum = s:match("^(%d+)$")
  if vnum then
    steps[#steps + 1] = { kind = "vnum", n = tonumber(vnum) }
  end
  return { steps = steps }
end

-- Candidate projection used by every builder: vnum|name|area|room_id.
local CAND = "vnum || '|' || name || '|' || area || '|' || room_id"

-- identified 40-hex rooms only (instances excluded: one id, hundreds of
-- identical rooms)
local IDENTIFIED = "room_id GLOB '[0-9a-f]*' AND room_id NOT GLOB '*[^0-9a-f]*'"

function M.build_id_query(term)
  return ("SELECT %s FROM rooms WHERE room_id = '%s' LIMIT 1"):format(CAND, util.sql_escape(term))
end

function M.build_origin_query(area)
  -- a case-insensitive prefix covers "@am" for "Ankh-Morpork" (SQLite LIKE
  -- is ASCII case-insensitive)
  return ("SELECT area || '|' || room_name FROM origins WHERE area LIKE '%s%%' ORDER BY area LIMIT 1")
    :format(util.sql_escape(util.glob_wildcards(area)))
end

function M.build_origin_room_query(room_name, area)
  return ("SELECT %s FROM rooms WHERE name = '%s' AND area LIKE '%s%%' AND %s LIMIT 1")
    :format(CAND, util.sql_escape(room_name), util.sql_escape(util.glob_wildcards(area)), IDENTIFIED)
end

function M.build_name_query(term, area)
  local pattern = util.glob_to_like(util.glob_wildcards(util.trim(term)))
  local sql = ("SELECT %s FROM rooms WHERE %s AND name LIKE '%s'"):format(CAND, IDENTIFIED, util.sql_escape(pattern))
  if area and area ~= "" then
    sql = sql .. (" AND area LIKE '%s'"):format(util.sql_escape(util.glob_to_like(util.glob_wildcards(area))))
  end
  return sql .. (" ORDER BY name LIMIT %d"):format(M.NAME_LIMIT)
end

function M.build_vnum_query(n)
  return ("SELECT %s FROM rooms WHERE vnum = %d AND %s LIMIT 1"):format(CAND, tonumber(n) or 0, IDENTIFIED)
end

return M
