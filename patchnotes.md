# Hex patchnotes

## v0.1.0 (unreleased)

First milestone: M1 core + Quow.

- GMCP wiring for Discworld (dual-cased registration, JSON decode, `/hexprobe` echo) feeding a vitals model and a 3-row status area: HP/GP bars with color bands, XP, XP/hour rate, current room, burden
- Quow database searches with tt_dw's exact query semantics: `/item` (wildcards, `^`/`$` anchors, `desc:`/`app:`/`mat:`/`sheat:` prefixes, `exact`), `/items` source search with sold/free/loot filters, `/npc` with `room:` filter, `/shop` for the current room
- `/where` room awareness keyed on the MUD's 40-hex identifier, backed by `tools/convert_map.py` which parses tt_dw's map into Hex's own rooms.db (62,130 rooms, 156,800 exits, 32,499 identified)
- Gags v1 ported from tt_dw (pet/summon movement spam, ambient magic lines, system noise), `/wmap` and `/dwmap` fed by GMCP room maps, `/hexset` config persistence
- Zero-dependency test suites: `lua tests/run.lua` (31) and `python3 -m unittest discover -s tests` (9)
- Spec invariants: no autonomous MUD input (Discworld anti-idle rule), third-party data strictly read-only, no third-party dependencies

First-login hotfix batch (same milestone, found live):

- Fixed dead vitals: Discworld's GMCP is nonstandard (`core.supports.set` naming all six commands individually, lowercase, no version suffix); blightmud's `gmcp.register()` wrapper was silently ignored. Hex now sends the documented handshake raw, and vitals arrive per command from the next one.
- `/hexraw`: the last raw GMCP payloads via a telnet option 201 tap, to pin down the real JSON keys; keys confirmed on the first live session (hp/maxhp/gp/maxgp/xp/burden/alignment) and `room.info`'s `kind` now feeds the terrain display.
- `/hexreload`: reap-and-reload without restarting the client; a handle registry in the session store removes exactly the triggers/aliases the previous load created, so reloads never double-register.
- Fixed the `/item` crash on rows with empty trailing columns (Quow's cabbage has no weight); every result renderer is nil-guarded and the pipe splitter keeps empty fields.
- The status area draws its placeholder bars at load and on connect instead of waiting silently for first data.
- Sent lines while a password prompt is on screen are marked skip-log, so passwords stay out of the session log file.
