# Hex spec

## Purpose

Hex is a Discworld MUD plugin suite for Blightmud. It exists because Blightmud had no Discworld ecosystem: no vitals handling, no room awareness, no Quow database access, no gags. Hex ports the semantics of tt_dw (the TinTin++ Discworld suite, public domain) onto Blightmud's Lua API, so a Blightmud user gets the community's standard tooling.

Non-negotiable constraints, in priority order:

1. **The MUD is never driven autonomously.** Discworld's automation rule (concepts/automation, quoted at the top of docs/discworld-docs-research.md) bans anything that could unidle a character without the user acting at the same time, "including blank lines" (concepts/gmcp). Hex contains no `mud.send` outside user-alias handlers, and no timer ever sends input. The sole multi-step sender is `/goto`'s ONE-SHOT batch speedwalk: every route command queued in a single burst on one user invocation, unalterable except by the user typing `stop`; this is the officially sanctioned "fast" style (the room-by-room "slow" style is explicitly banned and must never be implemented). This is a spec invariant, checked by grep.
2. **Third-party data is read-only.** Quow's database and the tt_dw clones (scripts, map) are never written by Hex. Generated artifacts (the Hex room database) live in Hex's own data directory.
3. **No third-party dependencies.** Lua 5.4 (the interpreter Blightmud embeds) and the Python standard library only.

## Semantics

### Data sources

- **GMCP.** Discworld's GMCP is documented at `https://discworld.starturtle.net/lpc/playing/documentation.c?path=/concepts/gmcp` and is **not** standard GMCP naming. On `gmcp.on_ready`, Hex sends two raw messages via `gmcp.send`: `core.hello {"client": "hex", "version": ...}` and one `core.supports.set ["char.login", "char.info", "char.vitals", "room.info", "room.map", "room.writtenmap"]` (lowercase full message names, individually, no version suffix). blightmud's `gmcp.register()` wrapper ("Core.Supports.Add ["Mod 1"]") is not used: Discworld ignores it. Wire formats confirmed live on 2026-11-05 (capture transcript, `~/.local/share/hex/captures/`): `char.vitals` pushes per command with flat keys `alignment, maxhp, hp, xp, maxgp, burden, gp`; `room.info` pushes on glance AND look (both, not just movement) with `identifier` (40-hex, matches rooms.db `room_id` verbatim), `name`, `visibility`, and `kind` (Discworld's name for terrain; `inside` observed); `room.map` is a JSON string containing real `\u001b` ANSI escapes and newlines; `room.writtenmap` is a plain string. Hex listens on the lowercase names (capitalized fallback listeners stay registered) and decodes with the bundled json.
- **Score/option output shapes** (capture-verified 2026-11-05). `score brief` prints exactly `Hp: N(N)  Gp: N(N)  Xp: N  Burden: N%` (matches the combat-fallback regex). Stats are TWO dot-padded lines (`Constitution ... N   Intelligence ... N   Wisdom ......... N   Weight ......... N kg` / `Dexterity ...... N   Strength ....... N   Height ......... N cm`), not the documented 3-line form; the same pair tails `score verbose`, and the guild clause (`level N in the X Guild;`) parses from the same card. `options output` lists `name = value <choices>` with `name <more options>` for submenus. `brief exits` (bare) works; `options set output brief exits on` does not exist; `options terminal automatic rows = off` is rejected when rows are telnet-negotiated (blightmud's NAWS), so `/hexsetup` does not send it. `hskills brief` prints `timestamp - skill increased by N level(s) (bonus) to level L (bonus).`
- **Combat-line shapes** (capture-verified 2026-11-06). The per-round monitor line is the MUD's DEFAULT format `Hp: N (N) Gp: N (N) Xp: N` (single spaces, parenthesised maxima, no burden), and the prompt is a bare `>`, even though `/hexsetup` installs the customised tt_dw prompt/monitor strings (they evidently do not take effect on this character; Hex registers all three shapes and the default one fires). The Combat Crib training pumpkin's dodge line `The X swings towards you, but you see it in time and manage to dodge it` exists nowhere in tt_dw and is a Hex-added nop family.
- **Weather and dark-room shapes** (verified against session logs 2026-11-06..09, hundreds of samples). Outdoor rooms append a weather line: `It is a <temperature> <season>'s <day-part> with <wind> and <cloud cover>.`; observed day-parts are `morning`/`afternoon`/`evening`/`night` (`dawn`/`dusk`/`noon`/`midnight` are tolerated extras, unobserved yet). A dark room collapses to the description `Something.  It's dark here, isn't it?`, its map payload becomes `It is too dark to see anything.`, a moon line (`The land is lit up by the eerie light of the <phase> moon.`) may light it, and its `room.info` push carries NO identifier (the v0.17.2 fact); lit outdoor rooms carry `It is night and the <phase> moon is hidden by the clouds.`. **Death is wire-verified (2026-11-08 20:25, his own log)**: attackers render as `Something` in the dark; Death appears mid-fight (`You turn and see Death standing behind you.` after a random small-caps `Someone says: <CAPS>` quote), monologues as `Death says: <CAPS>`, leaves on Binky, and first-death mercy adds the grinning dwarfs with the handbook; hex_scry's death anchors use the two invariant lines. Consider output: the 13-rung ladder is pinned in the doc mirror; live shapes `The rat would be an easy target.` and `The feral pigeon is weaker than you.` feed `/hexscan`'s prey/even/danger bands.
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

### Situational awareness (hex_scry, v0.18.0)

Read-only investigation commands; their triggers only record signals and nothing ever sends:

- `/hexexits`: every `exits` row for the current room's vnum with destination name/area and markers: `gate` (the map's gates table, same short-command key the pathfinder's `is_gate` uses), `swim`/`climb`/`journey` by command prefix, and exit-flag bits `hidden` (HIDE=1 or INVIS=4) and `unsafe` (AVOID=2, tt_dw's unsafe bit).
- `/hexzone`: room name/id, map area/terrain, Quow zone name, then component facts: the identified graph size and landmark reachability (Bes Pelargic, Genua, Bad Ass, Lancre Town, hardcoded 40-hex ids with disconnection notes) via one multi-target Dijkstra under the default walk rules. Answers "can /goto take me there at all" (Bad Ass: never).
- `/hexnight`: passive day-part state. The weather-line trigger records the day-part (freshness 1 hour); the dark-description trigger, the dark map payload, and the moon line record dark/moon signals (dark freshness 10 minutes, cleared by any IDENTIFIED room push, since dark pushes carry no identifier). `/hexnight` prints the state plus night implications; `/goto` prints a pre-queue warning when the verdict is night or the current room is dark (the Hubwards Gate incident).
- `/hexcorpse`: per-alt death site in hex.db (`deathsite` table). `mark` records the current identified room, `clear` removes, bare shows the stored site enriched from rooms.db and a `/goto <full-id>` walk-back hint (the id probe is exact-only, so the hint carries the full identifier, not a prefix).

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
