# Hex roadmap

External materials for every phase are staged under `testing_facility/` (gitignored; symlinks to the tt_dw and blightmud clones, both databases, the CC0 sounds; a downloaded stock blightmud v5.7.1 binary for degraded-path testing; a pinned GMCP doc snapshot; live-capture scaffolding) — see [docs/testing-facility.md](docs/testing-facility.md). The converter now carries the maze `extra`/shape column (1,246 shape rows verified), unblocking Phase 5's guess design.

Every phase below has an implementation-ready design document under [docs/](docs/README.md), produced by the 2026-11-04/05 exploration campaign (eight research agents; measured benchmarks, extracted formulas, wire-verification backlogs). The roadmap tracks boxes; the docs carry the designs.

North star: Hex becomes the Discworld suite a Blightmud player reaches for first, the way Quow's Cow Bar is the suite a MUSHclient player reaches for first. That bar has three parts, and every phase below serves one of them: nothing essential is missing (map, vitals, data, missions, magic), nothing breaks quietly (the GMCP lesson: verify every protocol claim against the live wire), and nothing feels alien to a terminal user (one binary, text everywhere, zero dependencies).

House invariants that out-rank every phase:

- No autonomous MUD input. Discworld bans anything that could unidle a character; every send lives behind a user alias, and a user-asked speedwalk is the only multi-step sender Hex will ever contain.
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
- [ ] `/hexsetup`: one alias that sets the game-side options tt_dw requires (prompt and monitor strings, `brief exits`, plain map output) so text-parsing fallbacks and room maps behave
- [ ] `room.map` colour handling: strip or render the ANSI the MUD embeds; honor the plain-map option
- [ ] `/gaglog` and a gag registry file so players add their own gags as data without touching code
- [ ] Optional quow DB auto-refresh check (`update.sh -q` parity): warn when the database is older than 60 days

## Phase 2: find your way (M2) — the mapper that matters first

The enabling fact from the M1 research: the MUD's 40-hex room identifier is the same key in tt_dw's map file, Quow's database, and GMCP `room.info`. Pathfinding therefore needs no spatial layout engine, only a graph.

- [ ] `tools/convert_map.py` v2: exits gain the dir bitmask and one-way flags as queryable columns (already captured, now exercised)
- [ ] `hex_paths`: Dijkstra over the identified-room subgraph (32,499 rooms) in pure Lua, weights from exit distance
- [ ] `/path <search>`: resolve a target by room name, identifier prefix, or Quow room id; print the route as a readable step list (street-by-street, not just "7n 2e")
- [ ] `/goto <target>`: the one sanctioned walker; sends the route step-per-step only because the user asked, cancellable with `/stopwalk`, every step verifies the room identifier before continuing (mismatch aborts, never re-routes blind)
- [ ] `/near <search>`: nearest match to the current room by path length
- [ ] Quow `/item` and `/npc` results gain walk-distance and "nearest source" ordering
- [ ] Arrival announcements and off-route detection as status chips
- [ ] Tests: golden routes against hand-picked city pairs; Dijkstra property tests on synthetic graphs

## Phase 3: the working character (M3)

- [ ] `hex_missions`: job market, dead letters, sausages, delivery cooldown trackers with per-alt persistence (tt_dw semantics, missions.tin port)
- [ ] Mission XP estimates and XP/hour integration into the status row
- [ ] Thief quota chip from `check quota brief` (regex already spec'd)
- [ ] `hex_skills`: parse `options output skills = branched` listings into a per-alt skills store
- [ ] Skill cost calculator and skill goals (`/skillcost`, `/goal`) ported from tt_dw
- [ ] Stat parsing from `score verbose` for bonus-dependent features

## Phase 4: magic & faith (M4)

- [ ] TPA tracker: glow-colour parse, duration model from defensive bonus, `[T:colour%]` status chip
- [ ] Bugshield (witches) and ritual chips (faith) on the same text-trigger pattern
- [ ] `hex_spells`: spelldata port (static dataset), `/spellinfo <spell>` with TM suggestions ordered by skill
- [ ] TM blacklist and cast-chance constants as config, not code
- [ ] Broomstick charge tracking, mindspace gauge, spell sizes
- [ ] Stat-item tracking (worn/removed chips)

## Phase 5: the room (M5) — mapper v2

- [ ] ASCII minimap panel from GMCP `room.map` (already stored; now rendered beside the status area or in a dev-tab, feature-detected)
- [ ] Written-map people tracker (MDT) parsing `room.writtenmap`
- [ ] Lost-room matching by name/area when the identifier is unknown (tt_dw's guess logic, identifier-keyed)
- [ ] Library (UU/Shades/AoA) and maze movement modes; shared-instance identifiers disambiguated by room name
- [ ] Journey/boat routing on top of the room graph (ferry tables as data)
- [ ] Blorps and bookmarks: label -> room id in Hex's own SQLite, walk-to via Phase 2

## Phase 6: the social layer (M6)

- [ ] Chat capture (tells, souls, club/talker channels) into a scrolling dev-tab, feature-detected (`blight.create_tab` exists in the dev tree)
- [ ] Combat spam levels (default/brief/verbose) with per-level gag sets, tt_dw `/combat` parity
- [ ] Combat monitor parsing as a vitals fallback when GMCP is unavailable
- [ ] URL catching and `/urls` recall
- [ ] Notification hooks: mission-ready, connection loss, TPA expiring (sound-ready, see Phase 7)

## Phase 7: feel & options (M7)

- [ ] Sound effects through blightmud's audio module (mission reset, TPA plink, damage), gated by an options flag
- [ ] `/hexoptions`: an options menu over config with persisted toggles (gag levels, sound, chat tab, walker confirmations)
- [ ] Guild packs: witch/warrior/thief/priest/assassin modules as opt-in data files, ported from tt_dw's guild trees
- [ ] Theme constants extracted so the whole suite re-skins from one table
- [ ] Per-alt profiles: config inheritance (global -> alt) like tt_dw's settings order

## Phase 8: ship as the premiere suite (M8)

- [ ] CI: GitHub Actions running `lua tests/run.lua` and the Python suite on every push; green before any tag
- [ ] Golden tests: recorded Quow query outputs asserted against the builders, so refactors cannot change semantics silently
- [ ] A fake-GMCP harness: replay captured payload fixtures through the handler chain in plain Lua, so protocol regressions die in CI instead of at login
- [ ] README with screenshots/asciinema of the status area, `/item`, and `/path`; install docs for `/add_plugin <url>`
- [ ] A dwwiki and r/MUD announcement post (drafted here, posted by Brandon)
- [ ] v1.0.0: every phase above either shipped or consciously deferred in this file, tag with the full patchnotes entry per house release procedure

## Deliberately out of scope

A spatial automapper that draws its own rooms (the MUD's `room.map` and the tt_dw-derived graph cover the need), any kind of botting or idle-keeping (the rules and the spec both forbid it), and any dependency outside the two standard libraries.
