# Phase 1.x: setup, gags, staleness, and the guild inventory

Design doc for the 1.x hotfix lane. Everything cites `file:line` against `~/.gitrepos/hex` and `~/.gitrepos/tt_dw`. Status: designed, not implemented.

## A1. `/hexsetup` — the game-side options, sanctioned

### The verbatim strings

Every command line tt_dw sends to the MUD, quoted exactly from `~/.gitrepos/tt_dw/doc/mud_settings.md` (MS) and `~/.gitrepos/tt_dw/scripts/util/setup_check.tin` (SC). MS:11 notes the backslashes in the doc prevent TinTin++ from eating dollar signs; the `$...$` tokens are literal MUD-side prompt template variables, and Hex sends the strings with no escaping (Lua has no `$` interpolation).

Prompt (MS:13, SC:42):
```
prompt "$hurtcolour$Hp: %^BOLD%^$hp$%^RESET%^$hurtcolour$ ($maxhp$)  Gp: $gp$ ($maxgp$)  Xp: $xp$   ($align$, $temp$)%^RESET%^>"
```

Combat monitor (MS:15, SC:43) — note the three spaces between HP and Gp:
```
monitor $hurtcolour$Hp: %^BOLD%^$hp$%^RESET%^$hurtcolour$   Gp: $gp$%^RESET%^
```

Map output (SC:66/75): `options set output map all "off"`

Brief exits (MS:17, SC:67/76): `brief exits`

Paging (SC:69-70/78-79, tt_dw comment "paging messes with listing skills" at SC:68/77):
```
options terminal automatic rows = off
rows 999
```

Aliases (SC:54-57, MS:21-28):
```
alias login mailinfo alts unread
alias afterinventory gp brief;shields;inventory;score brief
alias sn sneak $arg:low$
alias hw health wounded all
```
MS:27-28 documents a fourth alias (`alias k kill <safe_targets_in_this_room>`) that setup_check.tin does not send; it is generated dynamically by tt_dw's target system.

### Per-item decision

| Item | Hex feature that depends on it | Decision |
|---|---|---|
| `prompt "..."` | Phase 6 vitals fallback (GMCP-first until then) | Send |
| `monitor ...` | Phase 6 combat-monitor fallback; round counting | Send |
| `options set output map all "off"` | Stops the MUD's inline map duplicating `/dwmap` and the Phase 5 panel | Send |
| `brief exits` | Phase 5 lost-room/maze text parsing; clean room text | Send, but it is a bare toggle, not idempotent: after wire verification prefer `options set output brief exits on` if accepted |
| `options terminal automatic rows = off` | Stops "Rows changed" spam at the source (better than the existing gag) | Send |
| `rows 999` | Phase 3 skills listings; any long listing | Send |
| `alias afterinventory gp brief;shields;inventory;score brief` | Phase 4 reads `shields` output; user types `afterinventory` themselves — Hex never runs it | Send (define only) |
| `alias sn/hw/k`, `alias login mailinfo`, `screenreader set defaults` | tt_dw parser/numpad/speech peripherals; blightmud has native bindings and TTS | Skip |

### `/hexsetup` surface

Mirrors tt_dw's `/setup [preview] [help|prompt|aliases|options|all]` (setup_check.tin:10):

```
/hexsetup                 -> help text (no MUD traffic)
/hexsetup preview [what]  -> print what would be sent
/hexsetup prompt          -> prompt + monitor
/hexsetup aliases         -> afterinventory alias only
/hexsetup options         -> map off, brief exits, automatic rows off, rows 999
/hexsetup all             -> the three groups in order
```

Each command prints gray (`[hex] send: <cmd>`) then sends, one `mud.send` per line, unbatched, so the screen shows an unambiguous checklist. Closing line: `[hex] setup sent: 7 commands. /hexcheck to verify`. The sends live inside the alias handler, so the grep invariant stays green.

### `/hexcheck`

tt_dw's `/check_setup` (SC:89-199) checks local files only. Hex does two tiers:

