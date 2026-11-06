-- tests/shim.lua: a minimal fake blightmud environment (the first slice of
-- Phase 8's harness, docs/phase-8-engineering.md). Loads main.lua with the
-- whole blightmud surface stubbed so wiring bugs (missing functions, bad
-- registration order, nil fields) die in the suite instead of at login.
-- The shim records every registration; nothing talks to a MUD.

local shim = {}

shim.calls = {} -- kind -> list of recorded registrations (reset per environment)

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
  return record("alias", { re = _re })
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
  return {
    encode = function(t)
      if type(t) ~= "table" and type(t) ~= "string" and type(t) ~= "number" and type(t) ~= "boolean" then
        error("cannot encode " .. type(t))
      end
      -- minimal faithful-enough encoder for flat tables
      if type(t) ~= "table" then
        return '"' .. tostring(t) .. '"'
      end
      local parts = {}
      local is_array = (#t > 0)
      for k, v in pairs(t) do
        local vs = (type(v) == "table") and "{}" or (('"' .. tostring(v) .. '"'):gsub("\n", "\\n"))
        if is_array then
          parts[#parts + 1] = vs
        else
          parts[#parts + 1] = '"' .. tostring(k) .. '":' .. vs
        end
      end
      return (is_array and "[" or "{") .. table.concat(parts, ",") .. (is_array and "]" or "}")
    end,
    decode = function(raw)
      if raw == "{}" or raw == "" or raw == nil then
        return {}
      end
      return { __raw = raw }
    end,
  }
end

-- Build the global environment main.lua expects. Returns the recorded-calls
-- table so tests can assert on what got wired.
function shim.environment()
  for k in pairs(calls) do
    calls[k] = nil
  end

  local env = {}
  env._VERSION = "shim"

  env.registry = {
    record = function(kind, handle)
      return handle
    end,
    reap = function() end,
  }
  env.trigger = {
    add = function(re, opts, cb)
      return record("trigger", { re = tostring(re and re.pattern or re) })
    end,
    remove = function() end,
  }
  env.alias = {
    add = function(re, cb)
      return record("alias", { re = tostring(re and re.pattern or re) })
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
  env.core = {
    exec = function(cmd)
      local r = {
        code = function()
          return 0
        end,
        stdout = function()
          return ""
        end,
        stderr = function()
          return ""
        end,
      }
      return r
    end,
    subneg_recv = function() end,
    time = function()
      return 0
    end,
  }
  env.blight = {
    status_height = function() end,
    status_line = function() end,
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
    end,
    add_output_listener = function(cb)
      return record("output_listener", {})
    end,
    add_input_listener = function(cb)
      return record("input_listener", {})
    end,
    on_connect = function(cb)
      return record("on_connect", {})
    end,
    on_disconnect = function(cb)
      return record("on_disconnect", {})
    end,
  }
  env.gmcp = {
    on_ready = function(cb) end,
    receive = function(name, cb) end,
    send = function(text)
      record("gmcp_send", { text = text })
    end,
    echo = function() end,
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
  env.os = os
  env.table = table
  env.string = string
  env.math = math
  env.pairs = pairs
  env.ipairs = ipairs
  env.print = print
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
