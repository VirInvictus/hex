# Phase 3: the working character — missions, quota, skills, stats

Design doc. Status: designed, not implemented. Sources: tt_dw `scripts/missions/*.tin`, `status/quota.tin`, `char/*.tin`, `sql/migrations/*.tin`, `settings/default.tin`, `util/setup_check.tin`. Carried invariants: no `mud.send` outside user-alias handlers and no timer ever sends (cooldown reminders render/announce only); no third-party deps; per-alt state keyed on the `char.info` capname; nil-guarded parsers; registry-wrapped registration; Rust regex has no lookaround.

Blightmud facts used (verified): `timer.add(duration, count, cb)` one-shot with count=1 (`blightmud.d.lua:576-582`); `TriggerOptions.count` = fire N times then auto-remove (`:1401`) — the parse-window mechanism; `mud.add_output_listener` sees every line but is evaluated and rejected here (triggers are cheaper than an always-on listener).

## 1. hex_missions

### 1.1 Data model (per-alt)

Maps 1:1 to tt_dw's `mission` SQL table (`sql/migrations/001_create_database.tin`; loaded/saved by `missions/missions.tin:71-99, 103-145`):

```
missions[short_name] = { count, avg_time, est_time (EMA: (dur+est)/2), min_time, max_time,
                         start (epoch), resets[] (future reset epochs, one per completion),
                         data (optional, e.g. sausage critter) }
```

Static data module `src/hex_missiondata.lua` (pure, "gags as data" philosophy):

- Base XP per mission — `missions.tin:21-51`.
- Labels/icons — `missions.tin:54-61`, `job_market_board.tin:5-34`, `dead_letters.tin:22-49`.
- Sausage per-critter XP (plain + spiced) — `sausage_xp.tin:6-86` (upstream flags it "probably not 100% correct").
- Learned-XP override for the difficult letter — tt_dw mutates the static table (`dead_letters.tin:165-171`); Hex stores the override in the per-alt blob instead.
- In-room gating identifiers — `map/mapper.tin:7-9`: JOB_MARKET `a5846b0acd26afec87c2dc20daa7ccadecc94cff`, DEAD_LETTER `109a9d6ff64b288e95580099e5b72864d67e4d33`, SAUSAGES `4fa03c4998210cec6f87fbbde0ad82611270ddf9`; Hex gates board-parsing triggers on `room.id == <id>` from GMCP.

Derived (pure, unit-tested): `mission_count = #resets` (`:200-204`); `mission_xp = floor(base / 2^count)` (`:299-300`; sausages: per-critter table else `per_dollar_xp * dollars` with A$25 default, `:277-298`); `mission_rate = xp / (est_time + travel) * 3600` with `mission_travel_time` default 60 s (`settings/default.tin:140`) becoming config.

### 1.2 Missions shipped in v1

Full base-XP table: 13 job market missions (Thirst Quencher 1,600 up to Expert Street Maintenance Technician 188,000), 9 dead letters (12,800-50,064, difficult customer learned), 2 sausage types (per-dollar), 2 side missions (Theodor Hackett, Pennie Laced, 24,000 each). Repair writs are NOT v1: `repair.tin` has no start/complete calls (verified across all 107 lines). `deliver.tin`'s shopping-list tracker is a Phase 3.x follow-up (no cooldown semantics; depends on Phase 2).

### 1.3 Output-line triggers (tt_dw pattern → Rust regex)

