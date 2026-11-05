# Phase 5: the room — minimap, MDT, lost rooms, mazes, journeys, blorps

Design doc. Status: designed, not implemented. Ground truth: `room.info` = {identifier, name, visibility, kind}; `room.map` = JSON string with real ANSI escapes and newlines; `room.writtenmap` = plain string (wire-confirmed 2026-11-05). `room.info` carries **no exits** — movement translation and guessing need the look line's `[exits: …]` as a text trigger (tt_dw does the same, `map/basic.tin:6-15`), with `brief exits` guaranteed by `/hexsetup`. Maze map ids: `UULibrary` ×1246 rooms (each with `{{shape}{N}}`), `AMPepperPot` ×25, `StoLatLibrary` ×24, `BPMedina` ×19, `AMShades` ×16, `SkundHedgeMaze` ×6, `MagicCircle` ×1; RatFarm/LSpace/AbandonedMine/SandelfonMaze are not in the map at all (tt_dw builds throwaway temp maps, `map/instance.tin:5-28`). Key blightmud fact: `mud.send` sets `bypass_script` (`src/lua/mud.rs:84`) and the input pipeline skips such lines (`lua_script.rs:379`) — anything Hex sends programmatically never passes through the direction-translation listener.

## 1. hex_minimap — the ASCII minimap panel

**Storage** (module state): raw payload, decoded text (mode-dependent), lines, ANSI-stripped copy, has_player (contains `@`), has_people (contains `+`), room_id (dedupe key), seq.

**ANSI mode** — option `hex.map_ansi` ∈ {ansi, strip}, default ansi; `hex_util.strip_ansi` (Phase 1.x) used for width math always. No "plain" client mode: tt_dw's setup *disables* the MUD's inline look-map entirely (`options set output map all "off"`, `util/setup_check.tin:66,75`) and Hex renders its own.

**Render targets — decision matrix** (facts from `resources/help/tabs.md`, `top_area.md`, and `src/lua/blight.rs`: create_tab :448-477, output_to :558-569, top_line :259-264, set_top_row :265-275, add/remove_top_row :283-296; no tab-clear API exists):

| Target | Verdict |
|---|---|
| **Top rows** (add once, `set_top_row(name, {body})` per line) | **Primary** for the 3-5 line minimap; always on screen |
| **Dev tab** ("map" pane: minimap + MDT + room detail, `history_lines` bounded) | **Secondary**; snapshots append (no clear API) |
| **Inline print** | **Fallback** (stock v5.7.1); the existing `/dwmap`, on-demand only |

Not the status area (5-row cap, 3 already used). Not inline-per-room (scrollback spam). **Feature-detect ladder**: `blight.add_top_row → "toprows"`, else `blight.create_tab → "tab"`, else `"inline"`; option override `hex.map_panel`.

Refresh semantics: on `on_map`, deduped by (payload, room_id) — the MUD pushes on look *and* enter, so re-looking the same room must not re-render. Stale marking when the identifier changes without a map push (edge-case guard; they arrive in one burst per move). Empty/whitespace payloads hide the panel (`[no map — you can't see anything here]` in the tab); maps without `@` render with a `(no @ — vision?)` hint. Open question: whether `set_top_row` bodies render embedded SGR — verify live; if stripped, toprows falls back to strip mode and the tab keeps color.

## 2. hex_mdt — written-map people tracker

**Hex needs neither of tt_dw's two screen-scraping capture paths** (`mdt.tin:11-58`): GMCP `room.writtenmap` delivers the same content per room push, already decoded. The manual `map text` alias stays only as a refresh trigger. This deletes the most fragile third of tt_dw's mdt.tin.

**Parser** (pure, port of `@parse_mdt`, `mdt.tin:593-674`):
1. Normalizations: `"{X}, driver of the {Y} carriage"` → `"{Y} carriage driver"` (plus dwarfish/trollish/human variants); colour-pair entities `a black and white cat` → `a black-white cat` (16 mdt colors, `mdt_adverbs.tin:1-2`); `the net dead statue of` → `netdead`; `the limit of your vision is` → `…vision:` terminator; ` {and|are|is} ` → `", "` (prose → comma list).
2. Split on `", "`; per segment: door/exit segments set an ignore flag; the terminator closes the room group and resets direction state; leading count word (one…twelve) stripped; first remaining word through the direction table either appends to the room group's direction string or becomes an entity.

