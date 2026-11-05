# Phase 6: the social layer — chat, combat spam, monitor fallback, URLs, notifications

Design doc. Status: designed, not implemented. Ports from tt_dw `misc/chat.tin`, `ui/chat.tin`, `misc/combat.tin`, `status/status.tin`, `util/links.tin`, `misc/high.tin`, `sound/speech.tin`, `session.tin`.

## 0. Verified blightmud facts (do not re-derive)

- **Tabs API exists only in the dev tree** (`src/lua/blight.rs:444-650`); feature-detect everything.
- **`gag_main` semantics**: mirror by default; `gag_main=true` suppresses matched lines from main when any one matching tab sets it (`src/tabs/tab_set.rs:174-176`). Routing is a separate pass from triggers: `Event::MudOutput` runs the Lua listener chain first (`lua_script.rs:359-378`), **then** `route_and_print` matches `line.clean_line()` against tab filters (`event.rs:433-446`). A trigger-gagged line still routes to matching tabs; the screen just renders nothing.
- `add_tab_filter`/exclude match **anywhere** in the ANSI-stripped line (`tab.rs:146-151`); excludes veto includes; no remove-filter API (append-only) — family toggles must rebuild the tab.
- `create_tab` on an existing name **raises a Lua error** (`tab_set.rs:72-75`) — reload-safe setup must check `blight.tabs()` first.
- `output_to(name, ...)` joins strings into a **fresh Line** (MUD colors lost) and bumps unread (`blight.rs:563-566`).
- `history_lines` maps to drain length as lines/32 (`tab.rs:82-84`).
- **Plugin output listeners run after triggers** (the trigger engine is itself an output listener registered at startup): a Hex listener sees post-trigger gag/replace state.
- **No clipboard, OSC 52, or hyperlink support anywhere in blightmud** (grep over src/) — click-to-copy is an upstream gap.
- Notification primitives: `blight.bind` (overwrite semantics), `timer.add`, `mud.on_connect/on_disconnect`, `tts.speak` (feature-gated), `audio.play_sfx`. No bell API.
- Rust regex: no lookaround; `\b`, `(?:...)`, inline `(?i)` supported.

## 1. hex_chat — chat capture

### 1.1 Channel taxonomy (v1 order)

tell (in + own) highest; club; group; talker; system (shouts). Room say/souls **not captured** — tt_dw deliberately excludes them (its taxonomy is `all|group|tell|system|club|talker`, `chat.tin:55`; the channel is NPC-dominated); Hex matches that decision, a `room` family is post-v1 gated on wire verification.

tt_dw's color trick (every chat regex prefixed `%+1..c`, assuming the MUD colors chat lines, `chat.tin:179-181`) is unavailable: blightmud triggers match ANSI-stripped text by default. Hex compensates with tighter anchors plus exclusions; whether Discworld colors these lines is wire-verification item 1 (if confirmed via a `raw=true` probe, a raw-mode variant can restore the trick).

### 1.2 Trigger regexes (Rust, quoted; tintin→Rust conversions per AGENTS.md)

- Incoming tell/say-to/ask/exclaim-to/whisper-to: `^([\w'][\w' ]*) (?:says to|asks|tells|exclaims to|whispers to) .*you(?: in \w+)?: (.+)$` [case_insensitive]
- Own tells: `^You (?:tell|ask|exclaim to|whisper to) ([\w'][\w' ]*): (.+)$` with the `in <language>` broadcast guard (`chat.tin:211`)
- Clubs: `^\(([\w' -]+)\) ([\w' ]+):? (.+)$`
- Group: `^\[([\w'. -]+)\] ([\w' ]+):? (.+)$`
- Talker verbose + brief: `^([\w' -]+) ([\w' ]+)(?:'s wispy voice comes from .*, saying| wisps):? (.+)$`
- God shouts: `^Offler the Crocodile God shouts: (.+)$` (tt_dw knows only Offler; add others only after wire verification)

### 1.3 Exclusion filters (data, like hex_gags)

NPC speaker list (chat.tin:19-27, deduped: stephen jobbes, sam slager, mr werks, frank, sol, shifty jim, nella, jonas, thella, free sitting birds, nostos, philip legrande, will, jack straw, olivia, noobie, ryattenoki, the animal rights protester, cogsworth, louise eanna, velveta, mr myrtle, guard/watchmen/mercenary/musketeer patterns, the aged teller, shamir stonecutter, delivery/old man, talula, buccaneer, noelle ratson, very reverend khepresh, kess of sek, william cobbler, briony, someone, something) applied in Lua on captured names and compiled into tab excludes. The 12 job-completion noise texts (chat.tin:29-41, `.` = any char, `..?` = any 1-2 chars, tested against tell text with `"` → `'` replacement per `:228`).

