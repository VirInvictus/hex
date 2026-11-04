# Hex roadmap

## Phase 0: skeleton

- [x] House layout (README, spec, roadmap, patchnotes, AGENTS, LICENSE, logo, VERSION)
- [x] Repo on `main` (blightmud's plugin updater requires master/main)

## Phase 1: core + Quow (M1)

- [x] `hex_util`: ANSI helpers, SQL escape, glob-to-LIKE, row parsing
- [x] `hex_gmcp`: on_ready registration (dual casing), vitals/info/room handlers, JSON decode, `/hexprobe`
- [x] `hex_vitals`: vitals model, XP-rate model
- [x] `hex_status`: 3-row status area renderer (bars, XP, room, burden)
- [x] `hex_rooms`: current-room tracking, `/where`, rooms.db lookups
- [x] `hex_queries`: ported Quow query builders (`/item`, `/items`, `/npc`, `/shop`)
- [x] `hex_commands`: aliases and result rendering
- [x] `hex_gags`: gags v1 as data
- [x] `hex_config`: namespaced persistence, `/hexset`
- [x] `tools/convert_map.py`: tt_dw map -> Hex rooms.db (stdlib Python only)
- [x] `tests/run.lua` unit suite green; `tests/test_convert_map.py` green
- [ ] Live GMCP probe against Discworld (verify wire casing at the login prompt)
- [ ] v0.1.0 release: patchnotes entry, tag

## Phase 2: pathfinding (M2)

- [ ] Dijkstra over the identified-room subgraph in rooms.db
- [ ] `/path <target>`: room-name or identifier search plus route display
- [ ] `/goto <target>`: user-invoked speedwalk walker (the only autonomous sender allowed: it runs because the user asked; steps are user-cancellable)
- [ ] Quow results gain nearest-source sorting via path length

## Phase 3: quality of life (M3)

- [ ] Mission/job cooldown timers with per-alt persistence
- [ ] TPA/bugshield/ritual status chips (text-trigger ports)
- [ ] Chat capture into a dev-tab (feature-detected)
- [ ] Sound event triggers via blightmud audio
- [ ] Spellcheck/TM suggestion data
