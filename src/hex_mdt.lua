-- hex_mdt.lua: written-map people tracker (design: docs/phase-5-room.md §2;
-- ported from tt_dw's map/mdt.tin, map/mdt_hunt.tin and the Quow default
-- match rows in sql/migrations/004_create_mdt.tin).
--
-- GMCP room.writtenmap delivers per room push what tt_dw scrapes off the
-- screen, so Hex needs neither of tt_dw's capture paths: the parser runs on
-- the decoded payload (main.lua feeds on_writtenmap). Pure core throughout;
-- the only blightmud-bound calls are core.exec (sqlite) in the runtime glue
-- and print() for hunt alerts.
--
-- Matching semantics (documented deviations):
--   * user rows and hunting rows match as plain case-insensitive substrings.
--     tt_dw stores tintin patterns ("/mdt add can be a regex"); the Rust
--     regex engine is not reachable from pure Lua, so plain text only.
--   * the Quow default rows use tintin/PCRE constructs (lookahead, atomic
--     groups). They port as structured rules with the same intent:
--     find / exact / startswith / endswith / exclude-endswith /
--     prefix+noun / adjective+noun. Every row is ported, none dropped.
--   * precedence: hunting -> user rows -> defaults (tt_dw merges them into
--     one table; Hex keeps defaults in code so user rows can shadow them).
--   * " and | are | is " -> ", " replaces every occurrence (tt_dw's single
--     #replace would strand mid-line verbs as junk entities).
--   * hunting targets live in mdt_match as category='hunting' rows (the
--     design's merge of tt_dw's separate mdt_hunt.tin); tt_dw's main-feed
--     #high highlight is out of scope.
--   * tt_dw's pet rule strips a CHAIN of pet adverbs ("old black rat" ->
--     "rat"); Hex strips one prefix per pass, so a chained survivor that is
--     itself not a global adverb stays one word longer ("black rat").
--   * category overrides are read for ('_default', alt); tt_dw as shipped
--     reads ('_shared', alt) while WRITING _default, so its default-scope
--     disables never reload. Hex applying them is the intended behavior and
--     an improvement over the porting source.
--   * the fang-family rows need a token before the surname per the source
--     ("Han Sung bodyguard" matches, bare "sung bodyguard" does not); the
--     real Bes Pelargic wire shape is still capture-pending.
local util = require("src.hex_util")
local mdtdata = require("src.hex_mdtdata")

local M = {}

M.deps = {}

-- state: user matches + category overrides (loaded from hex.db), the latest
-- processed room list, and the hunt-alert seen list
M.state = { matches = {}, categories = {}, rooms = {}, seen = {} }

M.SEEN_TTL = 600 -- tt_dw's 10-minute alert expiry

