# Hex roadmap

External materials for every phase are staged under `testing_facility/` (gitignored; symlinks to the tt_dw and blightmud clones, both databases, the CC0 sounds; a downloaded stock blightmud v5.7.1 binary for degraded-path testing; a pinned GMCP doc snapshot; live-capture scaffolding) — see [docs/testing-facility.md](docs/testing-facility.md). The converter now carries the maze `extra`/shape column (1,246 shape rows verified), unblocking Phase 5's guess design.

Every phase below has an implementation-ready design document under [docs/](docs/README.md), produced by the 2026-11-04/05 exploration campaign (eight research agents; measured benchmarks, extracted formulas, wire-verification backlogs). The roadmap tracks boxes; the docs carry the designs. The official Discworld documentation mirror and the research findings built from it live in [docs/discworld-docs-research.md](docs/discworld-docs-research.md) — including the automation ruling that reshaped the `/goto` walker.

**Position (2026-11-05): Hex is Brandon's primary Discworld client** — the TinTin++/tt_dw setup was declined; the tt_dw clone stays as the porting source, and since v0.2.0 `/hexupdate` owns the Quow database and sound copies in Hex's data directory (the tt_dw copy is only a fallback until the first `/hexupdate` run).

North star: Hex becomes the Discworld suite a Blightmud player reaches for first, the way Quow's Cow Bar is the suite a MUSHclient player reaches for first. That bar has three parts, and every phase below serves one of them: nothing essential is missing (map, vitals, data, missions, magic), nothing breaks quietly (the GMCP lesson: verify every protocol claim against the live wire), and nothing feels alien to a terminal user (one binary, text everywhere, zero dependencies).

House invariants that out-rank every phase:

- No autonomous MUD input. Discworld's automation rule (concepts/automation, quoted in docs/discworld-docs-research.md) bans anything that could unidle a character without the user acting at the same time, including blank lines; every send lives behind a user alias, and the only multi-step sender Hex will ever contain is a user-asked ONE-SHOT batch speedwalk — the officially sanctioned "fast" style (all route commands queued in one go, unalterable except by the user typing `stop`; the room-by-room "slow" style is explicitly banned).
- Third-party data is read-only: Quow's database, the tt_dw clones, the MUD's logs.
- No third-party dependencies: Lua 5.4 stdlib and Python stdlib only.
- Protocol claims get verified on the wire (`/hexraw`, `/hexprobe`) before features build on them.

## Phase 1: core + Quow (M1) — shipped, hardening in 1.x

