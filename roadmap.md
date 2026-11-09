# Hex roadmap

External materials for every phase are staged under `testing_facility/` (gitignored; symlinks to the tt_dw and blightmud clones, both databases, the CC0 sounds; a downloaded stock blightmud v5.7.1 binary for degraded-path testing; a pinned GMCP doc snapshot; live-capture scaffolding); see [docs/testing-facility.md](docs/testing-facility.md). The converter now carries the maze `extra`/shape column (1,246 shape rows verified), unblocking Phase 5's guess design.

Every phase below has an implementation-ready design document under [docs/](docs/README.md), produced by the 2026-11-04/05 exploration campaign (eight research agents; measured benchmarks, extracted formulas, wire-verification backlogs). The roadmap tracks boxes; the docs carry the designs. The official Discworld documentation mirror and the research findings built from it live in [docs/discworld-docs-research.md](docs/discworld-docs-research.md), including the automation ruling that reshaped the `/goto` walker.

**Position (2026-11-05): Hex is Brandon's primary Discworld client**: the TinTin++/tt_dw setup was declined; the tt_dw clone stays as the porting source, and since v0.2.0 `/hexupdate` owns the Quow database and sound copies in Hex's data directory (the tt_dw copy is only a fallback until the first `/hexupdate` run).

**Debug lane (v0.5.2-dbg → REMOVED in v0.6.0 → RESURRECTED in v0.12.1-dbg)**: `/hexcapture` shipped in v0.5.2-dbg, fed the wire-verification backlog (transcripts archived at `~/.local/share/hex/captures/`), and was cut out of v0.6.0 entirely as planned. Reintroduced in v0.12.1-dbg (asked-for) for the combat-monitor verification pass; REMOVED again in v0.15.0 (its captures landed), while `/doctor` is the permanent in-client self-test.

North star: Hex becomes the Discworld suite a Blightmud player reaches for first, the way Quow's Cow Bar is the suite a MUSHclient player reaches for first. That bar has three parts, and every phase below serves one of them: nothing essential is missing (map, vitals, data, missions, magic), nothing breaks quietly (the GMCP lesson: verify every protocol claim against the live wire), and nothing feels alien to a terminal user (one binary, text everywhere, zero dependencies).

House invariants that out-rank every phase:

- No autonomous MUD input. Discworld's automation rule (concepts/automation, quoted in docs/discworld-docs-research.md) bans anything that could unidle a character without the user acting at the same time, including blank lines; every send lives behind a user alias, and the only multi-step sender Hex will ever contain is a user-asked ONE-SHOT batch speedwalk, the officially sanctioned "fast" style (all route commands queued in one go, unalterable except by the user typing `stop`; the room-by-room "slow" style is explicitly banned).
- Third-party data is read-only: Quow's database, the tt_dw clones, the MUD's logs.
- No third-party dependencies: Lua 5.4 stdlib and Python stdlib only.
- Protocol claims get verified on the wire (`/hexraw`, `/hexprobe`) before features build on them.

## Phase 1: core + Quow (M1); shipped, hardening in 1.x

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
- [x] `/hexsetup`: one alias that sets the game-side options tt_dw requires (prompt and monitor strings, `brief exits`, `options set output map all "off"`, `options terminal rows=999` (the documented form; bare `rows 999` is undocumented and invalid values reset to 24), plus `term xterm256`, the officially recommended colour setting) so text-parsing fallbacks and room maps behave; `brief exits` and `automatic rows` stay live-verified
- [x] `room.map` colour handling: strip or render the ANSI the MUD embeds; honor the plain-map option (`options output map plain = on`, officially documented): `/dwmap` strips at render by default (`hex.map_ansi ansi` keeps colours; the raw payload stays stored for Phase 5's panel)
- [x] `/hexcheck` Tier-2 parser: shipped v0.20.0 (`/hexcheck refresh` arms a short window and sends `options output`; the window trigger records `name = value <choices>` and `name <more options>` rows; `/hexcheck` renders the stored listing). Live shape CONFIRMED by the 2026-11-05 capture
  - live verification (2026-11-05 capture): `brief exits` bare works ("Okay."); `options set output brief exits on` is INVALID on this MUD (never sent by Hex); `options terminal automatic rows = off` is REJECTED under blightmud's NAWS negotiation (dropped from the send list); `rows=999`, `term xterm256`, `map all "off"` and `map plain = on` all confirm with `Set option ...` echoes (now gaged)
- [x] `/gaglog` and a gag registry file so players add their own gags as data without touching code
- [x] Optional quow DB auto-refresh check (`update.sh -q` parity): warn when the database is older than 60 days
- [x] **"Hex owns its data"**: default `quow_db` moves to `~/.local/share/hex/` with a `/hexupdate` alias that downloads Quow's database directly (and a Hex-owned CC0 sound copy), so daily play no longer depends on the tt_dw clone; shipped with the resolution ladder (explicit `/hexset` > Hex's copy > tt_dw copy with hint)