-- --- word data (ports of tt_dw's util/numbers.tin and map/util.tin) ------

M.numbers = {
  "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
  "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
  "eighteen", "nineteen",
}

M.decades = { "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety" }

for i, w in ipairs(M.numbers) do
  M.numbers[w] = i
end
for i, w in ipairs(M.decades) do
  M.decades[w] = 10 + i * 10
end

-- dir_short: full direction words -> shorts (compass 8 + up/down + the
-- SS Unsinkable deck directions; "?" means "not a direction")
M.dir_short = {
  north = "n", east = "e", south = "s", west = "w",
  northeast = "ne", northwest = "nw", southeast = "se", southwest = "sw",
  up = "u", down = "d",
  ["fore starboard"] = "fs", ["aft starboard"] = "as",
  ["aft port"] = "ap", ["fore port"] = "fp",
  fore = "f", starboard = "s", aft = "a", port = "p",
}

-- dir_arrow glyphs for the arrow column
M.dir_glyph = {
  n = "\u{2191}", e = "\u{2192}", s = "\u{2193}", w = "\u{2190}",
  ne = "\u{2197}", nw = "\u{2196}", se = "\u{2198}", sw = "\u{2199}",
  u = "\u{25b2}", d = "\u{25bc}",
}

M.colors = mdtdata.colors
local color_set = {}
for _, c in ipairs(M.colors) do
  color_set[c] = true
end

-- tt_dw colour names -> hex_util.ansi keys (the suite's nine-color palette)
local tt_color_key = {
  green = "green", orange = "yellow", red = "red", magenta = "magenta",
  purple = "magenta", pink = "magenta", blue = "cyan",
}

-- --- the adverbs list: split the verbatim alternation bracket-aware and
-- expand its seven pattern forms (mdt_adverbs.tin) -------------------------

local function split_alternation(raw)
  local entries = {}
  local depth = 0
  local cur = {}
  for i = 1, #raw do
    local ch = raw:sub(i, i)
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
    end
    if ch == "|" and depth == 0 then
      entries[#entries + 1] = table.concat(cur)
      cur = {}
    else
      cur[#cur + 1] = ch
    end
  end
  entries[#entries + 1] = table.concat(cur)
  local out = {}
  for _, e in ipairs(entries) do
    if e ~= "" then
      out[#out + 1] = e
    end
  end
  return out
end

-- the seven pattern forms present in the source; everything else is a plain
-- word. The two open-ended forms (\w+-(looking|...) and well-\w+) cannot
-- expand to words; they stay as Lua patterns for the strip pass.
local plain_extras = {} -- populated below
local adverb_patterns = {
  "^%w+[%-%s]looking%s+",
  "^%w+[%-%s]coloured%s+",
  "^%w+[%-%s]covered%s+",
  "^%w+[%-%s]eyed%s+",
  "^%w+[%-%s]haired%s+",
  "^well[%-%s]%w+%s+",
  -- the pet-strip moon family ("harvest moon", "full-moon"; mdt.tin:728)
  "^%w+[%-%s]moon%s+",
  "^%w+[%-%s]%w+[%-%s]moon%s+",
  -- tt_dw's catch-all pet adverb ("intelligent old black rat" -> "rat")
  "^intelligent%s.+%s+",
}

local plain, patterned = {}, {}
for _, e in ipairs(split_alternation(mdtdata.adverbs)) do
  if e:find("[()$]") then
    if e == "(?:battle-)weary" then
      plain_extras[#plain_extras + 1] = "weary"
      plain_extras[#plain_extras + 1] = "battle-weary"
    elseif e == "money( |-)grabbing" then
      plain_extras[#plain_extras + 1] = "money-grabbing"
      plain_extras[#plain_extras + 1] = "money grabbing"
    elseif e:find("^%(%a+|washed%-out%) %($mdt_colors%)$") then
      for _, c in ipairs(M.colors) do
        plain_extras[#plain_extras + 1] = "deep " .. c
        plain_extras[#plain_extras + 1] = "washed-out " .. c
      end
    elseif e:find("^%($mdt_colors%) and %($mdt_colors%)$") then
      -- colour-pair adverbs ("black and white"): expanded as "a-b"
      for _, c1 in ipairs(M.colors) do
        for _, c2 in ipairs(M.colors) do
          plain_extras[#plain_extras + 1] = c1 .. "-" .. c2
        end
      end
    elseif e:find("^%($mdt_colors%)%-%($mdt_colors%)$") then
      for _, c1 in ipairs(M.colors) do
        for _, c2 in ipairs(M.colors) do
          plain_extras[#plain_extras + 1] = c1 .. "-" .. c2
        end
      end
    elseif e:find("looking|coloured|covered|eyed|haired", 1, true) or e:find("well( |-)", 1, true) then
      -- the two open-ended forms; covered by the Lua strip patterns below
    else
      patterned[#patterned + 1] = e -- unknown pattern form; kept for tests
    end
  else
    plain[#plain + 1] = e
  end
end
for _, w in ipairs(plain_extras) do
  plain[#plain + 1] = w
end
-- the cleanup strip runs over $mdt_colors|$mdt_adverbs (mdt.tin:773), so
-- the 16 single colours are strippable adverbs too ("brown rat" -> "rat")
for _, c in ipairs(M.colors) do
  plain[#plain + 1] = c
end

-- longest-first so "bay dun" wins over "bay" (tt_dw's alternation order is
-- longest-match-at-leftmost in PCRE; a sorted list reproduces the intent)
table.sort(plain, function(a, b)
  return #a > #b
end)
M.adverbs = plain
M.adverb_patterns = adverb_patterns
M.unknown_adverb_patterns = patterned -- must stay empty; asserted in tests

-- --- small helpers ---------------------------------------------------------

local function lc(s)
  return tostring(s):lower()
end

-- tintin #replace replaces the first occurrence; entity strings are short
-- enough that the difference from gsub is nil, but stay faithful
local function replace_once(s, from, to, plain_find)
  local at = s:find(from, 1, plain_find ~= false)
  if not at then
    return s
  end
  return s:sub(1, at - 1) .. to .. s:sub(at + #from)
end

-- container units whose plural is "Xs of" (tt_dw's {bag|chunk|...} group;
-- Lua patterns have no alternation, so capture + membership instead)
local container_units = { bag = true, chunk = true, game = true, packet = true, pair = true, piece = true, set = true, side = true, tube = true }

-- Strip ARTicles (tt_dw's @sart, strings.tin:448)
function M.sart(s)
  s = tostring(s)
  s = s:gsub("^[Aa] ", ""):gsub("^[Aa]n ", ""):gsub("^[Tt]he ", "")
  local one = s:match("^one of the (.*)s$") or s:match("^one of your (.*)s$")
  if one then
    return one
  end
  return s
end

-- singularize (port of strings.tin:226): pre-step "men$"->"man", then the
-- chain stops at the first match (tt_dw's no-semicolon chain semantics)
function M.singularize(s)
  s = tostring(s)
  if s == "moose" or s == "ronin" or s == "sheep" then
    return s
  end
  if s == "geese" then return "goose" end
  if s == "grflxen" then return "grflx" end
  if s == "mains gauches" then return "main gauche" end
  if s == "petits fours" then return "petit fours" end

  local stem = s:match("^(.*)men$")
  local single = stem and (stem .. "man") or s -- pre-step appends "man"

  -- chain on the ORIGINAL string; first match wins
  local a, b
  a, b = s:match("^(.*) with (.*) on them$")
  if a then return M.singularize(a) .. " with " .. b .. " on" end
  local unit
  a, unit, b = s:match("^(.*)%f[%a](%a+)s of (.*)$")
  if a and container_units[unit] then return a .. unit .. " of " .. b end
  a, b = s:match("^(.*)%f[%a]flags with (.*)$")
  if a then return a .. "flag with " .. b end
  a = s:match("^(.*)auloi$")
  if a then return a .. "aulos" end
  a, b = s:match("^(.*)loaves of (.*)$")
  if a then return a .. "loaf of " .. b end
  a = s:match("^(.*)harness(es?)$")
  if a then return a .. "harness" end
  a = s:match("^(.+%sp)ies$")
  if a then return a .. "ie" end
  a = s:match("^(.*[bcdfghjklmnpqrstvwxz])ies$")
  if a then return a .. "y" end
  a = s:match("^(.*)lves$")
  if a then return a .. "lf" end
  a = s:match("^(.*)aves$")
  if a then return a .. "ave" end
  a = s:match("^(.*)eves$")
  if a then return a .. "ef" end
  a = s:match("^(.*)ves$")
  if a then return a .. "fe" end
  a = s:match("^(.*ch)es$")
  if a then return a end
  a = s:match("^(.*sh)es$")
  if a then return a end
  a = s:match("^(.*)sses$")
  if a then return a .. "ss" end
  a = s:match("^(.*)ises$")
  if a then return a .. "is" end
  a = s:match("^(.*)ses$")
  if a then return a .. "se" end
  a = s:match("^(.*%f[%a]axe)s$")
  if a then return a end
  a = s:match("^(.*[xs])es$")
  if a then return a end
  a = s:match("^(.*)s$")
  if a then return a end
  a = s:match("^(.*)children$")
  if a then return a .. "child" end
  return single
end

-- pluralize (port of strings.tin:185) for the display column
function M.pluralize(s)
  s = tostring(s)
  if s == "moose" or s == "ronin" or s == "sheep" then
    return s
  end
  if s == "goose" then return "geese" end
  if s == "grflx" then return "grflxen" end
  if s == "main gauche" then return "mains gauches" end
  if s == "petit fours" then return "petits fours" end

  local a, b
  a, b = s:match("^(.*) with (.*) on$")
  if a then return M.pluralize(a) .. " with " .. b .. " on them" end
  local unit
  a, unit, b = s:match("^(.*)%f[%a](%a+) of (.*)$")
  if a and container_units[unit] then return a .. unit .. "s of " .. b end
  a, b = s:match("^(.*)%f[%a]flag with (.*)$")
  if a then return a .. "flags with " .. b end
  a = s:match("^(.*)aulos$")
  if a then return a .. "auloi" end
  a, b = s:match("^(.*)loaf of (.*)$")
  if a then return a .. "loaves of " .. b end
  a = s:match("^(.*)man$")
  if a then return a .. "men" end
  a = s:match("^(.*)harness$")
  if a then return a .. "harnesses" end
  a = s:match("^(.*[sx])$")
  if a then return a .. "es" end
  a = s:match("^(.*[cs]h)$")
  if a then return a .. "es" end
  a = s:match("^(.*)fe?$")
  if a then return a .. "ves" end
  a = s:match("^(.*p)ie$")
  if a then return a .. "ies" end
  a = s:match("^(.*[bcdfghjklmnpqrstvwxz])y$")
  if a then return a .. "ies" end
  a = s:match("^(.*)child")
  if a then return s .. "ren" end
  return s .. "s"
end

-- word/decimal numbers to digits (<100; port of numbers.tin:225)
function M.parse_number(word)
  word = lc(word)
  if word:match("^%-?%d+$") then
    return tonumber(word)
  end
  if M.numbers[word] then
    return M.numbers[word]
  end
  local decade, unit = word:match("^(%a+)%-(%a+)$")
  if decade and M.decades[decade] and M.numbers[unit] then
    return M.decades[decade] + M.numbers[unit]
  end
  if M.decades[word] then
    return M.decades[word]
  end
  return nil
end

-- is_number accepts digits AND word numbers (numbers.tin:306)
function M.is_number(word)
  return M.parse_number(word) ~= nil
end

-- --- the parser (port of @parse_mdt, mdt.tin:593-674) ----------------------

local door_prefixes = { "doors ", "a door ", "exits ", "an exit ", "a hard to see through exit " }

local function is_door_segment(seg)
  local low = lc(seg)
  for _, p in ipairs(door_prefixes) do
    if low:sub(1, #p) == p then
      return true
    end
  end
  return false
end

-- normalizations run in tt_dw's order on the whole line
function M.normalize(line)
  line = tostring(line)
  -- "{X}, driver of the {Y} carriage" -> "{Y} carriage driver"
  line = line:gsub("(%u%a+), driver of the ([%w ]+) carriage", "%2 carriage driver")
  -- "{dwarfish|trollish|human} {Y} carriage driver" (no alternation in Lua;
  -- the nationality is a literal here, so the single capture is %1: the %2
  -- from tt_dw's two-group regex raised "invalid capture index" on every
  -- writtenmap that named a nationality'd carriage driver, live 2026-11-08)
  for _, nat in ipairs({ "dwarfish", "trollish", "human" }) do
    line = line:gsub(nat .. " ([%w ]+) carriage driver", "%1 carriage driver")
  end
  -- "a black and white cat" -> "a black-white cat" (mdt colour pairs)
  line = line:gsub(" (%a+) and (%a+) ", function(a, b)
    if color_set[a] and color_set[b] then
      return " " .. a .. "-" .. b .. " "
    end
    return nil
  end)
  line = replace_once(line, " the net dead statue of ", " netdead ")
  -- tt_dw's %i replace; the two-class pattern covers the realistic casings
  line = line:gsub(" [Tt]he [Ll]imit of your vision is ", " the limit of your vision:", 1)
  -- prose to comma list
  line = line:gsub(" and ", ", "):gsub(" are ", ", "):gsub(" is ", ", ")
  return line
end

function M.parse(text)
  local line = M.normalize(text)
  -- explode on ", "
  local segments = {}
  local rest = line
  while true do
    local at = rest:find(", ", 1, true)
    if not at then
      segments[#segments + 1] = rest
      break
    end
    segments[#segments + 1] = rest:sub(1, at - 1)
    rest = rest:sub(at + 2)
  end

  local results = {}
  local entities = {}
  local last_direction = ""
  local last_was_dir = false
  local ignoring_exits = false

  local function flush()
    if #entities > 0 then
      results[#results + 1] = {
        direction = util.trim(last_direction),
        entities = entities,
      }
    end
    entities = {}
    last_direction = ""
    last_was_dir = false
  end

  for _, raw_segment in ipairs(segments) do
    -- Lua 5.5 makes loop control variables read-only; the segment is
    -- progressively rewritten into a local
    local seg = util.trim(raw_segment)
    if seg ~= "" then
      if is_door_segment(seg) then
        ignoring_exits = true
      elseif seg:find("limit of your vision:", 1, true) then
        flush() -- the terminator closes the room group
      else
        local count = 1
        local word = seg:match("^(%w[%w%-]*)")
        if word and M.is_number(word) then
          count = M.parse_number(word)
          seg = seg:sub(#word + 1)
          seg = seg:gsub("^%s+", "")
        end
        seg = seg:gsub("^[Aa]n? ", ""):gsub("^[Tt]he ", "")
        local first = lc(seg:match("^(%w+)") or "")
        local dir = M.dir_short[first]
        if dir then
          if not ignoring_exits then
            last_direction = last_direction .. " " .. tostring(count) .. " " .. dir
            last_was_dir = true
          end
        else
          ignoring_exits = false
          if last_was_dir then
            flush()
          end
          entities[#entities + 1] = tostring(count) .. " " .. seg
        end
      end
    end
  end
  return results
end

-- --- matching (port of @mdt_match; defaults from migration 004) ------------

-- rule kinds: find, exact, startswith, endswith, exclude_endswith,
-- prefix_endswith, adj_endswith. All case-insensitive on the singular form.
local function rule_hit(rule, entity)
  local e = lc(entity)
  local kind = rule.kind
  if kind == "find" then
    return e:find(lc(rule.find), 1, true) ~= nil
  elseif kind == "exact" then
    for _, x in ipairs(rule.exact) do
      if e == lc(x) then
        return true
      end
    end
  elseif kind == "startswith" then
    for _, x in ipairs(rule.startswith) do
      if e:sub(1, #lc(x)) == lc(x) then
        return true
      end
    end
  elseif kind == "endswith" then
    for _, x in ipairs(rule.endswith) do
      if #e >= #x and e:sub(-#x) == lc(x) then
        return true
      end
    end
  elseif kind == "exclude_endswith" then
    if not e:find(lc(rule.exclude), 1, true) then
      for _, x in ipairs(rule.endswith) do
        if #e >= #x and e:sub(-#x) == lc(x) then
          return true
        end
      end
    end
  elseif kind == "contains_endswith" then
    -- the surname is the LAST word before the noun and needs a token
    -- before it: the source rows read "^(.+?) (fang|hong|...) bodyguards?$"
    for _, noun in ipairs(rule.endswith) do
      local tail = " " .. lc(noun)
      if #e > #tail and e:sub(-#tail) == tail then
        local stem = e:sub(1, -#tail - 1)
        for _, c in ipairs(rule.contains) do
          if #stem > #c + 1 and stem:sub(-#c - 1) == " " .. lc(c) then
            return true
          end
        end
      end
    end
  elseif kind == "adj_endswith" then
    for _, noun in ipairs(rule.endswith) do
      local tail = " " .. lc(noun)
      local at = e:find(tail, 1, true)
      while at do
        -- the noun must end the entity unless the row allows trailing text
        if rule.trailing or at + #tail > #e then
          local stem = e:sub(1, at - 1)
          local last = stem:match("(%S+)$")
          if last then
            for _, adj in ipairs(rule.adjectives) do
              if lc(adj) == last then
                return true
              end
            end
          end
        end
        at = e:find(tail, at + 1, true)
      end
    end
  end
  return false
end

-- the Quow defaults, ported row for row from
-- tt_dw sql/migrations/004_create_mdt.tin (colour names mapped to the
-- hex_util.ansi palette; category '' -> nil)
local function fr(find, score, category, color)
  return { rule = { kind = "find", find = find }, score = score, category = category or "", color = tt_color_key[color] }
end

local function en(ends, score, category, color, extra)
  local row = { rule = { kind = "endswith", endswith = ends }, score = score, category = category or "", color = tt_color_key[color] }
  if extra == "no_bureaucrat" then
    row.rule = { kind = "exclude_endswith", endswith = ends, exclude = "bureauc" }
  end
  return row
end

local FANG_SURNAMES = { "fang", "hong", "mcsweeney", "sung", "tang" }
local THUG_ADJECTIVES = { "muscular", "hulking", "smirking", "brooding", "grinning", "tough", "scruffy", "shady", "suspicious", "dashing", "knowing", "scarred", "leering" }

M.defaults = {
  fr("skeleton warrior", 0),
  fr("giant fruitbat", 0),
  fr("fireflies", 0),
  fr("small blue light", 0),
  fr("tortoise", 0),
  fr("cockroach", 0),
  en({ "cloud", "clouds" }, 0),
  en({ "rat", "rats" }, 0, "", "", "no_bureaucrat"),
  en({ "cat", "cats" }, 0),
  en({ "dog", "dogs" }, 0),
  en({ "pigeon", "pigeons" }, 0),
  fr("little old ladies", 2, "", "orange"),
  en({ "banker" }, 5, "loot", "green"),
  en({ "accountant" }, 5, "loot", "green"),
  en({ "lawyer" }, 5, "loot", "green"),
  fr("imperial guard", 8, "", "orange"),
  { rule = { kind = "contains_endswith", contains = FANG_SURNAMES, endswith = { "bodyguard" } }, score = 4, category = "", color = tt_color_key.orange },
  { rule = { kind = "contains_endswith", contains = FANG_SURNAMES, endswith = { "nobleman" } }, score = 10, category = "", color = tt_color_key.magenta },
  { rule = { kind = "contains_endswith", contains = FANG_SURNAMES, endswith = { "thug" } }, score = 3, category = "", color = tt_color_key.orange },
  { rule = { kind = "contains_endswith", contains = FANG_SURNAMES, endswith = { "captain" } }, score = 8, category = "", color = tt_color_key.orange },
  { rule = { kind = "adj_endswith", adjectives = { "diligent", "excellent", "experienced", "injured", "learned", "old", "skilled", "young" }, endswith = { "student" } }, score = 4, category = "", color = tt_color_key.orange },
  fr("palace guard", 8, "", "orange"),
  fr("d'reg", 2),
  fr("recruit", 2, "", "orange"),
  fr("soldier", 4, "", "orange"),
  { rule = { kind = "prefix_endswith", prefix = { "ceremonial" }, endswith = { "guard", "sentry" } }, score = 8, category = "", color = tt_color_key.orange },
  en({ "priest", "priestess" }, 0),
  en({ "wealthy man", "wealthy woman" }, 5, "loot", "green"),
  { rule = { kind = "startswith", startswith = { "rich ambassador" } }, score = 5, category = "loot", color = tt_color_key.green },
  fr("hoplite", 6, "", "orange"),
  { rule = { kind = "adj_endswith", adjectives = { "burly", "hefty", "muscular", "wiry", "sinewy", "tough" }, endswith = { "man" } }, score = 6, category = "", color = tt_color_key.orange },
  fr("citadel guard", 12, "", "orange"),
  fr("vyrt", 10, "", "purple"),
  fr("philosopher", 3),
  fr("knight", 4, "", "orange"),
  { rule = { kind = "adj_endswith", adjectives = { "muscular", "immaculate", "charming", "refined", "well-dressed", "dapper", "elegant" }, endswith = { "gentleman" } }, score = 5, category = "loot", color = tt_color_key.green },
  { rule = { kind = "startswith", startswith = { "baron ", "baroness ", "duchess ", "duke ", "countess ", "count ", "earl ", "marquis ", "lady ", "sir " } }, score = 5, category = "loot", color = tt_color_key.green },
  fr("hunter grflx", 3),
  fr("grflx mentor", 4),
  fr("grflx adolescent", 1),
  fr("grflx worker", 3),
  fr("grflx workleader", 4),
  fr("royal guard", 5, "", "orange"),
  en({ "nobleman", "noblewoman" }, 5, "loot", "green"),
  { rule = { kind = "exact", exact = { "rich man", "rich woman" } }, score = 5, category = "loot", color = tt_color_key.green },
  en({ "courtier" }, 5, "loot", "green"),
  { rule = { kind = "adj_endswith", trailing = true, adjectives = THUG_ADJECTIVES, endswith = { "highwayman", "character", "runaway", "vagrant", "thug", "man", "woman" } }, score = 2, category = "", color = tt_color_key.orange },
  fr("headless horse rider", 10, "", "red"),
  -- the dead-letter delivery targets (category letters)
  fr("berti boggis", 10, "letters", "pink"),
  fr("ryattenoki", 10, "letters", "pink"),
  fr("very reverend khepresh", 10, "letters", "pink"),
  fr("boy willie", 10, "letters", "pink"),
  fr("glod-san", 10, "letters", "pink"),
  fr("laggy-san", 10, "letters", "pink"),
  fr("lon fah lo", 10, "letters", "pink"),
  fr("mad hamish", 10, "letters", "pink"),
  fr("no go wan", 10, "letters", "pink"),
  fr("quisoda", 10, "letters", "pink"),
  fr("ruto of fish", 10, "letters", "pink"),
  fr("shi do gai", 10, "letters", "pink"),
  fr("lap-lip", 10, "letters", "pink"),
  fr("lip-phon lap-top", 10, "letters", "pink"),
  fr("mihk-gran-bohp", 10, "letters", "pink"),
  fr("phos-phor", 10, "letters", "pink"),
  fr("yclept", 10, "letters", "pink"),
  fr("casanunda", 10, "letters", "pink"),
  fr("greig schwitz", 10, "letters", "pink"),
  fr("noobie", 10, "letters", "pink"),
  fr("tfat chick", 10, "letters", "pink"),
  fr("mr cmoho dhblah", 10, "letters", "pink"),
  fr("miss pennie laced", 10, "letters", "pink"),
  fr("tuffy the vampire slayer", 10, "letters", "pink"),
}

-- category enable/disable resolution: the alt's row overrides _default,
-- unset means enabled (port of mdt_category_status; stored statuses are
-- ints 0/1, returned as booleans -- Lua treats 0 as truthy)
function M.category_status(category)
  local c = M.state.categories
  local alt = M.deps.config and M.deps.config.alt and M.deps.config.alt()
  if alt and c[alt] and c[alt][category] ~= nil then
    return c[alt][category] ~= 0
  end
  if c._default and c._default[category] ~= nil then
    return c._default[category] ~= 0
  end
  return true
end

-- match one singular entity (mdt.tin:677-720). First hit wins:
-- hunting -> user rows -> defaults; skips zero the score.
function M.match(entity)
  local low = lc(entity)
  for _, m in ipairs(M.state.matches) do
    if m.category == "hunting" and low:find(lc(m.match), 1, true) then
      return { score = 100, color = "red", alert = true, category = "hunting", show = true }
    end
  end
  local info = { score = 1, color = nil, alert = false, category = "", show = true }
  local matched = false
  for _, m in ipairs(M.state.matches) do
    if m.category ~= "hunting" and M.category_status(m.category) and low:find(lc(m.match), 1, true) then
      info = {
        score = m.score,
        color = m.color and tt_color_key[m.color] or m.color,
        alert = m.alert == 1,
        category = m.category or "",
        show = true,
      }
      matched = true
      break
    end
  end
  if not matched then
    for _, d in ipairs(M.defaults) do
      if M.category_status(d.category) and rule_hit(d.rule, entity) then
        info = { score = d.score, color = d.color, alert = false, category = d.category, show = true }
        break
      end
    end
  end
  -- skips (config data; tt_dw's bat/followers/fnp-cloud runtime vars). The
  -- value must be a Lua list; a stray string (e.g. raw /hexset JSON) would
  -- break ipairs on every push, so degrade to no skips instead.
  local skips = M.deps.config and M.deps.config.get("mdt_skips", {}) or {}
  if type(skips) == "table" then
    for _, skip in ipairs(skips) do
      if low == lc(skip) then
        info.score = 0
        info.show = false
        break
      end
    end
  end
  -- colour clouds carry their colour name ("a red cloud")
  local cword = lc(entity:match(" ([%a%-]+) cloud$") or entity:match("^([%a%-]+) cloud$") or "")
  if cword ~= "" and color_set[cword] then
    info.color = tt_color_key[cword] or info.color
  end
  return info
end

-- --- cleanup (port of @mdt_clean, mdt.tin:723-777) --------------------------

local HORSE_COLORS = {
  "bay dun", "blood bay", "blue roan", "liver chestnut", "red roan", "rose grey",
  "dapple grey", "bay", "black", "brindle", "brown", "buckskin", "chestnut",
  "dark", "dun", "grey", "piebald", "skewbald", "sorrel",
}

local PET_ADVERBS = { "black", "old", "fluffy", "astonished", "giant", "swamp", "tabby" }
local PET_CRITTERS = { "bird", "duck", "raven", "owl", "hawk", "chicken", "truffle pig", "dragon", "goose", "sheep", "rat" }

local function strip_prefix_forms(s, prefixes, replacement)
  for _, p in ipairs(prefixes) do
    if lc(s):sub(1, #p) == p then
      return replacement .. s:sub(#p + 1)
    end
  end
  return s
end

function M.clean(entity)
  local s = M.sart(entity)

  -- pets: "{adverb} {critter}" -> "{critter}" (mdt.tin:728-731); prefix
  -- strip loop until stable (tt_dw's pattern also repeats)
  local changed = true
  while changed do
    changed = false
    local low = lc(s)
    for _, critter in ipairs(PET_CRITTERS) do
      for _, adv in ipairs(PET_ADVERBS) do
        local pre = adv .. " " .. critter
        if low:sub(1, #pre) == pre then
          s = s:sub(#adv + 2) -- drop the adverb, keep the critter
          low = lc(s)
          changed = true
        end
      end
    end
  end
  -- "{X} the (alligator|mynah bird|monkey)" -> the animal
  for _, animal in ipairs({ "alligator", "mynah bird", "monkey" }) do
    s = s:gsub("%f[%w]%w+ the " .. animal, animal, 1)
  end

  -- "{size} whirlwind of ..." collapses entirely (mdt.tin:769)
  for _, size in ipairs({ "large", "huge", "gigantic", "colossal", "enormous", "humongous" }) do
    if lc(s):sub(1, #size + 14) == size .. " whirlwind of " then
      return "dust devil"
    end
  end

  -- horses: "{color} horse" -> "horse" (longest first)
  for _, c in ipairs(HORSE_COLORS) do
    s = replace_once(s, c .. " horse", "horse")
  end

  -- colour clouds collapse to "cloud" (the colour word feeds match())
  s = s:gsub("([%a%-]+) cloud", "cloud")

  -- specific shorthands (mdt.tin:741-771), row for row
  for _, p in ipairs({ "city", "town", "citadel", "palace", "Imperial", "Hattian" }) do
    s = replace_once(s, p .. " guard", "guard")
  end
  s = replace_once(s, "city sergeant", "sergeant")
  s = replace_once(s, " the gnoll", "")
  s = replace_once(s, "zombie town crier", "town crier")
  s = replace_once(s, "fox terrier", "terrier")
  for _, p in ipairs({ "tom", "tuxedo", "ragdoll" }) do
    s = replace_once(s, p .. " cat", "cat")
  end
  s = replace_once(s, "guard thief", "guard")
  s = replace_once(s, "guard thieves", "guards")
  s = replace_once(s, "street sweeper", "sweeper")
  s = replace_once(s, "stone mason", "mason")
  for _, p in ipairs({ "coachman", "church" }) do
    s = replace_once(s, p .. " mouse", "mouse")
  end
  s = replace_once(s, "man of low moral fibre", "man")
  s = replace_once(s, "street urchin", "urchin")
  s = s:gsub("%f[%w]%w+ delivery man", "delivery man")
  s = replace_once(s, "warehouse worker", "worker")
  s = replace_once(s, "merchant banker", "banker")
  for _, p in ipairs({ "novice", "student" }) do
    s = replace_once(s, p .. " assassin", "assassin")
  end
  s = replace_once(s, "warrior mercenar", "mercenar")
  s = replace_once(s, "Sheepridge's one licensed beggar", "beggar")
  s = replace_once(s, "skeleton warrior", "skeleton")
  s = s:gsub("%f[%w]%w+ %f[%w]%w+ cloud", "cloud")
  s = s:gsub("%f[%w]%w+ cloud", "cloud")
  s = replace_once(s, ", fifth Horseman of the Apocralypse", "")
  s = replace_once(s, " the shoeshine boy", "")
  s = s:gsub("%f[%w]%w+, driver of the .+ carriage", "carriage driver")
  s = s:gsub("%f[%w]%w+ mail carriage driver", "carriage driver")
  s = replace_once(s, "Vieux River Road carriage driver", "carriage driver")
  s = s:gsub("%f[%w]%w+ the giant fruitbat", "fruitbat")
  s = replace_once(s, " (hiding)", "")
  s = replace_once(s, "Miss ", "")

  -- the big adverb strip: plain words longest-first, interleaved with the
  -- anchored pattern forms, to a fixpoint (tt_dw's `(\badverb )+` also
  -- strips interleaved chains like "red-haired old man")
  local changed = true
  while changed do
    changed = false
    for _, adv in ipairs(M.adverbs) do
      if lc(s):sub(1, #adv + 1) == adv .. " " then
        s = s:sub(#adv + 2)
        changed = true
      end
    end
    for _, pat in ipairs(M.adverb_patterns) do
      local after = s:gsub(pat, "")
      if after ~= s then
        s = after
        changed = true
      end
    end
  end
  s = s:gsub("^ +", "")
  s = replace_once(s, "  ", " ")
  return s
end

-- --- arrows, distance, process (mdt.tin:780-794, 456-563) ------------------

-- "1 west 2 nw" -> "←↗↗"; also returns the step sum
function M.arrows(direction)
  local glyphs = {}
  local dist = 0
  for count, dir in tostring(direction):gmatch("(%d+) (%a+)") do
    dist = dist + tonumber(count)
    local short = M.dir_short[dir] or dir
    for _ = 1, tonumber(count) do
      glyphs[#glyphs + 1] = M.dir_glyph[short] or "?"
    end
  end
  return table.concat(glyphs), dist
end

-- process parsed groups -> display rooms + hunt alerts.
-- rooms: {direction, arrows, score, distance, text, show}
-- alerts: {entity, arrows} (dedupe + expiry happen in on_writtenmap)
function M.process(groups)
  local rooms = {}
  local alerts = {}
  for _, group in ipairs(groups) do
    local arrows, dist = M.arrows(group.direction)
    local room_score = 0
    local shown = {} -- key -> {count, score, label, color}
    local order = {}
    for _, raw in ipairs(group.entities) do
      local count, name = raw:match("^(%d+) (.+)$")
      count = tonumber(count) or 1
      name = name or raw
      local singular = count > 1 and M.singularize(name) or name
      local m = M.match(singular)
      room_score = room_score + count * m.score
      if m.show then
        local key = M.clean(singular)
        if not shown[key] then
          shown[key] = { count = 0, score = m.score, label = key, color = m.color }
          order[#order + 1] = key
        end
        shown[key].count = shown[key].count + count
        if m.alert then
          alerts[#alerts + 1] = { entity = key, singular = singular, arrows = arrows, direction = group.direction }
        end
      end
    end
    local text = {}
    for _, key in ipairs(order) do
      local e = shown[key]
      if e.count > 1 then
        text[#text + 1] = e.count .. " " .. M.pluralize(e.label)
      else
        text[#text + 1] = e.label
      end
    end
    rooms[#rooms + 1] = {
      direction = group.direction,
      arrows = arrows,
      score = room_score,
      distance = dist,
      entities = shown,
      order = order,
      texts = text,
      show = room_score > 0,
    }
  end
  -- sort: score desc, distance asc, stable by index (mdt_sort_compare + tie)
  for i, r in ipairs(rooms) do
    r.index = i
  end
  table.sort(rooms, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.index < b.index
  end)
  return { rooms = rooms, alerts = alerts }
end

-- render the room list (format_mdt list shape: "↑↑  [ 2] two city guards")
function M.render(rooms)
  local lines = {}
  local max_arrows = 0
  for _, r in ipairs(rooms) do
    if r.show then
      max_arrows = math.max(max_arrows, #r.arrows)
    end
  end
  for _, r in ipairs(rooms) do
    if r.show then
      local text_parts = {}
      for _, key in ipairs(r.order) do
        local e = r.entities[key]
        local label = e.count > 1 and (e.count .. " " .. M.pluralize(e.label)) or e.label
        -- colour priority: match colour > hot score > cold score > named
        local color = e.color
        if not color and e.score > 1 then
          color = "yellow"
        elseif not color and e.score < 1 then
          color = "gray"
        elseif not color and M.named_label(e.label) then
          color = "bold"
        end
        if color and util.ansi[color] then
          label = util.ansi[color] .. label .. util.ansi.reset
        end
        text_parts[#text_parts + 1] = label
      end
      local score = ("%5d"):format(r.score)
      lines[#lines + 1] =
        (r.arrows .. string.rep(" ", max_arrows - #r.arrows))
        .. "  [" .. score .. "] "
        .. table.concat(text_parts, ", ")
    end
  end
  return lines
end

-- witch-title exclusion list (mdt.tin:513): a capitalized label is a named
-- entity UNLESS it is a carriage driver, D'reg, Royal Guard, or a witch
-- title plus a name ("Granny Weatherwax" renders plain, like tt_dw)
M.witch_titles = {
  "Aunty", "Biddy", "Black", "Gammer", "Goodie", "Goody", "Gramma", "Granny",
  "Mama", "Mistress", "Mother", "Mss", "Nanna", "Nanny", "Old", "Sister",
  "Wee", "Wicked", "Young",
}

function M.named_label(label)
  if not label:sub(1, 1):match("%u") then
    return false
  end
  if label:find(" carriage driver", 1, true) or label:find("D'reg", 1, true) or label:find("Royal Guard", 1, true) then
    return false
  end
  local title = label:match("^(%u%a*) ")
  if title then
    for _, t in ipairs(M.witch_titles) do
      if t == title then
        return false
      end
    end
  end
  return true
end

-- --- SQL builders (hex.db; tt_dw migrations 004/005 schemas) ---------------

function M.init_sql()
  return {
    "CREATE TABLE IF NOT EXISTS mdt_match (match TEXT NOT NULL, category TEXT, color TEXT, score INT NOT NULL DEFAULT 1, alert INT NOT NULL DEFAULT 0, PRIMARY KEY (match));",
    "CREATE TABLE IF NOT EXISTS mdt_category (character TEXT NOT NULL, category TEXT NOT NULL, status INT NOT NULL, PRIMARY KEY (character, category));",
  }
end

function M.match_add_sql(match, category, color, score, alert)
  return ("INSERT OR REPLACE INTO mdt_match (match, category, color, score, alert) VALUES ('%s', '%s', '%s', %d, %d);")
    :format(
      util.sql_escape(match),
      util.sql_escape(category or ""),
      util.sql_escape(color or ""),
      tonumber(score) or 1,
      alert and 1 or 0
    )
end

function M.match_remove_sql(match)
  return ("DELETE FROM mdt_match WHERE match = '%s';"):format(util.sql_escape(match))
end

function M.match_list_sql()
  return "SELECT match || '|' || category || '|' || color || '|' || score || '|' || alert FROM mdt_match ORDER BY rowid;"
end

function M.match_delete_category_sql(category)
  return ("DELETE FROM mdt_match WHERE category = '%s';"):format(util.sql_escape(category))
end

function M.category_set_sql(character, category, status)
  -- status nil clears the override. tt_dw's clear branch deletes the whole
  -- character's rows (migration-wide WHERE); Hex scopes to the category.
  if status == nil then
    return ("DELETE FROM mdt_category WHERE character = '%s' AND category = '%s';")
      :format(util.sql_escape(character), util.sql_escape(category))
  end
  return ("INSERT OR REPLACE INTO mdt_category (character, category, status) VALUES ('%s', '%s', %d);")
    :format(util.sql_escape(character), util.sql_escape(category), status and 1 or 0)
end

function M.category_load_sql(character)
  return ("SELECT character || '|' || category || '|' || status FROM mdt_category WHERE character IN ('_default', '%s');")
    :format(util.sql_escape(character))
end

-- pure state loaders (fed with util.parse_rows output by the glue)
function M.load_matches(rows)
  local out = {}
  for _, f in ipairs(rows) do
    out[#out + 1] = {
      match = f[1],
      category = f[2],
      color = f[3] ~= "" and f[3] or nil,
      score = tonumber(f[4]) or 1,
      alert = tonumber(f[5]) or 0,
    }
  end
  M.state.matches = out
  return out
end

function M.load_categories(rows)
  local c = {}
  for _, f in ipairs(rows) do
    local character, category, status = f[1], f[2], tonumber(f[3])
    c[character] = c[character] or {}
    c[character][category] = status
  end
  M.state.categories = c
  return c
end

-- --- runtime glue -----------------------------------------------------------

local function sql(query)
  local r = core.exec({ "sqlite3", M.db(), query })
  if r:code() ~= 0 then
    print(util.ansi.red .. "[hex] sqlite error: " .. r:stderr() .. util.ansi.reset)
    return nil
  end
  return r:stdout()
end

function M.db()
  return (M.deps.config and M.deps.config.get("hex_db")) or ((os.getenv and os.getenv("HOME")) or "") .. "/.local/share/hex/hex.db"
end

function M.enabled()
  return M.deps.config and M.deps.config.get("mdt", true) or false
end

function M.setup(deps)
  M.deps = deps or {}
  for _, stmt in ipairs(M.init_sql()) do
    core.exec({ "sqlite3", M.db(), stmt })
  end
  M.refresh()
end

function M.refresh()
  local alt = M.deps.config and M.deps.config.alt() or ""
  local rows = util.parse_rows(sql(M.match_list_sql()) or "")
  M.load_matches(rows)
  M.load_categories(util.parse_rows(sql(M.category_load_sql(alt)) or ""))
end

-- per accepted writtenmap push: recompute, keep the latest room list for
-- /mdt, print deduped hunting alerts (seen entries expire after 10 minutes)
function M.on_writtenmap(text, room_id)
  if not M.enabled() or not text or text == "" then
    return
  end
  local parsed = M.parse(text)
  local result = M.process(parsed)
  M.state.rooms = result.rooms
  M.state.room_id = room_id
  local now = os.time()
  for entity, at in pairs(M.state.seen) do
    if now - at > M.SEEN_TTL then
      M.state.seen[entity] = nil
    end
  end
  for _, alert in ipairs(result.alerts) do
    if not M.state.seen[alert.entity] then
      M.state.seen[alert.entity] = now
      print(util.ansi.bold
        .. util.ansi.red
        .. "[hunt] "
        .. alert.entity
        .. util.ansi.reset
        .. ": "
        .. alert.arrows
        .. " of here!")
      if M.deps.notify then
        M.deps.notify.emit("mdt.hunt", { entity = alert.entity, arrows = alert.arrows })
      end
    end
  end
end

-- --- commands ---------------------------------------------------------------

local function bold(t)
  return util.ansi.bold .. t .. util.ansi.reset
end

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function alt_name()
  return (M.deps.config and M.deps.config.alt()) or "_default"
end

-- human-readable label for a default rule row in /mdt list
local function default_label(d)
  local r = d.rule
  local join = function(list)
    return table.concat(list, "/")
  end
  if r.kind == "find" then
    return r.find
  elseif r.kind == "exact" then
    return "one of: " .. join(r.exact)
  elseif r.kind == "startswith" then
    return "starts with: " .. join(r.startswith)
  elseif r.kind == "endswith" then
    return "ends with: " .. join(r.endswith)
  elseif r.kind == "exclude_endswith" then
    return "ends with: " .. join(r.endswith) .. " (never: " .. r.exclude .. ")"
  elseif r.kind == "prefix_endswith" then
    return join(r.prefix) .. " + ends with: " .. join(r.endswith)
  elseif r.kind == "adj_endswith" then
    return "<adj> + ends with: " .. join(r.endswith)
  end
  return tostring(r.kind)
end

function M.cmd_mdt(args)
  args = util.trim(args or "")
  local action, rest = args:match("^(%S+)%s*(.*)$")
  action = action or ""
  if action == "" then
    if #M.state.rooms == 0 then
      print(gray("[hex] no written map parsed yet (look around first; /mdt help for subcommands)"))
      return
    end
    print(bold("People nearby") .. gray("  from the last written map"))
    for _, line in ipairs(M.render(M.state.rooms)) do
      print("  " .. line)
    end
  elseif action == "help" then
    print(bold("/mdt") .. "                people in the rooms around you")
    print(gray("/mdt add <match> [score] [category]   store a highlight (plain text)"))
    print(gray("/mdt remove <match>                   delete a highlight"))
    print(gray("/mdt list [query]                     stored highlights (plus Quow defaults)"))
    print(gray("/mdt category <name> enable|disable [default|char]"))
    print(gray("/mdt categories                       category overview"))
    print(gray("/hunt <target> | /hunt list | /hunt stop <target> | /hunt clear"))
  elseif action == "add" then
    if util.trim(rest) == "" then
      print(gray("usage: /mdt add <match words...> [score=N] [category=X]"))
      return
    end
    -- trailing key=value tokens are options; everything else is the match
    -- (tt_dw took braced multi-word matches; bare multi-word reads here)
    local score, category = 1, ""
    local words = {}
    for token in rest:gmatch("%S+") do
      local k, v = token:match("^(%a+)=(%S+)$")
      if k == "score" then
        score = tonumber(v) or score
      elseif k == "category" then
        category = v
      else
        words[#words + 1] = token
      end
    end
    local match = table.concat(words, " ")
    if match == "" then
      print(gray("usage: /mdt add <match words...> [score=N] [category=X]"))
      return
    end
    sql(M.match_add_sql(match, category, "", score, false))
    M.refresh()
    print(gray("[hex] mdt match stored: " .. match .. " (score " .. tostring(score) .. ")"))
  elseif action == "remove" or action == "delete" then
    if util.trim(rest) == "" then
      print(gray("usage: /mdt remove <match>"))
      return
    end
    sql(M.match_remove_sql(util.trim(rest)))
    M.refresh()
    print(gray("[hex] mdt match removed: " .. util.trim(rest)))
  elseif action == "list" or action == "matches" then
    local query = lc(util.trim(rest))
    print(bold("MDT matches") .. gray("  user rows first, then the Quow defaults"))
    for _, m in ipairs(M.state.matches) do
      if query == "" or lc(m.match):find(query, 1, true) or lc(m.category):find(query, 1, true) then
        local flags = {}
        if m.category ~= "" then
          flags[#flags + 1] = m.category
        end
        if not M.category_status(m.category) then
          flags[#flags + 1] = "disabled"
        end
        print(("  %-30s score %3d  alert %s  %s"):format(
          m.match, m.score, m.alert == 1 and "yes" or "no", table.concat(flags, ", ")))
      end
    end
    for _, d in ipairs(M.defaults) do
      local label = default_label(d)
      if query == "" or lc(label):find(query, 1, true) or lc(d.category):find(query, 1, true) then
        print(("  %-44s score %3d  %s%s"):format(
          label, d.score, d.category ~= "" and (d.category .. " ") or "", gray("(default)")))
      end
    end
  elseif action == "category" then
    local category, verb, scope = rest:match("^(%S+)%s+(%a+)%s*(%S*)$")
    if not category or not (verb == "enable" or verb == "disable" or verb == "clear" or verb == "default") then
      print(gray("usage: /mdt category <name> enable|disable|clear [default|char]"))
      return
    end
    local char_scope = scope == "char"
    local character = char_scope and alt_name() or "_default"
    local status = verb == "enable" and 1 or verb == "disable" and 0 or nil
    sql(M.category_set_sql(character, category, status))
    M.refresh()
    print(gray("[hex] category " .. category .. " " .. verb .. " for " .. character))
  elseif action == "categories" then
    print(bold("MDT categories"))
    local counts = {}
    for _, m in ipairs(M.state.matches) do
      if m.category ~= "" then
        counts[m.category] = (counts[m.category] or 0) + 1
      end
    end
    local names = {}
    for name in pairs(counts) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      print(("  %-20s %d match(es)  %s"):format(name, counts[name],
        M.category_status(name) and "enabled" or gray("disabled")))
    end
  else
    print(gray("usage: /mdt [help|add|remove|list|category|categories]"))
  end
end

-- /hunt: stored as category='hunting' rows (score 100, alert 1)
function M.cmd_hunt(args)
  args = util.trim(args or "")
  local action, rest = args:match("^(%S+)%s*(.*)$")
  action = action or ""
  if action == "help" then
    print(gray("/hunt <target words...>    watch for a target (alert on sight)"))
    print(gray("/hunt list | /hunt stop <target> | /hunt clear"))
  elseif action == "" or action == "list" then
    local targets = {}
    for _, m in ipairs(M.state.matches) do
      if m.category == "hunting" then
        targets[#targets + 1] = m.match
      end
    end
    if #targets == 0 then
      print(gray("Not looking for anything. /hunt <target> starts; /hunt clear stops all."))
    else
      print(bold("Currently looking for:") .. " " .. table.concat(targets, ", "))
    end
  elseif action == "clear" then
    sql(M.match_delete_category_sql("hunting"))
    M.refresh()
    M.state.seen = {}
    print(gray("[hex] no longer hunting anything"))
  elseif action == "stop" then
    if util.trim(rest) == "" then
      print(gray("usage: /hunt stop <target>"))
      return
    end
    sql(M.match_remove_sql(util.trim(rest)))
    M.refresh()
    print(gray("[hex] no longer hunting: " .. util.trim(rest)))
  else
    sql(M.match_add_sql(args, "hunting", "", 100, true))
    M.refresh()
    print(gray("[hex] hunting: " .. args))
  end
end

function M.cmd_unhunt(args)
  local target = util.trim(args or "")
  if target == "" then
    print(gray("usage: /unhunt <target>"))
    return
  end
  M.cmd_hunt("stop " .. target)
end

return M