- [x] `hex_util`: ANSI helpers, SQL escape, glob-to-LIKE, pipe splitting, row parsing
- [x] `hex_gmcp`: the documented Discworld handshake (`core.supports.set`, lowercase, per-command), vitals/info/room handlers, JSON decode, `/hexprobe`
- [x] `hex_vitals`: vitals model with tolerant key spellings, XP-rate model
- [x] `hex_status`: 3-row status area renderer (bars, XP, room, burden)
- [x] `hex_rooms`: current-room tracking, `/where`, rooms.db lookups
- [x] `hex_queries`: ported Quow query builders (`/item`, `/items`, `/npc`, `/shop`)
- [x] `hex_commands`: aliases and nil-guarded rendering
- [x] `hex_gags`: gags v1 as data
- [x] `hex_config`: namespaced persistence, `/hexset`
- [x] `tools/convert_map.py`: tt_dw map -> rooms.db (62,130 rooms, 156,800 exits)
- [x] `tests/run.lua` + `tests/test_convert_map.py` green
- [x] Live GMCP probe against Discworld (handshake verified against the game's own doc after the first login exposed the dead-vitals bug)
- [x] v0.1.0 release: patchnotes entry, annotated tag, pushed (2026-11-05)

### 1.x hotfix lane (current)

- [x] `/hexraw`, `/hexreload` with the handle registry (no double-registration on reload)
- [x] Nil-guarded renderers; placeholder status bars at load and on connect
- [x] Password-safe logging (sent lines are skip-logged while a password prompt is up)
- [x] Pin the real `char.vitals` JSON keys (live 2026-11-05: hp, maxhp, gp, maxgp, xp, burden, alignment; room.info is {identifier, name, visibility, kind}, so `kind` feeds terrain)
- [x] `/hexsetup`: one alias that sets the game-side options tt_dw requires (prompt and monitor strings, `brief exits`, `options set output map all "off"`, `options terminal rows=999` — the documented form; bare `rows 999` is undocumented and invalid values reset to 24 — plus `term xterm256`, the officially recommended colour setting) so text-parsing fallbacks and room maps behave; `brief exits` and `automatic rows` stay live-verified
- [x] `room.map` colour handling: strip or render the ANSI the MUD embeds; honor the plain-map option (`options output map plain = on`, officially documented) — `/dwmap` strips at render by default (`hex.map_ansi ansi` keeps colours; the raw payload stays stored for Phase 5's panel)
- [ ] `/hexcheck` Tier-2 parser: the documented `options output` shape is space-separated with no `=` in some trees and `key = value` in others (tactics); live-verified before shipping (tonight's capture session)
- [x] `/gaglog` and a gag registry file so players add their own gags as data without touching code
- [x] Optional quow DB auto-refresh check (`update.sh -q` parity): warn when the database is older than 60 days
- [x] **"Hex owns its data"**: default `quow_db` moves to `~/.local/share/hex/` with a `/hexupdate` alias that downloads Quow's database directly (and a Hex-owned CC0 sound copy), so daily play no longer depends on the tt_dw clone — shipped with the resolution ladder (explicit `/hexset` > Hex's copy > tt_dw copy with hint)

## Phase 2: find your way (M2) — the mapper that matters first

The enabling fact from the M1 research: the MUD's 40-hex room identifier is the same key in tt_dw's map file, Quow's database, and GMCP `room.info`. Pathfinding therefore needs no spatial layout engine, only a graph.

- [x] `tools/convert_map.py` v2: exits gain the dir bitmask and one-way flags as queryable columns (already captured, now exercised) — area/area-name indexes added too; the graph build consumes command/dir/flag/distance
- [x] `hex_paths`: Dijkstra over the identified-room subgraph (32,499 rooms) in pure Lua, weights from exit distance — shipped at 31,157 nodes / 78,979 edges; BP and Genua are disconnected in this subgraph (measured 2026-11-05, docs/phase-2-mapper.md §0 correction; boats are Phase 5)
- [x] `/path <search>`: resolve a target by room name, identifier prefix, or Quow room id; print the route as a readable step list (street-by-street, not just "7n 2e") — grouped segments with counts, `--full` for every room, candidate list with per-candidate step counts
- [x] `/goto <target>`: user-invoked ONE-SHOT batch speedwalk — every route command queued in a single burst on one user invocation (the officially sanctioned "fast" style per concepts/automation), cancellable with `stop`/`/stopwalk`; room.info drives post-hoc drift reporting only (never re-sends, never re-routes) — shipped as tt_dw's packed-alias port: travel option + route + optional journey restore + frimble marker in one MUD-side alias, two sends total
- [x] `/near <search>`: nearest match to the current room by path length — top five, one multi-target Dijkstra
- [ ] Quow `/item` and `/npc` results gain walk-distance and "nearest source" ordering
- [ ] Research deltas applied: `options personal travel = walk|journey` handling is officially documented; journey arrival lines and maze identifiers remain wire-only (official docs silent)
- [ ] Walk drift reporting as a status chip (post-hoc: the batch queue sends once; room.info drives the step counter and drift warnings only) — drift REPORTING shipped in v0.3.0 as milestone/mismatch/completion lines; the status-row chip lands with Phase 3's `status.render` chips argument
- [x] Tests: golden routes against hand-picked city pairs; Dijkstra property tests on synthetic graphs — goldens are opt-in (`HEX_GOLDEN=1 lua tests/run.lua`, needs rooms.db): Djel 129 positive; BP and Genua documented-negative; BFS-equivalence, tie determinism, one-way, avoid, multi-target synthetic properties in the default suite

## Phase 3: the working character (M3)

- [x] `hex_missions`: job market, dead letters, sausages, delivery cooldown trackers with per-alt persistence (tt_dw semantics, missions.tin port) — shipped v0.4.0; skills and stats boxes below stay wire-gated on tonight's capture
- [x] Mission XP estimates and XP/hour integration into the status row — live XP table + best-rate ordering; the status row carries the minutes-to-reset chip (the full chips row lands with the skills batch)
- [x] Thief quota chip from `check quota brief` (regex already spec'd) — deadline model instead of tt_dw's 1 Hz tick; passive parse, `/quota refresh` sends
- [ ] `hex_skills`: parse `options output skills = branched` listings into a per-alt skills store
- [ ] Skill cost calculator and skill goals (`/skillcost`, `/goal`) ported from tt_dw
- [ ] `/skillcost` carries the official ETB caveat (the documented teaching-bonus formula differs from tt_dw's teach-cost model); parsers note `skillcap` (used level = cap when capped) and the 3-line `score stats` layout (live check); `/goal` alerts accept `hskills brief` lines as a sanctioned second feed
- [ ] Stat parsing from `score verbose` for bonus-dependent features

## Phase 4: magic & faith (M4)

- [ ] TPA tracker: glow-colour parse, duration model from defensive bonus, `[T:colour%]` status chip
- [ ] Bugshield (witches) and ritual chips (faith) on the same text-trigger pattern
- [ ] `hex_spells`: spelldata port (static dataset), `/spellinfo <spell>` with TM suggestions ordered by skill
- [ ] Official-doc hooks: resync via `shields` (the official command name; "check shields" appears nowhere) and `meditate upon divine protection`; the known-spells store purges on death (spells detach on death per helpdir/spells); TM framing stays informational per the automation page's trivialising clause
- [ ] TM blacklist and cast-chance constants as config, not code
- [ ] Sendable fallbacks where docs are silent: `spellcheck` (documented cost/accuracy model) and `remember` when skill data is unavailable
- [ ] Broomstick charge tracking, mindspace gauge, spell sizes
- [ ] Stat-item tracking (worn/removed chips)

## Phase 5: the room (M5) — mapper v2

- [ ] ASCII minimap panel from GMCP `room.map` (already stored; now rendered beside the status area or in a dev-tab, feature-detected)
- [ ] Written-map people tracker (MDT) parsing `room.writtenmap`
- [ ] Lost-room matching by name/area when the identifier is unknown (tt_dw's guess logic, identifier-keyed)
- [ ] Library (UU/Shades/AoA) and maze movement modes; shared-instance identifiers disambiguated by room name
- [ ] Journey/boat routing on top of the room graph (ferry tables as data) — now load-bearing: the identified-subgraph sea gap makes BP boat-only (measured 2026-11-05, docs/phase-2-mapper.md §0)
- [ ] Room-kind vocabulary: `outside` officially documented alongside inside/underwater (road/water stay live-verified)
- [ ] Travel annotations for `/path`: carriages (documented arrival message set) and arcane transport NPCs (`list / travel to / cancel`, fixed price, language-gated)
- [ ] Blorps and bookmarks: label -> room id in Hex's own SQLite, walk-to via Phase 2

## Phase 6: the social layer (M6)

- [ ] Chat capture (tells, souls, club/talker channels) into a scrolling dev-tab, feature-detected
- [ ] Awareness-rule constraint (concepts/automation): the chat tab must never bury tells out of sight - the main feed stays readable
- [ ] Talker regexes adopt the documented line shapes (leading dash, parenthesised channel, `saying : `); club names are player-configurable, so club regexes stay wire-checkable (`blight.create_tab` exists in the dev tree)
- [ ] Combat spam levels (default/brief/verbose) with per-level gag sets, tt_dw `/combat` parity
- [ ] Combat monitor parsing as a vitals fallback when GMCP is unavailable
- [ ] URL catching and `/urls` recall
- [ ] Notification hooks: mission-ready, connection loss, TPA expiring (sound-ready, see Phase 7)

## Phase 7: feel & options (M7)

- [ ] Sound effects through blightmud's audio module (mission reset, TPA plink, damage), gated by an options flag
- [ ] `/hexoptions`: an options menu over config with persisted toggles (gag levels, sound, chat tab, walker confirmations)
- [ ] Guild packs: witch/warrior/thief/priest/assassin modules as opt-in data files, ported from tt_dw's guild trees
- [ ] Theme constants extracted so the whole suite re-skins from one table
- [ ] Theme raw material: the MUD documents ~250 colour names (xterm256-exact), hex codes, and `ansi*` overrides; MXP offers native 24-bit colour
- [ ] `/hexoptions` records that auto-reconnect after quit/idle-out is banned by name (never grows one)
- [ ] Per-alt profiles: config inheritance (global -> alt) like tt_dw's settings order

## Phase 8: ship as the premiere suite (M8)

- [ ] CI: GitHub Actions running `lua tests/run.lua` and the Python suite on every push; green before any tag
- [ ] Reconcile the ruff pin (local 0.17.2 vs CI 0.16.8) with a format-only commit before the first CI run
- [ ] Golden tests: recorded Quow query outputs asserted against the builders, so refactors cannot change semantics silently
- [ ] A fake-GMCP harness: replay captured payload fixtures through the handler chain in plain Lua, so protocol regressions die in CI instead of at login
- [ ] README with screenshots/asciinema of the status area, `/item`, and `/path`; install docs for `/add_plugin <url>`
- [ ] A dwwiki and r/MUD announcement post (drafted here, posted by Brandon)
- [ ] v1.0.0: every phase above either shipped or consciously deferred in this file, tag with the full patchnotes entry per house release procedure

## Week sprint (declared 2026-11-05: "we'll have this finished within the week")

Aggressive, honest, gated: every LIVE item needs a capture session from Brandon (30-60 min/day with `/hexprobe` + `/hexraw` on). "Finished" definition for the sprint: the daily-play suite is transformed (1.x + Phases 2, 3, 4-core, 6 by Nov 12); Phase 8's full definition-of-done and Phase 5's wire-gated halves land week two on the way to v1.0.0.

- [x] **Thu 6**: 1.x completion — `strip_ansi` + `/dwmap` default, `/hexsetup` (documented strings, `term xterm256`, `options terminal rows=999`), gag registry file, Quow staleness + **"Hex owns its data"** (`/hexupdate`, quow_db moves to `~/.local/share/hex/`). Ship v0.2.0.
- [x] **Fri 7**: Phase 2 core — `hex_targets` resolver, `hex_paths` (Dijkstra + heap + render), `/path`, `/near`; bench + synthetic property tests. (shipped 2026-11-05, a day ahead of its label)
- [ ] **Sat 8 (FULL DAY - the open weekend)**: 1.x completion + Phase 2 core + Phase 2 walker in one run - `/hexsetup`, `/hexupdate`, gag registry, resolver, Dijkstra, `/path` `/near`, batch `/goto`, drift chip, goldens. Ship v0.3.0 by night. **Brandon: capture session #1 in the evening** (seed, `options output`, quota/score transcripts, chat sweep - this feeds everything after).
- [ ] **Sun 9 (FULL DAY)**: Phase 3 verified against Saturday's captures - missions data + board triggers + timer engine + `/missions`, quota chip, then skills parser + bonus/cost/goals + stats. Ship v0.4.0-pre by night. Phase 6 chat starts in the background.
- [ ] **Mon 10**: Phase 3 — skills parser + bonus/cost/goals + stats, verified against the capture. Ship v0.3.1.
- [ ] **Tue 11**: Phase 6 — chat capture + tab, combat gag ladder, URLs, `hex_notify` bus; monitor fallback.
- [ ] **Wed 12**: Phase 4 core — TPA state machine + prediction, charm chips, broom, stat-items. Ship v0.4.0 "premiere core". **Brandon: capture session #2** (maze rooms, journey, TPA expiry).
- [ ] **Week 2**: Phase 4 TM + spelldata converter; Phase 5 minimap/MDT/maze/guess (wire-gated) + blorps/hex.db; Phase 7 sound/theme/options; Phase 8 CI + shim + goldens + announcement. v1.0.0 when the definition-of-done is true, not when the calendar says so.

## Deliberately out of scope

A spatial automapper that draws its own rooms (the MUD's `room.map` and the tt_dw-derived graph cover the need), any kind of botting or idle-keeping (the rules and the spec both forbid it), and any dependency outside the two standard libraries.
