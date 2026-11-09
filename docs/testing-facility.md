# The testing facility

`testing_facility/` (gitignored) is Hex's staging ground for every external material the phase designs consume or verify against. The research behind this doc: two agents produced a 14-row requirements sweep (what each design consumes, where it lives, licensing) and a per-phase fixture map; their findings are folded in here. See also [testing_facility/README.md](../testing_facility/README.md) for the on-disk index and the per-item CONTEXT.md files.

**Audited 2026-11-09** by a four-agent sweep (tree+symlinks, doc-claims cross-check, database inventory, captures+docs staleness). The audit's verdicts and follow-ups live in the last section; the requirements and procedures below stand.

## What the roadmap actually requires externally

Almost nothing new: by design, every phase mines the two clones already on this machine (tt_dw, blightmud) plus Hex's own generated rooms.db. The sweep found exactly four genuinely missing items, all now staged:

| Missing item | Why it matters | Staged as |
|---|---|---|
| Stock blightmud v5.7.1 Linux binary | The dev tree has the tabs/top-row APIs; stock doesn't. The Phase 5/6 degradation ladders and the `/chat` fallback can only be tested against stock. | `blightmud-v5.7.1/` (RPM downloaded from the GitHub release, extracted via rpm2cpio; `usr/bin/blightmud` verified as the ELF from that release, build date 2026-05-31) |
| GMCP documentation snapshot | The protocol source of truth; the live page can drift under the designs | `gmcp-doc/gmcp-concepts.html` (fetched 2026-11-05; covers core.supports.set and all six char.*/room.* names) |
| Live payload captures | The Phase 8 harness fixtures and Phase 5's maze survey only exist in Brandon's sessions | `captures/gmcp/` + `captures/logs/` scaffolding with the capture procedures in CONTEXT.md (still EMPTY: the real transcripts live at `~/.local/share/hex/captures/` and have never been copied in) |
| Recorded Quow goldens staging | Phase 8's local-only layer | `golden/recorded/` (also gitignored at `tests/golden/recorded/`; the facility side is still empty, the tests side holds the 16 recorded goldens) |
| Discworld MUD official docs mirror | Every phase: the game's own docs are the source of truth (rules wording, options formats, skills/spells/rituals/missions pages) | `discworld-docs/` (crawled by `tools/mirror_discworld_docs.py`, resumable; research pass in `docs/discworld-docs-research.md`) |

Everything else resolves to existing local paths and is symlinked, never copied: tt_dw scripts, the map repo, the Quow DB (18.5 MB), rooms.db, sound_files (50 CC0 mp3s), the blightmud dev clone. The 2026-11-09 sweep verified every symlink resolves; note the two house CI repos (cquarry, dragon-agents) exist in `~/.gitrepos/` but are NOT staged here despite a stale doc claim below.

## Toolchain status (swept 2026-11-05, corrected 2026-11-09)

| Tool | Designs need | Local | Note |
|---|---|---|---|
| lua | 5.4 everywhere | **5.5.1** (`/usr/sbin/lua`, also what `~/.local/bin/lua5.4` symlinks to) | The 2026-11-05 "5.4.8" row was wrong when written (the binary predates it); the named `lua5.4` symlink resolves to 5.5.1, NOT a real 5.4. Hex code must run under both (for-loop control variables are read-only in 5.5); CI pins real 5.4.6 for the golden engine |
| sqlite3 | all phases | 3.53.4 (CI runners: 3.45.1; goldens pin the version in provenance headers) | 2026-11-09: was listed as 3.51.2 |
| python3 | converters, goldens | **3.15.0** (CI pins the 3.14 minor line) | 2026-11-09: drifted past the CI pin; converters are stdlib-only and unaffected so far |
| ruff | Phase 8 pin | 0.17.2 | Reconciled: CI now pins 0.17.2 too (the 2026-11-05 "drift to reconcile" note is done; `docs/phase-8-engineering.md` still says 0.16.8 in two places and needs the same touch-up) |
| rpm2cpio/cpio | stock-binary extraction | present | bsdtar absent, 7z present as fallback |
| sox | tt_dw only | absent, **correctly irrelevant**: Hex uses blightmud audio | |

