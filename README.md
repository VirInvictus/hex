# Hex

A Discworld MUD plugin suite for the [Blightmud](https://github.com/Blightmud/blightmud) terminal client. Named for the computer in Unseen University.

Hex gives Blightmud what the Discworld MUD community's tooling gives other clients: live vitals bars fed by GMCP, room awareness keyed on the MUD's stable 40-hex room identifiers, Quow's famous item/NPC/shop database searches, and a starter set of gags. It is the first Discworld plugin ecosystem for Blightmud; the semantics are ported from [tt_dw](https://code.tubul.net/tt_dw/scripts) (public domain), the TinTin++ Discworld suite, with gratitude.

## Install

From inside Blightmud, with the repo cloned to `~/.gitrepos/hex`:

```
/add_plugin /home/bdkl/.gitrepos/hex
/enable_plugin hex
```

Restart Blightmud (the plugin auto-loads if enabled). For updates after that: `/update_plugins` then `/hexreload`; a bare `/load_plugin` re-runs `main.lua` but Lua's require cache keeps the old modules warm, so a full restart or `/hexreload` is the only clean reload. Then connect to Discworld as usual.

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
| `/missions [name]` | Mission table: live XP (halving per pending reset), XP/hour from your own history, reset countdowns; `/missions <name>` for one mission's stats |
| `/apply <board id>`, `/dl <A-H>` | Take a job market / dead letter mission (records the pending mission, then sends) |
| `/quota [refresh]` | Thief quota chip and detail; `refresh` sends `check quota brief` |
| `/skills [refresh\|search]` | Skill store: `refresh` runs the listing round-trip; a search shows levels and bonuses |
| `/bonus <skill> [target]` | Current and target bonus for a skill (targets: `120`, `l120`, `+10`, `b200`, `r180`) |
| `/skillcost <skill\|prefix> [target] [etb N]` | XP cost to a target level or bonus; primaries flagged `*`; prefixes cover multi-skill totals |
| `/goal add <skill> <target>`, `/goals` | Skill goals with XP bars and reach alerts |
| `/chat [family] [n]` | Chat recall (tells, clubs, group, talkers, shouts) from session ring buffers; stays in the main feed (mirror mode) unless your blightmud has tabs |
| `/chatset <family> on|off`, `/chattab on|off` | Chat family toggles and the tab gate |
| `/combat [level]`, `/combatstat` | Combat spam ladder (verbatim/verbose/default/brief, per-alt) and attacks-per-round |
| `/urls [pattern]`, `/url <n>` | URL catch and recall; `open` shells out behind an opt-in flag |
| `/spellinfo <nick\|name>`, `/spellcheck` | The full spell card with your per-stage spellcheck chances and level hints |
| `/tm <method>`, `/spells [list\|long\|<text>]` | TM suggestions per method (blacklist and thresholds configurable) and spell search |
| `/chatnpc [name]` | Silence an NPC's tells (persisted; `remove <name>` undoes) |
| `/blorp add|delete|rename|list|all|goto` | Named places, per-alt, distance-sorted; `goto` shows the route |
| `/bookmark add <label>: comment`, `/bookmark find|goto|list` | Shared bookmarks with comments, attributed per alt |
| `/mdt`, `/mdt list` | People in the rooms around you, parsed from the written map: arrows, score, highlights; `add`/`remove`/`category` manage your own match rows |
| `/hunt <target>`, `/hunt list`, `/unhunt <target>` | Watch for a target in nearby rooms: alert line on sight, deduped per 10 minutes |
| `/hexexits` | Every exit of your room: command, destination, and markers (`[gate]`, `[swim]`, `[climb]`, `[journey]`, `[hidden]`, `[unsafe]`) |
| `/hexzone` | Current area, Quow zone, and graph-component facts: whether BP, Genua, Bad Ass, or Lancre Town are routable from here at all |
| `/hexnight` | In-game day-part from the weather line plus dark-room signals, with the night implications (gates lock, climbs fail, room pushes go unverified). `/goto` repeats the warning before queueing |
| `/hexcorpse [mark\|clear]` | Death-site tracker: mark where you died, get the `/goto` back; stored per-alt and survives restarts |
| `/stats [refresh]` | Read your stats into the bonus math (from `score verbose stats`) |
| `/hexoptions [key] [value]` | Validated options with alt/session layers; `brief`, `defaults`, `clear <key>` |
| `/hexsay <text>` | Speak text when a TTS-enabled blightmud build is available |
| `/wmap`, `/dwmap` | Show the GMCP written map / ASCII room map (`/dwmap` strips the MUD's colour codes by default; `/hexset map_ansi ansi` keeps them) |
| `/doctor` | Self-test everything: GMCP liveness, databases, data modules, parser fixtures, wiring, feature detection; writes a report file |
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

Milestones 1-3 plus the social layer and spell data: vitals and status area, room awareness, Quow lookups, gags, user setup, Hex-owned data, pathfinding (`/path`, `/near`, `/goto`), mission tracking, the thief quota, the skills store with bonus/cost math and goals, chat capture, the combat spam ladder, URL recall, and the spell dataset with TM tooling. See `roadmap.md` for magic trackers, the room, and beyond.

## Credits

- [tt_dw](https://code.tubul.net/tt_dw/scripts) by Oki (public domain): query semantics, status thresholds, gag sets, XP-rate model.
- [Quow's Cow Bar](http://quow.co.uk/minimap.php) and its database, which is the center of gravity of Discworld tooling.
- The Discworld MUD's own [GMCP documentation](https://discworld.starturtle.net/lpc/playing/documentation.c?path=/concepts/gmcp).

## License

MIT. See [LICENSE](LICENSE). The bundled `logo.svg` is a placeholder.
