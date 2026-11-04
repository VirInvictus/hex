# Hex patchnotes

## v0.1.0 (unreleased)

First milestone: M1 core + Quow.

- GMCP wiring for Discworld (dual-cased registration, JSON decode, `/hexprobe` echo) feeding a vitals model and a 3-row status area: HP/GP bars with color bands, XP, XP/hour rate, current room, burden
- Quow database searches with tt_dw's exact query semantics: `/item` (wildcards, `^`/`$` anchors, `desc:`/`app:`/`mat:`/`sheat:` prefixes, `exact`), `/items` source search with sold/free/loot filters, `/npc` with `room:` filter, `/shop` for the current room
- `/where` room awareness keyed on the MUD's 40-hex identifier, backed by `tools/convert_map.py` which parses tt_dw's map into Hex's own rooms.db (62,130 rooms, 156,800 exits, 32,499 identified)
- Gags v1 ported from tt_dw (pet/summon movement spam, ambient magic lines, system noise), `/wmap` and `/dwmap` fed by GMCP room maps, `/hexset` config persistence
- Zero-dependency test suites: `lua tests/run.lua` (28) and `python3 -m unittest discover -s tests` (9)
- Spec invariants: no autonomous MUD input (Discworld anti-idle rule), third-party data strictly read-only, no third-party dependencies
