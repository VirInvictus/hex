-- hex_options.lua: the /hexoptions engine (design: docs/phase-7-feel.md
-- §4-5). Layered persistence, highest first:
--   session override > alt override > global > schema default
-- session survives /hexreload (session store) and clears on client
-- restart; alt tracks char.info. /hexset stays the raw unvalidated escape
-- hatch writing the global layer.
--
-- Pure: lookup/validate/render. Runtime glue registers /hexoptions and
-- dispatches apply hooks populated by main.lua.
local util = require("src.hex_util")
local defs = require("src.hex_options_def")

local M = {}

M.deps = {}
M.hooks = {} -- apply-key -> function(value)

-- --- pure core ---

-- resolve key through aliases
function M.canonical(key)
  local entry = defs.find(key)
  if not entry then
    return nil, "unknown option: " .. tostring(key)
  end
  return entry.key, entry
end

-- validate a raw string value against the schema entry; returns
-- ok(value), or nil + error listing choices/range
function M.validate(entry, raw)
  local s = util.trim(tostring(raw))
  if entry.type == "bool" then
    local low = s:lower()
    if low == "on" or low == "yes" or low == "true" then
      return true
    elseif low == "off" or low == "no" or low == "false" then
      return false
    end
    return nil, "bool expected (on/off)"
  elseif entry.type == "enum" then
    for _, choice in ipairs(entry.choices or {}) do
      if choice == s then
        return s
      end
    end
    return nil, "must be one of: " .. table.concat(entry.choices or {}, ", ")
  elseif entry.type == "number" then
    local n = tonumber(s)
    if not n then
      return nil, "number expected"
    end
    if entry.min and n < entry.min then
      return nil, ("minimum is %s"):format(entry.min)
    end
    if entry.max and n > entry.max then
      return nil, ("maximum is %s"):format(entry.max)
    end
    return n
  elseif entry.type == "path" then
    if s == "" then
      return nil, "path expected"
    end
    return s
  end
  return s
end

-- session-layer serialization (one session-store key holding the table)
local function session_table()
  local raw = store.session_read("hex.options.session")
  if raw then
    local ok, saved = pcall(json.decode, raw)
    if ok and type(saved) == "table" then
      return saved
    end
  end
  return {}
end

local function global_table()
  local raw = store.disk_read("hex.options")
  if raw then
    local ok, saved = pcall(json.decode, raw)
    if ok and type(saved) == "table" then
      return saved
    end
  end
  return {}
end

local function alt_table(alt)
  if not alt then
    return {}
  end
  local raw = store.disk_read("hex.alt_options." .. alt)
  if raw then
    local ok, saved = pcall(json.decode, raw)
    if ok and type(saved) == "table" then
      return saved
    end
  end
  return {}
end

-- lookup with layer attribution: value, layer ("session"|"alt"|"global"|"default")
function M.lookup(key, alt)
  local entry = defs.find(key)
  if not entry then
    return nil, nil
  end
  local session = session_table()
  if session[key] ~= nil then
    return session[key], "session"
  end
  local at = alt_table(alt)
  if at[key] ~= nil then
    return at[key], "alt"
  end
  local global = global_table()
  if global[key] ~= nil then
    return global[key], "global"
  end
  return entry.default, "default"
end

-- write a value to a named layer; returns the written value
function M.write_to(layer, key, value, alt)
  local target
  if layer == "session" then
    target = session_table()
  elseif layer == "alt" then
    target = alt_table(alt)
  else
    target = global_table()
  end
  target[key] = value
  local payload = json.encode(target)
  if layer == "session" then
    store.session_write("hex.options.session", payload)
  elseif layer == "alt" then
    store.disk_write("hex.alt_options." .. (alt or "unknown"), payload)
  else
    store.disk_write("hex.options", payload)
  end
  return value
end

local function supply_mark(layer)
  if layer == "session" then
    return " (session)"
  elseif layer == "alt" then
    return " (alt)"
  end
  return ""
end

-- render the full list at a given width (tt_dw's %-21s alignment; the
-- description joins the key line at >=80 cols, else indents)
function M.render_all(width, alt)
  width = width or 80
  for _, entry in ipairs(defs.schema) do
    if not entry.hidden then
      local value, layer = M.lookup(entry.key, alt)
      local shown = (entry.type == "bool") and (value and "on" or "off") or tostring(value)
      local line = ("  %-21s %-10s"):format(entry.key, shown) .. supply_mark(layer)
      if entry.choices then
        line = line .. gray(" <" .. table.concat(entry.choices, "|") .. ">")
      end
      print(line)
      local desc = (entry.desc or "")
      if #desc > 0 then
        print(gray("    " .. desc))
      end
    end
  end
