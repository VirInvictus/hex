# Phase 7: feel & options — sound, TTS, /hexoptions, themes, guild packs, profiles

Design doc. Status: designed, not implemented. Verified against the blightmud and tt_dw clones with file:line citations.

## 1. Blightmud audio/TTS surface (verified facts)

The gating asymmetry that shapes the design:

| | audio | tts |
|---|---|---|
| Cargo feature | `audio = ["rodio"]`, **on by default** (Cargo.toml:19,22) | `text-to-speech = ["tts"]`, **off by default** (Cargo.toml:20) |
| Lua global | always present (`lua_script.rs:209`) | always present (`lua_script.rs:199`) |
| When compiled out | events route to a silent stub (`src/audio/stub.rs:15-20`) | every `tts.X` returns a no-op **and prints a UI error** (`tts.rs:139-160`) |
| Runtime detection | **impossible** — no capability probe | `tts.is_available()` always exists (`tts.rs:20`) |

Consequences: every `tts.*` call except `is_available()` must be gated on it (ungated code spams errors on non-TTS builds); audio is best-effort with no probe, so `/hexoptions sound on` runs a preflight on what CAN be checked (sound_dir exists, mapped files exist) and prints one courtesy line about non-default builds possibly lacking audio.

APIs (`src/lua/audio.rs:20-48`, `tts.rs:20-137`): `audio.play_sfx(path[, {loop, amplify}])` / `stop_sfx` / `play_music` / `stop_music` — FIFO queue per channel, serial not overlapped (`player.rs:45-83`); MP3/WAV/Vorbis/Flac via rodio; tt_dw's files are all `.mp3`, directly playable. TTS: `is_available()`, `is_enabled()`, `speak(msg[, interrupt])`, `enable`, `set_rate`, `stop`; `speak_direct` avoided (bypasses the user's `/tts off`).

**Ship without bundled sounds**: tt_dw's 50 sound files live at `~/.gitrepos/tt_dw/sound_files/*.mp3`, all CC0 (`SOURCES.txt:1-2`); Hex already requires the tt_dw clone as a fixture (quow_db default), so `sound_dir` defaults there. No repo binaries, no licensing bookkeeping; the CC0 grant permits a companion sound repo later if wanted.

## 2. Sound system port

tt_dw mechanism (for parity notes): external `sox play -q -G` fire-and-forget (`sound.tin:26-49`), gated on the `effects` option with a file-existence cache (`:95-107`); speech via spd-say/say (`speech.tin:10-71`). Hex replaces both with blightmud natives. Idle bells and the Hogswatch announcer are not ported (no autonomous timing value; Phase 7 is notify-driven).

**v1 event→sound table** (`src/hex_sound_events.lua`, pure data; stems are tt_dw file stems): `session.connected` → ding + "Connected"; `session.lost` → ding + "Disconnected"; `chat.tell` → bell + "Tell from {from}"; `mission.ready` → check + "Job market available"; `mission.done` → tada; `tpa.break` → plink + "TPA broken"; `room.lost` → squeak; `damage` → thud + the delta words. Damage thresholds ported verbatim (`status.tin:274-282`): hp delta < −200 "Ouch!", < −400 "Eeep!", < −500 "Youch! That hurt!". Ambient MUD-line sounds (doors, ferries, weather — 40+ triggers in `events.tin`) are a deferred v2 opt-in pack.

Emitter side: `hex_sound.setup` subscribes once per table entry via `hex_notify.subscribe`; handlers read options through the inheritance chain and no-op when sound is off (the `/play_sound` gate parity, `sound.tin:96`); file resolution `sound_dir/<stem>.mp3` with an existence cache; a missing file warns once and disables that mapping. New emitter: `hex_vitals.hp_delta(st, prev_hp)` from main's `on_vitals`, emitting `damage` via `emit_debounced(2s)` so fight bursts don't stack in the sfx FIFO.

**Sound defaults OFF** (divergence from tt_dw, which defaults on but suppresses for screen-reader users, `default.tin:19-40`): a terminal client is frequently SSH'd or at work; Hex bundles no files so default-on would emit missing-file warnings; opt-in is one command. `tts` defaults false too.

