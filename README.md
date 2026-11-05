# Hex

A Discworld MUD plugin suite for the [Blightmud](https://github.com/Blightmud/blightmud) terminal client. Named for the computer in Unseen University.

Hex gives Blightmud what the Discworld MUD community's tooling gives other clients: live vitals bars fed by GMCP, room awareness keyed on the MUD's stable 40-hex room identifiers, Quow's famous item/NPC/shop database searches, and a starter set of gags. It is the first Discworld plugin ecosystem for Blightmud; the semantics are ported from [tt_dw](https://code.tubul.net/tt_dw/scripts) (public domain), the TinTin++ Discworld suite, with gratitude.

## Install

From inside Blightmud, with the repo cloned to `~/.gitrepos/hex`:

```
/add_plugin /home/bdkl/.gitrepos/hex
/enable_plugin hex
```

Restart Blightmud (the plugin auto-loads if enabled). For updates after that: `/update_plugins` then `/hexreload` — a bare `/load_plugin` re-runs `main.lua` but Lua's require cache keeps the old modules warm, so a full restart or `/hexreload` is the only clean reload. Then connect to Discworld as usual.

Hex owns its data under `~/.local/share/hex/`:

- Quow's database: run `/hexupdate` once; it downloads the database from [quow.co.uk](https://quow.co.uk/maps/_quowmap_database.db) into `~/.local/share/hex/quow.db` (detached, so the client keeps responding; run `/hexupdate` again for status) and copies the CC0 sound set for later phases. Until then Hex falls back to `~/.gitrepos/tt_dw/quow/_quowmap_database.db` with a one-time hint. Read-only either way; Hex never writes tt_dw's copy. Hex warns at connect when the database is older than `quow_stale_days` (60).
- Hex's room database: run `python3 tools/convert_map.py` in the repo to build `~/.local/share/hex/rooms.db` from the tt_dw map clone.
- Your gags live in `~/.local/share/hex/gags.lua` (created on first load), edited with `/hexgag`.

Paths are overridable with `/hexset quow_db <path>`, `/hexset rooms_db <path>`, and `/hexset gags_file <path>`.

## Commands

| Command | What it does |
|---|---|
| `/item [exact] <search>` | Search Quow's item database (comma-separated terms, `*`/`?` wildcards, `^`/`$` anchors, `desc:`/`app:`/`mat:`/`sheat:` prefixes) |
| `/items [sold|free|loot] <search>` | Where to get an item: shops, NPC vendors, or found-in-world notes |
| `/npc <search>` | Find NPCs (`room:<identifier>` narrows to one room) |
| `/shop [room id]` | List what a room sells (defaults to your current room) |
| `/where` | Current room identifier plus map-database details |
| `/path [--full] [any] <target>` | Route from your room through the identified map graph. Targets: room name (with `*`/`?`/`^`/`$`), `@<area>`, a room id, `#<n>` from the last candidate list, a bare vnum. Multiple matches give a numbered list with step counts; `any` allows avoid-flagged/water rooms |
| `/near <search>` | The five nearest matches to your current room by path length |
| `/goto <target>` | One-batch speedwalk to a target: the whole route queues in a single user-invoked burst (the MUD's sanctioned "fast" style) and Hex never sends again after it. `stop` in-game or `/stopwalk` aborts; drift is reported for information only |
| `/stopwalk` | Send `stop` and clear the walk display |
| `/wmap`, `/dwmap` | Show the GMCP written map / ASCII room map (`/dwmap` strips the MUD's colour codes by default; `/hexset map_ansi ansi` keeps them) |
| `/hexsetup [what]` | Send the game-side options tt_dw requires (prompt, aliases, options; `preview` shows without sending) |
| `/hexupdate` | Download Quow's database + CC0 sounds into Hex's data directory |
| `/hexgag`, `/gaglog` | List and add your own gags as data (`/hexgag [-i] <pattern> [-> <substitution>]`) |
| `/hexungag <n\|text>` | Remove user gag entries |
| `/hexprobe` | Toggle raw GMCP echo (debugging) |
| `/hexraw` | Show the last raw GMCP payloads (debugging) |
| `/hexreload` | Reload Hex without restarting the client |
| `/hexset <key> <value>` | Persist a config override |
| `/hexhelp` | Command summary |

## Status

Milestones 1-2: vitals and status area, room awareness, Quow lookups, gags, user setup, Hex-owned data, and pathfinding (`/path`, `/near`, `/goto`). See `roadmap.md` for missions, magic, the social layer, and beyond.

## Credits

- [tt_dw](https://code.tubul.net/tt_dw/scripts) by Oki (public domain): query semantics, status thresholds, gag sets, XP-rate model.
- [Quow's Cow Bar](http://quow.co.uk/minimap.php) and its database, which is the center of gravity of Discworld tooling.
- The Discworld MUD's own [GMCP documentation](https://discworld.starturtle.net/lpc/playing/documentation.c?path=/concepts/gmcp).

## License

MIT. See [LICENSE](LICENSE). The bundled `logo.svg` is a placeholder.
