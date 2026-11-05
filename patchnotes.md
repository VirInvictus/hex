# Hex patchnotes

## v0.8.0 (2026-11-05)

Phase 7's comfort core: theme, a real options engine, and sound — all defaults-preserving, all notify-driven (sound triggers are explicitly legal per concepts/automation).

- `/hexoptions`: a validated options engine over the new layered store (session > alt > global > default, tt_dw's load order). Bool/enum/number/path validation with proper errors, aliases (`speech` = tts), `brief`, `defaults`, `clear <key>`, and alt/session layer overrides. Selection is by key name, never numbers (typing "3" into a MUD client sends it). `/hexset` remains the raw unvalidated escape hatch. Schema keys: sound, sound_dir, sound_volume, tts, theme, chat_tab, map_ansi, map_panel, allow_swim, avoid_gates, mission_travel_time (missions now reads it), quow_stale_days, guild, plus hidden db paths.
- Theme: `hex_theme` re-skins the whole suite from one place — classic (byte-identical to today's ANSI, golden-tested) and dragon (Kanagawa 24-bit) — `/hexoptions theme dragon` flips it live. Mechanism: use() mutates the shared hex_util.ansi table in place, the single table every module already reads, so re-skinning needs zero call-site migration (the design's delete-and-migrate simplified away).
- Sound: `hex_sound_events` maps notify-bus events to the CC0 mp3 stems (`/hexupdate` already copied them) — connect/disconnect, tells, mission-ready, damage. Defaults OFF (a terminal client is frequently SSH'd or at work); `/hexoptions sound on` runs a preflight (Hex's own copy of the set is detected first, tt_dw fallback). Damage words are verbatim tt_dw thresholds (-200/-400/-500) and debounced 2s so fight bursts don't stack.
- TTS: `/hexsay <text>` speaks whenever a TTS-enabled blightmud build is available; option-gated event speech shares the sound event table. Every tts call except is_available() is availability-gated (ungated calls spam errors on non-TTS builds).
- Tests grow to 140 (145 with the opt-in goldens): classic palette byte-golden, 24-bit shape, role paint/unknown-role, schema well-formedness, alias canonicalization, validation errors with choices/ranges, damage-word thresholds, template rendering.

## v0.7.0 (2026-11-05)

Phase 5's exploration core: the pieces that make leaving pumpkin village navigable.

- Blorps and bookmarks in Hex's OWN SQLite database (`~/.local/share/hex/hex.db`, real tables that survive rooms.db rebuilds). `/blorp add <label>` names the room you stand in; `/blorp list` sorts by walking distance (one multi-target Dijkstra); `/blorp goto <label>` shows the route; `/blorp all` spans alts. `/bookmark add <label>: comment` shares bookmarks across alts with attribution, plus comment/rename/delete/find/goto. Writes happen only inside these user aliases; tt_dw's hub-room blorp semantics are deliberately dropped (deviation noted in the module header).
- The minimap render ladder: on every room.map push (deduped per payload + room, since the MUD pushes on look AND enter), Hex renders to top rows when the client has them (dev trees), else to a dedicated `map` tab (stock 5.7.1's tabs are proven live by the chat tab), else nothing automatic (mirror mode; `/dwmap` stays the on-demand view). Empty payloads print a can't-see note; maps without the `@` player marker carry a limited-vision hint; `hex.map_panel` overrides the ladder. The tab path renders stripped (output_to drops MUD colors by design).
- Journey and water navigation: journey steps render as `[journey: N miles e]` (the map's edge distance IS the mile count); `/goto` excludes swim edges unless `/hexset allow_swim on` or you are already underwater (swim steps wear a `~` marker); `/goto avoid_gates on` routes around the city-gate table (gates lock at night). `/path` stays all-edges informational.
- Tests grow to 131 (136 with the opt-in goldens): SQL builder escaping and PK shapes, the minimap live-payload fixtures (real ESC bytes, empty and whitespace payloads, the no-@ case), dedupe keys, journey/swim/gate routing, and find-SQL single-wrapping.

## v0.6.0 (2026-11-05)

The wire-verification release: everything here is grounded in the capture transcript from `~/.local/share/hex/captures/` (v0.5.2-dbg's debug lane did its job and is gone, as planned).

- `/stats [refresh]` and `hex_stats`: stat parsing finally lands. The live layout is TWO dot-padded lines (`Constitution ...` / `Dexterity ...`), not the documented 3-line (wire-verified), and the same pair tails `score verbose`. Values store per-alt; the skills bonus math, `/spellinfo` hints, and `/skillcost` now compute on your real stats instead of the all-13 baseline. Stat-item netting stays Phase 4 (the stored values are the shown ones).
- Guild auto-detection: score verbose's `level N in the X Guild` clause maps to the primaries key (the capture caught `level 0 in the Adventurers' Guild`), so TM gating and `/skillcost` primary flags go live without touching `char.info` (whose guild field remains an open question; score answers it more reliably anyway).
- `/hexsetup` corrected from the wire: `options set output brief exits on` does not exist on this MUD (bare `brief exits` works and stays); `options terminal automatic rows = off` is rejected under blightmud's NAWS negotiation and was dropped from the send list. The option-confirmation lines (`Set option ...`, `Set output map ... to off`, `Terminal type unchanged as ...`) and their queued-command echoes are now permanent data gags.
- Wire facts hardened into spec.md: GMCP identifiers are 40-hex matching rooms.db verbatim; `glance` AND `look` both push info+map+writtenmap; the stats block, score-brief, hskills (plain-parens shape), and spells-negative shapes are now capture-quoted in the spec rather than ported claims.
- DEBUG LANE REMOVED: `src/hex_capture.lua`, the `/hexcapture` alias, and the `debug_capture` flag are gone exactly as the v0.5.2-dbg notes promised; the archived transcripts remain the wire-shape reference and AGENTS.md points at them.
- NPC tells in new areas: pumpkin village's NPCs (Melvyn Torche, Cony) were not on tt_dw's exclusion list, so their tells landed in the chat capture. Both added to the shipped list, and `/chatnpc [name]` now lets you silence any NPC you meet (persisted; `/chatnpc remove <name>` undoes, bare lists yours). Live play also confirmed the tell family's asks-to and exclaims-to variants on the wire.
- Tests grow to 121 (126 with the opt-in goldens): the stats block fixtures (round and odd values, negative controls), the guild-clause mapping, and the two registration/look-around invariants now cover the stats module; the capture-lane tests went with the lane.

First-live-session hotfix (same milestone, found live):

- Fixed the reload-time `[!!] create_tab(chat): tab already exists` error: the `blight.tabs()` existence check does not work on stock 5.7.1, so every reload re-created the existing chat tab. A session-store flag is now the gate — it survives `/hexreload` exactly as long as the tab itself does and clears on client restart. Also deduplicated the `[hex] alt:` line to print only when the alt actually changes (char.info pushes repeatedly at login).

## v0.5.2-dbg (2026-11-05)

DEBUG RELEASE. This lane ships one purpose-built debug command and is slated for removal in v0.6.0, which will cut it out entirely; do not build on it.

- `/hexcapture` (gated behind `/hexset debug_capture on`): the wire-verification capture harness. `/hexcapture on` arms a file sink at `~/.local/share/hex/captures/<stamp>.log` that mirrors every MUD output line (prompts flagged) and every raw GMCP payload; `/hexcapture probes` runs the read-only probe batch (options shapes, all four score layouts, the skills-listing round-trip, the spells listing, hskills, quota brief, glance/look room pushes, and say/soul as negative controls) bracketed with frimble markers; `/hexcapture off` disarms and prints the manual-probe list (a short /goto for walker echoes, weak combat for monitor lines, tells or a club line for chat shapes, and arming before the next login for char.login/char.info GMCP).
- Safety: every send lives inside the `/hexcapture` alias handler; the probe batch is read-only options/query commands plus two deliberate negative controls, asserted by test to contain no game-state-changing commands.
- Tests grow to 120 (125 with the opt-in goldens): the probe-group contents and the flattened frimble structure, and the capture-file path.

First-run hotfix (same dbg milestone, found live at startup):

- Fixed a load-killing regex: the own-tell chat pattern carried a `(?!in )` look-ahead, which the Rust regex engine rejects at `Regex.new`; the error aborted `main.lua` mid-load, leaving the status area drawn but every later registration dead. The look-ahead was redundant (the pure classifier already rejects the language broadcast), and a new suite invariant now scans every `src/` module for look-around constructs so this bug class dies in CI-style tests instead of at login.
- Second start found the next load-killer one line further: `blight.bind` takes a key plus a FUNCTION, and the tab setup was passing a tab name (`blight.bind("chat", "F2")`). Fixed to `bind("F2", function() blight.switch_tab("chat") end)`; `switch_tab` is the actual tab switcher; and the whole tab setup is now `pcall`-wrapped so any remaining tabs-API mismatch degrades to mirror mode with a note instead of aborting the load. (The tab itself had been created and filtered successfully; only the binds were broken.)
- Preventive sweep of the runtime-only paths in the same breath: the walker's frimble-completion trigger was built with Lua-style `%`-escapes and handed to the Rust engine, where they would silently never match (completion would have degraded to the last-planned-room heuristic without erroring). Now escaped Rust-style (`\\s`, backslash literals).
- Third live find, the biggest: 22 alias patterns were written with Lua character classes (`%s`, `%S`, `%d`) and handed to the Rust engine, where they match literal text; so every command from the pathfinding lane onward (`/path`, `/near`, `/goto`, `/missions`, `/apply`, `/dl`, `/quota`, `/skills`, `/bonus`, `/skillcost`, `/goal`, `/chat`, `/combat`, `/urls`, `/spellinfo`, `/tm`, `/hexcapture` and kin) passed straight through to the MUD as unknown commands. All rustified, plus the skills-listing trigger pattern (Lua classes there meant `/skills refresh` would have stored nothing). A second suite invariant scans every registration literal for Lua classes; the pure-Lua classifiers keep theirs by design. (The rustifier's own first pass wrote single backslashes; invalid Lua escapes that stop the file parsing; which the extended invariant now also catches; both defects were pushed briefly and fixed within minutes.)

## v0.5.1 (2026-11-05)

Phase 4's data lane: the spell dataset and the TM tooling. The trackers (TPA, charm, broom, stat items) stay wire-gated on capture session #2.

- The committed spell dataset: `tools/convert_spelldata.py` (stdlib, dev-time) parses tt_dw's spelldata.tin into `src/hex_spelldata.lua` (84 KB, 117 spells, 376 spellcheck stages), validated on every run (10 strictly ascending thresholds per stage, every shorthand resolved, type enumeration, the 93/93/25 octogram/tome/learnt-at counts) and shipping the upstream attribution verbatim. Committed so `/add_plugin` installs work without the tt_dw clone. Two upstream quirks handled: one spell carries two nicknames (`cmseq cms2`), and two distinct spells share the nickname `jmc` (suffixed deterministically).
- `/spellinfo <nick|name>`: the full card with type colour, GP, size, description, components, octogram/tome/learnt-at lines, and the spellcheck table showing your stage chance, the 50% bonus point, and the level that reaches it (via Phase 3's `level_for_bonus`). `/spellcheck <n>` is an alias for the card; nick, prefix, and name-substring resolution with ambiguity listing.
- `/tm <method>` and `/spells [list|long|<method>|<text>]`: the TM suggestion engine ported whole from spellinfo.tin; stage chance counts thresholds passed breaking at the first failure; the relative TM chance clamps 1-99 (near-certain casts TM poorly); the suggestion ranks by cast chance, skips the blacklist, and the scan breaks early on a good-enough incumbent. The list renders the suggestion starred, then candidates by TM chance descending, with the low-chance warning at the `tm_cutoff`. Constants are config (`tm_blacklist`, `tm_cast_chance` 30, `tm_cutoff` 9), defaults = tt_dw's.
- Tests grow to 117 (122 with the opt-in goldens): the dataset integrity matrix, stage-chance break behaviour, TM clamp edges (0/100 -> 1/99), the cast-chance product, the 50% thresholds, and suggestion ordering + blacklist demotion on a synthetic four-spell graph.

## v0.5.0 (2026-11-05)

Phase 6: the social layer. Chat shapes and the monitor strings stay wire-checkable for tonight's capture; everything else is tt_dw-faithful port.

- `/chat [family] [n]`: chat capture with tt_dw's taxonomy (tells in and out, clubs, group, talkers in both documented shapes, Offler shouts; room says and souls deliberately not captured, as upstream). Session ring buffers per family with the design's caps, the NPC speaker list and the twelve job-completion texts excluded exactly as ported. Mirror mode is the default, so the awareness rule holds: chat never leaves the main feed. With a blightmud carrying tabs (dev tree, feature-detected) one `chat` tab mirrors via Rust-side include/exclude filters, F1 main / F2 chat; `/chatset <family> on|off` persists (tab filters are append-only, so rebuilds need a restart) and `/chattab on|off` gates the tab.
- The combat spam ladder: `/combat` cycles verbatim -> verbose -> default -> brief (or sets directly), per-alt persisted. Levels are data over the tt_dw family patterns: defense and "nothing happened" lines gag at default, the hit/burn/hurt/miss/prepare/special alternations gag at brief, with the moon-dragon hurt-line exclusion as a code check. The divine-ire and special-weapon tail stays pending as data work against the live capture; the digest engine is Phase 7's.
- The combat monitor as a vitals fallback: the three strings `/hexsetup` installs (monitor, verbose prompt, `score brief` tail) parse into the vitals model when GMCP is stale or dead (120 s freshness window), and never touch it when GMCP is alive. A GMCP push always overwrites monitor values; both feeds assign absolutes, so nothing double-counts. The monitor lines gag (the status area replaces them) and count rounds for `/combatstat`, the attacks-per-round readout.
- `/urls [pattern]` and `/url <n>`: URL catching with tt_dw's false-positive guards (filenames, the MUD's own address, skill names and their short prefixes, double dots, under ten characters), a deduplicated recall ring, and `/url open <n>` shelling to xdg-open behind an opt-in flag (core.exec blocks the UI thread, so it defaults off). Click-to-copy is an upstream blightmud gap.
- `hex_notify`: the ~40-line event bus (subscribe/emit/debounced/list, per-subscriber pcall isolation, announce-only contract). It now carries chat.tell/club/group/talker/shout, url.captured, combat.attack, mission.ready, core.connected/disconnected; Phase 7's sound and TTS subscribe to it.
- Tests grow to 110 (115 with the opt-in goldens): the chat fixtures (language-tell, NPC and job exclusions, both talker shapes, room-say negative, ring caps), the URL guard matrix, the notify bus contract (order, isolation, debounce), the level-ladder table, and the GMCP-freshness precedence cases.

## v0.4.1 (2026-11-05)

Phase 3's skills lane. Stats parsing stays wire-gated (its layout question needs tonight's capture); bonus math runs on the documented all-13 baseline until then.

- `/skills [refresh|search]`: the listing round-trip ports tt_dw's three documented sends (`noalias options output skills = list`, `noalias skills`, `options output skills = branched`) inside the user alias, with a parse window armed for the listing, closed by the `Set option output skills to branched.` terminator or a 30-second display-only safety timer, triggers registered through the handle registry so a reload cannot orphan the window. Levels store per alt; a search shows levels and bonuses.
- The bonus model, ported from tt_dw (credited to bonuses.irreducible.org): piecewise raw-level bonus, the 0.1020408·ln(stat product) − 0.25 multiplicator over each skill's C/D/I/W/S dependencies, floored at zero. Golden-tested at the documented constant: all-13 stats give bonus 307 at level 300.
- `/bonus <skill> [target]` and `/skillcost <skill|prefix> [target] [etb N]`: the full tt_dw cost model (primary formula to the 300 skillcap, teach-cost curve with an optional ETB), multi-skill prefixes capped at 8 matches, primaries flagged `*`. The output carries the official-docs caveat that teach-cost numbers are tt_dw's approximation.
- `/goal add|remove`, `/goals`: per-alt goals with the xp-bar port (10 pips, divider, at least one pip lit unless empty or done). Goal alerts fire off the tightened advance line (now capturing skill and level) and the documented `hskills` shapes as the sanctioned second feed.
- Static data generated from tt_dw's char/data.tin: 251 skill stat-dependencies, primaries for all eight guilds including every specialisation branch, wizard order-to-colour translation. Guild is configurable via `/hexset guild` until char.info's guild key is wire-verified.
- Tests grow to 95 (100 with the opt-in goldens): the piecewise pins, the golden constant, multiplicator edge cases (zero skipped, negatives divide by abs), target grammar, cost monotonicity and the primary-branch discount, parent-fallback levels, listing lines at all four depths with hyphenated skills and X bonuses.

## v0.4.0 (2026-11-05)

Phase 3, missions lane: cooldowns and quota for the working character. (Skills and stats wait for tonight's capture session: their parsers are wire-gated.)

- `/missions`: the full mission table with live XP (halving per pending reset), XP/hour estimates from your own completion history, reset countdowns, and per-mission detail (`/missions <name>`). Ordered best-rate first, unrated by XP.
- Job market, dead letter office, sausage shop, and the two side missions (Theodor Hackett, Pennie Laced) parse their boards and lifecycle lines, gated on the GMCP room identifier so nothing misfires away from the board. `/apply <board id>` and `/dl <A-H>` record the pending mission before sending (the suite's only new send paths, both user aliases). A writ arriving with no pending record prints a fixup hint (`/missions pending <id>`).
- Cooldown engine: every completion re-arms its mission an hour later; the sweep announces "has been reset!" once per mission inside a 6-hour window and silently prunes older resets (no login spam). Timers are announce-only and registry-recorded, so `/hexreload` cannot double a pending reset. The difficult customer's real XP replaces the 40,000 guess on first live delivery, stored per alt.
- Per-alt persistence in the disk store (`hex.missions.<alt>`), keyed on the GMCP capname.
- Thief quota: `check quota brief` parses passively (A$ and pence forms, all six time-left shapes) into a deadline model, stored once and rendered live (no ticking, no drift). The status row gains `[Q:$max-$rcpt=$left]` with an owed flag and reset countdown; expiry announces once. `/quota` displays; `/quota refresh` sends the check (user alias).
- The status area's vitals row takes a chips argument: the quota chip first, then minutes to the next mission reset.
- Tests grow to 82 (87 with the opt-in goldens): hand-computed EMA stats, timer-sweep announce/prune rules, the quota brief fixture, all six time-left shapes, chip colors, per-critter sausage XP.

## v0.3.0 (2026-11-05)

Phase 2 complete: find your way.

- `/path [--full] [any] <target>` routes through the identified map graph. Targets: room name with the house glob rules (`*` `?` `^` `$`), `@<area>` for an area's origin room, a room id, `#<n>` from the last candidate list, or a bare vnum. Multiple matches give a numbered candidate list with per-candidate step counts, routed by `/path #n`; `any` allows avoid-flagged and water rooms; `--full` prints every room on the way.
- `/near <search>` ranks the five nearest matches to your current room by path length from one multi-target Dijkstra.
- The routable subgraph builds lazily inside the first routing command: 31,157 identified rooms, 78,979 directed edges, ~280 ms once and ~21 ms per route on this machine (21.7 MB heap after GC). `lua tests/bench_paths.lua` keeps the numbers honest. Known limits, measured 2026-11-05: Bes Pelargic and Genua are disconnected from Ankh-Morpork in the identified-room subgraph (the open-sea swim chain crosses unidentified rooms; the Bois has no inbound edges), so boats wait for Phase 5's journey/ferry tables.
- `/goto <target>` is the ONE-SHOT batch speedwalk in the MUD's officially sanctioned "fast" style, ported from tt_dw's packed-alias shape: the travel option, every route command, an optional journey restore (config `travel_mode`), and a frimble end-marker are defined as one MUD-side alias and invoked in two sends. Hex never sends again after the burst; `stop` in-game or `/stopwalk` aborts. room.info pushes drive post-hoc drift display only: a first mismatch is reported once with expected-vs-actual, the queue is never altered, and the frimble marker (or the last planned room) prints the arrival summary.
- Walk noise gags: the queued-command echo catch-all and the `Removed queue.` notice are walk-duration triggers; the travel-option confirmations and compact queued-command echoes are permanent data gags (tt_dw paths.tin port). The alias-definition echo shape is wire-unverified pending tonight's capture.
- Tests grow to 69 (74 with the opt-in `HEX_GOLDEN=1` goldens): batch-queue packing, drift transitions, frimble completion, BFS-equivalence, tie determinism, one-way edges, avoid reroute/refuse, and the documented-negative BP/Genua goldens.

## v0.2.0 (2026-11-05)

The 1.x hotfix lane completes: setup, user gags, and Hex's own data.

- `/hexsetup`: sends tt_dw's exact game-side strings (prompt, combat monitor, map off, brief exits, rows paging in the documented form, `term xterm256`, the afterinventory alias), one send per line behind a user alias, with `/hexsetup preview` for a no-traffic look. Hex never re-sends these or puts them on a timer.
- User gags as data: `~/.local/share/hex/gags.lua`, edited by `/hexgag [-i] <pattern> [-> <substitution>]`, listed by `/hexgag` or `/gaglog`, removed by `/hexungag <n|text>`. Entries register live, one bad regex skips only itself, and hand edits need `/hexreload`.
- Quow staleness check: at connect, once per session, the database's mtime warns when it is older than `quow_stale_days` (default 60, `/hexset`-able).
- "Hex owns its data": `/hexupdate` downloads Quow's database detached (curl with wget fallback, part file + atomic move, `/hexupdate` again as the status check) into `~/.local/share/hex/quow.db`, copies the CC0 sound set from the tt_dw clone once, and writes `quow_db` explicitly. The resolution ladder (explicit `/hexset` > Hex's copy > tt_dw copy with a one-time hint) keeps current sessions working during the move.
- `/dwmap` strips the room map's embedded ANSI at render time by default (a stray unclosed colour fragment reads as broken output); `/hexset map_ansi ansi` keeps the colours, and the stored payload stays raw for Phase 5's panel.
- `hex_version.lua` is the Lua-side version carrier (GMCP hello and the update User-Agent read it). Unit suite grows 31 -> 47 tests.
- Map converter (pre-sprint, in this range): rooms.db gains the tt_dw maze `extra`/shape column (1,246 shape rows verified), which unblocks Phase 5's lost-room guessing design.

## v0.1.0 (2026-11-05)

First milestone: M1 core + Quow.

- GMCP wiring for Discworld (dual-cased registration, JSON decode, `/hexprobe` echo) feeding a vitals model and a 3-row status area: HP/GP bars with color bands, XP, XP/hour rate, current room, burden
- Quow database searches with tt_dw's exact query semantics: `/item` (wildcards, `^`/`$` anchors, `desc:`/`app:`/`mat:`/`sheat:` prefixes, `exact`), `/items` source search with sold/free/loot filters, `/npc` with `room:` filter, `/shop` for the current room
- `/where` room awareness keyed on the MUD's 40-hex identifier, backed by `tools/convert_map.py` which parses tt_dw's map into Hex's own rooms.db (62,130 rooms, 156,800 exits, 32,499 identified)
- Gags v1 ported from tt_dw (pet/summon movement spam, ambient magic lines, system noise), `/wmap` and `/dwmap` fed by GMCP room maps, `/hexset` config persistence
- Zero-dependency test suites: `lua tests/run.lua` (31) and `python3 -m unittest discover -s tests` (9)
- Spec invariants: no autonomous MUD input (Discworld anti-idle rule), third-party data strictly read-only, no third-party dependencies

First-login hotfix batch (same milestone, found live):

- Fixed dead vitals: Discworld's GMCP is nonstandard (`core.supports.set` naming all six commands individually, lowercase, no version suffix); blightmud's `gmcp.register()` wrapper was silently ignored. Hex now sends the documented handshake raw, and vitals arrive per command from the next one.
- `/hexraw`: the last raw GMCP payloads via a telnet option 201 tap, to pin down the real JSON keys; keys confirmed on the first live session (hp/maxhp/gp/maxgp/xp/burden/alignment) and `room.info`'s `kind` now feeds the terrain display.
- `/hexreload`: reap-and-reload without restarting the client; a handle registry in the session store removes exactly the triggers/aliases the previous load created, so reloads never double-register.
- Fixed the `/item` crash on rows with empty trailing columns (Quow's cabbage has no weight); every result renderer is nil-guarded and the pipe splitter keeps empty fields.
- The status area draws its placeholder bars at load and on connect instead of waiting silently for first data.
- Sent lines while a password prompt is on screen are marked skip-log, so passwords stay out of the session log file.