**Scoring** (`@mdt_match`, `:677-720`): hunting targets first (score 100, alert 1; `/hunt <target>` = `/mdt add` with category hunting — merges tt_dw's separate mdt_hunt.tin); user match table with category/color/score/alert, first case-insensitive hit wins; skips (bat, followers, fnp cloud) as config data. Room score = Σ count × match score.

**Cleanup** (`@mdt_clean`, `:723-777`): ordered shorthand table (pet collapse, horse colors → horse, city guards → guard, delivery man, whirlwind → dust devil, carriage drivers, `(hiding)` strip, colour clouds); named-entity colouring with the witch-title exclusion list (`:513-516`).

**Arrows and sort** (`:780-794`, `:538-589`): direction strings expand to arrows (Unicode arrows via a dir table), distance = Σ counts, sort score desc then distance asc.

**Display**: list format one line per nearby room (`↑↑  [ 2] two city guards`); surfaces: the `map` dev tab under the minimap, `/mdt` always (stock-build primary), and alert lines for hunting matches printed immediately, deduped, seen-list expiring after 10 minutes. Cadence: recompute per accepted writtenmap push (microsecond-scale string work).

`/mdt` subcommands ported: add/remove/list/category/categories with the `_default` + per-alt category scoping (`:120-136, 285-328`).

## 3. hex_guess — lost-room matching

**"Lost" is strictly maze-scoped**: ordinary rooms always push a resolvable 40-hex id. Lost = symbolic id (`UULibrary`, `AMShades`, `StoLatLibrary`) or empty identifier (live-verify whether the MUD ever omits it). Detection ports `/check_lost` (`basic.tin:19-65`): UU entry/mode transitions; Shades also detected by exits matching `^1,2,3,4`; AoA by exit-set mismatch after aisle translation; a fresh 40-hex id clears the guess state.

`room_shape(exits)` ports exactly (`guess.tin:72-110`): `x` signature (s + fw/lt + bw/rt), `g` for gap, fw→n / bw→s / rt→e / lt→w normalization, 2 exits → `-` or `L`, counts 1-4, else `?`.

Inputs vs tt_dw: observed exits from the same look-line trigger; candidate universe from `SELECT vnum, name, data FROM rooms WHERE room_id = 'UULibrary'`; shapes parsed from `rooms.data` via a new pure `hex_util.parse_tin_list()`; exit sets from rooms.db; **no coordinates** (the map has none) — distance hints use the Phase 2 graph instead; last move recorded by the movement-mode input listener; absolute fixes from the lectern-book table (`LIBRARY_BOOKS`, `library.tin:376-441`, 16 entries) pinning position on `^A{n?} {desc} is chained to the ornate lectern.$`; south-end filter ported.

**Algorithm** (`guess.tin:129-289`): candidates = {vnum, facing}; if moved since last guess, shrink by stepping each candidate through the translated move; else seed all shape-matching rooms × four facings. Filter: skip book rooms, apply the south-end list, rotate candidate exits through the facing and compare as **multiset** (`:114-126`). Best = previously believed, else closest by graph distance (one Dijkstra per guess cycle). Resolution: exactly one candidate → confident, pin the facing by trying all four.

Output is advisory — Hex **never writes** the map: warning line on lost entry (`/lost` prints candidates with vnum, name, facing arrow, path length to the library exit, capped at 12).

## 4. hex_maze — movement modes

**Mechanism: input-listener rewrite.** `mud.add_input_listener` handlers receive the Line and return it; `line:replace(s)` changes what continues to the send path. Why this is not an autonomous send (the argument for the code comment and spec): (1) the listener executes only inside blightmud's user-input pipeline — no timer/trigger/walker path invokes it; (2) it never calls `mud.send` — it transforms the line the user themselves submitted (same class as tt_dw's `#PATHDIR` aliases, `movement.tin:178-226`); (3) plugin sends set `bypass_script` and never re-enter the listener, so `/goto` walker steps are not re-translated and the transform cannot loop; (4) the grep invariant still holds. The maze translator is a second input listener appended after the password skip-log one.

Modes and entry/exit, driven purely by `room.info.identifier` (no sends): `UULibrary` → uu (facing starts n); `LSpace` → lspace (fw/lt/rt/bw + gap; never in rooms.db, "L-Space is weird" notice); `StoLatLibrary` → aoa (aisle translation); `AMShades` → shades (guess-only; pathfinding unavailable); `SkundHedgeMaze` → hedge (name+id pairing); name `inside the magic circle` → circle; any 40-hex id clears (except the LSpace→library boundary, `instance.tin:58-68`).

**UU/LSpace translation**: facing tables ported from `dir_right/dir_left/dir_back` (`library.tin:330-356`); typed `n|e|s|w|north|...` → `exit_library(typed, facing)`; facing updates to the typed compass direction (`:160-163`); raw words pass through untouched but update facing. **Distortion guard**: tt_dw blocks the move and tells you to type fw deliberately (`library.tin:150-154`); Hex attempts `line:matched(true)` to cancel (live-verify that matched input lines are actually not sent) with the fallback of rewriting to `glance` — never an empty line. Exits display rotates through the facing so the user sees relative words, `s` always absolute (`:276-277`, south is the way out). Status hint `[Library: facing n]`.

**AoA**: typed compass direction → current room's exits → matching `aisle N` command rewrite (aisle→compass via `exits.dir` ordering, `library.tin:241-267`); no match → pass through.

**Magic circles**: trigger on finish/enter, remember the outside room id, suppress lost-warnings and walker verification complaints while circling; `The magic circle fades.` clears.

**Hedge maze and name+id disambiguation**: (room_id, name) is the composite key where room_id is symbolic; `hex_rooms.update` resolves `room.vnum = SELECT vnum FROM rooms WHERE room_id = ? AND name = ?`; `Introduction:*` (Pumpkin Town) treated as identified, no vnum.

