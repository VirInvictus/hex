# Hex agent guidance

Per-repo guidance; overrides the global `~/.zcode/AGENTS.md` where they conflict.

## What this is

Lua 5.4 plugin suite for Blightmud playing Discworld MUD (telnet discworld.starturtle.net:23 or :4242; the game's site says .com but DNS only resolves .net). Portfolio project owned by Brandon. Public at https://github.com/VirInvictus/hex.

## Commands

```
lua tests/run.lua                      # unit suite (pure modules)
HEX_GOLDEN=1 lua tests/run.lua         # + golden routes (needs ~/.local/share/hex/rooms.db)
lua tests/bench_paths.lua              # graph build/route benchmark against the real db
python3 -m unittest discover -s tests  # converter tests (stdlib unittest)
python3 tools/regen_goldens.py --check --synthetic   # golden engine, the CI gate (SQL + synthetic layers)
python3 tools/regen_goldens.py --record --synthetic  # re-author committed goldens after builder changes, then REVIEW THE DIFF
python3 tools/regen_goldens.py --check --recorded --strict --recorded-db <quow.db>  # pre-tag ritual, local only
python3 tools/regen_goldens.py --check --routes            # route-golden layer (committed fixtures, needs rooms.db)
python3 tools/convert_map.py           # rebuild rooms.db from the tt_dw map clone
python3 tools/convert_spelldata.py     # regenerate src/hex_spelldata.lua from tt_dw spelldata.tin
python3 tools/convert_mdtdata.py       # regenerate src/hex_mdtdata.lua from tt_dw mdt_adverbs.tin
```

Run all commands from the repo root.

## Architecture facts (verified against blightmud source, do not re-derive)

- `main.lua` is the only entry point. **All `require` calls stay at its top level**: blightmud prepends `<plugindir>/?.lua` to `package.path` only while executing that chunk (`src/lua/lua_script.rs:459-475` in the reference clone at `~/.gitrepos/blightmud`).
- The loader prepends `<plugindir>/?.lua` to `package.path` while `main.lua` executes (`lua_script.rs:459-475`), so modules live under `src/` and are required as `src.hex_*`. Basenames stay `hex_`-prefixed because `require` is global across plugins; same-named files silently collide (blightmud issue #1059).
- `gmcp.receive` callbacks get the raw JSON body string; decode with the bundled `json`.
- **Discworld GMCP is nonstandard** (verified against the game's own doc, `documentation.c?path=/concepts/gmcp`): registration is one raw `core.supports.set` naming all six commands individually, lowercase, no version suffix, plus a lowercase `core.hello`. blightmud's `gmcp.register()` ("Core.Supports.Add ["Mod 1"]") is silently ignored by Discworld, which is why M1's vitals were dead on first login. `char.vitals` pushes per command sent; `room.*` pushes on look/glance/enter. `hex_gmcp.lua` owns the handshake; `/hexraw` shows the last raw payloads via a tap on telnet option 201. Wire truth confirmed live 2026-11-05: `char.vitals` has flat keys hp/maxhp/gp/maxgp/xp/burden/alignment and is pushed twice per command (harmless); `room.info` is {identifier, name, visibility, kind} and `kind` is the terrain; `room.map` is a JSON string with real ANSI escapes; `room.writtenmap` is a plain string.
- Trigger/Alias objects expose a globally-unique `.id` and `trigger.remove(id)` searches every group, so `hex_registry.lua` records handles in the session store and `main.lua` reaps them on load; `/hexreload` = reap + clear `package.loaded["*hex_*"]` + `script.load` main.lua. Without the reap, a reload doubles every trigger.
- `gmcp.on_ready` supports multiple callbacks (the help doc claiming one is stale vs `resources/lua/gmcp.lua:110-115`).
- `core.exec` is synchronous on the UI thread: queries must stay millisecond-scale; use the array form `{ "sqlite3", db, sql }`.
- `store` is a flat string-to-string KV shared by every plugin: prefix keys with `hex.`.
- Status area: `blight.status_height(0-5)`, `blight.status_line(index, text)` 0-based; first/last rows render as bars.
- Rust regex engine: no lookaround/lookbehind. Tintin-to-Hex regex conversion: `%1..%n` becomes capture groups, `%*` becomes `.*`, tintin's `~` raw-prefix becomes the `raw` trigger option, `%i` becomes the case-insensitive `Regex.new` option.
- APIs newer than the v5.7.1 release (tabs, top rows, line tags) must be feature-detected.
- Command aliases must match the leading slash themselves (`"^/item\\s+"`): blightmud passes unmatched lines (slash included) straight to the MUD.
- `script.reset` does NOT clear `package.loaded`: after editing plugin files, `/load_plugin` re-executes main.lua but cached modules stay stale. Restart the client for a clean reload (learned live in the probe).
- **Wire facts (capture-verified 2026-11-05, `~/.local/share/hex/captures/`)**: GMCP identifiers are 40-hex and match rooms.db verbatim; `glance` and `look` both push info+map+writtenmap; `score brief` = `Hp: N(N)  Gp: N(N)  Xp: N  Burden: N%`; stats = TWO dot-padded lines (`Constitution ...` / `Dexterity ...`), not the documented 3-line, and the same pair tails `score verbose`; guild parses from score verbose's `level N in the X Guild` clause; `hskills brief` uses the plain-parens shape; `options set output brief exits on` is INVALID (bare `brief exits` works); `options terminal automatic rows = off` is REJECTED under blightmud's NAWS (not sent by /hexsetup).
- **Wire facts (combat, capture-verified 2026-11-06 00:31)**: the per-round combat line is the MUD's DEFAULT monitor format `Hp: N (N) Gp: N (N) Xp: N` (single spaces, parenthesised maxima, no burden) and the prompt is bare `>`, regardless of the customised prompt/monitor strings /hexsetup installs (all three shipped monitor shapes stay registered; DEFAULT_MONITOR is the one that fires). The training pumpkin's dodge line `The X swings towards you, but you see it in time and manage to dodge it` exists NOWHERE in tt_dw (it never fights the Combat Crib) and is a Hex-added nop family.
- **DEBUG LANE history**: `src/hex_capture.lua` shipped in v0.5.2-dbg, was REMOVED in v0.6.0 per plan, and RESURRECTED in v0.12.1-dbg (asked-for) for the combat-monitor pass; it comes out of the next feature release while `/doctor` (v0.12.1-dbg, permanent) is the in-client self-test. Transcripts live in `~/.local/share/hex/captures/` and remain the wire-shape reference; doctor reports land in `~/.local/share/hex/doctor-<stamp>.log`.

## Hard constraints (spec.md carries the details)

1. No `mud.send` outside user-alias handlers; no timer ever sends input. Discworld bans anything that could unidle a character. `rg -n 'mud\.send' src/` must only hit alias/command callbacks.
2. Quow's database and the tt_dw clones are read-only. Generated data goes to `~/.local/share/hex/`.
3. No third-party dependencies: Lua 5.4 stdlib and Python stdlib only.

## Editor support

LuaLS: point `.luarc.json` `workspace.library` at `~/.gitrepos/blightmud/resources/lua/types/` (the `blightmud.d.lua` class definitions). The committed `.luarc.json` holds the absolute path; it is machine-local by design while the repo stays local-only.

## Porting sources

Semantics are ported from tt_dw (`~/.gitrepos/tt_dw`, public domain): Quow SQL from `scripts/quow/*.tin`, status thresholds from `scripts/status/status.tin`, gags from `scripts/misc/gags.tin`, XP-rate model from `scripts/status/status.tin` (~610-680). Zone names from `scripts/quow/quow.tin` (`quow[map_names]`). Keep ports faithful and cite the source file in a comment when the mapping is non-obvious.
