-- hex_moneydata.lua: Discworld currency data + the Ankh-Morpork purse
-- parser (v0.23.0). Pure module; every value is verbatim from the pinned
-- official page (concepts/currency, staged in the doc mirror). The purse
-- line shape is wire-verified: "Your purse contains 3 Ankh-Morpork
-- half-dollars, 34 Ankh-Morpork ten-pence and 90 Ankh-Morpork pence."
-- (2026-11-09 log). A$ notation: one dollar is 400 brass and one penny is
-- 4, so A$3.07 reads as 3 dollars and 7 pence.
local util = require("src.hex_util")

local M = {}

-- Brass value of each Ankh-Morpork coin, singular and wire plural forms.
M.AM_COINS = {
  ["penny"] = 4, ["pence"] = 4,
  ["ten-pence"] = 40,
  ["half-dollar"] = 200, ["half-dollars"] = 200,
  ["dollar"] = 400, ["dollars"] = 400,
  ["ten-dollar"] = 4000, ["ten-dollars"] = 4000,
  ["royal"] = 40000, ["royals"] = 40000,
  ["crown"] = 3200000, ["crowns"] = 3200000,
}

-- The full brass table for reference cards (verbatim from the pinned page).
M.BRASS = {
  { name = "Ankh-Morpork", coins = "penny 4, ten-pence 40, half-dollar 200, dollar 400, ten-dollar 4000, royal 40000, crown 3200000" },
  { name = "Agatean Empire", coins = "saveloy-rhinu 4, quarter-rhinu 120, half-rhinu 240, rhinu 480, ten-rhinu 4800, fifty-rhinu 24000" },
  { name = "Genua", coins = "cent 3, vingt-cent 60, livre 300, forin 3000, ducat 30000" },
  { name = "Lancre", coins = "farthing 3, ha'penny 6, penny 12, tuppence 24, thruppence 36, sixpence 72, shilling 144, crown 1728, tencrown 17280, sovereign 20736, hedgehog 248832" },
  { name = "Djelibeybi", coins = "ptascp 2, talon 20, toon 200, talent 2000, ra 20000, thanra 100000" },
}

-- "3 Ankh-Morpork half-dollars, 34 Ankh-Morpork ten-pence and 90 Ankh-
-- Morpork pence" -> total brass, breakdown. Unknown coins are skipped and
-- counted; a string with no parseable coins returns nil.
function M.parse_am_purse(text)
  text = tostring(text):gsub("Ankh%-Morpork ", ""):gsub("%s+and%s+", ",")
  local total, parts, unknown = 0, {}, 0
  for raw in (text .. ","):gmatch("([^,%c]+)") do
    -- a local, not the loop variable: Lua 5.5 makes loop vars read-only
    local piece = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^and ", "")
    local n, coin = piece:match("^(%d+) (.+)$")
    if n then
      local v = M.AM_COINS[coin:lower()]
      if v then
        total = total + tonumber(n) * v
        parts[#parts + 1] = { n = tonumber(n), coin = coin, brass = tonumber(n) * v }
      else
        unknown = unknown + 1
      end
    end
  end
  if #parts == 0 then
    return nil
  end
  return total, parts, unknown
end

-- "A$3.07" -> brass (3 dollars x 400 + 7 pence x 4). Returns nil for
-- anything that is not the notation.
function M.parse_am_notation(text)
  local dollars, pence = tostring(text):match("^A%$(%d+)%.?(%d*)$")
  if not dollars then
    return nil
  end
  pence = pence == "" and 0 or tonumber(pence)
  return tonumber(dollars) * 400 + pence * 4
end

-- Brass -> "A$x.yy" (two pence digits).
function M.format_am(brass)
  brass = math.floor(tonumber(brass) or 0)
  local dollars = brass // 400
  local pence = (brass % 400) // 4
  return ("A$%d.%02d"):format(dollars, pence)
end

-- The documented bank card (room/bank, pinned): fee note verbatim.
function M.bank_card()
  return {
    "bank: balance | open account | close account",
    "  deposit <money> | withdraw <amount> <type> | balance book (A$5)",
    "  documented: banks charge a 5-10% administration fee on deposits;",
    "  withdrawals are free. Coins weigh: bank the grind money.",
    "  in-game: /hexdeposit <money> sends deposit (alias below)",
  }
end

-- The documented pawn card (room/pawn_shop, pinned).
function M.pawn_card()
  return {
    "pawn shop: pawn <object> -> a receipt; reclaim <receipt> to buy it back",
    "  documented: reclaim costs about 20% on top of the loan;",
    "  receipts expire and the item is sold; pawn shops never buy outright.",
    "  general stores buy for much less than they sell (shopping page).",
  }
end

-- --- runtime glue (blightmud globals below this line) -----------------------

M.deps = {}

function M.setup(deps)
  M.deps = deps or {}
end

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function bold(t)
  return util.ansi.bold .. t .. util.ansi.reset
end

function M.cmd_money(args)
  args = util.trim(args or "")
  if args == "" then
    print(gray("usage: /hexmoney <purse line | A$amount>   e.g. paste the purse line, or A$3.07"))
    print(gray("  /hexbank and /hexpawn print the documented money cards"))
    return
  end
  local notation = M.parse_am_notation(args)
  if notation then
    print(bold("money: ") .. M.format_am(notation) .. gray("  (" .. util.comma(notation) .. " brass)"))
    return
  end
  local total, parts, unknown = M.parse_am_purse(args)
  if not total then
    print(gray("[hex] no Ankh-Morpork coins parsed from that"))
    return
  end
  print(bold("money: ") .. M.format_am(total) .. gray("  (" .. util.comma(total) .. " brass)"))
  for _, p in ipairs(parts) do
    print(gray(("  %d x %s = %s brass"):format(p.n, p.coin, util.comma(p.brass))))
  end
  if unknown and unknown > 0 then
    print(gray("  " .. unknown .. " piece(s) were not Ankh-Morpork coins"))
  end
end

function M.card(kind)
  local lines = kind == "pawn" and M.pawn_card() or M.bank_card()
  print(bold(kind == "pawn" and "pawn (documented)" or "bank (documented)"))
  for _, l in ipairs(lines) do
    print(gray(l))
  end
end

return M
