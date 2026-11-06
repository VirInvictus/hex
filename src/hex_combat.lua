-- hex_combat.lua: the combat spam ladder and the combat-monitor vitals
-- fallback (design: docs/phase-6-social.md §2-3; ported from tt_dw's
-- misc/combat.tin and doc/mud_settings.md strings installed by /hexsetup).
--
-- Ladder (combat.tin:24-55 semantics, levels as data):
--   verbatim = raw everything, no gags
--   verbose  = raw + digests (Phase 7; today: same as verbatim)
--   default  = defense/"nothing happened" lines gagged
--   brief    = all raw gagged, only the digests to come
-- /combat cycles or sets; per-alt persistence via hex_config.get_for_alt.
--
-- Precedence rule (non-negotiable): GMCP wins. The monitor triggers count
-- rounds always, but only write vitals when no GMCP push has arrived within
-- 120 s; a GMCP push always overwrites monitor-sourced values (both feeds
-- assign absolute values, so there is no arithmetic and no double-counting).
--
-- Family patterns are the tt_dw verb alternations verbatim (tintin -> Rust:
-- %1ou becomes ^.+ou, the odd 'e' verb stems are tt_dw's own before the
-- trailing s). The divine-ire / special-weapon tail of combat.tin stays
-- pending as data work against tonight's capture.
local util = require("src.hex_util")
local notify = require("src.hex_notify")

local M = {}

M.deps = {}
M.level = "default"
M.handles = {} -- live family trigger ids (removed on rebuild)
M.rounds = 0
M.attacks = 0
M.round_baseline = nil

M.ORDER = { "verbatim", "verbose", "default", "brief" }

M.LEVEL_GAGS = {
  verbatim = { nop = false, act = false },
  verbose = { nop = false, act = false },
  default = { nop = true, act = false },
  brief = { nop = true, act = true },
}

-- defense / nothing-happened lines (gagged at default and brief)
M.NOP_FAMILIES = {
  "but you (?:deftly |just |easily )?(?:block|parry) the blow with .+",
  "but you (?:deftly |just |easily )?dodge out of the way",
  -- the Combat Crib training pumpkin's dodge (wire: capture 2026-11-06
  -- 00:31; tt_dw has no "see it in time" family -- it never fights dummies)
  "but you see it in time and manage to dodge it",
  "but, although unable to defend, you",
  "your floating .+ swoops in and absorbs (?:all|most)",
  "but your (?:flaming barrier|.+ flames) absorbs? (?:all|most|some)",
  "but your .+ absorbs? (?:all|most|some)",
  "but .+ (?:blocks|parries|dodges|absorbs|avoids)",
}

-- action lines (gagged at brief only): hits/burn verbs, unarmed forms,
-- hurt verbs, misses, prepares/fails, specials. The moon-dragon exclusion
-- is a code check in the hurt callback (Rust has no lookaround).
local HIT_VERBS = "snick|fillet|poke|chop up|chop|jab|scratch|boot|kick|hit|tickle|hack|prick|shred|nick|cut|stab|perforate|pierce|impale|slice|skewer|take|touch|sear|smoke|torch|fry|crisp|scorch|roast|singe|melt|char|burn|incinerate|cremate|vapourise|blister|broil"
local HURT_VERBS = "bruise|smashe|poke|chop|jab|scratche|boot|kick|hit|tickle|hack|prick|shred|nick|cut|stab|perforate|pierce|impale|slice|skewer|fillet"

