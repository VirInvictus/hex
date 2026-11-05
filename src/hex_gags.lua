-- hex_gags.lua: gags v1, ported from tt_dw's misc/gags.tin (top categories
-- only). Data, not code: each entry is { re = pattern, i = bool, sub = nil }.
-- A plain entry gags the whole line; an entry with sub = replacement empties
-- or rewrites the line so list tails stay readable. Patterns target the Rust
-- regex engine (no lookaround/lookbehind; tt_dw's %i becomes the 'i' flag).
local M = {}

-- tt_dw builds $pets/$summons/$critters/$movements and gags the assembled
-- pattern; the alternation below is the same list flattened.
local PETS = [[[\w']+ the mynah bird|an? (?:astonished chicken|battered old owl|intelligent black raven|proud black duck|young goose)|[\w-]+(?: [\w-]+)? (?:moon|swamp) dragon|deadly fluffy hawk|scrawny tabby cat]]
local SUMMONS = [[\w+ cabbages|an? (?:tiny .+ moth|cabbage|[\w-]+(?: [\w-]+)? cloud|small blue light)|swarm of fireflies|skeleton warrior|\w+ spectre|\w+ salamander]]
local CRITTERS = ("(?:(?:%s|%s)(?:, | and )?)+"):format(PETS, SUMMONS)
local MOVEMENTS = [[(?:trot|emerge|swim|flutter|succeed|arrive|journey|precede|follow|float)s?(?: you in)?]]

M.patterns = {
  -- pet/summon movement spam (tt_dw misc/gags.tin:6-14)
  { re = "^" .. CRITTERS .. MOVEMENTS, i = true },
  { re = "^You continue sneaking\\.$" },
  -- MWLC ambient line + its list tails
  { re = "^A small blue light is zipping about\\.$" },
  { re = "^A small blue light is zipping about[,.]", sub = "" },
  { re = "[,.] a small blue light is zipping about", sub = "" },
  { re = " and a small blue light is zipping about", sub = "" },
  -- UPDD moth + tails
  { re = "^A tiny .+ moth is flittering about\\.$" },
  { re = "^A tiny .+ moth is flittering about[,.]", sub = "" },
  { re = "[,.] a tiny .+ moth is flittering about", sub = "" },
  { re = " and a tiny .+ moth is flittering about", sub = "" },
  -- Hag's blessing fireflies + tails
  { re = "^A swarm of fireflies is buzzing around\\.$" },
  { re = "^A swarm of fireflies is buzzing around[,.]", sub = "" },
  { re = "[,.] a swarm of fireflies is buzzing around", sub = "" },
  { re = " and a swarm of fireflies is buzzing around", sub = "" },
  -- system noise
  { re = '^There are discussion items you have not voted for, use "rtfm list all" for a list\\.$' },
  { re = "^Rows changed from \\d+ to \\d+\\.$" },
  { re = "^Queued command: rows \\d+$" },
  -- /goto walk noise (tt_dw paths.tin:203-212 port): travel-option
  -- confirmations and compact queued-command echoes. The walk itself adds a
  -- catch-all "Queued command" gag for its duration; these cover the
  -- residual shapes seen outside walks. The alias-definition echo shape
  -- (Added/Changed alias) is wire-unverified: tonight's capture confirms.
  { re = "^Set option personal travel to walk\\.$" },
  { re = "^Set option personal travel to journey\\.$" },
  { re = "^Queued command: options personal travel = (walk|journey)$" },
  { re = "^Queued command: frimble hex: walk done$" },
  { re = "^Queued command: alias hex_goto_walk" },
  { re = [[^(Added|Changed) alias "hex_goto_walk"$]] },
  { re = "^Queued command: hex_goto_walk$" },
  { re = "^Queued command: (journey )?((n|s)?(e|w)|n|s|u|d)$" },
}

-- Register everything with blightmud's trigger system (called from main.lua,
-- which owns the blightmud globals).
function M.register(trigger_add, Regex)
  for _, p in ipairs(M.patterns) do
    local re = p.re
    if p.i then
      re = Regex.new(p.re, { case_insensitive = true })
    end
    if p.sub ~= nil then
      local to = p.sub
      trigger_add(re, {}, function(_, line)
        line:replace(to)
      end)
    else
      trigger_add(re, { gag = true }, function() end)
    end
  end
end

return M