end

-- render_one: key, value, layer
function M.render_one(key, alt)
  local entry = defs.find(key)
  if not entry then
    return nil
  end
  local value, layer = M.lookup(entry.key, alt)
  local shown = (entry.type == "bool") and (value and "on" or "off") or tostring(value)
  print(("  %-21s %-10s"):format(entry.key, shown) .. supply_mark(layer))
  if entry.desc then
    print(gray("    " .. entry.desc))
  end
  return true
end

-- --- runtime glue ---

function M.setup(deps)
  M.deps = deps
end

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

-- /hexoptions [brief | alt <key> <value> | session <key> <value> | clear <key> | defaults | <key> [<value>]]
function M.cmd(args)
  args = util.trim(args or "")
  local alt = M.deps.config and M.deps.config.alt()
  if args == "" or args == "brief" then
    print(util.ansi.bold .. "Hex options" .. util.ansi.reset .. gray("  /hexoptions <key> <value> sets; alt/session prefixes force a layer"))
    M.render_all(80, alt)
    return
  end
  local scope, scoped_value = args:match("^(alt|session)%s+(.+)$")
  if (scope == "alt" or scope == "session") and scoped_value then
    local key, value = scoped_value:match("^(%S+)%s+(.+)$")
    if not key then
      print(gray("[hex] usage: /hexoptions " .. scope .. " <key> <value>"))
      return
    end
    local canonical, entry = M.canonical(key)
    if not canonical then
      print(gray("[hex] " .. entry))
      return
    end
    local validated, verr = M.validate(entry, value)
    if not validated then
      print(gray("[hex] " .. verr))
      return
    end
    local alt_name = scope == "alt" and alt or nil
    if scope == "alt" and not alt_name then
      print(gray("[hex] no alt known yet; connect first"))
      return
    end
    M.write_to(scope, canonical, validated, alt_name)
    local hook = M.hooks[entry.apply]
    if hook then
      pcall(hook, validated)
    end
    print(gray("[hex] " .. canonical .. " = " .. tostring(validated) .. " (" .. scope .. ")"))
    return
  end
  if args:match("^clear ") then
    local key = util.trim(args:sub(6))
    local canonical = M.canonical(key)
    if not canonical then
      print(gray("[hex] unknown option: " .. key))
      return
    end
    -- clear from every layer except default
    local session = session_table()
    session[canonical] = nil
    store.session_write("hex.options.session", json.encode(session))
    if alt then
      local at = alt_table(alt)
      at[canonical] = nil
      store.disk_write("hex.alt_options." .. alt, json.encode(at))
    end
    local global = global_table()
    global[canonical] = nil
    store.disk_write("hex.options", json.encode(global))
    print(gray("[hex] " .. canonical .. " cleared (falls back to default)"))
    return
  end
  if args == "defaults" then
    print(util.ansi.bold .. "Defaults" .. util.ansi.reset)
    for _, entry in ipairs(defs.schema) do
      if not entry.hidden then
        print(("  %-21s %s"):format(entry.key, tostring(entry.default)))
      end
    end
    return
  end
  local key, value = args:match("^(%S+)%s*(.*)$")
  if not key then
    print(gray("[hex] usage: /hexoptions [brief|defaults|clear <key>|<key> [<value>]]"))
    return
  end
  local canonical, entry = M.canonical(key)
  if not canonical then
    print(gray("[hex] " .. entry))
    return
  end
  if util.trim(value) == "" then
    M.render_one(canonical, alt)
    return
  end
  local validated, verr = M.validate(entry, value)
  if not validated then
    print(gray("[hex] " .. verr))
    return
  end
  local layer = (alt and entry.scope == "alt") and "alt" or "global"
  if entry.scope == "alt" and not alt then
    print(gray("[hex] " .. canonical .. " is per-alt; connect first"))
    return
  end
  M.write_to(layer, canonical, validated, alt)
  local hook = M.hooks[entry.apply]
  if hook then
    pcall(hook, validated)
  end
  print(gray("[hex] " .. canonical .. " = " .. tostring(validated) .. " (" .. layer .. ")"))
end

return M
