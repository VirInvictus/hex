# Hex design docs

One document per roadmap phase, produced by the 2026-11-04/05 exploration campaign (eight research agents over the tt_dw and blightmud clones, the live wire samples, and Hex's own code; every claim carries a `file:line` citation). Each doc is implementation-ready: data schemas, algorithms, regex tables, module layouts, test plans, and a live-verification list. `roadmap.md` remains the phase tracker; these are the designs behind its boxes.

| Doc | Phase | Status | The one decision that shapes it |
|---|---|---|---|
| [phase-1x-setup.md](phase-1x-setup.md) | 1.x hotfix lane | shipped in v0.2.0 | `/hexsetup` sends tt_dw's exact eight game-side strings (documented rows form + `term xterm256`); user gags live in a data file; `/hexupdate` owns the Quow database |
| [phase-2-mapper.md](phase-2-mapper.md) | 2 find your way | shipped in v0.3.0 | Dijkstra over the identified subgraph in Lua, built lazily; BP and Genua are disconnected in the identified subgraph (measured), so the /goto walker is batch-only and never re-routes blind |
| [phase-3-character.md](phase-3-character.md) | 3 working character | missions + quota shipped in v0.4.0; skills/stats wire-gated | Missions mirror tt_dw's SQL schema as per-alt JSON; the bonus formula (0.1020408·ln(prod) − 0.25) is extracted and cross-checked |
| [phase-4-magic.md](phase-4-magic.md) | 4 magic & faith | designed | spelldata ships committed (117 spells, ~130 KB) so installs work without tt_dw; the TM algorithm is tt_dw's exact relative-chance pipeline |
| [phase-5-room.md](phase-5-room.md) | 5 the room | designed | Render ladder: top rows (dev) → tab → inline (stock); maze movement is an input-listener rewrite, legal because plugin sends bypass it |
| [phase-6-social.md](phase-6-social.md) | 6 social | designed | One mirror-mode `chat` tab routed by Rust-side filters (colors free, no double-routing); GMCP always beats the monitor fallback |
| [phase-7-feel.md](phase-7-feel.md) | 7 feel & options | designed | Sound off by default (no bundled files; tt_dw's CC0 set via sound_dir); options = schema-validated layers (session > alt > global > default) |
| [phase-8-engineering.md](phase-8-engineering.md) | 8 ship | designed | CI from the house shape; three-layer goldens; a fake-GMCP shim that makes the M1 dead-vitals bug class a red CI run instead of a dead status bar |

## Cross-phase shared infrastructure (build once, consumed everywhere)

- **hex_registry**: trigger/alias handles today; gains the `"timer"` kind in Phase 3 (every later phase relies on it).
- **status.render `chips` argument**: Phase 3 introduces it; Phases 4-6 contribute chips (assembly order: tpa, bugshield/faith, broom, statitems; quota > mission).
- **hex_config layers**: global `hex.options` → per-alt `get_for_alt/set_for_alt` (Phase 3) → session layer; Phase 7 formalizes the chain in `/hexoptions`.
- **hex.db** (`~/.local/share/hex/hex.db`): Phase 5 introduces real tables (blorp, bookmark, mdt_match, mdt_category, hunt, meta); separate from rooms.db so map rebuilds never touch user data.
- **hex_notify** (Phase 6): the ~40-line event bus every later notification (sound, TTS) subscribes to.
- **hex_theme** (Phase 7): semantic role → palette; Phases 2-6 chips consume roles.
- **tests/shim + replay** (Phase 8): the blightmud API shim that lets the whole handler chain run in plain lua.

## Dependency order

1.x → 2 (walker) → 3 (skills store feeds 4's bonus math) → 4 (stat-item netting, chips) → 5 (uses 2's graph and 6's tabs) → 6 (notify feeds 7's sound) → 7 → 8 (CI/shim can land incrementally from Phase 3 onward; the harness is most valuable once handlers multiply).

Phase 4 degrades gracefully without 3 (elapsed-only chips); Phase 5's guess needs 5's own maze modes; Phase 8's shim should be stood up early despite living in "Phase 8" — it is test infrastructure, not a feature.

## External materials

Everything the designs consume or verify against is staged under `testing_facility/` (gitignored): symlinks to the tt_dw/blightmud clones and both databases, the CC0 sound set, a downloaded stock blightmud v5.7.1 binary for the degraded-path ladder, a pinned GMCP doc snapshot, and live-capture scaffolding. See [testing-facility.md](testing-facility.md) for the requirements table, toolchain status, and capture procedures.

## Live-verification backlog (the wire-verification lists, merged)

Wire claims are verified with `/hexprobe`, `/hexraw`, and session logs before the feature that depends on them ships (spec invariant 4). The merged backlog lives in each doc's final section; the two highest-priority items: maze `room.info` behavior (blocks Phase 5's guess/modes) and whether `char.info` carries guild/guildspec (blocks pack autoload + TM gating).