## 3. hex_tts

~50 lines: subscribes the same table; per event, gated `tts.is_available()` → option → template render → `tts.speak(text)` (no interrupt; queue parity). Never speaks raw MUD lines (blightmud's own `/tts on` covers full-output reading). `/hexsay <text>` alias works whenever TTS is available regardless of the option (user-initiated).

## 4. /hexoptions

tt_dw's `/options` is a numbered interactive list with exec-link click targets (`options.tin:118-166`) — blightmud has neither. Hex renders the same information as a plain list but selection is **by key name**: numeric targets invite typing "3" into a client that will send it to the MUD (recorded decision). Everything else ports: canonical key aliases, value validation (bool on/off/yes/no; enum membership with valid-choices errors; numeric ranges), apply-side-effects after set, write-through persistence, the 80-column description breakpoint (`options.tin:101-104`).

**Schema module** `src/hex_options_def.lua` (pure data; ordered array of `{key, type=bool|enum|number|path, default, scope=global|alt, choices, min/max, hidden, aliases, desc, apply}`): sound (false), sound_dir (nil, resolved like hex_config defaults), sound_volume (1.0, 0.1-3.0), tts (false, alias "speech"), theme (enum dragon|classic), gags (true), chat_tab (true), combat_spam (enum), walker_confirm (true), guild (enum, **scope="alt"**, none/witch/warrior/thief/priest/assassin/wizard), hidden: quow_db, rooms_db.

**Logic module** `src/hex_options.lua`: pure `lookup(schema, layers, key) -> value, layer`, `validate`, `render_all` (`%-21s` key alignment like tt_dw's `#format`, `(alt)`/`(session)` supply marks, choices appended, description same-line ≥80 cols else indented), `render_one`. Client `setup(deps)` registers:

```
/hexoptions [brief]           -> render all
/hexoptions <key> [<value>]   -> render one / validate + write the ACTIVE layer (named in the
                                 confirmation: "[hex] sound = on (alt: Bemused)")
/hexoptions alt <key> <value> -> force-write the alt layer
/hexoptions session <key> <value> / clear <key> / defaults
```

Apply hooks table populated by main.lua wiring (theme → `theme.use` + refresh_status; sound → preflight; tts → availability check; gags → module flag; chat_tab/combat_spam/guild → delegate to the owning module via `package.loaded` feature-detection, silent no-op when absent so the schema ships ahead of those phases).

**Persistence layers**: global `hex.options` (existing key); per-alt `hex.alt_options` JSON `{[altname]={key=value}}` via Phase 3's helpers; session `hex.options.session` (survives `/hexreload`, cleared on restart). `/hexset` remains the raw unvalidated escape hatch; no tt_dw-style `/override` freeze is needed because Hex has no settings-file layer that can silently disagree with the UI (recorded divergence).

## 5. Per-alt profile inheritance

Chain, highest first (mirrors tt_dw's load order, `settings.tin:48-131`):

```
session override > alt override > global > schema default
```

`alt` tracks `char.info` (nil before it arrives; chain degrades nil-guarded). Single consumer entry `hex_options.get(key)`; other phases migrate opportunistically (quow_db reads — a one-line swap). The pure `lookup` also returns the supplying layer, which drives both the render marks and writer routing.

## 6. Theme: src/hex_theme.lua

Current color inventory (complete): `hex_util.ansi` (reset/bold/red/green/yellow/magenta/cyan/gray/white), HP bands green/yellow/magenta/red (`hex_util.lua:160`), XP-rate green/yellow/red/cyan (`hex_vitals.lua:85-97`), status/command usage scattered.

Design: `M.palettes` — `dragon` (Kanagawa Dragon as 24-bit escapes built from RGB triples: bg #181616, fg #c5c9c5, surface #282727, muted #625e5a, aqua #8ea4a2, blue #8ba4b0, green #87a987, red #c4746e, yellow #c4b28a, orange #b6927b) and `classic` (byte-identical to today's `hex_util.ansi`, golden-tested). `M.roles` maps semantic names to per-palette keys: label (fg+b/bold), muted (muted/gray), accent (aqua/cyan), error, hp_good/hp_warn/hp_low/hp_crit (hp_low moves magenta→orange: Dragon has no magenta in this set, orange preserves the worse-than-warn ordering), xp_good/ok/neutral/poor, the chip roles (chip_tpa, chip_mission, chip_quota, chip_broom, chip_bugshield, chip_mind, chip_route, chip_lost), chat_tell, notice. `M.get(role)` (unknown role → "", nil-guarded), `M.paint(role, text)`, `M.use(name)` (unknown keeps current).

Truecolor assumes a modern terminal; `classic` is the graceful fallback preserving today's look (`/hexoptions theme classic`). blightmud's own `C_*` globals are 16-color and exist only in-client — the theme keeps Hex's pure-escape property. Migration is mechanical: `hex_util.ansi` deleted, `colored()`/`a()` become `theme.paint` aliases, band values become role names.

## 7. Guild packs

**The tt_dw reality**: no per-guild directories; `session.tin:24-38` loads everything for every player. Guild behavior concentrates in magic/ (witch/wizard), faith/ (priest), quota + daggers (thief), and the primaries dataset. Assassin and warrior have primaries rows only — Hex would be adding net-new features there, not porting. Witch tea brewing does not exist.

v1 design: `src/hex_guild_data.lua` (pure, ~200 lines): `primaries[guild]` ported verbatim from `char/data.tin:270-310` including subguild maps (wizards ×8 colors, thieves ×5, assassins ×4, warriors ×8+, adventurers); format matches Phase 3's skills store so Phase 4's TM ordering consumes it directly. `src/hex_guild.lua` (~90 lines): reads `hex_options.get("guild")`; `none` registers nothing. Opt-in registers through the registry: thief — the two dagger tingle triggers + a `DAG` chip; priest — rod-charge substitutions as gag-data entries, totem triggers + `/hextotem`, the find-ritual movement-word decoder table as a pure function + decorating trigger; witch/wizard/assassin/warrior — primaries data only in v1. Changing `/hexoptions guild <name>` reaps and re-registers the pack's handles (no full reload). Pack autoload keys off `char.info` guild/guildspec (wire-verify their presence first).

## 8. Wiring and tests

New top-level requires: hex_theme, hex_options_def, hex_options, hex_sound_events, hex_sound, hex_tts, hex_guild_data, hex_guild. After `commands.setup`: `theme.use(options.get("theme"))`, `options.setup` with the hooks table, `sound.setup`/`tts_mod.setup` (notify + options), `guild.setup`. `/hexhelp` gains `/hexoptions`, `/hexsound test` (plays each mapped file once), `/hexsay`. Nothing new calls `mud.send`.

Tests: theme (every role in both palettes; classic byte-identical goldens; dragon matches the truecolor prefix pattern; unknown role returns ""), options_def well-formedness (unique keys, enum defaults ∈ choices, min≤default≤max), options (alias canonicalization; validation errors listing choices; lookup chain with layer attribution; nil alt; render snapshots at widths 80/60), sound_events (every stem ∈ the verified inventory set), sound (off → zero plays; path construction; missing-file warn-once; amplify passthrough; damage debounce), tts (availability gate spy; option gate; damage words at thresholds), guild_data (primaries non-empty for all seven; find-decoder spot checks), regression (existing suite updated for role names; grep invariant; all new pure modules load with a plain interpreter). Manual checklist: sound preflight output; real playback; theme classic restore; guild re-registration leaves zero orphan handles.

New files: hex_theme (~100), hex_options_def (~90), hex_options (~200), hex_sound_events (~30), hex_sound (~110), hex_tts (~60), hex_guild_data (~200), hex_guild (~90).

## 9. Deferred

Ambient MUD-line sound pack (data-only, once v1 ships); witch flyto destination table; priest find as a full ritual tracker; assassin/warrior features (nothing to port); a bundled sound repo (CC0 permits it later).
