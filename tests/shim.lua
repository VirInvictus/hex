-- tests/shim.lua: a minimal fake blightmud environment (the first slice of
-- Phase 8's harness, docs/phase-8-engineering.md). Loads main.lua with the
-- whole blightmud surface stubbed so wiring bugs (missing functions, bad
-- registration order, nil fields) die in the suite instead of at login.
-- The shim records every registration; nothing talks to a MUD.

local shim = {}

shim.calls = {} -- kind -> list of recorded registrations (reset per environment)
shim.clock = 1730000000 -- controllable os.time (the replay drives it)
shim.exec_responses = {} -- queued core.exec stdout strings (popped FIFO)
shim.prints = {} -- every print() body, for render assertions

local calls = shim.calls

local function record(kind, item)
  calls[kind] = calls[kind] or {}
  calls[kind][#calls[kind] + 1] = item
  return { id = kind .. "#" .. #calls[kind], remove = function() end }
end

-- The regex stub: accepts any pattern, matches nothing (the suite never
-- feeds it lines). Regex.new errors on nil patterns like the real engine.
local regex_stub = {
  new = function(pattern, opts)
    if pattern == nil then
      error("regex parse error: nil pattern")
    end
    return { pattern = pattern, opts = opts }
  end,
}

local function make_trigger(_re, _opts, _cb)
  return record("trigger", { re = _re })
end

local function make_alias(_re, _cb)
  -- the cb is kept so the harness can fire alias fixtures (/item etc.)
  return record("alias", { re = _re, cb = _cb })
end

local function make_timer(_dur, _count, _cb)
  return record("timer", { duration = _dur })
end

local store_data = {}

local function stub_store()
  return {
    disk_read = function(key)
      return store_data[key]
    end,
    disk_write = function(key, value)
      store_data[key] = value
    end,
    session_read = function(key)
      return store_data["session:" .. key]
    end,
    session_write = function(key, value)
      store_data["session:" .. key] = value
    end,
  }
end

local function stub_json()
  -- the vendored rxi/json.lua (blightmud's own bundle, MIT header preserved)
  -- IS the environment json now: the replay must exercise the real decode
  -- path, including room.map's JSON-string-with-ANSI-escapes. The stub only
  -- returns if the vendored file is somehow missing.
  local here = debug and debug.getinfo and debug.getinfo(1, "S").source:match("^@?(.*/)")
  if here then
    local ok, mod = pcall(dofile, here .. "shim-json.lua")
    if ok and type(mod) == "table" then
      return mod
    end
  end
  error("hex shim: tests/shim-json.lua (the vendored json) failed to load")
end

-- Build the global environment main.lua expects. Returns the recorded-calls
-- table so tests can assert on what got wired.
function shim.environment()
  for k in pairs(calls) do
    calls[k] = nil
  end
  -- recordings reset per environment; the STORE intentionally persists so a
  -- second load_main replays a real /hexreload against live handle state
  shim.mud_sent = {}
  shim.gmcp_sent = {}
  shim.on_ready_cbs = {}
  shim.receive_cbs = {}
  shim.subneg_cbs = {}
  shim.input_listeners = {}
  shim.output_listeners = {}
  shim.on_connect_cbs = {}
  shim.exec_responses = {}
  shim.prints = {}
  shim.status = {}

  local env = {}
  env._VERSION = "shim"

  -- bytes_to_string: blightmud provides it as a global for GMCP taps; the
  -- faithful form is a byte-table to string conversion
  env.bytes_to_string = function(bytes)
    if type(bytes) == "string" then
      return bytes
    end
    local chars = {}
    for i, b in ipairs(bytes) do
      chars[i] = string.char(b)
    end
    return table.concat(chars)
  end

  -- Line stub: what input/output listeners receive. skip_log and gag record.
  shim.make_line = function(text, is_prompt)
    local line = { _text = text, _prompt = is_prompt and true or false, _skip_log = false, _gagged = false }
    function line:line()
      return self._text
    end
    function line:prompt()
      return self._prompt
    end
    function line:skip_log(v)
      self._skip_log = v and true or false
    end
    function line:gag(v)
      self._gagged = v == nil and true or v
    end
    function line:replace(s)
      self._text = s
    end
    return line
  end

  -- controllable clock behind a real-os fallback (the replay drives time)
  env.os = setmetatable({ time = function()
    return shim.clock
  end }, { __index = os })

  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    shim.prints[#shim.prints + 1] = table.concat(parts, "\t")
  end

  env.registry = {
    record = function(kind, handle)
      return handle
    end,
    reap = function() end,
  }
  env.trigger = {
    add = function(re, opts, cb)
      -- the cb is kept so the harness can fire output-shaped fixtures
      return record("trigger", { re = tostring(re and re.pattern or re), cb = cb })
    end,
    remove = function() end,
  }
  env.alias = {
    add = function(re, cb)
      -- the cb is kept so the harness can fire alias fixtures (/item etc.)
      return record("alias", { re = tostring(re and re.pattern or re), cb = cb })
    end,
    remove = function() end,
  }
  env.timer = {
    add = function(duration, count, cb)
      return record("timer", { duration = duration })
    end,
    remove = function() end,
  }
  env.regex = regex_stub
  env.store = stub_store()
  env.json = stub_json()
  -- core.exec pops the response queue (the harness seeds realistic rows);
  -- an empty queue behaves like a query with no results.
  env.core = {
    exec = function(cmd)
      local out = table.remove(shim.exec_responses, 1) or ""
      record("exec", { argv = cmd, stdout = out })
      return {
        code = function()
          return 0
        end,
        stdout = function()
          return out
        end,
        stderr = function()
          return ""
        end,
      }
    end,
    subneg_recv = function(cb)
      record("subneg_recv", {})
      table.insert(shim.subneg_cbs, cb)
    end,
    time = function()
      return shim.clock
    end,
  }
  env.blight = {
    status_height = function(n)
      record("status_height", { n = n })
    end,
    status_line = function(index, text)
      -- the primary assertion surface (docs/phase-8-engineering.md §3)
      shim.status[index] = text
    end,
    terminal_dimensions = function()
      return 80, 24
    end,
    data_dir = function()
      return "/tmp"
    end,
    version = function()
      return "shim"
    end,
    create_tab = function() end,
    switch_tab = function() end,
    add_tab_filter = function() end,
    bind = function() end,
    tabs = function()
      return {}
    end,
    add_top_row = function() end,
    set_top_row = function() end,
    output_to = function() end,
    on_dimensions_change = function(cb)
      record("on_dimensions_change", {})
    end,
    remove_top_row = function() end,
    active_tab = function()
      return "main"
    end,
  }
  env.mud = {
    send = function(text)
      record("send", { text = text })
      table.insert(shim.mud_sent, text)
    end,
    add_output_listener = function(cb)
      table.insert(shim.output_listeners, cb)
      return record("output_listener", {})
    end,
    add_input_listener = function(cb)
      table.insert(shim.input_listeners, cb)
      return record("input_listener", {})
    end,
    on_connect = function(cb)
      table.insert(shim.on_connect_cbs, cb)
      return record("on_connect", {})
    end,
    on_disconnect = function(cb)
      return record("on_disconnect", {})
    end,
  }
  env.gmcp = {
    -- recording hooks: the harness replays fixtures by firing these
    on_ready = function(cb)
      table.insert(shim.on_ready_cbs, cb)
    end,
    receive = function(name, cb)
      shim.receive_cbs[name] = shim.receive_cbs[name] or {}
      table.insert(shim.receive_cbs[name], cb)
    end,
    send = function(text)
      record("gmcp_send", { text = text })
      table.insert(shim.gmcp_sent, text)
    end,
    echo = function(on)
      record("gmcp_echo", { on = on })
    end,
    -- the hard tripwire (docs/phase-8-engineering.md §3): Discworld ignores
    -- Core.Supports.Add, so Hex must never reach for blightmud's wrapper
    register = function()
      error("hex shim: gmcp.register is forbidden (Discworld ignores Core.Supports.Add; hex sends core.supports.set raw)")
    end,
    unregister = function()
      error("hex shim: gmcp.unregister is forbidden alongside register")
    end,
  }
  env.log = {
    start = function() end,
  }
  env.audio = {
    play_sfx = function(path, opts)
      record("sfx", { path = path })
    end,
  }
  env.tts = {
    is_available = function()
      return false
    end,
    speak = function(text)
      record("tts", { text = text })
    end,
  }
  env.io = io
  env.table = table
  env.string = string
  env.math = math
  env.pairs = pairs
  env.ipairs = ipairs
  env.tonumber = tonumber
  env.tostring = tostring
  env.pcall = pcall
  env.error = error
  env.unpack = unpack or table.unpack
  env.select = select
  env.next = next
  env.type = type
  env.setmetatable = setmetatable
  env.getmetatable = getmetatable
  env.rawget = rawget
  env.rawset = rawset
  env.utf8 = utf8
  env.package = {
    loaded = {},
    path = "",
  }

  return env, calls
end

-- Load main.lua inside the stub environment. Returns ok, err, calls.
function shim.load_main(path)
  local env = shim.environment()
  calls = shim.calls
  local chunk = assert(loadfile(path))
  -- run the main chunk with the stub globals via setfenv-equivalent
  local overridden = {}
  for k in pairs(env) do
    if k ~= "_VERSION" then
      overridden[k] = rawget(_G, k) ~= nil or false
      rawset(_G, k, env[k])
    end
  end
  local ok, err = pcall(chunk)
  -- leave the stub globals in place for the rest of the suite (shim only)
  return ok, err, calls
end

return shim
