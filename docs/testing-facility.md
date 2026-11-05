# The testing facility

`testing_facility/` (gitignored) is Hex's staging ground for every external material the phase designs consume or verify against. The research behind this doc: two agents produced a 14-row requirements sweep (what each design consumes, where it lives, licensing) and a per-phase fixture map; their findings are folded in here. See also [testing_facility/README.md](../testing_facility/README.md) for the on-disk index and the per-item CONTEXT.md files.

## What the roadmap actually requires externally

Almost nothing new: by design, every phase mines the two clones already on this machine (tt_dw, blightmud) plus Hex's own generated rooms.db. The sweep found exactly four genuinely missing items, all now staged:

| Missing item | Why it matters | Staged as |
|---|---|---|
| Stock blightmud v5.7.1 Linux binary | The dev tree has the tabs/top-row APIs; stock doesn't. The Phase 5/6 degradation ladders and the `/chat` fallback can only be tested against stock. | `blightmud-v5.7.1/` (RPM downloaded from the GitHub release, extracted via rpm2cpio; `usr/bin/blightmud --version` verified printing `blightmud v5.7.1`) |
| GMCP documentation snapshot | The protocol source of truth; the live page can drift under the designs | `gmcp-doc/gmcp-concepts.html` (fetched 2026-11-05) |
| Live payload captures | The Phase 8 harness fixtures and Phase 5's maze survey only exist in Brandon's sessions | `captures/gmcp/` + `captures/logs/` scaffolding with the capture procedures in CONTEXT.md |
| Recorded Quow goldens staging | Phase 8's local-only layer | `golden/recorded/` (also gitignored at `tests/golden/recorded/`) |

Everything else resolves to existing local paths and is symlinked, never copied: tt_dw scripts, the map repo, the Quow DB (18.5 MB), rooms.db, sound_files (CC0), both house CI repos, the blightmud dev clone.

## Toolchain status (swept 2026-11-05)

| Tool | Designs need | Local | Note |
|---|---|---|---|
| lua | 5.4 everywhere | 5.4.8 (`/usr/sbin/lua`) | `lua5.4` named binary added via `~/.local/bin/lua5.4` symlink (the Phase 8 golden engine shells to `lua5.4`; CI's apt package is 5.4.6 — goldens tolerate the minor delta) |
| sqlite3 | all phases | 3.51.2 (CI runners: 3.45.1; goldens pin the version in provenance headers) | |
| python3 | converters, goldens | 3.14.10 (matches the CI pin) | |
| ruff | Phase 8 pin `0.16.8` | **0.17.2** — drift to reconcile when Phase 8 lands (the format-only commit) | |
| rpm2cpio/cpio | stock-binary extraction | present | bsdtar absent, 7z present as fallback |
| sox | tt_dw only | absent, **correctly irrelevant** — Hex uses blightmud audio | |

## Per-phase staging table

The full per-phase map (inputs → source path → stage action → regen command) from the research:

- **1.x**: Quow DB (reference; staleness test uses a temp fake), rooms.db (reference), live: `options output` sweep + `char.info` capture + one `look` with `/hexraw` for the strip_ansi sample.
- **2**: rooms.db symlink for golden routes (`HEX_GOLD=1`, endpoints verified present: 3424, 5898, 4659, 12472, 11279-unreachable); live: maze captures, journey arrival, queued-command vocabulary, travel default. Missing tooling noted: `tests/bench_paths.lua` and the converter index additions are authored when the phase lands.
- **3**: transcript fixtures are synthetic (transcribed from verified tt_dw files); live: skills-listing round-trip capture, `char.info`.
- **4**: spelldata.tin read straight from the tt_dw clone by the future converter; live: TPA-to-expiry, bugshield noun samples, `/spells` output, `score verbose stats` spacing.
- **5**: live room.map/writtenmap fixtures (normal, empty, people-only, two-line; maze rooms for the top-priority item), the UULibrary shapes (now staged: the converter's `extra` column fixed the 0/1246 gap — see below); everything else synthetic.
- **6**: synthetic chat/combat fixtures from quoted tt_dw lines; live: monitor/prompt spacing after `/hexsetup`, a chat sweep log.
- **7**: sound_files symlink for the `/hexsound test` checklist; primaries transcribed from `char/data.tin:270-310`; unit tests use fake temp dirs.
- **8**: house workflow pins copied verbatim from cquarry/dragon-agents; vendored `json.lua` copied from the blightmud clone (MIT header preserved); the seed fixture recorded live; Quow DB referenced via `--recorded-db`; golden scaffolding (`tests/golden/{cases.json,sql,synthetic.sql,expected,recorded}`) authored when Phase 8 lands.

## Findings from the sweep (resolved here)

1. **Converter bug (fixed)**: `convert_map.py` discarded the 10th room field — the tintin list data (`{{shape}{3}}`) that Phase 5's maze guessing needs; measured 0/1,246 shapes in rooms.db. The `extra` column now carries it; rooms.db rebuilt and verified (1,246 shape rows, `{shape}{3}`/`{shape}{x}` samples); converter tests extended.
2. **Phase-2 maze stats were stale** (said 1,282 rooms / 9 ids): actual is **1,341 rooms across 12 ids** (UULibrary 1,246, AMPepperPot 25, StoLatLibrary 24, BPMedina 19, AMShades 16, SkundHedgeMaze 6, MagicCircle 1, Introduction:* ×3, tt_dw_blorp ×1). Corrected in [phase-2-mapper.md](phase-2-mapper.md) §0.
3. **`hex.map_ansi` default conflict**: phase-1x said `strip`, phase-5 said `ansi`. Resolved as a split, not a fight: `/dwmap` inline defaults `strip` (1.x, scrollback context), the Phase 5 panel defaults `ansi`; each doc now notes the other's scope.
4. **AGENTS.md wire-truth gap**: `room.writtenmap` (plain string) was missing from the recorded payload shapes; added.
5. **`lua5.4` named binary**: missing locally; `~/.local/bin/lua5.4` symlink created.
6. **Session logs**: `~/.local/share/blightmud/logs/` exists but is **never staged** (private conversation, sent lines); the facility's captures come from deliberate `/hexraw` sessions instead.

## Live-capture procedures (for Brandon's sessions)

Record into `testing_facility/captures/gmcp/` as JSON in the Phase 8 fixture shape `{label, event, module, raw, t}` (with `/hexprobe` on for raw visibility, `/hexraw` for the payloads):

1. `seed_session.json`: connect → vitals push → `look` in a normal room → second room (the Phase 8 seed).
2. `char_info.json`: one login (answers the guild/guildspec wire question).
3. `room_map_{normal,empty,people,twolines}.json` + `writtenmap_{single,multi}.json`.
4. `maze_{uulibrary,shades,aoa,hedge}.json`: enter each maze, record identifier casing/name/kind and whether map payloads push (top backlog item).
5. `journey.json`: one ferry/journey command (arrival line + identifier jump).
6. `logs/`: `options output` listing, skills listing, monitor/prompt lines after `/hexsetup`, a chat sweep, TPA worn to expiry, `/spells` output.

Scrub character names before anything graduates into committed `tests/fixtures/gmcp/`.
