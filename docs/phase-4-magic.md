# Phase 4: magic & faith: TPA, charms, spells, broom, stat items

Design doc. Status: §4's data lane implemented 2026-11-05 (v0.5.1: hex_spelldata committed dataset via tools/convert_spelldata.py, hex_spells TM/spellinfo/search; known-spells store deferred to the trackers batch). §2-3, §5-6 (TPA, charm, broom, stat items) stay designed-not-implemented, wire-gated on capture session #2. Measured source sizes: `magic/tpa.tin` 223 lines, `bugshield.tin` 99, `spellinfo.tin` 788, `spelldata.tin` 2,179 (117 spells), `spellsizes.tin` 138, `broomstick.tin` 92, `faith/*` 468, `items/*` 9 files. All paths relative to `~/.gitrepos/tt_dw/scripts/` unless `hex:`.

## 0. Modules

| Module | Purpose |
|---|---|
| `src/hex_tpa.lua` | TPA state machine, duration prediction, chip, expiry announce |
| `src/hex_charm.lua` | bugshield + faith rituals + FTF (shared tiny-tracked-effect shape) |
| `src/hex_spelldata.lua` | static 117-spell dataset (generated, committed, attributed) |
| `src/hex_spells.lua` | spelldata queries, TM algorithm, known spells, sizes, mindspace |
| `src/hex_broom.lua` | broomstick charges |
| `src/hex_statitems.lua` | worn/removed stat items; per-stat effect table |
| `tools/convert_spelldata.py` | dev-time spelldata.tin → hex_spelldata.lua (stdlib only) |

Constraint compliance: every timer only prints (the word "cast" may appear in an announcement; a `mud.send` never does); announce timers go through the registry "timer" kind (Phase 3); chips fit the `chips` argument to `status.render`; spell data is a static pure module with attribution.

## 1. Shared infrastructure

- Chips row contract (from Phase 3): `status.render(st, room, width, chips)`; producer contract `M.chip(state)` returns nil or a colored string ≤ ~22 visible chars. Assembly order in main.lua: `tpa, bugshield/faith, broom, statitems`.
- Registry "timer" kind: blightmud `timer.add(duration, count, cb) → id` (`blightmud.d.lua:569-596`); record as `registry.record("timer", { id = timer.add(...) })`; `reap()` gains `timer.remove(id)`. This matters: an armed TPA reminder without it fires a stale announcement after `/hexreload`.
- `hex_util` additions: `M.dur(seconds)` (port of `@dur`, `util/strings.tin:288-338`: `45s` / `12m05s` zero-padded / `1:05:12` / `2d03:05:12`), `M.parse_number` (English words → int; `util/numbers.tin`), `M.ansi.orange = "\27[38;5;208m"` (256-color, TPA wobbling orange only).
- Substitutions: every tt_dw `#sub` ports as a trigger whose callback calls `line:replace(...)` (`hex_gags.lua` already does this).

## 2. hex_tpa

State per alt (session-scoped): `{ status, start, end, hit, predicted }`.

Color → percentage tables ported verbatim from `tpa_col`/`tpa_perc` (`tpa.tin:51-72`): broken 0% bold white; invisible 100% bold yellow; dull red 80% red; bright red 60% bold red; wobbling orange 40% orange; flickering yellow 20% yellow.

Own-shield triggers (Rust regex, registry-wrapped), with `tpa.tin` line cites: the Plink! cast line (`:170-175`), absorb-visible (`:177-180`, hit+1), absorb-change (`:181-184`, hit+1), plain drift change (`:186-189`, no hit), lapse-to-invisible (`:190-193`), the white-flash break (`:195-198`, double space), look lines `You are surrounded by a (…) magical impact shield` (`:205-216`, `* ` prefix variant included), and the prepare-to-cast restart (`:217-221`).

`set_tpa` logic (port of `:97-131`): start anchoring rules, transition line `* <prev> -> <new> (<perc>%)` with `*` borders when the percentage dropped. `break_tpa` (`:133-168`): three-line banner with hit count, elapsed, and the expectation comparison.

