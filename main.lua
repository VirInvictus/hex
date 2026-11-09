-- Hex: a Discworld MUD plugin suite for Blightmud.
-- Entry point. Every require MUST stay at this top level: blightmud resolves
-- plugin-local modules only while this chunk itself is executing
-- (lua_script.rs prepends <plugindir>/?.lua to package.path around the load).
local util = require("src.hex_util")
local vitals_mod = require("src.hex_vitals")
local rooms_mod = require("src.hex_rooms")
local registry = require("src.hex_registry")
local gags = require("src.hex_gags")
local gagfile = require("src.hex_gagfile")
local setup_cmd = require("src.hex_setup")
local data = require("src.hex_data")
local walk = require("src.hex_walk")
local missions = require("src.hex_missions")
local quota = require("src.hex_quota")
local skills = require("src.hex_skills")
local spells = require("src.hex_spells")
local chat = require("src.hex_chat")
local combat = require("src.hex_combat")
local urls = require("src.hex_urls")
local notify = require("src.hex_notify")
local stats = require("src.hex_stats")
local theme = require("src.hex_theme")
local options = require("src.hex_options")
local sound = require("src.hex_sound")
local tts_mod = require("src.hex_tts")
local blorps = require("src.hex_blorps")
local minimap = require("src.hex_minimap")
local mdt = require("src.hex_mdt")
local doctor = require("src.hex_doctor")
local guild = require("src.hex_guild")
local scry = require("src.hex_scry")
local gmcp_wire = require("src.hex_gmcp")
local status = require("src.hex_status")
local config = require("src.hex_config")
local commands = require("src.hex_commands")

-- remove exactly the triggers/aliases the previous load registered (the
-- handle list lives in the session store and survives /script reset)
registry.reap()

-- all registrations go through the registry so /hexreload can reap them
local trigger_add = function(re, opts, cb)
  return registry.record("trigger", trigger.add(re, opts, cb))
end

-- announce-only timers (mission resets, quota expiry) are registry-recorded
-- too, so a reload cannot double a pending timer
local timer_add = function(duration, count, cb)
  return registry.record("timer", timer.add(duration, count, cb))
end
local timer_remove = function(id)
  return timer.remove(id)
end

local vitals = vitals_mod.new()
local room = rooms_mod.new()
local maps = { written = nil, ascii = nil }
-- the route graph and the last /path candidate list live for the session
local paths_cache = {}

-- Pull a displayable string out of room.map / room.writtenmap payloads,
-- which may be JSON objects ({map: ...} / {text: ...}) or plain strings.
local function map_text(data)
  if type(data) == "string" then
    return data
  elseif type(data) == "table" then
    return data.map or data.text or data.writtenmap or ""
  end
  return ""
end

