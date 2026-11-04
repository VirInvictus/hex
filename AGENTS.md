# Hex agent guidance

Per-repo guidance; overrides the global `~/.zcode/AGENTS.md` where they conflict.

## What this is

Lua 5.4 plugin suite for Blightmud playing Discworld MUD (https://discworld.starturtle.com). Portfolio project owned by Brandon. Local-only for now (no remote).

## Commands

```
lua tests/run.lua                      # unit suite (pure modules)
python3 -m unittest discover -s tests  # converter tests (stdlib unittest)
python3 tools/convert_map.py           # rebuild rooms.db from the tt_dw map clone
```

Run all commands from the repo root.

## Architecture facts (verified against blightmud source, do not re-derive)

- `main.lua` is the only entry point. **All `require` calls stay at its top level**: blightmud prepends `<plugindir>/?.lua` to `package.path` only while executing that chunk (`src/lua/lua_script.rs:459-475` in the reference clone at `~/.gitrepos/blightmud`).
- The loader prepends `<plugindir>/?.lua` to `package.path` while `main.lua` executes (`lua_script.rs:459-475`), so modules live under `src/` and are required as `src.hex_*`. Basenames stay `hex_`-prefixed because `require` is global across plugins; same-named files silently collide (blightmud issue #1059).
- `gmcp.receive` callbacks get the raw JSON body string; decode with the bundled `json`.
- `gmcp.on_ready` supports multiple callbacks (the help doc claiming one is stale vs `resources/lua/gmcp.lua:110-115`).
- `core.exec` is synchronous on the UI thread: queries must stay millisecond-scale; use the array form `{ "sqlite3", db, sql }`.
- `store` is a flat string-to-string KV shared by every plugin: prefix keys with `hex.`.
- Status area: `blight.status_height(0-5)`, `blight.status_line(index, text)` 0-based; first/last rows render as bars.
- Rust regex engine: no lookaround/lookbehind. Tintin-to-Hex regex conversion: `%1..%n` becomes capture groups, `%*` becomes `.*`, tintin's `~` raw-prefix becomes the `raw` trigger option, `%i` becomes the case-insensitive `Regex.new` option.
- APIs newer than the v5.7.1 release (tabs, top rows, line tags) must be feature-detected.
- Command aliases must match the leading slash themselves (`"^/item\\s+"`): blightmud passes unmatched lines (slash included) straight to the MUD.
- `script.reset` does NOT clear `package.loaded`: after editing plugin files, `/load_plugin` re-executes main.lua but cached modules stay stale. Restart the client for a clean reload (learned live in the probe).

## Hard constraints (spec.md carries the details)

1. No `mud.send` outside user-alias handlers; no timer ever sends input. Discworld bans anything that could unidle a character. `rg -n 'mud\.send' src/` must only hit alias/command callbacks.
2. Quow's database and the tt_dw clones are read-only. Generated data goes to `~/.local/share/hex/`.
3. No third-party dependencies: Lua 5.4 stdlib and Python stdlib only.

## Editor support

LuaLS: point `.luarc.json` `workspace.library` at `~/.gitrepos/blightmud/resources/lua/types/` (the `blightmud.d.lua` class definitions). The committed `.luarc.json` holds the absolute path; it is machine-local by design while the repo stays local-only.

## Porting sources

Semantics are ported from tt_dw (`~/.gitrepos/tt_dw`, public domain): Quow SQL from `scripts/quow/*.tin`, status thresholds from `scripts/status/status.tin`, gags from `scripts/misc/gags.tin`, XP-rate model from `scripts/status/status.tin` (~610-680). Zone names from `scripts/quow/quow.tin` (`quow[map_names]`). Keep ports faithful and cite the source file in a comment when the mapping is non-obvious.