- **Tier 1, local**: `quow_db` exists + age (feeds A3), `rooms_db` exists + row count, GMCP handshake confirmed by scanning `hex_gmcp.recent()` for a `char.vitals` payload since connect.
- **Tier 2, MUD-side**: sends `options output`, a registry-wrapped temporary trigger collects `^(%w[%w %.]*)%s*=%s*(.+)$` lines into a table (the same parser shape Phase 3's skills listing needs), a client-side display-only timer prints the checklist ~2 s later. Whether `prompt`/`monitor` appear in `options output` is a live-verification item; if absent, those rows print "check manually" with the reference strings.

## A2. Gag registry file — user gags as data

- Path: `~/.local/share/hex/gags.lua` (configurable, `/hexset gags_file <path>`), loaded additively after `hex_gags.M.patterns` (built-ins first; a user `sub` wins by registration order since `line:replace` overwrites). Re-application on `/hexreload` is automatic via the registry.
- Load via `dofile` in `pcall`: blightmud creates the Lua state with `Lua::unsafe_new()` (`src/lua/lua_script.rs:149`), which loads the full standard library including io/os. Guard `if io == nil` so a future safe-state switch degrades to "gags work, /hexgag write disabled".
- File format (the shipped template):
```lua
-- ~/.local/share/hex/gags.lua -- your gag/substitution data for Hex.
-- Written by /hexgag, /hexungag; safe to edit by hand. Hand-edits need /hexreload.
-- Each entry: { re = "<Rust regex>", i = true|nil, sub = "text"|nil }
return {
  { re = [[^The priest blesses you\.$]] },
  { re = [[^Xavara whispers, .*$]], i = true },
  { re = [[^A .* messenger arrives and delivers a message\.$]], sub = "" },
}
```
- Bad user regexes: each entry registers inside its own `pcall`; failure prints `[hex] gags: skipping entry 2 (user file): regex parse error: ...` and continues. `/hexgag` validates with `pcall(Regex.new, ...)` before writing, so lookaround can never enter through the alias (the Rust engine rejects it).
- Alias surface:
```
/hexgag                      -> numbered list: kind, flags, source, pattern
/hexgag <pattern>            -> validate + append + register live
/hexgag <pattern> -> <text>  -> substitution entry
/hexgag -i <pattern> [...]   -> case-insensitive
/hexungag <n>                -> remove user entry n
/hexungag <pattern-text>     -> remove matching user entries
```
Writer emits `[[...]]` long strings unless the pattern contains `]]` (then `%q`). Zero-dep: dofile/io/pcall only.

## A3. Quow staleness warning

Mechanism: mtime via `core.exec({ "stat", "-c", "%Y", path })` (macOS fallback `-f %m` tried only on non-zero exit), compared to `os.time()`. No stored download date: the mtime *is* the download date, and a stored date would drift the first time the user updates outside Hex. Threshold `quow_stale_days` (default 60, `/hexset`-able). Trigger point: `mud.on_connect`, one `stat`, warn once per session. Output:

```
[hex] Quow's database is 73 days old (~/.gitrepos/tt_dw/quow/_quowmap_database.db).
[hex] Refresh it with: cd ~/.gitrepos/tt_dw && bash/update.sh   (Hex never writes it.)
```

tt_dw has no staleness warning of its own (`bash/update.sh` has only `-q`); this is Hex-native.

## A4. `room.map` ANSI handling

`hex_util.strip_ansi(s)`: `return (tostring(s):gsub("\27%[[%d;]*%a", ""))` — covers `\x1b[39;49m`, `\x1b[0m`, `\x1b[31m`, and other CSI final letters. Config `hex.map_ansi` = `ansi | strip`. Scope note: this doc's `strip` default governs the 1.x `/dwmap` inline print; Phase 5's panel owns the full ANSI path and defaults `ansi` there (`hex.map_ansi` is one key read by both surfaces — Phase 5 resolves the per-surface default when it lands) (a stray unclosed color fragment is what makes raw output look broken). Strip at **render** time in `/dwmap`, not at store time (`maps.ascii` stays raw so Phase 5's panel keeps colors). Phase 5 owns the full `ansi` rendering path.

## Part B. Guild-pack inventory

Headline: **tt_dw has no `guild/` tree and no per-guild command scripts.** Guild functionality is (1) spell/ritual trackers under `magic/` and `faith/`, (2) thief quota, (3) item trackers, (4) the primaries dataset in `char/data.tin:274-308`. Verified negatives: no witch tea-brewing script exists (`tea|brew` grep hits only `teach`/`breath` and the `brewing` skill), no thief theft/casing commands, no warrior-specific file (all hits are incidental: skeleton-warrior gag, zone names), no assassin-specific file (`flyto.tin` is a generic locator whose data includes Assassins' Guild rooms), no `nightwind` anywhere.

| Guild | tt_dw files (lines) | Features | Covered by phase | Phase 7 priority |
|---|---|---|---|---|
| Witch | `magic/broomstick.tin` (92) | charge model, shake/fuel/takeoff | Phase 4 | Low |
| Witch | `magic/bugshield.tin` (99) | up/warn/gone/down state machine + chip | Phase 4 | Low |
| Witch | `magic/fnp.tin` (85) | cloud color set/track + duration | **New** (Phase 4 pattern) | Medium |
| Witch | `magic/ccc.tin` (88) | skin-covering state + alarm + chip | **New** | Medium |
| Witch | `magic/eff.tin` (88) | floater counter chip (needs combat-def stats) | **New**, waits on Phase 6 | Low until then |
| Witch | `magic/other.tin` (96) | spell-ambient subs (KOF, NES, MVC, DKDD, JPCT, EHA2, OTF, CIPS, CMSEQ, PMG, RTFM, enchant-funnel) | Mostly **new**; ideal pure data module | Medium |
| Wizard | `magic/tpa.tin` (223), `spelldata.tin` (2179), `spellinfo.tin` (788), `spellsizes.tin` (138) | TPA, spell DB/TM, mindspace | Phase 4 | Low |
| Wizard | `magic/obbk.tin` (45), `ftf.tin` (47), `gfr.tin` (27), `klein.tin` (77), `enchant.tin` (37), `delude/eha/pfg` (40) | buff levels, float timer, lighten, klein fill, enchant %, damage-band subs | **New** (klein pairs with Phase 4 stat-items) | Medium |
| Priest | `faith/faith.tin` (73) | Divine Ire + duration, Dark Sight, Rage, Cool/Warm | Phase 4 (partial) | Low |
| Priest | `faith/major.tin` (123) | major/minor shield stacks + log duration approximation | **New** beyond the chip; the formula is the port-worthy part | **High** |
| Priest | `faith/find.tin` (176) | find ritual: movement-word → distance, degrees → compass | **New**; self-contained, big QoL | **High** |
| Priest | `faith/totem.tin` (68), `rods.tin` (28) | totem duration/feed; rod charges 1/7 subs | **New** | Medium |
| Thief | `status/quota.tin` (152), `items/thiefs_daggers.tin` (7) | quota chip; dagger held-state | Phase 3 / Phase 4 | Low |
| Warrior, Assassin | primaries rows only (`char/data.tin:296-308`) | nothing else exists | Data-only for Phase 3 goals | Low |
| All | `char/char.tin:28-47` | GMCP `char_info[guild]`/`[guildspec]` detection + unknown-pair warning | **New**; keys pack autoload in Hex's `on_char_info` | **High** (enabler) |
| Adjacent | `misc/combat.tin` (776), `status/hands.tin` (458+67), `misc/spellingcheck.tin` (77) | spam levels; held inventory; input spellcheck | Phase 6; hands **new** (generic); spellcheck **skip** (blightmud ships Hunspell) | Medium/Low/Skip |

Implication for Phase 7: a guild pack is (a) a slice of the primaries dataset plus (b) 3-8 small text-trigger/chip modules. Assassin and Warrior packs are primaries-only in tt_dw; Hex would be adding net-new features there.

### Live-wire verification before coding

1. Does `options output` list prompt/monitor/map/brief-exits/automatic-rows, in what exact `name = value` shape? (Feeds `/hexcheck` and the `brief exits` idempotency fix.)
2. Does `char.info` carry `guild`/`guildspec` on the wire? (Feeds pack autoload.)


## Official-docs corrections (2026-11-05 research)

- `rows 999` (bare) is undocumented; documented syntax is `options terminal rows=[number]`, and invalid values reset to 24. `/hexsetup` sends the documented form; keep bare `rows 999` only if live verification shows it still sets.
- The `options output` listing shape is space-separated (`look brief`) with no `=` - but the tactics tree shows `attack = left`. `/hexcheck`'s parser stays live-verified.
- `brief exits` and `automatic rows` appear nowhere in the official corpus (live-verify only).
- `term xterm256` is the officially recommended colour setting (newbie essentials); added to the `/hexsetup` option set.
- `options output map plain = on` is officially documented (answers Phase 5's open question).
