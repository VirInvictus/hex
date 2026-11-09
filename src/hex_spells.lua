-- hex_spells.lua: spelldata queries, the TM algorithm, and the spellinfo
-- card (design: docs/phase-4-magic.md §4; ported from tt_dw's
-- magic/spellinfo.tin over the committed hex_spelldata dataset).
--
-- TM constants are config (defaults = tt_dw's): tm_blacklist (comma
-- separated nicks), tm_cast_chance 30, tm_cutoff 9. The skill inputs come
-- from Phase 3's skills store; guild gating (witches -> learnt_at, wizards
-- -> tome) uses /hexset guild until char.info carries it.
--
-- Pure core (stage chance, TM/cast chance, ordering, suggestion) is
-- unit-tested; runtime glue owns the commands.
local util = require("src.hex_util")
local skilldata = require("src.hex_skilldata")

local M = {}

M.deps = {}
M.data = require("src.hex_spelldata")
-- the dataset rides M.data (injected here, swapped by tests)

-- tt_dw spellinfo.tin:6-12 defaults
M.DEFAULT_BLACKLIST =
  "bep,cms,cmseq,cms2,dwfpp,ehai,eham,eha2,jmc,grtw,mac,masi,mgagt,plg,rpd,tdcf,tea,wpl,yee,fetch,rrd,rtfm,lleb"

local function config()
  return M.deps.config
end

local function blacklist()
  local raw = config() and config().get("tm_blacklist", M.DEFAULT_BLACKLIST) or M.DEFAULT_BLACKLIST
  local set = {}
  for nick in tostring(raw):gmatch("[^,]+") do
    set[util.trim(nick)] = true
  end
  return set
end

-- --- pure core ---

-- Stage chance (spellinfo.tin:699-704): count thresholds passed ascending,
-- breaking at the first failure; each pass is 10%.
function M.stage_chance(thresholds, bonus)
  local passed = 0
  for _, t in ipairs(thresholds) do
    if bonus >= t then
      passed = passed + 1
    else
      break
    end
  end
  return passed * 10
end

-- TM chance (spellinfo.tin:743-768): a *relative* number for sorting; the
-- real chance is way lower. Stages without the method contribute nothing.
function M.tm_chance(spell, method, bonus)
  local notm = 1
  for _, st in ipairs(spell.spellcheck or {}) do
    if st.skill == method then
      local chance = M.stage_chance(st.thresholds, bonus)
      local p = math.max(1, math.min(99, chance)) / 100
      local tm = p * (1 - p)
      notm = notm * (1 - tm)
    end
  end
  return math.floor((1 - notm) * 100 + 0.5)
end

-- Cast chance (spellinfo.tin:708-723): product over ALL stages. tt_dw's
-- comment: "(Probably) not the actual chance, so don't show this to users."
-- It drives the suggestion ranking only.
function M.cast_chance(spell, method, bonus)
  local product = 1
  for _, st in ipairs(spell.spellcheck or {}) do
    if st.skill == method then
      local chance = M.stage_chance(st.thresholds, bonus)
      product = product * math.max(1, math.min(99, chance)) / 100
    end
  end
  return math.floor(product * 100 + 0.5)
end

