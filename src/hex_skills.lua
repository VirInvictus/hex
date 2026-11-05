-- hex_skills.lua: the skills store, bonus/cost math, and goals (design:
-- docs/phase-3-character.md §3; ported from tt_dw's char/skill_functions.tin,
-- skill_cost.tin, skill_input.tin, skill_updates.tin, skills.tin).
--
-- The listing round-trip (/skills refresh) sends tt_dw's three documented
-- lines inside the user alias, arms the parse-window triggers, and closes on
-- the "Set option output skills to branched." terminator (or a 30 s
-- display-only safety timer). Advance lines and the documented hskills
-- shapes feed goal alerts. Bonus math runs on stored stats with the
-- documented all-13 baseline until the stats batch lands.
--
-- Official-docs caveat surfaced in /skillcost: ETB as documented differs
-- from tt_dw's teach-cost model, so the numbers carry that caveat.
--
-- Pure core is unit-tested (golden constants: all-13 bonus = 307); runtime
-- glue below the marker owns blightmud globals.
local util = require("src.hex_util")
local data = require("src.hex_skilldata")

local M = {}

M.deps = {}
M.state = {} -- per-alt: dotted skill -> level
M.goals = {} -- per-alt: array of { skill, target, start_level, spent }

-- documented baseline: stats start at 13 (official docs); the stats batch
-- replaces this from `score verbose stats`
M.DEFAULT_STATS = { con = 13, dex = 13, int = 13, wis = 13, str = 13 }

-- --- pure core ---

-- skill_functions.tin:102-114
function M.raw_level_bonus(level)
  level = math.floor(tonumber(level) or 0)
  local r
  if level <= 20 then
    r = 5 * level
  elseif level <= 40 then
    r = 2.5 * (level - 20) + 100
  elseif level <= 60 then
    r = (level - 40) + 150
  else
    r = 0.5 * (level - 60) + 170
  end
  return math.floor(r)
end

-- stat deps for a skill; unknown skills get one of each (tt_dw stat_deps)
function M.deps_for(skill)
  return data.skill_stats[skill] or "CDISW"
end

-- skill_functions.tin:117-151: product of stat values (0 skipped,
-- negatives divide by abs), m = 0.1020408 * ln(prod) - 0.25, floored at 0.
function M.multiplicator(deps, stats)
  stats = stats or M.DEFAULT_STATS
  local letter_stat = { C = "con", D = "dex", I = "int", W = "wis", S = "str" }
  local prod = 1
  for dep in tostring(deps):gmatch("%a") do
    local val = tonumber(stats[letter_stat[dep]] or 13)
    if val == 0 then
      -- skip
    elseif val > 0 then
      prod = prod * val
    else
      prod = prod * (-1) / val
    end
  end
  local m = 0.1020408 * math.log(prod) - 0.25
  if m < 0 then
    m = 0
  end
  return m
end

-- bonus at a level (skill_functions.tin:81-99)
function M.bonus_for(level, deps, stats)
  return math.floor(M.raw_level_bonus(level) * M.multiplicator(deps, stats))
end

-- inverse (skill_functions.tin:33-55): raw = floor(wanted/m) nudged up
-- until floor(m*raw) >= wanted, then invert the piecewise table, ceil.
function M.level_for_bonus(wanted, deps, stats, use_raw)
  local m = M.multiplicator(deps, stats)
  if m <= 0 then
    return -1
  end
  local raw = math.floor(wanted / m)
  while math.floor(m * raw) < wanted do
    raw = raw + 1
  end
  if not use_raw then
    raw = raw -- level targets invert through the same table
  end
  local level
  if raw <= 100 then
    level = raw / 5.0
  elseif raw <= 150 then
    level = (raw - 100) / 2.5 + 20.0
  elseif raw <= 170 then
    level = (raw - 150) + 40.0
  else
    level = (raw - 170) * 2 + 60.0
  end
  return math.ceil(level)
end