M.ACT_FAMILIES = {
  { "^\\w+ou (?:viciously |messily |barely |neatly )?(?:" .. HIT_VERBS .. ") " },
  -- tt_dw combat.tin:394 anchors with period+end; the port's trailing space
  -- never matched the live "with an uppercut." form (found by the 00:31 capture)
  { "^\\w+ou (?:gently |barely )?(?:slice at|run .+ through|make a kebab of|beat|hit .+ with a{n|} (?:vicious |)(?:hook|cross|kick|uppercut))\\.$" },
  { " (?:viciously |messily |barely |neatly )?(?:" .. HURT_VERBS .. ")s ", moon_dragon = true },
  { " runs you through the " },
  { " hitting you on the " },
  { " makes a kebab of your " },
  { "^You .+ but .+ (?:absorb|dodge|parri|block)s?" },
  { "^You .+ but, although unable to defend" },
  { "^You .+ but you cannot" },
  { "^You prepare to " },
  { "^You attempt to .+ but (?:you move too slowly|you cannot)" },
  { "^You attempt to prepare a special attack but" },
  { "^You launch a powerful attack" },
}

-- The combat-monitor strings installed by /hexsetup (doc/mud_settings.md).
-- Wire truth (capture 2026-11-06 00:31): the MUD actually sends its DEFAULT
-- monitor format per combat round -- "Hp: N (N) Gp: N (N) Xp: N" (single
-- spaces, parenthesised maxima, no burden, no prompt tail) -- and a bare
-- ">" prompt; the customised prompt/monitor shapes below stay registered
-- for when the /hexsetup strings take effect on a character.
M.MONITOR_LINE = "^Hp: (%d+)   Gp: (%d+)$"
M.DEFAULT_MONITOR = "^Hp: (\\d+) \\((\\d+)\\) Gp: (\\d+) \\((\\d+)\\) Xp: (\\d+(?:,\\d{3})*)$"
M.VERBOSE_PROMPT = "^Hp: (%d+) %((%d+)%)  Gp: (%d+) %((%d+)%)  Xp: (\\d+(?:,\\d{3})*)   \\(([^,]+), (.+)\\)>$"
M.SCORE_BRIEF = "^Hp: (%d+)\\((%d+)\\)  Gp: (%d+)\\((%d+)\\)  Xp: (\\d+(?:,\\d{3})*)  Burden: (\\d+)%%$"

-- --- pure core ---

