-- hex_util.lua: pure helpers shared across Hex.
-- Must stay free of blightmud globals so the unit tests can load it with a
-- plain Lua interpreter. Module names are hex_-prefixed because blightmud's
-- require namespace is global across plugins.
local M = {}

-- ANSI escapes (blightmud exposes C_* globals too, but the suite renders from
-- pure code and those globals only exist inside the client).
M.ansi = {
  reset = "\27[0m",
  bold = "\27[1m",
  red = "\27[31m",
  green = "\27[32m",
  yellow = "\27[33m",
  magenta = "\27[35m",
  cyan = "\27[36m",
  gray = "\27[90m",
  white = "\27[37m",
}

-- Strip CSI sequences (ESC [ params final-letter): the colour codes the MUD
-- embeds in room.map payloads. Covers \x1b[39;49m, \x1b[0m, \x1b[31m and
-- other final letters, not just 'm'.
function M.strip_ansi(s)
  return (tostring(s):gsub("\27%[[%d;]*%a", ""))
end

-- SQL string literal escape, matching tt_dw's @sql_escape: double single
-- quotes and strip pipes (pipes are the result-field separator).
function M.sql_escape(s)
  return (tostring(s):gsub("'", "''"):gsub("|", ""))
end

-- Translate a search term into a LIKE fragment the way tt_dw's item_sql_test
-- does: '^' anchors the start (no leading %), '$' anchors the end (no
-- trailing %), anything else is wrapped. The '*' and '?' glob wildcards are
-- converted separately (see glob_wildcards) to keep parity with tt_dw's
-- replace-on-the-whole-clause ordering.
function M.glob_to_like(term)
  local t = tostring(term)
  local anchor_start = t:sub(1, 1) == "^"
  if anchor_start then
    t = t:sub(2)
  end
  local anchor_end = #t > 0 and t:sub(-1) == "$"
  if anchor_end then
    t = t:sub(1, -2)
  end
  if not anchor_start then
    t = "%" .. t
  end
  if not anchor_end then
    t = t .. "%"
  end
  return t
end

-- Convert tt_dw-style glob wildcards to SQL LIKE wildcards.
function M.glob_wildcards(s)
  return (s:gsub("%*", "%%"):gsub("%?", "_"))
end

-- Split a comma-separated search into trimmed, non-empty terms (tt_dw drops
-- stray commas the same way).
function M.split_terms(input)
  local terms = {}
  -- Lua 5.5 makes loop control variables read-only; trim into a local
  for raw_term in tostring(input):gmatch("[^,]+") do
    local term = M.trim(raw_term)
    if term ~= "" then
      terms[#terms + 1] = term
    end
  end
  return terms
end

function M.trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 1234567 -> "1,234,567" (xp-style grouping, as tt_dw prompts show).
-- Accepts already-grouped strings ("12,345") by stripping commas first.
function M.comma(n)
  n = tostring(n or 0):gsub(",", "")
  local number = math.floor(tonumber(n) or 0)
  local formatted = tostring(number):reverse():gsub("(%d%d%d)", "%1,"):gsub(",$", ""):reverse()
  return formatted
end

-- Split on literal pipes, keeping empty fields (a trailing "|" means the
-- last column is present-but-empty, and callers nil-guard anyway).
function M.split_pipe(line)
  local fields = {}
  local start = 1
  while true do
    local sep = line:find("|", start, true)
    if not sep then
      fields[#fields + 1] = line:sub(start)
      break
    end
    fields[#fields + 1] = line:sub(start, sep - 1)
    start = sep + 1
  end
  return fields
end

-- Parse sqlite3 CLI output: rows separated by newlines, fields by '|'.
function M.parse_rows(text)
  local rows = {}
  if not text or text == "" then
    return rows
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      rows[#rows + 1] = M.split_pipe(line)
    end
  end
  return rows
end

-- Greedy word wrap at width (description rendering).
function M.wrap(text, width)
  local lines = {}
  local current = ""
  for word in tostring(text):gmatch("%S+") do
    if current == "" then
      current = word
    elseif #current + 1 + #word <= width then
      current = current .. " " .. word
    else
      lines[#lines + 1] = current
      current = word
    end
  end
  if current ~= "" then
    lines[#lines + 1] = current
  end
  return lines
end

-- Clamp ratio to 0..1.
function M.ratio(cur, max)
  cur = tonumber(cur) or 0
  max = tonumber(max) or 0
  if max <= 0 then
    return 0
  end
  local r = cur / max
  if r < 0 then
    return 0
  elseif r > 1 then
    return 1
  end
  return r
end

-- Bar as "[####----]" using Unicode blocks; color selection is the caller's.
function M.bar(width, r)
  local filled = math.floor(r * width + 0.5)
  if filled > width then
    filled = width
  end
  return "[" .. string.rep("\u{2588}", filled) .. string.rep("\u{2500}", width - filled) .. "]"
end

-- HP color thresholds (simplified from tt_dw's five bands): >=90% green,
-- >=50% yellow, >=20% magenta, else red.
M.hp_bands = { { 0.9, "green" }, { 0.5, "yellow" }, { 0.2, "magenta" }, { 0, "red" } }

function M.hp_color_name(r)
  for _, band in ipairs(M.hp_bands) do
    if r >= band[1] then
      return band[2]
    end
  end
  return "red"
end

return M