**Gates**: `/goto` gains `hex.avoid_gates` (default off): Dijkstra treats edges whose (from_vnum, command) pair is in `gates` as blocked; `/path` annotates gate crossings (gates lock at night).

## 5. hex_journeys

Journey edges are already single graph edges in rooms.db (Phase 2 routes through them). Added semantics: `/path`/`/goto` render `journey n` as `journey: 2 miles north` (the edge distance is the mile count); arrival trigger `^You arrive after having journeyed .*` with the move-list parse (`journey.tin:78-85`) feeds the walker a **journey-aware branch** — intermediate room.info pushes don't exist for a multi-room command, so the walker accepts the identifier jump after this line instead of aborting; travel-mode chip from the `Set option personal travel` trigger, stored in hex.db meta. Water/swim: `room.info.kind` `underwater` → water on (text fallbacks ported from `water.tin:66-71`); `/goto` excludes `swim %` edges unless `hex.allow_swim` or already in water; `~` marker on swim steps.

## 6. hex_blorps + bookmarks

**Storage: real SQLite tables in `~/.local/share/hex/hex.db`** (not JSON blobs): user data must survive `convert_map.py` rebuilds (rooms.db is delete-and-recreated); rows are naturally relational; writes go through `core.exec({"sqlite3", db, sql})` in alias handlers only. Schema (tt_dw-faithful): `blorp(character, label, vnum, room_id, PK(character,label))` (`blorps.tin:398-403`); `bookmark(character, vnum, label, comment, room_id, PK(character,vnum))` (`bookmarks.tin:442-451`); `mdt_match`, `mdt_category` (`_default` = all alts), `hunt`, `meta(alt, key, value)`. Config key `hex.db`.

Blorps: tt_dw models blorps as exits from a hub room (BLORP_VNUM 57559) and computes steps as hub-path minus 1 plus `blorp_cost`; Hex drops the hub *semantics* and keeps the user-visible ones (deviation noted in the module header): steps = Phase 2 distance; `blorp_cost` reserved. Commands: `/blorp add|delete|rename|list|all|goto` (instance-id refusal ported, `blorps.tin:90-93`; `@area` filter; distance-sorted via one multi-target Dijkstra). Bookmarks: per-character rows with shared visibility (`[alt]` attribution, `bookmarks.tin:384-389`); add/comment/rename/delete/find/goto; label:comment split on ` -- | : | ; | #`; inside a library `/bookmark goto` refuses to walk and shows the path only (`:192-210`).

## 7. Test plan

room.map fixtures (the real live payload; empty; whitespace; two-line; no-@; people-only) through `update()` asserting state fields, dedupe, and empty handling. Writtenmap fixtures: the live sample (`A door north of here and the limit of your vision is here.` → one group, zero entities) and a multi-room sample exercising the grammar (counts, colour-pair merge, carriage-driver rewrite, vision-limit terminator). Scoring/cleanup first-hit-wins and every shorthand row. Shape table exhaustive over the 16 direction subsets plus x/g/?. Facing math 4×8. Input-rewrite table (mode × typed × facing), with a structural grep test that `hex_maze.lua` holds no send reference. Multiset exit matching. Guess-shrink simulation on a synthetic 20-room UULibrary subgraph (monotone shrink to 1; book-room override). Journey parse. SQLite builders asserted like the existing query tests. Fake-GMCP seeding of room fixtures (first slice of Phase 8's harness). Python side: `rooms.data` shape extraction for all 1246 UULibrary rows; gates row-count.

## 8. Live-verification list

1. **Maze room.info behavior** (highest priority): exact identifier strings/casing in UULibrary/Shades/AoA/hedge, pushed name/kind/visibility, whether room.map/writtenmap push inside mazes at all, and whether empty identifiers ever occur outside mazes.
2. Plain-map MUD option: tt_dw never uses one (it kills the inline map); verify via `options options` whether a plain setting exists — regardless, `/hexsetup` sends the tt_dw option set.
3. Top-row ANSI rendering of SGR bodies.
4. Tab `history_lines` trim behavior (oldest-first? active-tab reset?).
5. Input cancellation: does `line:matched(true)` suppress the send? (fallback: rewrite to `glance`).
6. `room.info.kind` vocabulary beyond inside/underwater (road/water).
7. Journey arrival wording variants and mile-word range.
8. Walker × listener interplay in a library (verify `/goto` steps bypass the maze listener once, live).
9. Screen budget: indicator + 5 map rows + 3 status rows on a 24-row terminal — measure; consider `hex.map_panel = tab` default for short terminals.

## 9. Build order (each step independently shippable)

1. `hex_util` helpers + minimap with the inline/toprows/tab ladder; 2. `hex_mdt` parser + `/mdt` with hex.db; 3. blorps/bookmarks; 4. journeys (display + walker branch + water); 5. maze modes + input listener; 6. guess (depends on 5's move recording); 7. live-verification pass, docs, patchnotes.
