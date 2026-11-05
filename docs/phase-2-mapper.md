# Phase 2: "find your way" — the graph pathfinding mapper

Design doc. Status: designed, not implemented. Every number in §0 was measured on this machine (lua 5.4.8, the real `rooms.db`) during the exploration; re-verify with the benchmark harness (§6.6) before trusting them for release claims.

## 0. Measured facts the design rests on

Data (`~/.local/share/hex/rooms.db` from `tools/convert_map.py`):

- 62,130 rooms; 32,499 identified; 156,800 exit rows.
- **Every exit `distance` is 1.0 and every room `weight` is 1.0** — the weight model is unit-per-step until the map ever says otherwise.
- Exit `flag` bits (ground truth from tintin's `tintin.h`, confirmed in the data): `HIDE=1` (864 exits), `AVOID=2` (84), `HIDE|AVOID=3` (22), `INVIS=4` (2), `BLOCK=8` (0 present). tt_dw treats `flags & 2` as unsafe (`map/movement.tin:150-158`).
- Room `flags`: `AVOID=1`; `513` = AVOID_TMP (3,069 rooms — exactly the water/underwater rooms, set by `water.tin:45` and `mapper.tin:112`); `4104` = VOID_TMP (128 rooms).
- Exit `dir` is the PATHDIR bitmask: n=1 e=2 s=4 w=8 u=16 d=32, diagonals summed (`movement.tin:161-172`). 1,798 exits have `dir=0`: the special exits ("enter crate", "embark", "out", "leave", "enter stall", ...).
- Non-cardinal commands in the identified subgraph: 1,110 `journey <dir>`, 167 `swim <dir>`, plus climb variants, `out`, `leave`, one-off names. All are sent verbatim by the walker.
- **171 identifiers map to more than one vnum** (mostly parallel Terrains road tiles): identifier-keyed verification must tolerate this (§4.4).
- 1,341 rooms carry non-40-hex shared-instance ids across 12 distinct ids: UULibrary 1,246, AMPepperPot 25, StoLatLibrary 24, BPMedina 19, AMShades 16, SkundHedgeMaze 6, MagicCircle 1, Introduction:* x3, tt_dw_blorp x1 (re-measured 2026-11-05 after the converter gained the `extra` column); RatFarm/LSpace/AbandonedMine/SandelfonMaze never appear in the file (`map/instance.tin:37-83`).
- Identified-only subgraph: 31,562 nodes, 82,307 directed edges, **1.7% one-way** (1,393 pairs with no reverse edge). 1,152 undirected components; the giant one holds 27,836 nodes (88%). AM 4,149/4,200 in-giant; **Genua is directed-unreachable from AM**: the Bois has zero inbound edges (the only Bois→Genua links are `enter crate` 5783→55987 and `embark`).
- tt_dw's `links.tin` is wiki URLs, not graph edges — correctly not parsed. `gates.tin` is `{vnum}{exit}` city gates (in rooms.db); tt_dw toggles AVOID on gate exits (`util.tin:668-681`). `origins.tin` is `{area}{origin room name}` (`describe.tin:87-88`), in rooms.db.

Performance (stock lua 5.4.8, full runs):

- Identified-only adjacency built from one grouped SQL dump: **parse+build 87 ms, Dijkstra 26-40 ms cold / ~26 ms warm, ~12.5 MB Lua heap.** Full 62k graph: ~195 ms build, 36 ms Dijkstra, ~10.6 MB.
- The sqlite3 subprocess (the only thing `core.exec` waits on) is single-digit ms. The ~130 ms one-time build cost lives in Lua, inside a user-invoked alias, once per session.
- Reference routes: AM Job Market (3424) → BP Imperial Palace Gates (5898) = 118 steps; Mended Drum bar (4659) → 5898 = 123 steps.
- blightmud creates the plugin state with `Lua::unsafe_new()` (`src/lua/lua_script.rs:149`): full stdlib including io/os, so a file-based precomputed artifact remains possible (§1 fallback).

## 1. Graph storage decision

**SQLite-per-query for everything except shortest path; the shortest-path graph lives in Lua, built lazily on first routing command from ONE grouped `core.exec` query, cached in module state for the session.** No precomputed artifact in v1.

- SQL cannot express weighted shortest path sanely at this size; but target resolution, identifier→vnum, and gate joins are indexed single queries and stay in SQL.
- Up-front graph load would add ~90-150 ms to every `/hexreload` and login; lazy build pays ~90 ms once, inside a command the user invoked. The spec's millisecond rule constrains line-triggered work, not user commands.
- Per-area caches rejected for v1: partial graphs produce false "no route" answers, the worst mapper failure mode. 87 ms beats any cache-invalidation logic.
- The Python-precomputed flat file (CSR + `string.pack`, ~20-40 ms load) is the designated **fallback** if the 90 ms build hitching shows up in the field; design `hex_paths.load` so the source is swappable.
- What loads: the *routable* subgraph — 40-hex-identified rooms only, minus shared-instance ids, minus AVOID rooms. One statement; both filters live in SQL:

```sql
SELECT e.from_vnum || ' ' || group_concat(e.dest || ' ' || e.flag, ' ')
FROM exits e
JOIN rooms a ON a.vnum = e.from_vnum
JOIN rooms b ON b.vnum = e.dest
WHERE a.room_id GLOB '[0-9a-f]*' AND a.room_id NOT GLOB '*[^0-9a-f]*'
  AND b.room_id GLOB '[0-9a-f]*' AND b.room_id NOT GLOB '*[^0-9a-f]*'
  AND (a.flags & 1) = 0 AND (a.flags & 512) = 0
GROUP BY e.from_vnum;
```

## 2. `hex_paths` — the pure graph module

```lua
-- graph = { idx={[vnum]=dense}, vnum={...}, adj={...}, flag={...}, cmd={...}, ids={...} }
M.load(rows) -> graph
M.find_route(graph, start_vnums, target_vnum, opts) -> route | nil, reason
  -- opts = { allow_avoid=false, max_steps=nil }
  -- route = { steps, from, to, path={{from,to,command,dir,eflag,room_id},...} }
M.distances(graph, start_vnum, target_set) -> dist_table   -- one Dijkstra, multi-target
M.render(route, name_of, area_of, width) -> { line, ... }  -- street-by-street display
```

- **Dijkstra, not A\***: the tintin map stores no coordinates, so no heuristic exists. Bidirectional Dijkstra would halve 26-40 ms; not worth it in v1. Tie-break on dense index for stable golden routes.
- Weight: `math.max(exit_distance, 1)` in code, so the `distance` column goes live the day the map uses it. Do not invent heavier water/road weights — tt_dw models those as avoid flags.
- One-way exits are just directed edges (1.7%); the walker never assumes a way back. Route steps carry `command` verbatim (`enter sea`, `swim n`, `journey w`); `dir=0` steps render by command text.

## 3. Target resolution — `/path`, `/near`

Resolver tried in order (ported from `find.tin:27-61`):

1. 40-hex or instance identifier direct lookup (`is_room_id` port, `identifiers.tin:37-47`).
2. `#<n>` session reference into the last search's candidate list (Hex's replacement for tt_dw's `map[targets]`).
3. Quow room_id — the same identifier space, so case 1 covers it transparently.
4. `@<area>` — origin room from `origins(area, room_name)` by name.
5. Name search — `LIKE` with house glob rules, `@area`-qualified, `^`/`$` anchors, identified rooms only by default (29,631 unidentified rooms would flood results).
6. Bare vnum — offered only if routable.

0 hits → gray "no rooms match"; 1 hit → route; 2+ hits → numbered candidate list with step counts (`#1 name (area) — N steps`) and `/path #2` routes. `/path` never guesses past ambiguity (tt_dw's `/guess_room` stays Phase 5).

`/near <search>`: one Dijkstra with early exit, top 5 by step count. Requires a verified current room.

Route display groups consecutive same-command steps: `[3 north]`, `[1 northeast, 2 east]`, `[enter crate]`; `--full` prints every room name.

## 4. The `/goto` walker — the one sanctioned multi-step sender

### 4.1 State machine (pure transitions; sends isolated as effects)

States `idle | walking | stalled`. `M.transition(state, event, now) -> state, effects` where effects are explicit (`{send=cmd} | {announce=...} | {chip=...}`); the blightmud-bound wrapper in main.lua is the only thing that calls `mud.send`.

- `start(route)` (from the `/goto` alias only): step 1's send is an effect of the alias call itself. Every subsequent send is an effect of a `room_verified` event.
- `room_info(identifier, name)`: match `route[i].room_id` → verified: arrival if last step, else advance and send the next command. Mismatch → **abort to idle**, red expected-vs-found line, never re-route blind (tt_dw re-syncs with `look`, `paths.tin:31-33`; it never silently re-plans either).
- `stall_check(now)` (UI-only timer): no room.info for >10 s → `stalled` chip ("walk stalled at step i/N — move manually or /stopwalk"). **The timer sends nothing, ever.**
- `stop` (`/stopwalk`): idle, gray "walk stopped after N steps". A user-typed bare `stop` (input listener, port of `paths.tin:5-8`) pauses on next verified room; `/goto resume` re-runs find_route from the verified identifier — a fresh user invocation.
- `queue_cleared` (trigger on MUD's `Removed queue.`, `events.tin:15-20`): informational in v1; Hex always has ≤1 command in flight, so a cleared queue means interference → verify-on-next-room_info, no resend.

Anti-idle compliance argument (ships in the spec): (1) entered only by an explicit user alias; (2) sends only while verifiably moving — every send follows the MUD's own room.info push; (3) stops permanently on anomaly, never retries; (4) no timer sends, stalls are UI-only; (5) one command in flight, never out-running the player. Strictly more conservative than tt_dw's accepted whole-path queue (`paths.tin:276-278`).

### 4.2 Verification vs duplicate identifiers

For consecutive route rooms sharing a room_id (Terrains tiles): verification additionally requires name equality; if two vnums share both, abort as "ambiguous terrain segment". Can only ever abort, never mis-send.

### 4.3 Travel mode (journey safety)

Port tt_dw faithfully: `/goto` prepends `options personal travel = walk` (first send) and restores `journey` at the end only if Hex observed a non-walk default via the `^Set option personal travel to (\w+)\.` trigger (`journey.tin:3-8`; restore parity at `paths.tin:236, 266-268`).

### 4.4 Walk gags (session triggers, reaped on walk end)

`^Queued command: ` + this route's exact commands (generic cardinal form ported from `paths.tin:205`), the `options personal travel` echo lines. No `frimble` end-marker machinery: Hex knows the end from the identifier match.

## 5. Lost-room and unverified-room policy (v1: strictly identified-only)

- Never routes through unidentified rooms (29,631 of them); guessing (`guess.tin`) is a mapper-tracking feature, Phase 5.
- Never routes through AVOID rooms, BLOCK exits, or shared-instance ids (a shared id cannot verify position).
- `/path any <search>` includes avoid-flagged rooms/water (`opts.allow_avoid`).
- T-shop refusal: `/path`/`/goto` to `04fd563a7f8d4ccfc83661bbec60971ac9aa72ca` says the travelling shop moves (port of `find.tin:371-374`).
- Unreachable targets (Genua today): "no route found — <area> is not connected in the map graph".

## 6. Module layout and tests

New files: `src/hex_paths.lua` (pure: load/find_route/distances/render, binary-heap Dijkstra), `src/hex_targets.lua` (pure: search grammar + SQL builders), `src/hex_walk.lua` (pure: transition/chip), wiring in `hex_commands`/`main.lua`; `convert_map.py` gains `idx_rooms_area` + `idx_rooms_area_name`.

Tests:
1. Golden routes against the real rooms.db (opt-in `HEX_GOLDEN=1`): 3424→5898 = 118; 4659→5898 = 123; 4659→12472 = 129; negative: 4659→11279 (Genua) unreachable; maze-id refusal.
2. Synthetic property tests: Dijkstra == BFS on unit graphs; one-way edges never reversed; tie determinism; multi-target consistency.
3. Walker state machine: table-driven sequences (happy path, mismatch abort with no post-mismatch sends, stall, pause, duplicate-id ambiguity, travel-mode effects).
4. Resolver: anchors, globs, @area, #n, 40-hex, T-shop refusal.
5. Benchmark harness `tests/bench_paths.lua` keeping §0 honest.

## 7. Open questions (wire verification)

1. `room.info` on unidentified rooms: empty string, absent key, or something else? (Mismatch branch assumes treat-as-mismatch → abort.)
2. Failed movement: no room.info → stalled (presumed). If the MUD re-pushes the same room, add an idempotence rule.
3. Exact `Queued command:` vocabulary for non-cardinal commands during walks.
4. Does `look` re-push room.info without movement? (Assume yes; tt_dw relies on it.)
5. Bois/Genua gap: Hex import bug or upstream truth? Check tt_dw's own pathing live.
6. Personal travel default in the wild (drives whether §4.3's prepend/restore is noise).
7. Journey steps: one command moves multiple rooms; route must model `journey w` as arriving directly at the destination (the data already links them as single edges — verify the pushed identifier after a journey).
8. mlua GC behavior with the ~12.5 MB heap on long sessions (field test).