-- skill_input.tin:141-188 target grammar: 120, l120, 120l, +10, b200,
-- 200b, r180, and the + variants of each (relative to current). Returns
-- the number and its kind ("level"|"bonus"|"raw"), or nil + reason; the
-- caller converts bonus/raw targets via level_for_bonus.
function M.parse_target(spec, current)
  local s = tostring(spec):lower():gsub("%s", "")
  local relative = s:find("%+") ~= nil
  s = s:gsub("%+", "")
  local kind, num
  if s:match("^l%d+$") then
    kind, num = "level", s:match("^l(%d+)$")
  elseif s:match("^%d+l$") then
    kind, num = "level", s:match("^(%d+)l$")
  elseif s:match("^b%d+$") then
    kind, num = "bonus", s:match("^b(%d+)$")
  elseif s:match("^%d+b$") then
    kind, num = "bonus", s:match("^(%d+)b$")
  elseif s:match("^r%d+$") then
    kind, num = "raw", s:match("^r(%d+)$")
  elseif s:match("^%d+r$") then
    kind, num = "raw", s:match("^(%d+)r$")
  elseif s:match("^%d+$") then
    kind, num = "level", s
  else
    return nil, "unparseable target: " .. tostring(spec)
  end
  num = tonumber(num)
  if not num then
    return nil, "unparseable target: " .. tostring(spec)
  end
  if relative then
    local base = (kind == "level" and (current.level or 0))
      or (kind == "bonus" and (current.bonus or 0))
      or (current.raw_bonus or 0)
    num = base + num
  end
  return num, kind
end

-- skill_cost.tin: primary levels (to min(target,300)) use the primary
-- formula, everything after uses teach cost. is_primary from the guild's
-- primaries; stats feed the bonus inside teach cost.
function M.skill_cost(skill, from, to, teach, is_primary, stats)
  if from >= to then
    return 0
  end
  local total = 0
  local level = from
  if is_primary and level < 300 then
    local goal = math.min(to, 300)
    while level < goal do
      total = total + math.floor(75 * math.floor(level / 3 + 1) * math.exp(level / 150))
      level = level + 1
    end
  end
  while level < to do
    local bonus = M.raw_level_bonus(level)
    local max_etb = math.max(bonus + 200, bonus * 1.5)
    local cetb = max_etb
    if teach and teach > 0 then
      cetb = math.min(teach, max_etb)
    end
    local min_k = 0.5 * bonus / 800 + 1
    local simple_k = 0.5 * bonus / cetb + 1
    local etb_range = max_etb - bonus
    local k = 1.5 - (cetb - bonus) / etb_range * (1.5 - min_k)
    if simple_k < k then
      k = simple_k
    end
    total = total + math.floor(500 + 250 * level * math.exp(level / 500) * k)
    level = level + 1
  end
  return total
end

-- primaries lookup (skill_functions.tin primaries): guild (+ spec for
-- wizards/thieves/assassins/warriors), wizard orders translated via
-- wizard_colors. Returns the list or nil.
function M.primaries_for(guild, spec)
  if not guild or not data.primaries[guild] then
    return nil
  end
  local branch = data.primaries[guild]
  if type(branch) == "table" and branch[1] then
    return branch -- flat list (adventurers, priests, witches, fools)
  end
  if guild == "wizards" and spec then
    spec = data.wizard_colors[spec] or spec
  end
  return branch[spec]
end

function M.is_primary(skill, guild, spec)
  local list = M.primaries_for(guild, spec)
  if not list then
    return false
  end
  for _, s in ipairs(list) do
    if s == skill then
      return true
    end
  end
  return false
end

-- level lookup with the parent fallback (skill_functions.tin:52-56: the
-- MUD omits children equal to their parent)
function M.level_of(skill, state)
  local s = state or M.state
  if s[skill] then
    return s[skill]
  end
  local parent = skill:match("^(.*)%.[^.]+$")
  if parent then
    return M.level_of(parent, s)
  end
  return nil
end

