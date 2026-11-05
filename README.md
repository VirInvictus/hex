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

Hex also expects two data files (created once, refreshed manually):

- Quow's database: `~/.gitrepos/tt_dw/quow/_quowmap_database.db` (downloaded from [quow.co.uk](http://quow.co.uk/maps/_quowmap_database.db)). Read-only; Hex never writes it.
- Hex's room database: run `python3 tools/convert_map.py` in the repo to build it from the tt_dw map clone.

Both paths are overridable with `/hexset quow_db <path>` and `/hexset rooms_db <path>`.

## Commands

| Command | What it does |
|---|---|
| `/item [exact] <search>` | Search Quow's item database (comma-separated terms, `*`/`?` wildcards, `^`/`$` anchors, `desc:`/`app:`/`mat:`/`sheat:` prefixes) |
| `/items [sold|free|loot] <search>` | Where to get an item: shops, NPC vendors, or found-in-world notes |
| `/npc <search>` | Find NPCs (`room:<identifier>` narrows to one room) |
| `/shop [room id]` | List what a room sells (defaults to your current room) |
| `/where` | Current room identifier plus map-database details |
| `/wmap`, `/dwmap` | Show the GMCP written map / ASCII room map |
| `/hexprobe` | Toggle raw GMCP echo (debugging) |
| `/hexraw` | Show the last raw GMCP payloads (debugging) |
| `/hexreload` | Reload Hex without restarting the client |
| `/hexset <key> <value>` | Persist a config override |
| `/hexhelp` | Command summary |

## Status

Milestone 1 (vitals, status area, room awareness, Quow lookups, gags v1). See `roadmap.md` for pathfinding and beyond.

## Credits

- [tt_dw](https://code.tubul.net/tt_dw/scripts) by Oki (public domain): query semantics, status thresholds, gag sets, XP-rate model.
- [Quow's Cow Bar](http://quow.co.uk/minimap.php) and its database, which is the center of gravity of Discworld tooling.
- The Discworld MUD's own [GMCP documentation](https://discworld.starturtle.net/lpc/playing/documentation.c?path=/concepts/gmcp).

## License

MIT. See [LICENSE](LICENSE). The bundled `logo.svg` is a placeholder.
