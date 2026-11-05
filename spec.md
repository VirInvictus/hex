# Hex spec

## Purpose

Hex is a Discworld MUD plugin suite for Blightmud. It exists because Blightmud had no Discworld ecosystem: no vitals handling, no room awareness, no Quow database access, no gags. Hex ports the semantics of tt_dw (the TinTin++ Discworld suite, public domain) onto Blightmud's Lua API, so a Blightmud user gets the community's standard tooling.

Non-negotiable constraints, in priority order:

1. **The MUD is never driven autonomously.** Discworld's automation rules allow client-triggered rendering but ban anything that could unidle a character, including blank lines. Hex contains no `mud.send` outside user-alias handlers, and no timer ever sends input. This is a spec invariant, checked by grep.
2. **Third-party data is read-only.** Quow's database and the tt_dw clones (scripts, map) are never written by Hex. Generated artifacts (the Hex room database) live in Hex's own data directory.
3. **No third-party dependencies.** Lua 5.4 (the interpreter Blightmud embeds) and the Python standard library only.

## Semantics

### Data sources

- **GMCP.** Discworld's GMCP is documented at `https://discworld.starturtle.net/lpc/playing/documentation.c?path=/concepts/gmcp` and is **not** standard GMCP naming. On `gmcp.on_ready`, Hex sends two raw messages via `gmcp.send`: `core.hello {"client": "hex", "version": ...}` and one `core.supports.set ["char.login", "char.info", "char.vitals", "room.info", "room.map", "room.writtenmap"]` (lowercase full message names, individually, no version suffix). blightmud's `gmcp.register()` wrapper ("Core.Supports.Add ["Mod 1"]") is not used: Discworld ignores it. Server push timing per the doc: `char.login`/`char.info` at login; `char.vitals` whenever a command is sent (like the prompt); `room.info`/`room.map`/`room.writtenmap` on look/glance/enter. Hex listens on the documented lowercase names (capitalized fallback listeners stay registered), decodes the raw JSON strings, and resolves vitals fields from candidate key spellings until the exact JSON keys are pinned live (`/hexraw` shows the last raw payloads; a raw tap on telnet option 201 feeds it).
- **Quow's SQLite database.** Queried through the `sqlite3` CLI via blightmud's synchronous `core.exec`, exactly as tt_dw does. Millisecond-scale indexed reads only.
- **Hex's room database** (`~/.local/share/hex/rooms.db`). Built by `tools/convert_map.py` from the tt_dw map file: rooms keyed by vnum with the MUD's 40-hex identifier as an indexed column, plus exits. The identifier is the join key between GMCP `room.info`, the map, and Quow's `rooms.room_id`.

### Quow query semantics (ported from tt_dw)

- Search terms are comma-separated; each term contributes an `OR` clause. Empty terms are dropped.
- `*` becomes `%`, `?` becomes `_`. A leading `^` anchors the start (no leading `%`); a trailing `$` anchors the end (no trailing `%`).
- Field prefixes on item terms: `desc:` searches `description`, `app:` searches `appraise_text`, `mat:` searches `appraise_text LIKE 'it is made of <term>'`, `sheat:`/`scab:` matches scabbard name-or-description.
- `exact` on `/item` switches to equality instead of `LIKE`.
- Ordering: `ORDER BY REPLACE(item_name, 'an ', 'a ')` (and the npc_name equivalent). Result caps: 31 rows for `/item` and `/npc`, 61 for `/shop`, 41 for `/items`.
- Single quotes in user input are doubled; `|` is stripped from user input because it is the result-field separator. This matches tt_dw's string-interpolated-SQL conventions.

### `/items` source flags

- no flag: everything.
- `sold`: price contains a digit (`price GLOB '*[0-9]*'`), excluding the Shonky Shop.
- `free`: price has no digit.
- `loot`: `price = 'loot'`.

### Vitals and status

- `char.vitals` values update the vitals model; the status area (3 rows) renders HP/GP bars, XP, burden, current room, and XP rate.
- XP rate: once XP exceeds 100, a start point is recorded; rate = (current xp + spent - start xp) / elapsed hours. Skill-advance lines add to `spent`. Thresholds for coloring: good > 200k/h, ok > 100k/h, poor < 10k/h (tt_dw's values).
- HP bar color thresholds: >= 90% green, >= 50% yellow, >= 20% magenta, else red (simplified from tt_dw's five bands).

### Gags v1

Ported categories: pet/summon movement spam, sneak-continue lines, magic-client ambient lines (MWLC blue light, UPDD moth, hag's fireflies), discussion-items reminder, rows-changed notices, and their associated `Queued command:` echoes. Substitutions empty out the leading fragments of ambient lines so trailing list items stay readable. New gags are added as data, not code changes.

### Config and persistence

- All blightmud `store` keys are prefixed `hex.` (the keyspace is global across plugins).
- Disk-persisted config: `hex.options` (JSON: `quow_db`, `rooms_db`, and future keys). Per-character state is keyed by the identifier from `char.info`.
- Session state (current room, vitals) lives in module state; it is rebuilt from GMCP on connect.

### Loading rules (blightmud constraints, verified in source)

- `main.lua` is the plugin entry point and **all `require` calls happen at its top level**: blightmud resolves plugin-local modules only while `main.lua`'s own chunk executes.
- Module files are prefixed `hex_` because blightmud's `require` namespace is global and same-named files across plugins silently conflict.
- The plugin branch must be `main` (blightmud's updater only pulls `master`/`main`).
- APIs newer than the v5.7.1 release (tabs, top rows, line tags) are feature-detected before use.

## Non-goals (M1)

Pathfinding and speedwalks, mission timers, TPA/bugshield tracking, chat capture, sounds, spell data, spatial minimap rendering, and anything that writes to third-party data or sends input to the MUD without a user alias.
