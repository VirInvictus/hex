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

return M