-- The 50% thresholds (spellinfo.tin:662-679): the 5th value per stage.
function M.skills_50(spell)
  local out = {}
  for _, st in ipairs(spell.spellcheck or {}) do
    out[#out + 1] = { stage = st.stage, skill = st.skill, bonus = st.thresholds[5] }
  end
  return out
end

-- method shorthand -> full skill name (spellskills map)
function M.method_full(short)
  return M.data.spellskills[short] or short
end

-- Your bonus for a method, from the skills store (Phase 3). Falls back to
-- level 0 when the listing has not been read.
function M.method_bonus(short)
  local skills = M.deps.skills
  if not skills then
    return 0
  end
  local full = M.method_full(short)
  local level = skills.level_of(full) or 0
  local deps = skilldata.skill_stats[full] or "CDISW"
  return skills.bonus_for(level, deps, skills.stats())
end

-- Guild gating (spellinfo.tin:543-565): witches see learnt_at spells,
-- wizards see tome spells, unknown guild sees everything.
function M.guild_ok(spell)
  local guild = config() and config().get("guild")
  if guild == "witches" then
    return spell.learnt_at ~= nil
  elseif guild == "wizards" then
    return spell.tome ~= nil
  end
  return true
end

-- The TM suggestion scan (spellinfo.tin:568-582) for one method: spelldata
-- order, blacklist skipped, a candidate replaces the incumbent when the
-- incumbent is blacklisted or the candidate's cast chance is higher, and
-- the scan breaks early on a good-enough incumbent. Returns the ordered
-- candidate list (suggestion first); each entry carries tm/cast chances.
function M.suggestions(method, bonus)
  local bl = blacklist()
  local cast_accept = tonumber(config() and config().get("tm_cast_chance", 30)) or 30
  local cutoff = tonumber(config() and config().get("tm_cutoff", 9)) or 9
  local candidates = {}
  local best_index = nil
  for order_index, nick in ipairs(M.data.order) do
    local spell = M.data.spells[nick]
    if not M.guild_ok(spell) then
      goto continue
    end
    local has_method = false
    for _, st in ipairs(spell.spellcheck or {}) do
      if st.skill == method then
        has_method = true
        break
      end
    end
    if not has_method then
      goto continue
    end
    local entry = {
      nick = nick,
      spell = spell,
      tm = M.tm_chance(spell, method, bonus),
      cast = M.cast_chance(spell, method, bonus),
      order_index = order_index,
      blacklisted = bl[nick] or false,
    }
    candidates[#candidates + 1] = entry
    if best_index == nil then
      best_index = #candidates
    elseif (candidates[best_index].blacklisted and not entry.blacklisted)
      or (entry.cast > candidates[best_index].cast and not entry.blacklisted) then
      best_index = #candidates
    end
    -- break once good enough: a non-blacklisted incumbent above the
    -- accept threshold (spellinfo.tin:581)
    if
      best_index
      and not candidates[best_index].blacklisted
      and candidates[best_index].cast >= cast_accept
      and candidates[best_index].tm >= cutoff * 10
    then
      break
    end
    ::continue::
  end
  -- suggestion first, then the rest by tm descending, stable on the
  -- spelldata order (design §4 point 5): the sort runs on the remainder,
  -- so the suggestion cannot be buried by its own tm value
  local best = nil
  if best_index then
    best = table.remove(candidates, best_index)
    best.suggestion = true
  end
  table.sort(candidates, function(a, b)
    if a.tm ~= b.tm then
      return a.tm > b.tm
    end
    return a.order_index < b.order_index
  end)
  if best then
    table.insert(candidates, 1, best)
  end
  return candidates
end

-- nick/name resolution: exact nick, nick prefix, then name substring.
-- Returns spell, nick or nil + reason.
function M.resolve(query)
  local q = util.trim(tostring(query)):lower()
  if q == "" then
    return nil, "no spell given"
  end
  if M.data.spells[q] then
    return M.data.spells[q], q
  end
  local nick_hits, name_hits = {}, {}
  for _, nick in ipairs(M.data.order) do
    local spell = M.data.spells[nick]
    if nick:find(q, 1, true) then
      nick_hits[#nick_hits + 1] = nick
    elseif spell.name:lower():find(q, 1, true) then
      name_hits[#name_hits + 1] = nick
    end
  end
  if #nick_hits == 1 then
    return M.data.spells[nick_hits[1]], nick_hits[1]
  end
  if #name_hits == 1 then
    return M.data.spells[name_hits[1]], name_hits[1]
  end
  local all = {}
  for _, n in ipairs(nick_hits) do
    all[#all + 1] = n
  end
  for _, n in ipairs(name_hits) do
    all[#all + 1] = n
  end
  if #all == 0 then
    return nil, "no spell matches: " .. query
  end
  table.sort(all)
  return nil, "ambiguous (" .. #all .. "): " .. table.concat(all, ", ")
end

-- --- runtime glue (commands below; blightmud globals not needed) ---

function M.setup(deps)
  M.deps = deps
end

-- --- live probes (v0.21.0): the sendable spellcheck and the shields read ---
-- Both are user-alias sends; the parsers run on distinctive personal-status
-- lines pinned verbatim in the doc mirror (known_command/spellcheck and
-- helpdir/shields), so they work offline. The item-condition rows of the
-- shields block are deliberately NOT parsed: "It is in <x> condition" also
-- appears in every examine.

-- "For stage two using the evoking skill, you would almost certainly succeed."
-- The stage number is a word on the wire (the doc's own example), so it
-- stays a string; the trigger literal mirrors that with %a+.
function M.parse_stage_line(line)
  local n, skill, verdict = tostring(line):match("^For stage (%a+) using the (.+) skill, you would (.+)%.$")
  if n then
    return { n = n, skill = skill, verdict = verdict }
  end
  return nil
end

-- "The spell, Kamikaze Oryctolagus Flammula, is an offensive spell requiring a carrot and a torch."
function M.parse_spell_header(line)
  local name, kind = tostring(line):match("^The spell, (.+), is an? (.+) spell")
  if name then
    return { name = name, kind = kind }
  end
  return nil
end

function M.parse_shield_line(line)
  line = tostring(line)
  local names = line:match("^  (.+) are floating around you%.$")
  if names then
    return { kind = "items", detail = names }
  end
  if line == "  You are surrounded by a magical impact shield." then
    return { kind = "impact" }
  end
  local god, dur = line:match("^  You are protected by the power of (.+)%.  You will be protected for (.+)%.$")
  if god then
    return { kind = "god", detail = god .. ", " .. dur }
  end
  return nil
end

function M.shields_report(rows)
  local lines = {}
  for _, r in ipairs(rows or {}) do
    if r.kind == "items" then
      lines[#lines + 1] = "floating: " .. r.detail
    elseif r.kind == "impact" then
      lines[#lines + 1] = "impact shield: UP"
    elseif r.kind == "god" then
      lines[#lines + 1] = "divine: " .. r.detail
    end
  end
  if #lines == 0 then
    lines[#lines + 1] = "no shields seen in the listing"
  end
  return lines
end

-- The live-print triggers (spellcheck stage verdicts, impact and divine
-- shields); registered through the registry from main.lua.
function M.register(trigger_add, regex)
  trigger_add("^For stage (\\a+) using the (.+) skill, you would (.+)\\.$", {}, function(matches)
    local r = M.parse_stage_line(matches[1])
    if r then
      print(util.ansi.gray .. ("[spellcheck] stage %d %s: %s"):format(r.n, r.skill, r.verdict) .. util.ansi.reset)
    end
  end)
  trigger_add("^The spell, (.+), is an? (.+) spell requiring", {}, function(matches)
    local r = M.parse_spell_header(matches[1])
    if r then
      print(util.ansi.gray .. ("[spellcheck] %s (%s spell)"):format(r.name, r.kind) .. util.ansi.reset)
    end
  end)
  trigger_add("^  You are surrounded by a magical impact shield\\.$", {}, function()
    print(util.ansi.cyan .. "[shields] impact shield: UP" .. util.ansi.reset)
  end)
  trigger_add("^  You are protected by the power of (.+)\\.  You will be protected for (.+)\\.$", {}, function(matches)
    local r = M.parse_shield_line(matches[1])
    if r then
      print(util.ansi.cyan .. "[shields] divine: " .. r.detail .. util.ansi.reset)
    end
  end)
end

-- /spellcheck <nick> live: resolve the nick and send the documented probe
-- (25 magic gp + 25 per stage for the full form, per the pinned help page).
function M.cmd_spellcheck_live(nick)
  local spell, nick_or_err = M.resolve(nick)
  if not spell then
    print(a("gray", "[hex] " .. tostring(nick_or_err)))
    return
  end
  mud.send("spellcheck fully " .. spell.name)
  print(a("gray", "[hex] sent: spellcheck fully " .. spell.name .. "  (stage verdicts print as they land)"))
end

local TYPE_COLOR = { Offensive = "red", Defensive = "green", Miscellaneous = "cyan" }

local function a(name, text)
  return util.ansi[name] .. text .. util.ansi.reset
end

local function bold(text)
  return util.ansi.bold .. text .. util.ansi.reset
end

local function spellcard(spell, nick)
  local skills = M.deps.skills
  local stats = skills and skills.stats() or nil
  print(
    a(TYPE_COLOR[spell.type] or "bold", bold(spell.name))
      .. a("gray", "  (" .. nick .. ")  " .. spell.type .. "  GP " .. spell.gp .. "  size " .. spell.size)
  )
  for _, line in ipairs(util.wrap(spell.description, 78)) do
    print("  " .. a("gray", line))
  end
  if spell.components and spell.components ~= "" then
    for _, line in ipairs(util.wrap("components: " .. spell.components, 78)) do
      print(a("gray", "  " .. line))
    end
  end
  local extras = {}
  if spell.octogram and spell.octogram ~= "" then
    extras[#extras + 1] = "octogram"
  end
  if spell.tome and spell.tome ~= "" then
    extras[#extras + 1] = "tome: " .. spell.tome
  end
  if spell.learnt_at and spell.learnt_at ~= "" then
    extras[#extras + 1] = "learnt at: " .. spell.learnt_at
  end
  if spell.notes and spell.notes ~= "" then
    extras[#extras + 1] = "notes: " .. spell.notes
  end
  if #extras > 0 then
    print(a("gray", "  " .. table.concat(extras, "  |  ")))
  end
  if not (spell.spellcheck and #spell.spellcheck > 0) then
    return
  end
  print(a("bold", "  spellcheck") .. a("gray", "  (your chance, the 50% bonus, and the level that reaches it)"))
  for _, st in ipairs(spell.spellcheck) do
    local full = M.data.spellskills[st.skill] or st.skill
    local deps = skilldata.skill_stats[full] or "CDISW"
    local level = skills and skills.level_of(full) or 0
    local bonus = skills and skills.bonus_for(level, deps, stats) or 0
    local chance = M.stage_chance(st.thresholds, bonus)
    local t50 = st.thresholds[5]
    local hint_level = skills and skills.level_for_bonus(t50, deps, stats) or "?"
    print(
      ("   %d. %-12s %3d%%   50%% at bonus %3d   (%s level %s)"):format(
        st.stage,
        st.skill,
        chance,
        t50,
        full,
        tostring(hint_level)
      )
    )
  end
end

-- /spellinfo <nick|name>
function M.cmd_spellinfo(query)
  local spell, nick = M.resolve(query)
  if not spell then
    print(a("gray", "[hex] " .. nick))
    return
  end
  spellcard(spell, nick)
end

-- /spellcheck <nick|name>: the card's table alone.
function M.cmd_spellcheck(query)
  M.cmd_spellinfo(query)
end

-- /tm <method> [n]: the suggestion list for a method shorthand.
function M.cmd_tm(method, limit)
  local bonus = M.method_bonus(method)
  local list = M.suggestions(method, bonus)
  if #list == 0 then
    print(a("gray", "[hex] no spells use the method: " .. method))
    return
  end
  limit = tonumber(limit) or 10
  local cutoff = tonumber(config() and config().get("tm_cutoff", 9)) or 9
  print(
    a("bold", "TM candidates: " .. method)
      .. a("gray", ("  (method bonus %d, blacklist via /hexset tm_blacklist)"):format(bonus))
  )
  local shown, warned = 0, false
  for _, entry in ipairs(list) do
    if shown >= limit then
      break
    end
    if not warned and entry.tm < cutoff * 10 then
      print(a("yellow", "  Very low TM chance:"))
      warned = true
    end
    local star = entry.suggestion and a("green", " * ") or "   "
    print((" %s %-12s tm %3d%%  %s"):format(star, entry.nick, entry.tm, entry.spell.name))
    shown = shown + 1
  end
end

-- /spells [list|long|<method>|<text>]
function M.cmd_spells(args)
  args = util.trim(args or "")
  local stats = M.deps.skills and M.deps.skills.stats() or nil
  if args == "" or args == "list" then
    print(a("bold", "Spells") .. a("gray", "  " .. #M.data.order .. " in the dataset; /spells long for descriptions"))
    for _, nick in ipairs(M.data.order) do
      print(("  %-12s %s"):format(nick, M.data.spells[nick].name))
    end
  elseif args == "long" then
    for _, nick in ipairs(M.data.order) do
      print(a("bold", ("  %-12s %s"):format(nick, M.data.spells[nick].name)))
      for _, line in ipairs(util.wrap(M.data.spells[nick].description, 74)) do
        print("        " .. a("gray", line))
      end
    end
  elseif M.data.spellskills[args] then
    M.cmd_tm(args)
  else
    -- text search over names and descriptions
    local hits = {}
    for _, nick in ipairs(M.data.order) do
      local spell = M.data.spells[nick]
      if spell.name:lower():find(args:lower(), 1, true) or spell.description:lower():find(args:lower(), 1, true) then
        hits[#hits + 1] = nick
      end
    end
    if #hits == 0 then
      print(a("gray", "[hex] no spells match: " .. args))
      return
    end
    print(a("bold", #hits .. " spells match") .. a("gray", "  /spellinfo <nick> for the card"))
    for _, nick in ipairs(hits) do
      print(("  %-12s %s"):format(nick, M.data.spells[nick].name))
    end
  end
end


return M
