# Phase 2: "find your way" — the graph pathfinding mapper

Design doc. Status: §1-3 and §5-6 implemented 2026-11-05 (Phase 2 core: `hex_targets`, `hex_paths`, `/path`, `/near`, synthetic property tests, opt-in goldens, bench); §4's walker is the next batch. Every number in §0 was measured on this machine; **2026-11-05 correction: the implementation's loader (this doc's §1 SQL verbatim) measured the graph smaller than the exploration's numbers, and two BP/Genua golden claims from the campaign proved wrong — see the correction block at the end of §0.**

## 0. Measured facts the design rests on

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

### Correction block (2026-11-05, first implementation)

The loader above, run verbatim against today's `rooms.db`, measures: **31,157 nodes, 78,979 directed edges** (the campaign's 31,562/82,307 came from a leakier exploration loader; `sqlite3` count of both-endpoints-identified edges equals 78,979 exactly, so the shipped graph loses nothing the filter admits). sqlite3 dump fetch 4-5 ms; Lua parse+build ~280-305 ms (above the campaign's 87 ms; the bucket parser trades speed for simplicity, still a one-time cost inside the first routing command); Dijkstra ~21 ms warm; heap after `collectgarbage("collect")` 21.7 MB (above the campaign's 12.5 MB: names and areas are embedded in the graph so render needs no second query).

**The campaign's BP goldens were wrong.** AM→Bes Pelargic (5898) is NOT 118 steps on the identified subgraph: BP's water component is 65 rooms and its westward continuation crosses an unidentified sea room, so BP is unreachable from AM with and without `allow_avoid` (the AM-side ocean chain itself IS reachable: 3424 → the Circle Sea room, 178 steps). Genua was already known directed-unreachable. tt_dw never hits this because its mapper routes unidentified rooms by vnum; Hex's v1 identified-only policy (§5) is deliberately stricter and pays BP and Genua until Phase 5's journey/ferry tables model the boats. The goldens in §6 test the disconnection as a documented negative.

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

## 4. The `/goto` walker — one-shot batch queue (officially sanctioned "fast" style)

**Correction (2026-11-05, docs/discworld-docs-research.md §1):** the original design sent each step after the previous room.info arrived, arguing that per-step verification made it "more conservative". The MUD's own `concepts/automation` page rules the opposite way: room-by-room sending is the banned "slow" speedwalk; the allowed "fast" kind sends *"all route commands ... in one go and cannot be altered afterwards (other than by manually sending 'stop')"*, with the MUD aborting queues that run past 5 minutes. The design below is the compliant shape.

### 4.1 Mechanism

`/goto <target>` resolves the route, prints the step list, then — as one user invocation —

1. sends `options personal travel = walk` (journey-safety, port of tt_dw; restore `journey` at the end if a non-walk default was observed via the `Set option personal travel` trigger),
2. sends **every route command in one burst**, one `mud.send` per command, no waiting between them,
3. sends the journey-restore line (if applicable).

Everything after that is the MUD's own queue executing the route. Hex sends nothing more. Abort paths: the user typing `stop` in-game (the officially named abort), or `/stopwalk`, which sends `stop` from the alias handler (sanctioned user-alias send). The MUD itself clears overlong queues ("if such a speedwalk takes more than 5 minutes, the MUD will eventually abort it due to inactivity" — routes estimated over ~4 minutes get a warning at invocation).

### 4.2 Verification becomes post-hoc drift reporting

The room.info pushes arriving during the walk are compared against the planned sequence purely for *display*: on match, the status chip advances (`» 23/119 to the Palace Gates`); on mismatch, a red line reports expected-vs-actual and the chip marks drift — **Hex never re-sends and never re-routes**. There is no stall state and no stall timer: with one burst in flight there is no per-step expectation to stall on. The `Removed queue.` line (MUD clearing an interfered queue) is reported informationally.

### 4.3 Compliance argument (replaces the old one)

This is the documented "fast" kind, verbatim in design: all route commands are sent in one go, immediately, on one user invocation; the queue cannot be altered afterwards other than by the user manually sending `stop`; Hex adds nothing to the wire after the burst except nothing at all. No timer, no trigger, no continuation ever sends. If the player disappears mid-walk, the queue runs out or the MUD aborts it at 5 minutes — exactly the behaviour the rules text describes as allowed. The travel-mode prepend/restore and the `stop` send are part of the single user-invoked operation (port of tt_dw `paths.tin:276-278`, which the rules text describes as the permitted style).

### 4.4 Walk gags

`Removed queue.` gags stay informational; the queued-command echo gags port unchanged (the burst will echo each command as the MUD queue drains them — port the generic cardinal form plus this route's exact commands from `speedwalk.tin:3-17` and `paths.tin:205`).

## 5. Lost-room and unverified-room policy (v1: strictly identified-only)

- Never routes through unidentified rooms (29,631 of them); guessing (`guess.tin`) is a mapper-tracking feature, Phase 5.
- Never routes through AVOID rooms, BLOCK exits, or shared-instance ids (a shared id cannot verify position).
- `/path any <search>` includes avoid-flagged rooms/water (`opts.allow_avoid`).
- T-shop refusal: `/path`/`/goto` to `04fd563a7f8d4ccfc83661bbec60971ac9aa72ca` says the travelling shop moves (port of `find.tin:371-374`).
- Unreachable targets (Genua today): "no route found — <area> is not connected in the map graph".

## 6. Module layout and tests

New files: `src/hex_paths.lua` (pure: load/find_route/distances/render, binary-heap Dijkstra), `src/hex_targets.lua` (pure: search grammar + SQL builders), `src/hex_walk.lua` (pure: transition/chip), wiring in `hex_commands`/`main.lua`; `convert_map.py` gains `idx_rooms_area` + `idx_rooms_area_name`.

Tests:
1. Golden routes against the real rooms.db (opt-in `HEX_GOLDEN=1`): 4659→12472 = 129; negatives: 3424/4659→5898 (BP) unreachable, sea-chain gap (see §0's correction block); 4659→11279 (Genua) unreachable; maze-id refusal. Measured 2026-11-05, superseding the campaign's 118/123 claims.
2. Synthetic property tests: Dijkstra == BFS on unit graphs; one-way edges never reversed; tie determinism; multi-target consistency; avoid reroute/refuse; blocked-start escape; distance weights.
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