## Phase 2: find your way (M2), the mapper that matters first

The enabling fact from the M1 research: the MUD's 40-hex room identifier is the same key in tt_dw's map file, Quow's database, and GMCP `room.info`. Pathfinding therefore needs no spatial layout engine, only a graph.

- [x] `tools/convert_map.py` v2: exits gain the dir bitmask and one-way flags as queryable columns (already captured, now exercised); area/area-name indexes added too; the graph build consumes command/dir/flag/distance
- [x] `hex_paths`: Dijkstra over the identified-room subgraph (32,499 rooms) in pure Lua, weights from exit distance; shipped at 31,157 nodes / 78,979 edges; BP and Genua are disconnected in this subgraph (measured 2026-11-05, docs/phase-2-mapper.md §0 correction; boats are Phase 5)
- [x] `/path <search>`: resolve a target by room name, identifier prefix, or Quow room id; print the route as a readable step list (street-by-street, not just "7n 2e"): grouped segments with counts, `--full` for every room, candidate list with per-candidate step counts
- [x] `/goto <target>`: user-invoked ONE-SHOT batch speedwalk: every route command queued in a single burst on one user invocation (the officially sanctioned "fast" style per concepts/automation), cancellable with `stop`/`/stopwalk`; room.info drives post-hoc drift reporting only (never re-sends, never re-routes); shipped as tt_dw's packed-alias port: travel option + route + optional journey restore + frimble marker in one MUD-side alias, two sends total
- [x] `/near <search>`: nearest match to the current room by path length: top five, one multi-target Dijkstra
- [x] Quow `/npc` and `/items sold` results gain walk-distance and "nearest source" ordering — shipped v0.20.0 (one multi-target Dijkstra annotates the result rows; unreachable sorts last; the plain `/item` card has no room to measure and stays as-is)
- [x] Drift reporting as a status chip — shipped v0.20.0 (the walk chip `»N/M` shows queue progress and `!drift N/M` marks the first mismatch; milestone/mismatch lines unchanged since v0.3.0)
- [ ] Research deltas applied: `options personal travel = walk|journey` handling is officially documented; journey arrival lines and maze identifiers remain wire-only (official docs silent)
- [ ] Walk drift reporting as a status chip (post-hoc: the batch queue sends once; room.info drives the step counter and drift warnings only); drift REPORTING shipped in v0.3.0 as milestone/mismatch/completion lines; the status-row chip lands with Phase 3's `status.render` chips argument
- [x] Tests: golden routes against hand-picked city pairs; Dijkstra property tests on synthetic graphs; goldens are opt-in (`HEX_GOLDEN=1 lua tests/run.lua`, needs rooms.db): Djel 129 positive; BP and Genua documented-negative; BFS-equivalence, tie determinism, one-way, avoid, multi-target synthetic properties in the default suite

## Phase 3: the working character (M3)