local function refresh_status()
  vitals.rate = vitals_mod.xp_rate(vitals)
  -- chips: the active walk first, then quota (priority over missions), then
  -- minutes to the next mission reset; all nil-able
  local chips = {}
  local wchip = walk.chip(walk.state)
  if wchip then
    chips[#chips + 1] = wchip
  end
  local qchip = quota.chip(quota.state, os.time())
  if qchip then
    chips[#chips + 1] = qchip
  end
  local mchip = missions.chip(missions.state, os.time())
  if mchip then
    chips[#chips + 1] = mchip
  end
  status.apply(status.render(vitals, room, select(1, blight.terminal_dimensions()), chips))
end

status.setup()
refresh_status() -- draw the placeholder bars immediately, not on first data
gags.register(trigger_add, regex)

-- missions + quota (Phase 3): announce-only timers, no send paths outside
-- the /apply, /dl and /quota refresh aliases
missions.setup({ config = config, room = room, timer_add = timer_add, timer_remove = timer_remove })
quota.setup({ config = config, timer_add = timer_add, timer_remove = timer_remove })
missions.register(trigger_add, regex)
quota.register(trigger_add, regex)

-- skills: the listing round-trip arms its own window triggers inside the
-- /skills refresh alias; the passive hskills feed registers here
skills.setup({ config = config, timer_add = timer_add, timer_remove = timer_remove, trigger_add = trigger_add })
skills.register(trigger_add, regex)

-- stats: the score-verbose-stats block feeds the per-alt store that
-- skills.stats() reads (real bonus math replaces the all-13 baseline)
stats.setup({ config = config })
stats.register(trigger_add, regex)

-- Phase 7 feel: theme re-skins hex_util.ansi in place (all modules read
-- the shared table at call time); options engine with the layered store;
-- sound + tts subscribe the notify bus (announce-only, defaults off)
theme.use(config.get("theme", "classic"))

-- options engine (hooks dispatch to the owning modules)
options.setup({ config = config })
options.hooks = {
  theme = function(value) theme.use(value) end,
  sound = function() sound.preflight() end,
  chat_tab = function() end, -- applies at next start
  guild = function() guild.refresh() end,
}
sound.setup({
  config = config,
  notify = notify,
  file_exists = function(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
  end,
  play = function(path, opts) audio.play_sfx(path, opts) end,
  tts_speak = function(text)
    if tts_mod.available() and config.get("tts", false) then
      tts.speak(text)
    end
  end,
})
sound.register(notify.subscribe)
tts_mod.setup({ config = config })
tts_mod.register(notify.subscribe)

-- damage emitter: hp deltas emit the debounced damage event so fight
-- bursts don't stack in the sfx FIFO (words at tt_dw's thresholds)
local prev_hp = nil

-- Phase 5 exploration core: blorps/bookmarks in hex.db and the minimap
-- render ladder (toprows -> tab -> inline, feature-detected). hex.db is
-- Hex's OWN sqlite file; user data never touches rooms.db or tt_dw.
blorps.setup({ config = config, room = room })
minimap.setup({ config = config })
-- the people tracker shares hex.db (mdt_match/mdt_category) and recomputes
-- per accepted writtenmap push; hunt alerts print + emit on the notify bus
mdt.setup({ config = config, notify = notify })

-- situational awareness (v0.18.0): /hexexits /hexzone /hexnight /hexcorpse.
-- Read-only: triggers record signals, commands query and print; the route
-- graph is injected later by commands.setup (deps.scry.get_graph)
scry.setup({ config = config, room = room })
scry.register(trigger_add, regex)

-- v0.12.x debug lane REMOVED in v0.15.0 (transcripts consumed: combat
-- monitor verdict, guild clause, the first real writtenmap corpus);
-- /doctor is the permanent in-client self-test.

-- the guild pack (v0.15.0): autoloads off config.guild (the score-verbose
-- clause); /hexoptions guild re-runs the refresh through the options hook
guild.setup({ config = config })

-- /doctor: the in-client self-test (permanent). last_vitals_at feeds the
-- GMCP freshness check.
doctor.setup({
  config = config,
  vitals = vitals,
  room = room,
  maps = maps,
  gmcp = gmcp_wire,
  data = data,
  mdt = mdt,
  minimap = minimap,
  sound = sound,
  tts_mod = tts_mod,
  guild = guild,
})

-- spells: spelldata queries + TM suggestions feed off the skills store;
-- the live-probe triggers (spellcheck verdicts, shields) print from main
spells.setup({ config = config, skills = skills })
spells.register(trigger_add, regex)

-- debug capture lane REMOVED in v0.6.0 (transcripts consumed; wire facts
-- folded into spec.md and the parsers)

-- Phase 6 social layer: chat capture (mirror mode; tab feature-detected),
-- the combat spam ladder + monitor fallback (GMCP wins), URL recall, and
-- the notify bus wiring (core events emitted beside log.start)
chat.setup({ config = config })
combat.setup({ config = config, vitals = vitals, vitals_mod = vitals_mod, trigger_add = trigger_add })
urls.setup({ config = config })
chat.register(trigger_add, regex)
combat.register(trigger_add, regex)
urls.register(trigger_add, regex)
chat.setup_tab()

-- user gags as data: loaded additively after the built-ins (a bad entry
-- skips only itself; the file degrades to built-in gags only if unloadable)
gagfile.activate(trigger_add, regex, function(id)
  trigger.remove(id)
end, config.get("gags_file", data.hex_dir() .. "/gags.lua"))

-- Hex-owned data paths (quow_db ladder, /hexupdate, staleness)
data.setup(config)

-- /hexcheck's listing window timer (announce-only, never sends)
setup_cmd.setup({ timer_add = timer_add, timer_remove = timer_remove })

-- the /goto walker: registry-wrapped triggers + raw remover + config
walk.init(trigger_add, function(id)
  trigger.remove(id)
end, config)

gmcp_wire.setup({
  on_vitals = function(data)
    vitals_mod.apply(vitals, data)
    local hp = vitals.cur.hp
    if prev_hp and hp and hp < prev_hp then
      notify.emit_debounced("damage", { delta = hp - prev_hp }, 2, "damage")
    end
    prev_hp = hp
    refresh_status()
  end,
  on_char_info = function(data)
    if type(data) == "table" and (data.capname or data.name) then
      local name = data.capname or data.name
      if config.alt() ~= name then
        config.set_alt(name)
        print(util.ansi.gray .. "[hex] alt: " .. name .. util.ansi.reset)
      end
      missions.load_if_needed() -- per-alt mission state follows the alt
    end
  end,
  on_char_login = function(data)
    if type(data) == "table" and data.name then
      config.set_alt(data.name)
    end
  end,
  on_room = function(data)
    rooms_mod.update(room, data)
    walk.on_room(type(data) == "table" and data.identifier or nil)
    scry.on_room(type(data) == "table" and data.identifier or nil)
    refresh_status()
  end,
  on_map = function(data)
    maps.ascii = map_text(data)
    minimap.on_map(maps.ascii, room.id) -- deduped; renders per the ladder
    scry.on_map(maps.ascii) -- the dark-map payload is a night signal
  end,
  on_writtenmap = function(data)
    maps.written = map_text(data)
    mdt.on_writtenmap(maps.written, room.id)
  end,
})

-- XP spent on skill advances feeds the xp-rate model and the skill-goal
-- alerts (tt_dw counts the same line: "You advance your skill in X from A
-- to B for N xp and ..."; the level capture strips any trailing "levels").
trigger_add("^You advance your skill in (.+) from .+ to (.+) for ([\\d,]+) xp", {}, function(matches)
  local amount = tonumber((matches[4]:gsub(",", ""))) or 0
  vitals_mod.add_spent(vitals, amount)
  skills.advance(matches[2], tonumber(matches[3]:match("%d+")) or 0, amount)
  refresh_status()
end)

-- never log a password: while a password prompt is on screen, the next sent
-- line is marked skip_log so it stays out of the session log file
local password_armed = false
registry.record("trigger", trigger.add("^Enter password:", { gag = false }, function()
  password_armed = true
end))
mud.add_input_listener(function(line)
  if password_armed then
    password_armed = false
    line:skip_log(true)
  end
  return line
end)

mud.on_connect(function()
  -- Client-side logging only; nothing is ever sent to the MUD on connect.
  log.start("discworld")
  notify.emit("core.connected", {})
  data.on_connect() -- migration hints + Quow staleness, once per session
  refresh_status()
end)

mud.on_disconnect(function()
  notify.emit("core.disconnected", {})
end)

blight.on_dimensions_change(function()
  refresh_status()
end)

commands.setup({
  vitals = vitals,
  room = room,
  maps = maps,
  config = config,
  gmcp = gmcp_wire,
  registry = registry,
  gags = gags,
  gagfile = gagfile,
  setup = setup_cmd,
  data = data,
  walk = walk,
  missions = missions,
  quota = quota,
  skills = skills,
  spells = spells,
  chat = chat,
  combat = combat,
  urls = urls,
  notify = notify,
  stats = stats,
  theme = theme,
  options = options,
  sound = sound,
  tts_mod = tts_mod,
  blorps = blorps,
  minimap = minimap,
  mdt = mdt,
  doctor = doctor,
  guild = guild,
  scry = scry,
  paths_cache = paths_cache,
})

-- /hexcheck registers through the registry too (alias + the listing-window
-- trigger, both reaped on /hexreload); the alias wrapper mirrors the one
-- hex_commands.setup builds
setup_cmd.register_check(function(re, cb)
  return registry.record("alias", alias.add(re, cb))
end, trigger_add)

print(util.ansi.gray .. "[hex] loaded: /hexhelp for commands" .. util.ansi.reset)
