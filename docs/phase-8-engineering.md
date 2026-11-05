# Phase 8: engineering — CI, goldens, the fake-GMCP harness, docs, releases

Design doc. Status: designed, not implemented. House evidence read from `~/.gitrepos/cquarry/.github/workflows/{ci,publish}.yml` and `~/.gitrepos/dragon-agents/.github/workflows/ci.yml`; release conventions from the house release skill; runner facts from the actions/runner-images Ubuntu 24.04 README.

## 0. House conventions extracted

1. Trigger `push: branches: [main]` + `pull_request` (+ `workflow_dispatch`).
2. Top-level `permissions: contents: read`; escalate per-job only (`contents: write` for release minting).
3. `concurrency: ci-${{ github.ref }}` cancel-in-progress true (CI); `false` for releases.
4. `timeout-minutes: 10`.
5. All actions SHA-pinned with a `# vX.Y.Z` comment; copy cquarry's current pins verbatim (`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`, `actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0`).
6. Python: setup-python pinned "3.14", raw pip with exact pin `ruff==0.16.8`, `ruff check .` + `ruff format --check .`, `python -m unittest discover`. (Raw pip, not uv — house-most-recent wins: cquarry and dragon-agents use raw pip.)
7. Releases gated on `v*.*.*` tags; tests re-run on the tag; GitHub Release minted from the tag's verbatim message, idempotently.
8. No CHANGELOG anywhere in the house; `patchnotes.md` only.

**Lua on runners**: ubuntu-latest (24.04) preinstalls no Lua and no luarocks; it does preinstall sqlite3 CLI 3.45.1. Most reproducible route: `sudo apt-get install -y --no-install-recommends lua5.4` (noble carries 5.4.6) plus an explicit `lua5.4 -v` assert so runner-image drift fails loudly. A `container:` job was considered and rejected (no maintained official Lua image; apt keeps the plain-runner house shape). Interpreter-only install leaves the no-luarocks constraint intact.

## 1. CI workflows (drafts, verbatim-ready)

`.github/workflows/ci.yml` — two jobs:

- **lua**: checkout (pinned); install lua5.4 + assert "Lua 5.4"; **spec-invariant grep step** (`grep -rn "mud\.send" src/ main.lua` must find nothing — when Phase 2's sanctioned walker lands, upgrade to a marker convention: allowed only on lines carrying `-- hex:send:user-alias`); `lua5.4 tests/run.lua`; `python3 tools/regen_goldens.py --check --synthetic` (the golden engine is stdlib Python shelling out to lua5.4 + sqlite3, both present in this job).
- **python**: setup-python 3.14; `pip install ruff==0.16.8`; `ruff check .`; `ruff format --check .`; `python -m unittest discover -s tests`.

`.github/workflows/release.yml` — tag-gated `v*.*.*`: a `test` job re-running every gate on the tag, then `create-release` (`contents: write`, checkout at the tag ref because `--notes-from-tag` reads the local tag object) running the idempotent mint: `gh release view "$GITHUB_REF_NAME"` guard, else `gh release create "$GITHUB_REF_NAME" --notes-from-tag --verify-tag`.

Implementation prerequisites (one-time before first green): run `ruff format` locally once on `tests/test_convert_map.py` + `tools/convert_map.py` and commit the reformat separately.

## 2. Golden tests — three layers

| Layer | Locks | Data | Runs |
|---|---|---|---|
| SQL goldens | exact SQL each builder emits | none | CI + local |
| Synthetic row goldens | SQL + sqlite3 CLI output shape + parse pipeline | `tests/golden/synthetic.sql` (committed, our own rows) | CI + local |
| Recorded row goldens | real outputs vs the real Quow DB | real DB, **local-only, gitignored** | local ritual |

Rationale: recorded Quow outputs contain MUD item descriptions (Quow's copyrighted compilation) — safest default is local-only. **Route goldens are different**: rooms.db derives from tt_dw's public-domain map, so recorded route fixtures are likely committable (flagged for Brandon's confirmation).

**Fixtures**: `tests/golden/cases.json` (committed inputs only: 14 cases covering plain/anchors/wildcards/exact-quote/field-prefixes/multi-term-OR item queries, npc room-filter and bare, shop union, sources sold/free/loot, where escaping, zone lookup). `tests/golden/sql/<name>.sql` (committed, byte-exact builder output). `tests/golden/synthetic.sql` (committed; authored rows pinning ordering, escaping, empty fields, price filters, the Shonky exclusion, and caps — full listing in the exploration report). `tests/golden/expected/<name>.txt` (synthetic expectations, committed). `tests/golden/recorded/<name>.txt` (gitignored) with a provenance header: recorded timestamp, tool, sqlite3 version, db path, db sha256 (16 hex), size; comparison strips `# ` lines.

**`tools/regen_goldens.py`** (stdlib: argparse, subprocess, hashlib, json, pathlib, difflib, datetime):

```
--check                    # SQL goldens only (CI-cheap)
--check --synthetic        # + synthetic rows (the CI Lua-job step)
--record --synthetic       # (re)author sql/ + expected/
--check --recorded         # local, against the real Quow DB
--record --recorded        # re-record after a Quow refresh
--recorded-db <path>       # override
```

Implementation: reads cases.json; gets SQL per case by invoking `lua5.4 tools/dump_golden_sql.lua cases.json` once (a ~20-line helper requiring `src.hex_queries`, printing `{name: sql}` JSON, decoded with the shim's vendored json — §3); SQL goldens diffed byte-exact; row goldens run `subprocess.run(["sqlite3", "-batch", db], input=sql)` — deliberately the same CLI form production gets from `core.exec` (Python's sqlite3 module would give tuples, not pipe-joined text; CLI parity is the point). Recorded mode adds the provenance header and DB fingerprint; `--check --recorded` recomputes the fingerprint — mismatch means stale goldens (Quow updated): warn, fail under `--strict` (pre-tag ritual), re-record and **review the diff** (a semantic surprise is a real finding, e.g. a Quow column rename — exactly what goldens exist to catch). Also warns when the DB mtime exceeds 60 days (pairs with the 1.x staleness item). `.gitignore` gains `tests/golden/recorded/`.

**Route goldens** (Phase 2 preview, pattern defined now): `tests/golden/routes.json` (from/to pairs); `--routes` ensures rooms.db exists, dumps the identified subgraph edge-list through the sqlite3 CLI, runs `lua5.4 tests/golden/run_routes.lua` which loads `src.hex_paths` and prints the route; Python diffs. These are the fixtures that can graduate to committed once confirmed.

## 3. The fake-GMCP harness (core engineering piece)

**Decision: shim, not refactor.** Evidence: the pure/bound split already exists and is good (hex_util/hex_queries/hex_vitals/hex_rooms/hex_status.render pure and tested; hex_gags.register and hex_commands.setup already dependency-injected); the bound surface is ~30 call sites across 8 globals, concentrated in main.lua's wiring; the thing we most want to test — the handler chain INCLUDING main.lua's wiring and hex_gmcp's routing/decoding — is exactly what a refactor would leave untested anyway. The shim changes zero production code and makes main.lua itself loadable in plain lua5.4. Side benefits: the shim doubles as an executable specification of the blightmud API subset Hex depends on (API drift fails the suite loudly), and protocol invariants become runtime assertions (the M1 dead-vitals bug class becomes a red CI run, not a dead status bar in-game).

**The shim** (`tests/shim/blightmud.lua`, strict): enumerated from grepped call sites —

| Global | Shim behavior |
|---|---|
| trigger.add/remove | record `{kind,id,re,opts,cb}`; remove by id (parity with pcall'd registry calls) |
| alias.add/remove | same, cb signature (matches, line) |
| gmcp.on_ready | record (multiple supported); replay fires explicitly |
| gmcp.send | append to `shim.gmcp.sent` (ordered) |
| gmcp.receive | per-name listener lists; replay invokes cb(raw string) |
| gmcp.echo | record |
| **gmcp.register/unregister** | **stub that errors immediately**: "hex must not use gmcp.register (Discworld ignores Core.Supports.Add)" |
| core.exec | assert argv[1] == "sqlite3"; pop a test response queue; ExecResponse stub with :code/:stdout/:stderr; record argv |
| core.subneg_recv | record; replay calls cb(201, bytes) |
| blight.terminal_dimensions/status_height/status_line/on_dimensions_change/data_dir | configured w,h; `shim.status[i] = s` is the primary assertion surface; data_dir → /tmp/hex-shim-data |
| mud.add_input_listener / on_connect / .send | record; `.send` records into `shim.mud_sent` — replay asserts `#shim.mud_sent == 0`, making the anti-idle invariant a runtime check |
| store.* | four in-memory tables (disk_* optionally temp-dir backed) |
| log.start / script.load | record |
| regex.new | stub capturing {pattern, opts}; :test/:match/:replace error ("Rust regex semantics not reproducible in plain Lua; invoke callbacks with hand-built matches") |
| json.encode/decode | **vendor blightmud's bundled rxi/json.lua verbatim as `tests/shim/json.lua`** (MIT header preserved) — not a new dependency; it is byte-for-byte the implementation production injects, so the harness exercises the real decode path incl. room.map's JSON-string-with-ANSI-escapes. Flagged for Brandon's sign-off; alternative is a from-scratch RFC 8259 decoder with more fidelity risk in the very tests protecting protocol fidelity. Recommended: vendor. |
| bytes_to_string, print | copy the 8-line implementation verbatim with attribution; print redirected into `shim.output` |

Strictness rule: every OTHER known blightmud global gets an erroring stub ("hex shim: <name> not implemented — extend tests/shim/blightmud.lua"), so new API use fails loudly instead of passing against a fictional environment. Entry points: `tests/shim/blightmud.lua` (`M.install(shim)`), a fake `os.time` override (xp_rate uses it; replay drives the clock deterministically), `tests/replay.lua` (install, set `package.path` to `./src/?.lua;./tests/shim/?.lua`, `dofile("main.lua")`, run assertions — integrated into `tests/run.lua` so `lua tests/run.lua` stays the single command).

**Fixture format** `tests/fixtures/gmcp/<name>.json`: recorded payload strings (not decoded tables — the real decode path runs), each step `{label, event: on_ready|receive|subneg, module, raw, t}` with `t` driving the fake clock. The seed fixture uses the LIVE-CONFIRMED payloads: `char.vitals` `{"alignment":"neutral","maxhp":500,"hp":500,"xp":5356,"maxgp":50,"burden":3,"gp":50}`; `room.info` `{"identifier":"917446ff80d14cacf75b035961cc89303d3d51e9","name":"Combat Crib","visibility":1,"kind":"inside"}`; room.map/writtenmap as double-encoded JSON strings captured exactly by `/hexraw` during the recording session.

**Replay assertions** (example from the seed fixture): exactly two handshake sends in order, core.supports.set naming all six commands, never gmcp.register; vitals landed coerced into status row 1 ("500/500"); room name + burden in row 2; xp-rate over the driven clock asserted in row 3; `#shim.mud_sent == 0` after a full replay; the subneg tap saw the payload. Additional fixtures: `reload.json` (run main.lua twice; handle count does not grow — kills the double-registration class), `password.json` (Line stub skip_log set exactly once), `emptyfields.json` (trailing-empty row through /item's alias callback — the cabbage-crash class). The Line stub exposes only skip_log/replace/gag + no-op raw()/line(); anything else errors via the strict metatable.

**Regressions killed**: the dead-vitals class (handshake naming/casing/suffix/format, gmcp.register use) pinned byte-level; payload-shape drift; string-payload handling; integration rendering (GMCP → vitals → status rows); lifecycle (reload, password, connect logging); spec invariants at runtime; version drift (handshake version asserted == VERSION).

## 4. Docs & announcement

README structure: logo + tagline + CI badge (no version-baked badges — the release skill flags those as silent-stale traps); "What you get" with screenshot placeholders (status area, /item, /path); Requirements (Blightmud v5.7.1+, sqlite3 CLI on PATH); Install via `/add_plugin https://github.com/VirInvictus/hex` (local path as dev note) + data-file setup; Commands table; **Feature status table mirroring roadmap.md**; Configuration; Privacy & safety (anti-idle rule, password skip-log, read-only data); Development pointer to AGENTS.md + the goldens ritual; Credits; License. House convention: patchnotes.md only, never a CHANGELOG. Announcement drafts kept in-repo (`docs/announcement-dwwiki.md`, `docs/announcement-reddit.md`): what/why-terminal paragraph, install block, feature bullets honest about shipped-vs-planned, the "will never do" reassurance (anti-idle), credits, links. CONTRIBUTING.md: pointer to AGENTS.md, hard rules recap, dev loop commands, "protocol changes require wire evidence recorded into fixtures", PR expectations.

## 5. Versioning & release

Version lives in: `VERSION` (canonical) + new `src/hex_version.lua` (`return { version = "0.1.0" }`) required by hex_gmcp, which builds `core.hello` from it instead of the hardcoded string — so the handshake can never disagree with the release. `/hexhelp` banner prints `Hex v<version>`. AGENTS.md records the mapping (the release skill's "language manifest" step maps to VERSION + hex_version.lua). Version-consistency test in the Lua suite (VERSION file == hex_version == hello constant) gates every CI run and tag. Tag procedure: house release skill verbatim — bump both version carriers, prepend patchnotes, tick roadmap boxes (grep for twin boxes), sync-reference-docs, commit (approval), annotated tag `--cleanup=verbatim -F` from the extracted entry, `git cat-file` verification, push commit+tag together; release.yml then mints the GitHub Release.

## 6. Definition of done ("premiere", operationally)

1. CI green on main and on the release tag; grep step silent.
2. Goldens fresh: SQL + synthetic green in CI; `--check --recorded --strict` passes pre-tag (re-record + review on Quow updates); route goldens same ritual.
3. Zero-dep verified: no require outside src/ and tests/shim/ (vendored json carries its MIT header); no luarocks anywhere; ruff clean with stdlib-only imports in tools/ and tests/.
4. Spec invariants hold: CI grep + replay runtime assertion; third-party data read-only everywhere.
5. Harness coverage complete: every shim-table call site exercised by at least one test; the three confirmed payload families recorded; reload and password fixtures green.
6. Docs true: README install steps executed from a clean clone; command table == /hexhelp; feature table == roadmap; AGENTS.md current; patchnotes current.
7. Announcements drafted and matching the release.
8. Tagged per house procedure; sync-reference-docs run.

## 7. Open questions for Brandon

1. Quow-derived fixture licensing: may recorded goldens be committed if trimmed to name+price? Default until answered: gitignored, local-only.
2. Route-golden commitment (tt_dw map is public domain): confirm.
3. Vendored json.lua sign-off (recommended: vendor with provenance).
4. Branch protection: make the two CI checks required on main? (house precedent unstated).
5. ruff format adoption: approve the format-only commit.