- [x] `hex_missions`: job market, dead letters, sausages, delivery cooldown trackers with per-alt persistence (tt_dw semantics, missions.tin port); shipped v0.4.0; skills and stats boxes below stay wire-gated on tonight's capture
- [x] Mission XP estimates and XP/hour integration into the status row (live XP table + best-rate ordering; the status row carries the minutes-to-reset chip (the full chips row lands with the skills batch)
- [x] Thief quota chip from `check quota brief` (regex already spec'd); deadline model instead of tt_dw's 1 Hz tick; passive parse, `/quota refresh` sends
- [x] `hex_skills`: parse `options output skills = branched` listings into a per-alt skills store; shipped v0.4.1 (round-trip inside the alias, parse window closed by the terminator or a 30 s safety timer; live check of the option strings pending tonight's capture)
- [x] Skill cost calculator and skill goals (`/skillcost`, `/goal`) ported from tt_dw; shipped v0.4.1; bonus math runs on the documented all-13 baseline until the stats batch
- [x] `/skillcost` carries the official ETB caveat (the documented teaching-bonus formula differs from tt_dw's teach-cost model); parsers note `skillcap` (used level = cap when capped) and the 3-line `score stats` layout (live check); `/goal` alerts accept `hskills brief` lines as a sanctioned second feed: ETB caveat, skillcap note, and both hskills shapes shipped v0.4.1; the `score stats` layout check waits for the capture (stats parsing box below stays open)
- [x] Stat parsing from `score verbose` for bonus-dependent features; shipped v0.6.0: the live layout is TWO dot-padded lines (wire-verified, not the documented 3-line); hex_stats stores per-alt, /stats + /stats refresh, and the skills bonus math reads real stats instead of the all-13 baseline; stat-item netting stays Phase 4

## Phase 4: magic & faith (M4)

- [ ] TPA tracker: glow-colour parse, duration model from defensive bonus, `[T:colour%]` status chip
- [ ] Bugshield (witches) and ritual chips (faith) on the same text-trigger pattern
- [x] `hex_spells`: spelldata port (static dataset), `/spellinfo <spell>` with TM suggestions ordered by skill; shipped v0.5.1: the committed dataset (117 spells, 376 stages, generated by tools/convert_spelldata.py with validation) plus /spellinfo, /spellcheck, /tm, /spells; the known-* marker waits for the known-spells listing (wire)
- [ ] Official-doc hooks: resync via `shields` (the official command name; "check shields" appears nowhere) and `meditate upon divine protection`; the known-spells store purges on death (spells detach on death per helpdir/spells); TM framing stays informational per the automation page's trivialising clause (the store itself lands with the trackers batch)
- [x] TM blacklist and cast-chance constants as config, not code; shipped v0.5.1 (`tm_blacklist`, `tm_cast_chance` 30, `tm_cutoff` 9, defaults = tt_dw's)
- [ ] Sendable fallbacks where docs are silent: `spellcheck` (documented cost/accuracy model) and `remember` when skill data is unavailable
- [ ] Broomstick charge tracking, mindspace gauge, spell sizes
- [ ] Stat-item tracking (worn/removed chips)

## Phase 5: the room (M5), mapper v2

- [x] ASCII minimap panel from GMCP `room.map` (already stored; now rendered beside the status area or in a dev-tab, feature-detected); shipped v0.7.0 as the render ladder: toprows → `map` tab (stock 5.7.1; tabs proven live) → inline (`/dwmap` stays the fallback). Wire correction from live play (v0.8.1): stock 5.7.1 HAS the toprows API (add_top_row takes one opts table with name/body), so the minimap renders on-screen on the shipping client; deduped per room push, empty payloads noted, no-@ vision hint, `hex.map_panel` override; MUD colors are dropped on the tab path (output_to joins fresh lines) so it renders stripped
- [x] Written-map people tracker (MDT) parsing `room.writtenmap`; shipped v0.10.0: the parser ports tt_dw's mdt.tin onto the decoded payload (neither of tt_dw's capture paths needed); /mdt, /hunt, /unhunt with hex.db storage (mdt_match global + mdt_category per-alt/_default); hunting alerts print deduped with 10-minute expiry and emit `mdt.hunt` on the notify bus; the Quow default table ports whole as structured rules (no tintin/PCRE in pure Lua); the map-tab surface waits for the screen-budget check (§8.9) and matching is plain text (documented deviation)
- [ ] Lost-room matching by name/area when the identifier is unknown (tt_dw's guess logic, identifier-keyed)
- [ ] Library (UU/Shades/AoA) and maze movement modes; shared-instance identifiers disambiguated by room name
- [x] Journey/boat routing on top of the room graph (ferry tables as data); journey edges were already single graph edges; v0.7.0 adds the display (`[journey: N miles e]`, the edge distance IS miles), swim-edge exclusion for `/goto` unless `hex.allow_swim` or already underwater (`~` marker on swim steps), and gate avoidance for `/goto` (`hex.avoid_gates`, default off; `/path` stays all-edges informational). The identified-subgraph sea gap remains measured fact: BP is boat-only until the ferry tables land as route data (Phase 5 slice 2)
- [ ] Room-kind vocabulary: `outside` officially documented alongside inside/underwater (road/water stay live-verified)
- [ ] Travel annotations for `/path`: carriages (documented arrival message set) and arcane transport NPCs (`list / travel to / cancel`, fixed price, language-gated)
- [x] Blorps and bookmarks: label -> room id in Hex's own SQLite, walk-to via Phase 2; shipped v0.7.0: hex.db (`~/.local/share/hex/hex.db`, real tables surviving rooms.db rebuilds), /blorp add|delete|rename|list|all|goto and /bookmark add|comment|rename|delete|find|goto|list, distance-sorted listings via one multi-target Dijkstra, instance-id refusal at add time; tt_dw's hub-room blorp semantics deliberately dropped (deviation noted in the module header)

## Phase 6: the social layer (M6)

- [x] Chat capture (tells, souls, club/talker channels) into a scrolling dev-tab, feature-detected; shipped v0.5.0: tells/club/group/talker/shout capture with tt_dw's exclusions, session rings, mirror default; the tab is a feature-detected Rust-filter mirror (F1/F2 binds), stock blightmud sees no change
- [x] Awareness-rule constraint (concepts/automation): the chat tab must never bury tells out of sight - the main feed stays readable; mirror mode is the design's answer; the tab never gags main
- [x] Talker regexes adopt the documented line shapes (leading dash, parenthesised channel, `saying : `); club regexes are player-configurable, so club regexes stay wire-checkable (`blight.create_tab` exists in the dev tree); both talker shapes shipped; wire checks ride tonight's capture
- [x] Combat spam levels (default/brief/verbose) with per-level gag sets, tt_dw `/combat` parity; shipped v0.5.0 with the design's core families; the divine-ire/special-weapon tail and the digest engine wait for the capture and Phase 7
- [x] Combat monitor parsing as a vitals fallback when GMCP is unavailable: the `/hexsetup` prompt/monitor strings, GMCP-freshness precedence (120 s window), `/combatstat` rounds. Wire-verified 2026-11-06 via the /hexcapture pass: the MUD sends its DEFAULT monitor format `Hp: N (N) Gp: N (N) Xp: N` with a bare `>` prompt (the customised strings do not take), so DEFAULT_MONITOR is the shape that fires; the same capture fixed the uppercut family's ported anchor (tt_dw's period-end, ours had a trailing space) and added the training pumpkin's dodge family (no tt_dw counterpart)
- [x] URL catching and `/urls` recall: tt_dw guard set ported; `/url open` behind an opt-in flag
- [x] Notification hooks: mission-ready, connection loss, TPA expiring (sound-ready, see Phase 7); hex_notify bus shipped with chat/url/combat/mission/core events; TPA arrives with Phase 4

## Phase 7: feel & options (M7)

- [x] Sound effects through blightmud's audio module (mission reset, TPA plink, damage), gated by an options flag; shipped v0.8.0: notify-bus subscribers over the hex_sound_events table, defaults OFF (terminal clients travel; tt_dw defaults on), damage words verbatim at the -200/-400/-500 thresholds, debounced 2s; ambient line sounds remain a deferred v2 pack
- [x] `/hexoptions`: an options menu over config with persisted toggles; shipped v0.8.0: schema-validated keys (bool/enum/number/path), the session > alt > global > default layer chain (tt_dw's load order), selection by key name not numbers (typing "3" into a MUD client sends it), /hexset remains the raw escape hatch
- [ ] Guild packs: witch/warrior/thief/priest/assassin modules as opt-in data files, ported from tt_dw's guild trees
- [x] Theme constants extracted so the whole suite re-skins from one table; shipped v0.8.0 as hex_theme: classic (byte-identical to today, golden-tested) + dragon (Kanagawa 24-bit); use() mutates the shared hex_util.ansi table in place so the whole suite re-skins with zero call-site migration (design's "delete hex_util.ansi" simplified away); guild packs remain unticked below
- [ ] Theme raw material: the MUD documents ~250 colour names (xterm256-exact), hex codes, and `ansi*` overrides; MXP offers native 24-bit colour
- [ ] `/hexoptions` records that auto-reconnect after quit/idle-out is banned by name (never grows one)
- [ ] Per-alt profiles: config inheritance (global -> alt) like tt_dw's settings order (the session/alt/global/default LAYERS shipped v0.8.0 in /hexoptions; full per-key inheritance migration pending)

## Phase 8: ship as the premiere suite (M8)

- [x] CI: GitHub Actions running `lua tests/run.lua` and the Python suite on every push; green before any tag; shipped v0.9.0 (lua5.4 + converter suite + pinned-ruff 0.17.2 format/lint jobs; HEX_GOLDEN stays local by design; first run green)
- [x] Reconcile the ruff pin (local 0.17.2 vs CI 0.16.8) with a format-only commit before the first CI run; the CI pin matches local 0.17.2; the format+lint pass ran first and the tools/ files are now green under it
- [x] Golden tests: recorded Quow query outputs asserted against the builders, so refactors cannot change semantics silently; shipped v0.11.0 as the three-layer engine (tools/regen_goldens.py + tools/dump_golden_sql.lua over tests/golden/cases.lua): SQL + synthetic layers committed and CI-gated (`--check --synthetic` in the lua job; authored rows pin ordering, escaping, price filters, the Shonky exclusion and the 31/61/41 caps); the recorded layer stays local-only gitignored with a provenance fingerprint, staleness warning and --strict pre-tag ritual; cases carry a db tag because /where reads Hex's rooms.db while the rest read Quow. Day-one catches: /npc and /items never escaped apostrophes and /items sold was broken by an ambiguous room_id. Route goldens shipped v0.12.0: committed fixtures (confirmed: tt_dw's map is public domain), local-only to run since rooms.db is not in CI; the 4-pair file pins both directions of the Drum/Djel route (129 vs 130 steps: the reverse pins tie-breaking asymmetry) plus the two unreachable renders
- [x] A fake-GMCP harness: replay captured payload fixtures through the handler chain in plain Lua, so protocol regressions die in CI instead of at login; shipped v0.13.0: the shim grew replay hooks (recorded on_ready/receive/subneg/input callbacks, a core.exec response queue, a controllable clock, recorded status lines and prints, a Line stub) and a hard gmcp.register tripwire; blightmud's rxi/json.lua ships vendored (approved) so the REAL decode path runs; the login fixture replays the verbatim 2026-11-06 capture (handshake shape, vitals to bar row, clock-driven xp rate, zero sends asserted at runtime) plus reload/password/emptyfields fixtures; wire-pending payloads (char.login/info) are marked in the fixture
- [ ] README with screenshots/asciinema of the status area, `/item`, and `/path`; install docs for `/add_plugin <url>`
- [ ] A dwwiki and r/MUD announcement post (drafted here, posted by Brandon)
- [ ] v1.0.0: every phase above either shipped or consciously deferred in this file, tag with the full patchnotes entry per house release procedure

## Week sprint (declared 2026-11-05: "we'll have this finished within the week")

Aggressive, honest, gated: every LIVE item needs a capture session from Brandon (30-60 min/day with `/hexprobe` + `/hexraw` on). "Finished" definition for the sprint: the daily-play suite is transformed (1.x + Phases 2, 3, 4-core, 6 by Nov 12); Phase 8's full definition-of-done and Phase 5's wire-gated halves land week two on the way to v1.0.0.

- [x] **Thu 6**: 1.x completion (`strip_ansi` + `/dwmap` default, `/hexsetup` (documented strings, `term xterm256`, `options terminal rows=999`), gag registry file, Quow staleness + **"Hex owns its data"** (`/hexupdate`, quow_db moves to `~/.local/share/hex/`). Ship v0.2.0.
- [x] **Fri 7**: Phase 2 core (`hex_targets` resolver, `hex_paths` (Dijkstra + heap + render), `/path`, `/near`; bench + synthetic property tests. (shipped 2026-11-05, a day ahead of its label)
- [ ] **Sat 8 (FULL DAY - the open weekend)**: 1.x completion + Phase 2 core + Phase 2 walker in one run - `/hexsetup`, `/hexupdate`, gag registry, resolver, Dijkstra, `/path` `/near`, batch `/goto`, drift chip, goldens. Ship v0.3.0 by night. **Brandon: capture session #1 in the evening** (seed, `options output`, quota/score transcripts, chat sweep - this feeds everything after).
- [ ] **Sun 9 (FULL DAY)**: Phase 3 verified against Saturday's captures - missions data + board triggers + timer engine + `/missions`, quota chip, then skills parser + bonus/cost/goals + stats. (missions + quota shipped 2026-11-05 as v0.4.0, ahead of the label; the skills parser lands after the captures, as v0.4.1). Phase 6 chat starts in the background.
- [ ] **Mon 10**: Phase 3 (skills parser + bonus/cost/goals + stats, verified against the capture. Ship v0.4.1. (skills parser + bonus/cost/goals shipped 2026-11-05 as v0.4.1, ahead of the label; stats parsing + live verification remain)
- [ ] **Tue 11**: Phase 6 (chat capture + tab, combat gag ladder, URLs, `hex_notify` bus; monitor fallback.
- [ ] **Wed 12**: Phase 4 core (TPA state machine + prediction, charm chips, broom, stat-items. Ship v0.5.0 "premiere core". **Brandon: capture session #2** (maze rooms, journey, TPA expiry).
- [ ] **Week 2**: Phase 4 TM + spelldata converter; Phase 5 minimap/MDT/maze/guess (wire-gated) + blorps/hex.db; Phase 7 sound/theme/options; Phase 8 CI + shim + goldens + announcement. v1.0.0 when the definition-of-done is true, not when the calendar says so.

## Situational awareness lane (shipped v0.18.0, 2026-11-09)

Born directly from the week's live failures (night walks, locked gates, dark rooms, the corpse walk):

- [x] `hex_scry`: `/hexexits` (verbose exits with gate/swim/climb/journey/hidden/unsafe markers), `/hexzone` (area + Quow zone + landmark reachability: BP/Genua/Bad Ass/Lancre), `/hexnight` (day-part from the weather line + dark signals; implications; pre-queue warning in `/goto`), `/hexcorpse` (per-alt death site in hex.db; the walk back is one command). Permanent keeper-quality commands, NOT a -dbg lane.
- [x] Folded backlog QoL: `/dl` refusal carries the `/goto dead letter office` hint; `/item` teaches `/items sold` in a footer.
- [x] Cut consciously, stated in the entry: `/hexdoors` (no door-state data source exists in rooms.db, GMCP, or tt_dw) and `/hexscan` as then-designed (consider output had never been captured; Quow's npc_info has no combat stats).
- [x] v0.19.0: the wire backlog LANDED. The death-line anchors are wire-verified from the 2026-11-08 forest-clearing death in his own logs (Death appears, quotes random small-caps lines, leaves on Binky; attackers render as "Something" in the dark). `/hexscan` ships for real: the 13-rung consider ladder (pinned in the doc mirror, two live shapes) colour-banded prey/even/danger, plus corpse-floor lines, kill history, the rats-eating-corpses alarm, and the lit-outdoor night/moon line feeding `/hexnight`. Also fixed the latent `/apply` crash (`board_market` was called but never defined, shipped v0.4.0, never hit live).
- [ ] Still wire-pending: the unobserved day-parts (dawn/dusk word choice), and the advertised-but-unimplemented `/goto` id-prefix resolution.

## Deliberately out of scope

A spatial automapper that draws its own rooms (the MUD's `room.map` and the tt_dw-derived graph cover the need), any kind of botting or idle-keeping (the rules and the spec both forbid it), and any dependency outside the two standard libraries.