**Duration prediction, the actual arithmetic**: `guess = bonus("magic.spells.defensive", "current") * 10` (`tpa.tin:82,150`; "duration based on guessed duration (bonus*10s)"); `left = guess - (now - start)`. The bonus comes from Phase 3's `hex_skills.bonus` (floor(raw_level_bonus × multiplicator)). Active-duration color bands (`:84-92`): <60s bold red, <300 red, <600 orange, <900 yellow. Break-time comparison (`:149-162`): guess > actual+600 bold red; +300 red; < actual−600 bold green; −300 green; prints `(expected: @dur{guess})`.

Announce-on-expiry: on cast and every re-colour implying remaining time, cancel and re-arm a one-shot `timer.add(max(left,1), 1, cb)`; the callback prints and refreshes status, never sends. On break, cancel (the break line is authoritative). Registry-recorded. Without `hex_skills`: no timer, chip shows elapsed only (silent degradation).

Chip (port of `:6-35`): hidden when broken >30 min ago; `[T:<colour><perc>% <hits>/<dur>]`; examples `[T:<red>80% 2/3m12s]`, `[T:<byellow>5m00s]`.

Others' shields: v1 ports only the green highlight and trivial look-line annotations; inline `(tpa: colour%)` annotations for other players deferred.

## 3. hex_charm: bugshield, faith, FTF

One module, submodules by table; each with `handle(line, state)`, `chip(state)`.

**Bugshield** (port of `bugshield.tin:7-35`; tt_dw matches unanchored, Hex anchors on determiners): orbit/hover/buzz/circle/web/cluster/flutter variants → up(size, bugs); hasty-retreat variant; look parse; warn/gone/down lines with their `***` banners. Shorteners (`:41-55`): strip "swarm"/" insects"/" bugs"/" beetles"/"praying "/"winged "/"flying ". Chip: up green, warn red, down bold red, gone yellow.

