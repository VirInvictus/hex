-- hex_missiondata.lua: static mission data, ported from tt_dw
-- (missions/missions.tin:21-61 base XP, job_market_board.tin:4-33 names and
-- icons, dead_letters.tin:14-56 letter tables, sausage_xp.tin per-critter
-- tables, mapper.tin:7-9 the in-room gating identifiers). Pure data: gags-
-- as-data philosophy, so balance changes from upstream are data edits.
-- Sausage XP is dwwiki research, flagged upstream as "probably not 100%
-- correct"; duplicates in tt_dw's spiced table resolve to their last value.
local M = {}

-- in-room gating identifiers (tt_dw map/mapper.tin:7-9)
M.JOB_MARKET_ID = "a5846b0acd26afec87c2dc20daa7ccadecc94cff"
M.DEAD_LETTER_ID = "109a9d6ff64b288e95580099e5b72864d67e4d33"
M.SAUSAGES_ID = "4fa03c4998210cec6f87fbbde0ad82611270ddf9"

-- board id letter -> mission short name (job_market.tin ids)
M.jobs = {
  quencher = "Thirst Quencher",
  gofer = "Gofer",
  dogwalker = "Dog Walker",
  advertising = "Advertising Manager",
  lackey = "Delivery Lackey",
  fixer = "Street Fixer",
  sett_maker = "Sett Maker",
  textiles = "Textiles Fixer",
  runner = "Delivery Runner",
  repairer = "Full-time Street Repairer",
  rare = "Deliverer of Rare Items",
  forn = "Deliverer of Foreign Goods",
  maintenance = "Expert Street Maintenance Technician",
}

-- name -> short (board lines carry these; the (m/f) suffix is stripped by
-- the lookup before it gets here)
local jobs_long = {}
for short, name in pairs(M.jobs) do
  jobs_long[name] = short
end

-- board line name -> short; tolerates the "(m/f)" suffix some boards show
function M.job_short(name)
  local short = jobs_long[name]
  if not short then
    local bare = name:match("^(.-)%s*%([^()]*%)$")
    if bare then
      short = jobs_long[bare]
    end
  end
  return short
end

-- pigeonhole letter -> mission id suffix (dead_letters.tin:18-28)
M.letters = {
  A = "close_smudged",
  B = "close_decipher",
  C = "close_vague",
  D = "close_city_only",
  E = "far_smudged",
  F = "far_decipher",
  G = "far_vague",
  H = "far_city_only",
  I = "difficult",
}

-- pigeonhole letter -> the board's description line (dead_letters.tin:29-39)
M.tletters = {
  A = "Close by; smudged address",
  B = "Close by; terrible handwriting",
  C = "Close by; vague address",
  D = "Close by; only the city",
  E = "Far away; smudged address",
  F = "Far away; terrible handwriting",
  G = "Far away; vague address",
  H = "Far away; only the city",
  I = "Difficult customer",
}

-- base XP per mission (missions.tin:21-51)
M.xp = {
  market_quencher = 1600,
  market_gofer = 6400,
  market_dogwalker = 16000,
  market_advertising = 24000,
  market_lackey = 16800,
  market_fixer = 19200,
  market_sett_maker = 20480,
  market_textiles = 25200,
  market_runner = 57600,
  market_repairer = 59200,
  market_rare = 72000,
  market_forn = 152720,
  market_maintenance = 188000,
  letter_close_smudged = 12800,
  letter_close_decipher = 25600,
  letter_close_vague = 24128,
  letter_close_city_only = 47823,
  letter_far_smudged = 25600,
  letter_far_decipher = 27456,
  letter_far_vague = 33440,
  letter_far_city_only = 50064,
  letter_difficult = 40000, -- a guess until the first difficult delivery learns the real value
  theodor_hackett = 24000,
  pennie_laced = 24000,
  plain_sausages = 1955, -- per-dollar; average payout assumed A$25
  spiced_sausages = 1992,
}

-- per-critter sausage XP (sausage_xp.tin, dwwiki research)
M.sausage_xp = {
  plain = {
    antelope = 49356,
    badger = 52800,
    bear = 80208,
    blowfish = 66000,
    chicken = 45000,
    cow = 52200,
    deer = 78311,
    donkey = 66264,
    elephant = 81708,
    fox = 43415,
    giraffe = 78000,
    goat = 56100,
    hare = 55176,
    heron = 56940,
    hippo = 96564,
    horse = 59615,
    hyena = 78311,
    ibis = 49500,
    jellyfish = 54431,
    leopard = 97032,
    lion = 78311,
    lobster = 64115,
    mixed = 66000,
    mollusc = 75059,
    mouse = 43200,
    octopus = 46332,
    penguin = 94068,
    pig = 65808,
    rabbit = 52559,
    raptor = 36384,
    rat = 34560,
    sheep = 51000,
    snake = 49500,
    squid = 104676,
    squirrel = 47520,
    tiger = 103272,
    tortoise = 59124,
    turkey = 63492,
    vulture = 47880,
    wolf = 72287,
    zebra = 60852,
  },
  spiced = {
    antelope = 91583,
    badger = 83700,
    deer = 110808,
    donkey = 98496,
    dragon = 87168,
    eagle = 102144,
    ["giant catfish"] = 120600,
    hare = 86592,
    hippo = 134352,
    hyena = 110808,
    ibis = 82944,
    jellyfish = 88332,
    leopard = 135000,
    lion = 110808,
    lobster = 96768,
    mixed = 100080,
    mollusc = 108239,
    monkey = 78120,
    moose = 110808,
    octopus = 87936,
    pig = 91583,
    penguin = 131112,
    raptor = 67548,
    rat = 66768,
    sheep = 81900,
    snake = 82944,
    squid = 145368,
    squirrel = 82175,
    tiger = 143424,
    tortoise = 72744,
    vulture = 95472,
    whale = 149280,
  },
}

return M