Job market: `^Basic Jobs:$` (board reset, in-room gated); `^\s*([BMH][A-F])\) (.+)$` (board id → short name; generic match avoids tt_dw's paren-escaping workaround at `job_market_board.tin:41-43`); `^Mr Werks hands you an official employment writ\.$` (start pending); `^You have been awarded ([\d,]+) experience points for .*completing this job\.` (complete); `^The time has expired on your present job\.$` (cancel); `^Mr Werks exclaims to you: Resigning your job!$` (cancel + 600 s announce); the writ-pop line (clear).

Dead letters: pigeonholes header reset; `^DL([A-I]): (.+)$` (available letters); `^Frank grabs a.+? letter ...$` (start); `^You offer to give a.+? letter to Frank\.$` (cancel + 600 s); awarded line (learn difficult XP); `^As you were too late, ...$` (10 s late flag suppressing completion); `^You deliver the.+? letter to ` (complete).

Sausages — a 4-state board machine (tt_dw arms/disarms one-shot actions at `sausages.tin:61-72`; Hex uses a `board_state` field): start `^You have .+ to deliver (\d+) fresh (.+) sausages to Sam Slager\.$` (critter = **last word** of capture 2, per `:14-17`); postpone; awarded; `^Written in pinned notes:$` opens; `^Plain:` / `^Flavoured:` set category; entry `^(.+?) +(\d+) sausages      A\$(\d+)\.(\d+)$` — **six literal spaces** before `A$` per the pattern; terminator closes the board.

Side missions: Theodor Hackett and Pennie Laced start/complete lines as quoted in their `.tin` files.

**Starting a mission:** tt_dw hijacks raw input (`apply for X`); Hex does not hijack arbitrary input. `/apply <board id or name>` sends `apply for <id>` and records the pending short name (user alias = sanctioned); `/dl <A-H>` same for letters. Writ with no pending record prints tt_dw's failure line plus the `/missions pending <id>` hint.

### 1.4 Completion + announce-only timer engine

Completion (`missions.tin:315-370`): duration only when start known; `est_time = (dur+est)/2`; `avg` arithmetic update; min/max; announce `Mission: <label> gave <xp>xp in <dur>: <rate>/hr.`; `count += 1`, `resets += now + 3600` regardless; save; re-check timers.

Timer engine (`check_mission_timers`, `:225-268`), pure + announce-only:

```
prune resets <= now:
  expired within the last 6 h (alert_time) -> queue "Mission: <label> has been reset!"
    (once per mission, only when its pending count reaches 0, :372-379)
  older -> silent prune (login spam prevention, :245-248)
persist; if a future reset exists: timer.add(1 + next - now, 1, check_mission_timers)
```

No send path at all. The three 600 s "available" announces are session-only one-shot timers. **Registry extension (load-bearing): `hex_registry` gains kind `"timer"` with `timer.remove(id)` in `reap()`** — without it `/hexreload` doubles pending timers.

### 1.5 Persistence

Store key `hex.missions.<alt>` (JSON blob; their save is DELETE+INSERT, `:105, 137-144`; full rewrite is the honest equivalent). Learned difficult-letter XP under top-level `"_learned"`.

### 1.6 Status chip + `/missions`

`status.render(st, room, width)` gains a 4th `chips` argument (ordered strings; row 2 becomes the chips row: XP/h, alignment, then chips by priority `quota > mission > future`). Mission chip `[M:32m]` = minutes to next reset. `/missions` sorts by rate descending then XP descending (tt_dw's comparator at `:382-395`; its trailing comment contradicts its own comparator — the spec follows the code). `/missions <name>` shows reset epochs; XP display rules from `/show_mission` (`:433-496`): `(N)` pending suffix, `~` prefix for sausages/difficult letter.

## 2. hex_quota

Session-only state (tt_dw unvars it on class load, `quota.tin:4`). Parsers (all two-space indented, nil-guarded): receipts (dollar + pence forms), min/max quota, owed, paid, and the six `Time left:` variants (`:48-83`), missing units stored as 0. Design improvement over the port: tt_dw decrements with a 1 Hz tick (`:131-150`); Hex stores `quota_deadline = now + seconds` once and derives remaining time at render — no tick, no drift. Expiry announces `*** Quota reset! ***` via a one-shot registry timer. Chip port of `:85-129`: `[Q:$max-$rcpt=$left]` + ` O:$owed!` + time (`1:10` / `9m` / `9m5s`), colors red/yellow/cyan (`:110-117`). Populated passively when the player runs `check quota brief` (tt_dw never sends it either); `/quota refresh` is an explicit user alias.

## 3. hex_skills

### 3.1 The listing parser — armed per-line triggers, not an output listener

tt_dw's flow (`char/skills.tin:442-468`): send `options output skills = list`, `skills`, then `options output skills = branched`; the listing arrives in list mode; the restore line is the terminator. The whole round-trip lives inside the `/skills refresh` alias (sanctioned). Requires the Phase 1.x paging setup (`rows 999`, `options terminal automatic rows = off` — `util/setup_check.tin:68-79`).

Triggers armed only while the window is open (alias opens; terminator or a 30 s display-only safety timer closes): terminator `^Set option output skills to branched\.$`; header `^SKILL\s+Level Bonus$` (confirm+gag); echo gags for the three sent commands; and one combined skill-line regex replacing tt_dw's four depth patterns (`skill_updates.tin:60,64,71,74`):

```
^(\w[\w-]*(?:\.\w[\w-]*){0,3})\s+(\d+)\s+(\d+|X)$
```

(tt_dw's 4-comp pattern forbids hyphens, its 3-comp allows them; no 4-comp skill in `char/data.tin:4-262` contains a hyphen, so the superset is safe.) Only the level column is stored — tt_dw parses the bonus but never uses it (`skill_updates.tin:16-30`); bonuses are derived. Parent fallback for omitted child skills (`skill_functions.tin:71-77`).

### 3.2 Bonus formula (Phase 4 depends on this)

From `char/skill_functions.tin` (credited to bonuses.irreducible.org / Jeanie):

```
raw_level_bonus(level)            -- :102-114
  <= 20: 5*level | <= 40: 2.5*(level-20)+100 | <= 60: (level-40)+150 | else: 0.5*(level-60)+170 (floored)

stat_multiplicator(skill)         -- :117-151
  deps = skill_stats[skill] (e.g. "CCDDS", char/data.tin:4-262)
  prod = product of stat values (0 skipped, negatives divide by abs)
  m = 0.1020408 * ln(prod) - 0.25 ; m < 0 -> 0

bonus = floor(raw * m)            -- :81-99
```

Cross-check pinning the constant: all stats 13 → prod 13^5 = 371,293 → m = 1.05865, exactly the `base = 1.0586452` in `stat_quality_indicator` (`:213`). Golden test material. Inverse `level_for_bonus` (`:33-55`): raw = wanted/m rounded up to the integer satisfying floor(m*raw) ≥ wanted, then invert the piecewise table.

### 3.3 Cost formulas (`char/skill_cost.tin`)

```
primaries to min(target,300):  cost/level = floor(75 * floor(level/3 + 1) * e^(level/150))   (:21-43)
others (teach_cost :48-75):
  bonus = raw_level_bonus(level)
  max_etb = max(bonus+200, bonus*1.5)
  cetb = teach_bonus and min(teach_bonus, max_etb) or max_etb
  k = 1.5 - (cetb-bonus)/(max_etb-bonus) * (1.5 - (0.5*bonus/800 + 1))
  simple_k = 0.5*bonus/cetb + 1 ; if simple_k < k: k = simple_k
  cost = floor(500 + 250*level*e^(level/500) * k)
```

Their cache is unneeded — keep the function pure. Target grammar ported from `skill_input.tin:151-188` (`120`, `+10`, `l120`, `b200`, `r180`, `+b20`).

### 3.4 Storage and commands

`hex.skills.<alt>`: flat dotted keys → level. Static companion `src/hex_skilldata.lua`: skill_stats deps (`data.tin:4-262`), primaries per guild/spec (`:274-314`), root skills list.

Commands: `/skills [refresh|search]`, `/bonus <skill> [target]`, `/skillcost <skill> [target] [etb N]` (multi-skill totals, primaries flagged `*`, cap note at 300), `/goal add|update|remove`, `/goals` (xp_goal_bar port, `skills.tin:399-439`). Goal alerts: tighten the existing advance trigger to capture skill + level (tt_dw does the same, `status.tin:724-730`), diff stored goals, announce-only. Goal storage `hex.goals.<alt>` JSON array (mirrors their `skill_goal` table).

## 4. hex_stats

The whole `score verbose stats` table is **one line** (`stat_updates.tin:5`); `/stats refresh` sends `score verbose stats` inside the alias with echo gags. One combined regex with literal dot counts (3/6/3/7/9/9/9), optional parenthesised boost per stat, height/weight. `raw = current - boost` (`:30-40`); the stored boost excludes known effects — the netting contract with Phase 4's stat-items is documented there and finalized in Phase 4's design. Storage `hex.stats.<alt>` JSON. Stats are hidden state (no chips): consumers are `/stats` display, the Phase 3 bonus math, and Phase 4.

## 5. Command surface

| command | sends? | notes |
|---|---|---|
| `/missions [name]`, `/missions pending <id>` | never | table per §1.6; pending fixup |
| `/apply <id>`, `/dl <A-H>` | **yes** (user alias) | record pending mission/letter |
| `/quota`, `/quota refresh` | display / **yes** | chip + display |
| `/skills`, `/skills refresh` | never / **yes** | summary; 3-command listing round-trip |
| `/bonus`, `/skillcost`, `/goal*`, `/goals` | never | formulas above |
| `/stats`, `/stats refresh` | display / **yes** | raw (+boost) per stat |

Announce-only outputs (no send, ever): mission-reset, job-market/letter/sausage-available (600 s), quota-reset, skill-goal-reached, skill-increase lines.

## 6. Test plan

Fixtures are transcript blocks built from the action patterns themselves: quota brief (the real example at `quota.tin:6-15`, plus pence variant and all six Time-left forms), job market board + writ lifecycle (EMA math against hand-computed values), dead letter office (including Frank-grabs with no pending record — nil-guard), sausage board (six-space rows, last-word critter), skills listing (hyphenated 3-comp, 4-comp, `X` bonus, terminator closing), score verbose (boost netting), golden math (raw_level_bonus at 20/40/60/300; all-13 bonus = floor(290 × 1.05865) = 307; level_for_bonus round-trip; cost monotonicity), timer engine (announce vs silent prune vs re-arm delay; structural no-send check).

## 7. Open questions

1. Does `options output skills = list` still exist? (Branched fallback would change the terminator.)
2. The `X` bonus column semantics.
3. Comma-grouped currency in quota receipts (parser already tolerates).
4. Does `char.info` carry guild/specialisation (primaries selection)? Fallback: `/skillcost --guild <name>` stored per-alt.
5. `mission_travel_time` is a flat 60 s upstream; per-mission travel via Phase 2 path lengths is the better v2.
6. Bare-id input hijack (`B` → `apply for B`) deliberately not ported — `/apply` covers it.
7. Skill-increase lines: confirm the plain advance line always fires so goal alerts can't miss self-taught levels.


## Official-docs corrections (2026-11-05 research)

- The official ETB definition differs from tt_dw's model: ETB is the average of (taught-skill bonus) and min(teaching bonus, 2 x taught bonus), capped. `/skillcost` output carries a caveat that its teach-cost numbers are tt_dw approximations.
- `hskills` (and `hskills brief`) is the documented skill-increase feed (`X increased by N levels (and bonus B) to level L (and bonus B).`) - sanctioned fallback for goal alerts.
- `score stats` is documented as a 3-line dot-padded table (dot counts match ours exactly); the one-line assumption needs the live check with cols/rows set.
- `score brief` documented shape (`Hp: 913 (1040) Gp: 122(122) Xp: 36190`) has no Burden field and different paren spacing than phase-6's regex - wire-verify.
- `skillcap` exists (>=300, multiples of 25): a capped skill's used level is the cap; parsers should note it.
- Official: stats start at 13; `rearrange` sets 8-23 total <=65, once ever. Guild primaries tables list category entries meaning 'all children primary' - hex_skilldata stores that rule.