-- prefix search over known skills (skill_input.tin match_skills, simplified:
-- exact first, then unique-prefix)
function M.resolve_skill(name)
  local n = util.trim(tostring(name)):lower()
  if data.skill_stats[n] then
    return n
  end
  local hits = {}
  for skill in pairs(data.skill_stats) do
    if skill:find(n, 1, true) then
      hits[#hits + 1] = skill
    end
  end
  table.sort(hits)
  if #hits == 1 then
    return hits[1]
  end
  return nil, (#hits == 0 and "unknown skill: " or "ambiguous skill (" .. #hits .. " matches): ") .. tostring(name)
end

-- one skills-listing line: skill, level, bonus ("X" possible). tt_dw's four
-- depth patterns collapse into this superset (no 4-comp skill has a hyphen).
function M.parse_line(line)
  -- Lua patterns have no alternation, no (?:...) groups and no {n,m}
  -- quantifiers, so capture loosely and validate the skill shape after:
  -- 1-4 dot-separated components of letters/digits/hyphens. The Rust
  -- trigger keeps its own combined form.
  local skill, level, bonus = tostring(line):match("^(.-)%s+(%d+)%s+([%dX]+)$")
  if not skill or not (bonus == "X" or bonus:match("^%d+$")) then
    return nil
  end
  local shaped = skill:match("^%w[%w%-]*$")
    or skill:match("^%w[%w%-]*%.%w[%w%-]*$")
    or skill:match("^%w[%w%-]*%.%w[%w%-]*%.%w[%w%-]*$")
    or skill:match("^%w[%w%-]*%.%w[%w%-]*%.%w[%w%-]*%.%w[%w%-]*$")
  if not shaped then
    return nil
  end
  return skill, tonumber(level), bonus
end

-- goals: { skill, target, start_level, spent }; xp bar port of
-- skills.tin:399-439 in plain ANSI (10 pips, one divider, at least one pip
-- each side unless empty or done).
function M.goal_bar(xp_left, total)
  if not total or total <= 0 then
    return "-"
  end
  local spent = total - xp_left
  local fill = 21 * (spent / total)
  if spent > 0 then
    fill = math.max(fill, 1)
  end
  if xp_left > 0 then
    fill = math.min(fill, 20)
  end
  fill = math.floor(fill + 0.5)
  local text = string.format("%10d/%10d", xp_left, total)
  local filled = text:sub(1, fill)
  local empty = text:sub(fill + 1)
  return util.ansi.green .. filled .. "/" .. util.ansi.yellow .. empty .. util.ansi.reset
end

function M.goal_xp_left(goal, guild, spec, stats)
  local from = M.level_of(goal.skill) or goal.start_level or 0
  local primary = M.is_primary(goal.skill, guild, spec)
  local total = M.skill_cost(goal.skill, goal.start_level or 0, goal.target, nil, primary, stats)
  local remaining = M.skill_cost(goal.skill, from, goal.target, nil, primary, stats)
  return remaining, total
end

-- --- runtime glue (blightmud globals below this line) ---

M.window = nil -- listing parse-window state { handles = {}, count = 0 }

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function bold(t)
  return util.ansi.bold .. t .. util.ansi.reset
end

local function red(t)
  return util.ansi.red .. t .. util.ansi.reset
end

function M.setup(deps)
  M.deps = deps
  M.load_if_needed()
end

function M.load_if_needed()
  local alt = M.deps.config and M.deps.config.alt() or nil
  if M.alt_loaded == alt then
    return
  end
  M.alt_loaded = alt
  M.state = {}
  M.goals = {}
  if not alt then
    return
  end
  for _, key in ipairs({ "hex.skills." .. alt, "hex.goals." .. alt }) do
    local raw = store.disk_read(key)
    if raw then
      local ok, saved = pcall(json.decode, raw)
      if ok and type(saved) == "table" then
        if key:find("hex%.skills") then
          M.state = saved
        else
          M.goals = saved
        end
      end
    end
  end
end

function M.save()
  local alt = M.deps.config and M.deps.config.alt() or nil
  if not alt then
    return
  end
  store.disk_write("hex.skills." .. alt, json.encode(M.state))
  store.disk_write("hex.goals." .. alt, json.encode(M.goals))
end

-- Passive hskills feed (documented shapes, both formats): "X - skill
-- increased by N levels (and bonus B) to level L (and bonus B)." and the
-- plain-parens variant — both wire-verified 2026-11-05 (hskills brief).
-- Plus guild auto-detection from score verbose's "level N in the X Guild"
-- clause (wire-verified: "level 0 in the Adventurers' Guild"). Announce-only.
function M.register(trigger_add, Regex)
  local shapes = {
    "^.- %- (%w[%w%-]*(?:%.%w[%w%-]*){0,3}) increased by (%d+) levels? %(and bonus (%d+)%) to level (%d+) %(and bonus (%d+)%)%.$",
    "^.- %- (%w[%w%-]*(?:%.%w[%w%-]*){0,3}) increased by (%d+) levels? %((%d+)%) to level (%d+) %((%d+)%)%.$",
  }
  for _, re in ipairs(shapes) do
    trigger_add(Regex.new(re), {}, function(matches)
      M.advance(matches[2], tonumber(matches[5]) or 0, nil)
    end)
  end
  -- guild clause on score verbose / score: map to a primaries key
  local GUILD_NAMES = {
    ["Adventurers"] = "adventurers",
    ["Warriors"] = "warriors",
    ["Assassins"] = "assassins",
    ["Thieves"] = "thieves",
    ["Priests"] = "priests",
    ["Witches"] = "witches",
    ["Wizards"] = "wizards",
    ["Fools"] = "fools",
  }
  trigger_add(Regex.new("\\blevel \\d+ in the ([\\w' ]+) Guild"), {}, function(matches)
    local key = GUILD_NAMES[matches[2]] or GUILD_NAMES[matches[2]:gsub("'$", "")]
    if key and M.deps.config and M.deps.config.get("guild") ~= key then
      M.deps.config.set("guild", key)
      print(util.ansi.gray .. "[hex] guild: " .. key .. util.ansi.reset)
    end
  end)
end

function M.stats()
  -- per-alt stats arrive with the stats batch; until then the documented
  -- all-13 baseline (an override may exist in the disk store already)
  local alt = M.deps.config and M.deps.config.alt()
  local stats = { con = 13, dex = 13, int = 13, wis = 13, str = 13 }
  if alt then
    local raw = store.disk_read("hex.stats." .. alt)
    if raw then
      local ok, saved = pcall(json.decode, raw)
      if ok and type(saved) == "table" then
        for k, v in pairs(saved) do
          stats[k] = v
        end
      end
    end
  end
  return stats
end

local function window_close(message)
  if not M.window then
    return
  end
  for _, h in ipairs(M.window.handles) do
    pcall(trigger.remove, h.id)
  end
  local count = M.window.count
  M.window = nil -- the safety timer is count=1: it removes itself
  M.save()
  print(gray("[hex] " .. message .. " (" .. count .. " skills)"))
end

-- /skills refresh: the sanctioned 3-command round-trip + armed window.
-- Window triggers go through the registry-wrapped add (a /hexreload
-- mid-listing reaps them instead of orphaning them); close removes them
-- directly, and reaping already-removed ids is a harmless pcall.
function M.refresh()
  if M.window then
    print(gray("[hex] a skills listing is already running"))
    return
  end
  if not M.deps.trigger_add then
    print(red("[hex] skills window unavailable (no trigger_add wired)"))
    return
  end
  local handles = {}
  local function arm(re, cb)
    handles[#handles + 1] = M.deps.trigger_add(re, { gag = true }, cb)
  end
  M.window = { handles = handles, count = 0 }
  -- terminator closes the window
  arm("^Set option output skills to branched\\.$", function()
    window_close("skills listing done")
  end)
  -- header + the three sent-line echoes are noise
  arm("^SKILL\\s+Level Bonus$", function() end)
  arm("^Queued command: (noalias )?options output skills = (list|branched)$", function() end)
  arm("^Queued command: (noalias )?skills$", function() end)
  arm("^Set option output skills to list$", function() end)
  -- the listing itself: matches[2] = skill, [3] = level, [4] = bonus (X ok)
  -- RUST pattern: the Lua-side parse_line in hex_skills keeps its own
  -- %-class form; this one must use Rust classes or it never matches
  arm("^([A-Za-z][A-Za-z0-9-]*(?:\\.[A-Za-z][A-Za-z0-9-]*){0,3})\\s+(\\d+)\\s+(\\d+|X)$", function(matches)
    M.state[matches[2]] = tonumber(matches[3])
    M.window.count = M.window.count + 1
  end)
  -- 30 s display-only safety timer (never sends)
  if M.deps.timer_add then
    M.deps.timer_add(30000, 1, function()
      if M.window then
        window_close("skills listing timed out (saved what arrived)")
      end
    end)
  end
  -- the round-trip, one send per line, inside this user alias
  mud.send("noalias options output skills = list")
  mud.send("noalias skills")
  mud.send("options output skills = branched")
end

-- Advance line feed (main.lua's tightened trigger) + the documented hskills
-- shapes: update the store, alert goals. announce-only.
function M.advance(skill, new_level, xp_spent)
  M.load_if_needed()
  local old = M.state[skill]
  M.state[skill] = new_level
  if xp_spent and xp_spent > 0 then
    for _, goal in ipairs(M.goals) do
      if goal.skill == skill or skill:find(goal.skill .. "%.", 1, true) == 1 then
        goal.spent = (goal.spent or 0) + xp_spent
      end
    end
  end
  for _, goal in ipairs(M.goals) do
    if (goal.skill == skill or skill:find(goal.skill .. "%.", 1, true) == 1) and new_level >= goal.target and (old or 0) < goal.target then
      print(bold("[hex] GOAL reached: ") .. skill .. " level " .. new_level)
    end
  end
  M.save()
end

function M.goal_add(skill, target)
  for i, g in ipairs(M.goals) do
    if g.skill == skill then
      g.target = target
      g.start_level = g.start_level or M.level_of(skill) or 0
      M.save()
      return "updated"
    end
  end
  M.goals[#M.goals + 1] = { skill = skill, target = target, start_level = M.level_of(skill) or 0, spent = 0 }
  M.save()
  return "added"
end

function M.goal_remove(skill)
  for i, g in ipairs(M.goals) do
    if g.skill == skill then
      table.remove(M.goals, i)
      M.save()
      return true
    end
  end
  return false
end

return M