**Faith rituals**: Divine Ire set/clear with lasted duration (`faith.tin:21-35`; tt_dw's `#delay 0` exists only so the sub can read the duration first; Hex computes before clearing); Dark Sight set/clear; Cool/Warm set/clear lines; chip `[DS]`/`[DI]`/`[Cool]`/`[Warm]`.

**Major shield** (port of `faith/major.tin`): duration formula `duration = round(bonus("faith.rituals.defensive.self","current") - 10)` seconds (the dwwiki log formula approximated linearly upstream, `major.tin:16-22`); stacking `end = (end == nil) and now+duration or end + duration` (`:49-58`); gain/shift/weakening/expiry trigger lines (`:62-71, 52-55`); `check shields` range words → [min,max] pairs (`:75-123`); chip `[S: <colour>@dur{left}]` with 30/60/90/120/600s bands (`:23-37`). No expiry timer (tt_dw has none).

**Totem** (`faith/totem.tin`): rise/form/fed/crumble triggers, `/hextotem` info line.

**FTF** (`magic/ftf.tin`): float start/end triggers, `[FTF:<dur>]` chip. No pathfinding needed.

v1 vs deferred: CCC, EFF (needs Phase 6 combat stats), obbk, gfr, klein color chips, rod substitutions (pure `line:replace` data), find-ritual decoder (Phase 7 guild pack), PFG damage bands, all quoted in the exploration and cheap to add later.

Resync: `^Arcane protection status\.$` clears TPA + bugshield state (port of `magic.tin:22-28`).

## 4. hex_spelldata + hex_spells

**Dataset shape (measured)**: 117 spells; every spell carries name/nick/description/gp/size/components/type/spellcheck (117 each), octogram 93, tome 93 (wizards), learnt_at 25 (witches, plus one "Sold by Jorodin"). Every `spellcheck` stage has exactly 10 ascending bonus thresholds (5th = 50% point; 1st = fail, 10th = success). Skill shorthand map `spellskills` = 35 entries; `spellprimaries` = 8 wizard colors + witches.

**Port strategy**: `tools/convert_spelldata.py` (stdlib, dev-time) parses `#var spellinfos` from the read-only clone and emits a **committed** `src/hex_spelldata.lua` (~120-140 KB), committed because `/add_plugin` installs must work without a tt_dw clone (static shipped data is source, not runtime data; runtime data like rooms.db stays in `~/.local/share/hex`). Converter validates: 117 spells; 10 ascending checks per stage; every shorthand resolves; type ∈ {Offensive, Defensive, Miscellaneous}. Attribution header kept verbatim ("Spell info grabbed from the wiki; Spellcheck skills pilfered from Quow's plugin"; public domain).

**TM constants as config** (`spellinfo.tin:6-12`): `tm_blacklist` (24-spell default list, quoted in the exploration), `tm_cast_chance` 30, `tm_cutoff` 9, all via `/hexset`.

**TM algorithm (extracted, deterministic)**:
1. Stage chance: count thresholds passed ascending, **breaking at the first failure** (`:699-704`); `stage_chance = passed * 10`.
2. `spell_tm_chance` (`:743-768`): relative chance: for each stage with the method, `p = clamp(stage_chance,1,99)/100`, `tm = p*(1-p)`, `notm *= (1-tm)`; result `round((1-notm)*100)`. Comment quoted: "gives *relative* TM chance for sorting, real chance is way lower".
3. `spell_cast_chance` (`:708-723`): product over ALL stages; "(Probably) not the actual chance, so don't show this to users".
4. `spell_skills_50` (`:662-679`): the 5th threshold per stage.
5. Ordering: descending tm_chance; **stable** sort with spelldata-order tie-break, asserted by test.
6. Suggestion scan (`:568-582`): first non-blacklisted entry; replace when cast_chance improves or the current suggestion is blacklisted and the candidate is not; **break** once good enough (`:581`).
7. Filtering (`:543-565`): guild gating (witches → learnt_at spells, wizards → tome; unknown guild → no gating); known spells always listed; unknown with tm_chance ≤ 1 skipped unless `all`; if everything was skipped, show the skipped set anyway.
8. Low-chance marker: `Very low TM chance:` before the first entry under `tm_cutoff`.

Player skill inputs come from Phase 3's store; primaries stars from `spellprimaries` + guild.

**Commands**: `/spellinfo <nick|name>` (full card: type-colored bold name with known-`*`, gp/size, components, octogram/tome/learnt_at lines, the spellcheck table with Fail/Maybe/Success columns and per-stage chance/level/bonus/hint using Phase 3's `level_for_bonus`), `/spellcheck <nick>`, `/spells [list|long|<method>|<text>]`, `/tm <method>` (Hex convenience; tt_dw embeds the suggestion in `/spell <method>`; no `/tm` upstream).

**Known spells + sizes + mindspace** (port of `spellsizes.tin`): the `You know the following (offensive|defensive|misc) magic spells:` listing mode scanned with bounded `string.find` against the 117 canonical names (replaces tt_dw's 117 priority-9 actions); `You successfully remember X` adds; forget/do-not-know lines remove; persisted per-alt. `Total spell size: X/Y` where mindspace = `bonus("magic.spells.special","raw") + 30` (`spellsizes.tin:125-132`), red/green colored; wizard/witch note gated on guild.

## 5. hex_broom

Per-alt persisted `{ current, charges = {[name]=n} }` (deliberate improvement: tt_dw's charges are session-only but the broom survives logout). Capacity 3. Charge colors 4→bold green, 3→green, 2→yellow, 1→red, 0→bold red. Triggers (`broomstick.tin:56-90`): overfuel slosh → 3; brimming → 3; shake "fuel enough for N trips" → parse_number(N); not-enough/empty → 0; seating yourself → charges−1 floored at 0. Chip `[Broom:<n>]` (Hex composition of tt_dw's inline colors).

## 6. hex_statitems

Tracked set (`items.tin:5-7`): bronze_helm, dex_gloves, flat_cap, gp_light, klein_bottle, prayer_beads, str_gauntlets, thiefs_daggers. Per-alt persisted (improvement: tt_dw resets on user switch; the helm stays worn across logins). Trigger lines quoted and ported from the nine `items/*.tin` files (eyes prickle → helm on; dizzy → off; fingers twitch/stiffen; hands clench/twitch; unimagined possibilities → klein 1; mind races → 2; less articulate → off; the three faith glows → beads 0, power-of → 1, closeness/presence → 2, let-go → off; glow envelopes → gp_light; neck itch → cap on; skipping feeling → cap off; dagger tingle up/down).

**Effects table** (port of `@stat_effects`): con −3 helm; dex +2 dex_gloves, +1 daggers, burden bands −3/−2/−1 (≥100/>75/≥50); int +klein, +3 helm, +2 cap; str −1 dex_gloves, −3 cap, +2 str_gauntlets; wis +beads(0/1/2), +2 helm, +3 cap. Deferred: ephebe horse, Sek heart, shrine, bless, FNP (each needs its own timer).

**Netting math** (finalizing Phase 3's reserved contract): on the `score verbose stats` parse, `raw = current - shown_boost`; `stored_boost = shown_boost - statitems.effect(stat, burden)`; display `current = raw + effect + stored_boost`. `type=raw` uses raw alone (matches tt_dw `@stat{con;raw}` in the multiplicator). Self-healing if an item fires before a parse. Chip set: `[Helm] [Cap] [Str.G] [Dex.G] [T-dag] [Klein+n] [Beads] [Glow]` in fixed order with upstream's colors.

## 7. Travel files (brief, deferred)

`flyto.tin` (211 lines): per-area broomstick destination tables; the `where` field is prose, not a room key; resolving it needs Phase 2; tables port as pure data later. `pfg.tin`: six damage-word annotations, pure subs, v1-optional. No OCC file exists upstream.

## 8. Test plan

TPA fixtures (plink → absorb → change → lapse → break sequence; golden duration math at bonus 250 → 2500 s; band boundaries; break comparison bands; chip golden strings). Charm fixtures (every quoted trigger line; shortener table; major stacking math; totem counting). TM determinism (fake skills; exact ordering; blacklist-from-config changes the suggestion; clamp edges 0/100 → 1/99; skills_50 = 5th thresholds). Spelldata integrity (117 spells; 10 ascending checks; shorthand resolution; type enumeration; counts 93/93/25). Statitem netting round-trip (current 13, shown boost −1, helm on → raw 12, stored 2, current 13). Mindspace (raw-type bonus excludes item boosts). Broom sequences with word-numbers. Chip budget (≤24 visible chars; nil on empty state).

## 9. Open questions (wire verification)

1. Which command emits `Arcane protection status:`? (tt_dw only reacts.)
2. Natural TPA expiry silence (confirm by wearing to expiry); the `* ` look-line prefix source.
3. Bugshield noun/verb surface (one live sample each).
4. `spells` command output shape (one per line vs comma list).
5. `score verbose stats` exact spacing (Phase 3 dependency).
6. GMCP `char.info` guild/spec fields (witch/wizard TM gating); fallback `/hexset guild witches`.
7. `skill_stats` coverage for `magic.spells.defensive`, `magic.spells.special`, `faith.rituals.defensive.self`, and the ~35 spellcheck method skills.
8. prayer_beads tier-1 ambiguity (tt_dw's own comment: "can also be 2 :-(").
9. 256-color pass-through on the user's terminal (cosmetic).


## Official-docs corrections (2026-11-05 research)

- The official shield-status command is `shields` (no 'check shields' anywhere); output includes condition lines and 'protected for at least <duration>' wording.
- `meditate upon divine protection` officially clears all faith shields anywhere: second resync verb for hex_charm.
- Spells detach on death (helpdir/spells); the known-spells store needs a death-purge hook.
- `remember` documents mindspace's official dependency (magic.spells.special bonus); `spellcheck` documented (25 gp + 25/stage, accuracy vs magic.spells.special, stage verdict wording) as a sendable fallback.
- TPA, glow percentages, mindspace +30, and the ritual-duration approximations have NO official documentation - tt_dw attribution and Phase 8 fixture verification remain the path.