### 1.4 Tab design — decision

**One tab named `chat`, `gag_main=false`, routed by `add_tab_filter` includes + exclude filters; triggers do capture/notify only; no `output_to` in the hot path.**

Justification: (1) tt_dw parity — chat lines stay in main scrollback AND the panel (`/add_chat` never gags), and mirror mode reproduces it exactly; (2) colors for free — filter routing appends the original Line, `output_to` would discard them; (3) cost — filters compile once in Rust, zero Lua per line; (4) no double-routing hazard (mixing filters and trigger-forwarding would duplicate entries; both passes run). Tab construction is idempotent (`blight.tabs()` existence check), includes OR'd per enabled family, excludes as compiled `(?i)` alternations, binds: F1 main, F2 chat (bind overwrites, `blight.rs:198-202`).

### 1.5 Capture storage — ring buffers per channel

Session-only pure rings: tell 150, group 100, system 100, talker all 200 / per 100, club all 300 / per 100, all 500. tt_dw's unbounded lists are consciously dropped.

### 1.6 Rendering

Stock fallback: nothing changes on screen (mirror mode); `/chat [family] [channel] [n]` prints the ring (`[hh:mm] name text`, wrapped via `hex_util.wrap`), first use notes the missing tab API. With tabs, `/chat` remains the greppable recall view. Channel colors (Hex render colors; the tab shows the MUD's native colors): tell bold magenta, own gray, club cyan, group yellow, talker green, system red. Aliases: `/chat`, `/chatset <family> on|off` (rebuilds the tab live — filters are append-only), `/chattab on|off`.

### 1.7 Persistence — global

`chat.tab` (true), `chat.tab_name`/`label` ("chat"), `chat.tab_shortcut` ("F2"), `chat.tab_history` (2000), `chat.gag_main` (false, reserved), `chat.families` (all five on), `chat.notify` ({tell=true, system=true, others=false}). Per-alt config arrives with hex_combat only.

## 2. hex_combat — spam levels

### 2.1 The tt_dw mechanism, quoted

Two pair-aliases per level (combat.tin:24-55): "action" lines (something happened) run `/c_show` + `/c_gag`; "defense" lines (nothing happened) run `/c_show_nop` + `/c_nop`. Ladder: **verbatim** = raw everything, no digests; **verbose** = raw + digests; **default** = raw actions + action digests, defense raws gagged but defense digests shown; **brief** = all raw gagged, action digests only. Phase 6 ships the gag ladder (the 776-line digest engine is a Phase 7 companion).

### 2.2 Hex port: levels as data

```lua
M.LEVEL_GAGS = { verbatim = {nop=false, act=false}, verbose = {nop=false, act=false},
                 default  = {nop=true,  act=false}, brief   = {nop=true,  act=true} }
```

`nop` families (gagged at default+brief): defenses (`but you (?:deftly |just |easily )?block|parry|dodge`, floating-sword/flame absorbs, unable-to-defend), others-missing (`but .+ blocks|parries|dodges|absorbs|avoids`). `act` families (gagged at brief only): hits/burn/hurt verb alternations (full lists quoted from `combat.tin:364-613`, ported as data; the `%1ou` prefix trick becomes `^.+ou `), misses, prepares/fails, specials, backstab. Moon-dragon exclusion ported as a code check.

### 2.3 `/combat` + per-alt persistence

`/combat` cycles verbatim → verbose → default → brief; `/combat <level>` sets directly. Per-alt persistence via new `hex_config.get_for_alt/set_for_alt` (store key `hex.alts.<alt>`) — a warrior wants brief, a witch verbose; the only Phase 6 per-alt key.

Attacks-per-round (`/combatstat`): `rounds` increments on every monitor line; `attacks` on act matches (minus backstabs); prints `Attacks per round: X/Y (Z.dd)` since the previous query, resets the baseline (`combat.tin:6-11, 74-94`).

## 3. Combat monitor parsing — the vitals fallback

Source strings from `doc/mud_settings.md` (installed by `/hexsetup`):

| what | Hex regex |
|---|---|
| monitor line | `^Hp: (\d+)   Gp: (\d+)$` |
| verbose prompt ({prompt=true}) | `^Hp: (\d+) \((\d+)\)  Gp: (\d+) \((\d+)\)  Xp: (\d+(?:,\d{3})*)   \(([^,]+), (.+)\)>$` |
| `score brief` tail | `^Hp: (\d+)\((\d+)\)  Gp: (\d+)\((\d+)\)  Xp: (\d+(?:,\d{3})*)  Burden: (\d+)%$` |

Monitor and prompt triggers carry `{gag = true}` (the status area replaces them).

**Precedence rule (explicit, non-negotiable): GMCP wins; the monitor fills a dead-GMCP gap.** (1) `hex_vitals` records `last_gmcp = os.time()` in apply(); (2) monitor handlers ask `vitals.gmcp_alive(120)`; (3) GMCP alive → monitor triggers still count rounds but never write vitals; (4) GMCP stale/never → monitor writes into the same vitals fields; (5) a GMCP push always overwrites monitor-sourced values — both feeds assign absolute values, so there is no merging arithmetic and no double-counting; the only incrementing feed remains the skill-advance line. Fallback state shows a gray `monitor` chip when `last_gmcp == nil`.

## 4. hex_urls

Pattern ported from `util/links.tin:52-54`: `(?:https?://.)?(?:www\.)?[-a-zA-Z0-9@:%._+~#=]{2,256}\.[a-z]{2,6}\b[-a-zA-Z0-9@:%_+.~#?&/=]*`. False-positive guards (`:59-64`): file-extension endings without http; `.starturtle.net`; skill-list lookalikes (`(adventuring|...)(\.[a-z]{2,})+` and the short prefix forms); `..` inside; <10 chars. One trigger, re-extract in the callback (registry-friendly). Recall ring: most-recent-first, deduped, cap `urls.keep` (50). `/urls [pattern]` (glob conversion per `urls.tin:44-53`), `/url <n>` prints for terminal-native click, `/url open <n>` runs `core.exec({"xdg-open", url})` — user-alias-initiated, behind `urls.open_allowed` (default false; `core.exec` is synchronous on the UI thread). Click-to-copy is an upstream blightmud gap; note it in the README when this ships.

## 5. hex_notify — the event bus

Blightmud has no pub/sub; the bus is ~40 lines of pure Lua (unit-testable):

```lua
M.subscribe(event, cb) -> id ; M.unsubscribe(id)
M.emit(event, payload)              -- registration order; each cb pcall'd
M.emit_debounced(event, payload, seconds, key)
M.list()
```

Subscriber contract: run on the UI thread inside a trigger callback, millisecond-scale, **never `mud.send`**. Phase 7 consumers: `audio.play_sfx` (feature-detected) and `tts.speak` (behind `tts.is_available()`).

Event taxonomy (tt_dw precedent cited): `chat.tell` (bell+speak, chat.tin:132-134, 234), `chat.club/group/talker`, `chat.shout`, `core.connected/disconnected` (session.tin:76-103), `url.captured`, `combat.level`, `mission.ready` (Phase 3), `tpa.low/tpa.break` (tpa.tin:124,135), `shield.low`, `room.lost` (identifiers.tin:66). "Chat highlight when tabbed away" needs no bus subscriber: blightmud's tab indicator already tracks unread counts.

## 6. Integration and reload safety

New requires at main.lua top level; all triggers/aliases through the registry wrapper; tabs and binds deliberately NOT reaped (create_tab would error on duplicate — existence check instead; binds overwrite). One `HAS_TABS = blight.create_tab ~= nil` gate. `mud.on_connect/on_disconnect` emit `core.*` next to `log.start`. `/hexhelp` gains the new commands.

## 7. Test plan

Chat fixtures (tell family with language-broadcast negative, NPC + job exclusion, clubs/groups/talkers/shouts, room-say negative, ring caps), tab filter/exclude string construction, combat gag tables (level × family class), monitor-vs-GMCP precedence cases (fresh/stale/overwrite/xp continuity), URL match/reject/recall/dedupe, notify (order, pcall isolation, unsubscribe, debounce, list), per-alt config round-trip (needs a tiny store stub — the same pattern Phase 8's harness formalizes).

## 8. Open questions (wire verification)

1. Does Discworld color chat lines? (tt_dw's `%+1..c` assumes yes; verify with a raw=true probe.)
2. Exact tell verbs/punctuation live.
3. Club-line edge cases (multi-word club names, optional colon).
4. Talker verbose wording and brief spacing.
5. Other God shouts beyond Offler (sweep a log).
6. Group chat bracket style (tt_dw marks its group capture unused).
7. Monitor/prompt exact spacing after `/hexsetup` runs once.
8. Which blightmud release ships tabs (until then the fallback is the shipping behavior).