## Per-phase staging table

The full per-phase map (inputs → source path → stage action → regen command) from the research:

- **1.x**: Quow DB (reference; staleness test uses a temp fake), rooms.db (reference), live: `options output` sweep + `char.info` capture + one `look` with `/hexraw` for the strip_ansi sample.
- **2**: rooms.db symlink for golden routes (`HEX_GOLDEN=1`, endpoints verified present: 3424, 5898, 4659, 12472, 11279-unreachable); live: maze captures, journey arrival, queued-command vocabulary, travel default. (`tests/bench_paths.lua` and the converter index additions landed with the phase.)
- **3**: transcript fixtures are synthetic (transcribed from verified tt_dw files); live: skills-listing round-trip capture, `char.info`.
- **4**: spelldata.tin read straight from the tt_dw clone by the converter; live: TPA-to-expiry, bugshield noun samples, `/spells` output, `score verbose stats` spacing.
- **5**: live room.map/writtenmap fixtures (normal, empty, people-only, two-line; maze rooms for the top-priority item), the UULibrary shapes (the converter's `extra` column fixed the 0/1246 gap); everything else synthetic.
- **6**: synthetic chat/combat fixtures from quoted tt_dw lines; live: monitor/prompt spacing after `/hexsetup`, a chat sweep log.
- **7**: sound_files symlink for the `/hexsound test` checklist; primaries transcribed from `char/data.tin:270-310`; unit tests use fake temp dirs.
- **8**: house workflow pins copied verbatim from cquarry/dragon-agents (the clones are at `~/.gitrepos/`, unstaged here). Vendored `json.lua` copied from the blightmud clone (MIT header preserved); the seed fixture recorded live; Quow DB referenced via `--recorded-db`; the golden scaffolding lives at `tests/golden/` (`cases.lua`, not .json, plus `routes.lua`, `run_routes.lua`, `routes/`, `sql/`, `synthetic.sql`, `expected/`, `recorded/`).

## Findings from the sweeps (resolved here)

1. **Converter bug (fixed)**: `convert_map.py` discarded the 10th room field (the tintin list data (`{{shape}{3}}`) that Phase 5's maze guessing needs); measured 0/1,246 shapes in rooms.db. The `extra` column now carries it; rooms.db rebuilt and verified (1,246 shape rows, `{shape}{3}`/`{shape}{x}` samples); converter tests extended.
2. **Phase-2 maze stats were stale** (said 1,282 rooms / 9 ids): actual is **1,341 rooms across 12 ids** (UULibrary 1,246, AMPepperPot 25, StoLatLibrary 24, BPMedina 19, AMShades 16, SkundHedgeMaze 6, MagicCircle 1, Introduction:* ×3, tt_dw_blorp ×1). Corrected in [phase-2-mapper.md](phase-2-mapper.md) §0.
3. **`hex.map_ansi` default conflict**: phase-1x said `strip`, phase-5 said `ansi`. Resolved as a split, not a fight: `/dwmap` inline defaults `strip` (1.x, scrollback context), the Phase 5 panel defaults `ansi`; each doc now notes the other's scope.
4. **AGENTS.md wire-truth gap**: `room.writtenmap` (plain string) was missing from the recorded payload shapes; added.
5. **`lua5.4` named binary**: missing locally; `~/.local/bin/lua5.4` symlink created (now known to point at the 5.5.1 binary; see the toolchain table).

## Audit 2026-11-09 (four-agent sweep, folded)

**Healthy:** all 7 symlinks resolve (3 top-level + `db/`'s map/quow.db/rooms.db + the RPM's build-id link); `db/` holds symlinks only, zero copies, and `db/rooms.db` is byte-identical to the live file (same inode; route goldens run against the same bytes either way); `discworld-docs/` is complete (1,721 pages, every entry `fetched` in `index.json`, crawled 2026-11-05); `blightmud-v5.7.1/` has the intact RPM + extracted binary; `scratch/` is empty by design; recorded-golden provenance headers match the current Quow db hash exactly (no fingerprint drift).

**Broken / stale (fixed in this doc):** the lua row claimed 5.4.8 but the machine has 5.5.1 (it was wrong when written); sqlite3 3.51.2 is now 3.53.4; python3 3.14.10 is now 3.15.0 (CI pins 3.14); the ruff "drift pending" row was done; the Phase-2 "missing tooling" note is landed; the Phase-8 scaffolding note said `cases.json` (it is `cases.lua`); "both house CI repos" were never staged as symlinks; `db/CONTEXT.md`'s "32,499 identified" figure has no queryable counterpart in rooms.db (a converter-time statistic; treat it as narrative, not a db fact); `testing_facility/README.md`'s Quow age figure (171 days on 2026-11-05) drifts by the day: the dataset is 2026-05-17.

**Still empty (by design, still the gap):** `captures/gmcp/`, `captures/logs/`, `golden/recorded/` on the facility side. The three real transcripts from live play (`~/.local/share/hex/captures/`, 2026-11-05/06/08) never graduated: only the 2026-11-06 login replay is committed (`tests/fixtures/gmcp/login.lua`, char.login/char.info still documented-only placeholders). `tests/golden/recorded/` has the 16 goldens; the facility mirror does not.

**Next live-verification session needs staged:** (1) `maze_{uulibrary,shades,aoa,hedge}.json` (still the top wire item blocking Phase 5's guess/modes); (2) `char_info.json`: one fresh login with `/hexraw` armed (also answers the guild/guildspec question); (3) the log sweeps listed in `captures/CONTEXT.md` (options output, skills listing, monitor/prompt, chat sweep, TPA expiry, `/spells`); (4) a DEATH capture: the hex_scry death anchors are wire-pending guesses and the very next death fixes them (arm `/hexprobe`-era captures or copy the session log segment; scrub names before anything enters `tests/fixtures/`); (5) graduation of the 2026-11-05 options sweep and 2026-11-08 room capture into fixtures; (6) `python3 tools/regen_goldens.py --record --synthetic` on the facility side if recorded goldens are re-authored (note `~/.local/share/hex/quow.db` does not exist; pass `--recorded-db` explicitly); (7) optionally re-crawl the docs mirror (`tools/mirror_discworld_docs.py` is resumable) and re-fetch the GMCP snapshot if a protocol question comes up that the 2026-11-05 pin can't answer.

## Live-capture procedures (for Brandon's sessions)

Record into `testing_facility/captures/gmcp/` as JSON in the Phase 8 fixture shape `{label, event, module, raw, t}` (with `/hexprobe` on for raw visibility, `/hexraw` for the payloads):

1. `seed_session.json`: connect → vitals push → `look` in a normal room → second room (the Phase 8 seed).
2. `char_info.json`: one login (answers the guild/guildspec wire question).
3. `room_map_{normal,empty,people,twolines}.json` + `writtenmap_{single,multi}.json`.
4. `maze_{uulibrary,shades,aoa,hedge}.json`: enter each maze, record identifier casing/name/kind and whether map payloads push (top backlog item).
5. `journey.json`: one ferry/journey command (arrival line + identifier jump).
6. `logs/`: `options output` listing, skills listing, monitor/prompt lines after `/hexsetup`, a chat sweep, TPA worn to expiry, `/spells` output, and a death sequence (fixes hex_scry's wire-pending anchors).

Scrub character names before anything graduates into committed `tests/fixtures/gmcp/`.
