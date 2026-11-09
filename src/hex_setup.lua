-- hex_setup.lua: /hexsetup, the game-side options tt_dw requires so text
-- parsing and room maps behave (design: docs/phase-1x-setup.md A1).
-- Every string is verbatim from tt_dw's scripts/util/setup_check.tin and
-- doc/mud_settings.md; the $...$ tokens are literal MUD-side prompt template
-- variables, not Lua interpolation. Rows paging uses the DOCUMENTED form
-- ("options terminal rows=999"; bare "rows 999" is undocumented and invalid
-- values reset to 24), and "term xterm256" is the officially recommended
-- colour setting (see the official-docs corrections at the bottom of the
-- design doc).
--
-- Spec invariant: these sends live inside the alias handler only. Hex never
-- re-sends, schedules, or batches them.
local util = require("src.hex_util")

local M = {}

-- group -> list of MUD command lines, in send order.
M.groups = {
  prompt = {
    'prompt "$hurtcolour$Hp: %^BOLD%^$hp$%^RESET%^$hurtcolour$ ($maxhp$)  Gp: $gp$ ($maxgp$)  Xp: $xp$   ($align$, $temp$)%^RESET%^>"',
    'monitor $hurtcolour$Hp: %^BOLD%^$hp$%^RESET%^$hurtcolour$   Gp: $gp$%^RESET%^',
  },
  aliases = {
    "alias afterinventory gp brief;shields;inventory;score brief",
  },
  options = {
    'options set output map all "off"',
    "brief exits",
    -- "options terminal automatic rows = off" is deliberately NOT sent:
    -- wire-verified 2026-11-05, the MUD rejects it ("Unable to set") when
    -- rows are telnet-negotiated, which blightmud always does via NAWS
    "options terminal rows=999",
    "term xterm256",
  },
}

local GROUP_ORDER = { "prompt", "aliases", "options" }

function M.commands(what)
  local out = {}
  for _, group in ipairs(GROUP_ORDER) do
    if what == "all" or what == group then
      for _, cmd in ipairs(M.groups[group]) do
        out[#out + 1] = cmd
      end
    end
  end
  return out
end

local function a(name, text)
  return util.ansi[name] .. text .. util.ansi.reset
end

local function help()
  print(a("gray", "/hexsetup: send the game-side options tt_dw requires"))
  print("  /hexsetup preview [what]  show what would be sent (no MUD traffic)")
  print("  /hexsetup prompt          the MUD prompt + combat monitor strings")
  print("  /hexsetup aliases         the afterinventory alias (you run it yourself)")
  print("  /hexsetup options         map off, brief exits, rows paging, colours")
  print("  /hexsetup all             the three groups, in order")
  print(a("gray", "  Each line prints first, then sends one at a time. Hex never"))
  print(a("gray", "  re-sends these or puts them on a timer."))
end

-- what: nil|"help"|"all"|"prompt"|"aliases"|"options"; send=false renders
-- the preview instead of touching the MUD.
function M.run(what, send)
  if what == "help" or M.commands(what)[1] == nil then
    if what ~= "help" and what ~= nil then
      print(a("gray", "[hex] unknown group: " .. what))
    end
    help()
    return
  end
  local cmds = M.commands(what)
  for _, cmd in ipairs(cmds) do
    print(a("gray", "[hex] send: " .. cmd))
    if send then
      mud.send(cmd)
    end
  end
  if send then
    print(a("gray", "[hex] setup sent: " .. #cmds .. " commands. Verify in-game with: options output"))
  end
end

-- Register /hexsetup through the caller's registry-wrapped alias_add.
function M.register(alias_add)
  alias_add("^/hexsetup$", function()
    M.run(nil, false)
  end)
  alias_add("^/hexsetup\\s+(.+)$", function(matches)
    local arg = matches[2]:match("^(%S+)") or ""
    if arg == "preview" then
      local rest = matches[2]:match("^preview%s+(%S+)%s*$")
      M.run(rest or "all", false)
    else
      M.run(arg, true)
    end
  end)
end

-- --- /hexcheck: the options-output reader (the 1.x Tier-2 parser) -----------
-- The live listing shape (wire-verified 2026-11-05): "name = value <choices>"
-- and "name <more options>" for submenus. /hexcheck refresh arms a short
-- window, sends "options output", and a wide trigger records the rows while
-- armed; /hexcheck bare shows the stored listing. The window timer is
-- announce-only and never sends (spec invariant 1).

M.OPTION_WINDOW = 3
M.check = { armed_until = nil, rows = nil }

-- One listing line -> row table or nil. Pure.
function M.parse_option_line(line)
  line = util.trim(tostring(line))
  local name, value, choices = line:match("^([%a%d][%a%d _]-) = (.+)%s*<(.+)>$")
  if name then
    return { name = util.trim(name), value = util.trim(value), choices = util.trim(choices) }
  end
  name = line:match("^([%a%d][%a%d _]-)%s*<more options>$")
  if name then
    return { name = util.trim(name), submenu = true }
  end
  return nil
end

function M.render_options(rows)
  local lines = {}
  for _, r in ipairs(rows or {}) do
    if r.submenu then
      lines[#lines + 1] = ("  %-28s <more options>"):format(r.name)
    else
      lines[#lines + 1] = ("  %-28s = %s %s"):format(r.name, r.value or "?", r.choices and ("[" .. r.choices .. "]") or "")
    end
  end
  return lines
end

-- --- runtime glue (blightmud globals below this line) ------------------------

M.deps = {}

function M.setup(deps)
  M.deps = deps or {}
end

local function check_armed()
  return M.check.armed_until and os.time() <= M.check.armed_until
end

-- The listing-window trigger: broad on purpose, gated by the armed window
-- in the callback (a two-line guard when disarmed).
function M.register_check(alias_add, trigger_add)
  alias_add("^/hexcheck\\s*(.*)$", function(matches)
    local arg = util.trim(matches[2] or "")
    if arg == "" and M.check.rows and #M.check.rows > 0 then
      print(a("bold", "options listing") .. a("gray", "  " .. #M.check.rows .. " rows; /hexcheck refresh re-reads"))
      for _, l in ipairs(M.render_options(M.check.rows)) do
        print(l)
      end
      return
    end
    M.check.armed_until = os.time() + M.OPTION_WINDOW
    M.check.rows = {}
    mud.send("options output")
    print(a("gray", "[hex] sent: options output (listing lands within " .. M.OPTION_WINDOW .. "s; /hexcheck views it)"))
    if M.deps.timer_add then
      M.deps.timer_add(M.OPTION_WINDOW, 1, function()
        M.check.armed_until = nil
        print(a("gray", "[hex] options listing closed: " .. (#M.check.rows or 0) .. " rows"))
      end)
    end
  end)
  trigger_add("^\\w.*$", {}, function(matches)
    if not check_armed() then
      return
    end
    local row = M.parse_option_line(matches[1])
    if row then
      M.check.rows[#M.check.rows + 1] = row
    end
  end)
end

return M