function M.next_level(current)
  for i, level in ipairs(M.ORDER) do
    if level == current then
      return M.ORDER[i % #M.ORDER + 1]
    end
  end
  return M.ORDER[1]
end

-- which family sets are live at a level (design §2.2 table)
function M.families_for(level)
  return M.LEVEL_GAGS[level] or M.LEVEL_GAGS.default
end

-- Attacks-per-round since the previous query (combat.tin:6-11, 74-94):
-- rounds increment on monitor lines, attacks on act matches minus
-- backstabs. Pure: takes counted values, returns the report line.
function M.combatstat_line(rounds, attacks)
  if not rounds or rounds == 0 then
    return nil
  end
  return ("Attacks per round: %d/%d (%.2f)"):format(attacks, rounds, attacks / rounds)
end

-- --- runtime glue (blightmud globals below this line) ---

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function cyan(t)
  return util.ansi.cyan .. t .. util.ansi.reset
end

function M.setup(deps)
  M.deps = deps
  M.level = deps.config.get_for_alt("combat_level", "default")
end

-- (Re)register the family triggers for the current level. Family triggers
-- go through the registry-wrapped add so a reload reaps them; this module
-- tracks the ids for rebuild removal, and reaping removed ids is harmless.
function M.rebuild()
  for _, id in ipairs(M.handles) do
    pcall(trigger.remove, id)
  end
  M.handles = {}
  if not M.deps.trigger_add then
    return
  end
  local families = M.families_for(M.level)
  local function arm(patterns, is_nop)
    for _, entry in ipairs(patterns) do
      local re, moon = entry, nil
      if type(entry) == "table" then
        re, moon = entry[1], entry.moon_dragon
      end
      if (is_nop and families.nop) or (not is_nop and families.act) then
        local id = M.deps.trigger_add(re, { gag = not moon }, function(matches, line)
          -- act matches count attacks (backstabs included; the digest
          -- engine in Phase 7 splits them)
          if not is_nop then
            M.attacks = M.attacks + 1
            notify.emit("combat.attack", { line = line })
          end
          -- moon-dragon hurt lines stay visible when the Line API allows
          if moon and type(line) == "table" and tostring(line):find("moon dragon", 1, true) and type(line.gag) == "function" then
            line:gag(false)
          end
          return line
        end)
        M.handles[#M.handles + 1] = id
      end
    end
  end
  arm(M.NOP_FAMILIES, true)
  arm(M.ACT_FAMILIES, false)
end

-- /combat [level]: cycle or set, persist per alt, rebuild the ladder.
function M.cmd_level(args)
  local requested = util.trim(args)
  if requested ~= "" then
    local ok = false
    for _, level in ipairs(M.ORDER) do
      if level == requested then
        ok = true
      end
    end
    if not ok then
      print(gray("[hex] levels: verbatim, verbose, default, brief"))
      return
    end
    M.level = requested
  else
    M.level = M.next_level(M.level)
  end
  M.deps.config.set_for_alt("combat_level", M.level)
  M.rebuild()
  print(cyan("[hex] combat spam: " .. M.level))
end

-- Monitor + prompt triggers: count rounds always; write vitals only when
-- GMCP is stale or dead (docs §3 precedence). Gagged: the status area
-- replaces them.
local function monitor_write(vals)
  local vitals, vitals_mod = M.deps.vitals, M.deps.vitals_mod
  if not vitals or not vitals_mod then
    return
  end
  if vitals_mod.gmcp_alive(vitals, 120) then
    return -- GMCP wins; the monitor only counted the round
  end
  for key, value in pairs(vals) do
    if key == "maxhp" or key == "maxgp" then
      vitals.max[key == "maxhp" and "hp" or "gp"] = value
    else
      vitals.cur[key] = value
    end
  end
  if vals.xp and vitals.cur.xp and vitals.cur.xp > 100 and not vitals.xp_start then
    vitals.xp_start = { xp = vitals.cur.xp, t = os.time() }
  end
end

function M.register(trigger_add, Regex)
  -- the monitor/prompt strings (gagged; the status area replaces them)
  trigger_add(Regex.new(M.MONITOR_LINE, { gag = true }), {}, function(matches)
    M.rounds = M.rounds + 1
    monitor_write({ hp = tonumber(matches[2]), gp = tonumber(matches[3]) })
  end)
  -- the default format the MUD actually sends per round (wire-verified)
  trigger_add(Regex.new(M.DEFAULT_MONITOR, { gag = true }), {}, function(matches)
    M.rounds = M.rounds + 1
    monitor_write({
      hp = tonumber(matches[2]),
      maxhp = tonumber(matches[3]),
      gp = tonumber(matches[4]),
      maxgp = tonumber(matches[5]),
      xp = tonumber((matches[6]:gsub(",", ""))),
    })
  end)
  trigger_add(Regex.new(M.VERBOSE_PROMPT, { gag = true }), {}, function(matches)
    M.rounds = M.rounds + 1
    monitor_write({
      hp = tonumber(matches[2]),
      maxhp = tonumber(matches[3]),
      gp = tonumber(matches[4]),
      maxgp = tonumber(matches[5]),
      xp = tonumber((matches[6]:gsub(",", ""))),
    })
  end)
  trigger_add(Regex.new(M.SCORE_BRIEF, { gag = true }), {}, function(matches)
    monitor_write({
      hp = tonumber(matches[2]),
      maxhp = tonumber(matches[3]),
      gp = tonumber(matches[4]),
      maxgp = tonumber(matches[5]),
      xp = tonumber((matches[6]:gsub(",", ""))),
      burden = tonumber(matches[7]),
    })
  end)
  M.rebuild()
end

-- /combatstat: attacks per round since the previous query, baseline reset.
function M.cmd_combatstat()
  local line = M.combatstat_line(M.rounds - (M.round_baseline or 0), M.attacks - (M.attack_baseline or 0))
  if not line then
    print(gray("[hex] no combat rounds counted yet (the monitor counts during combat)"))
    return
  end
  print(cyan("[hex] " .. line))
  M.round_baseline = M.rounds
  M.attack_baseline = M.attacks
end

return M
