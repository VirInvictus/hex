-- hex_gagfile.lua: user gags as data (design: docs/phase-1x-setup.md A2).
-- The user's gag/substitution entries live in a Lua file under Hex's data
-- directory, loaded additively AFTER the built-ins so a user substitution
-- wins by registration order (line:replace overwrites). /hexgag and
-- /hexungag edit the file and re-register live; hand edits need /hexreload.
-- Zero dependencies beyond the Lua state blightmud already provides (it
-- creates the state with the full standard library, so io/dofile exist; if
-- that ever changes the load degrades to built-in gags only).
--
-- The pure parts (serialize/sanitize/render) take no blightmud globals so
-- tests/run.lua can exercise them; the runtime glue receives trigger_add /
-- Regex / trigger_remove from main.lua.
local util = require("src.hex_util")

local M = {}

-- session state: the loaded user entries, their live handles (aligned by
-- index), the file path, and the registration/removal functions.
M.state = { entries = {}, handles = {}, path = nil }

local function a(name, text)
  return util.ansi[name] .. text .. util.ansi.reset
end

M.HEADER_LINES = {
  "-- Hex user gags -- your gag/substitution data, edited by /hexgag //hexungag.",
  "-- Safe to edit by hand; hand edits need /hexreload. This file is rewritten",
  "-- by /hexgag, so keep personal notes elsewhere.",
  '-- Each entry: { re = "<Rust regex>", i = true|nil, sub = "text"|nil }',
}

-- A regex goes into the file as a Lua long string unless it contains "]]"
-- (which would close it early) or starts with a newline (which [[ strips);
-- then %q keeps it intact. Substitution text always goes through %q.
local function lua_literal(s)
  if s:find("]]", 1, true) or s:sub(1, 1) == "\n" then
    return string.format("%q", s)
  end
  return "[[" .. s .. "]]"
end

function M.serialize_entry(e)
  local parts = { "re = " .. lua_literal(e.re) }
  if e.i then
    parts[#parts + 1] = "i = true"
  end
  if e.sub ~= nil then
    parts[#parts + 1] = "sub = " .. string.format("%q", e.sub)
  end
  return "  { " .. table.concat(parts, ", ") .. " },"
end

function M.serialize(entries)
  local out = {}
  for _, line in ipairs(M.HEADER_LINES) do
    out[#out + 1] = line .. "\n"
  end
  out[#out + 1] = "return {\n"
  for _, e in ipairs(entries) do
    out[#out + 1] = M.serialize_entry(e) .. "\n"
  end
  out[#out + 1] = "}\n"
  return table.concat(out)
end

-- Validate one parsed entry; returns the normalized entry or nil + reason.
function M.sanitize(raw)
  if type(raw) ~= "table" or type(raw.re) ~= "string" or raw.re == "" then
    return nil, "entry must be a table with a non-empty re string"
  end
  local e = { re = raw.re }
  if raw.i then
    e.i = true
  end
  if raw.sub ~= nil then
    if type(raw.sub) ~= "string" then
      return nil, "sub must be a string"
    end
    e.sub = raw.sub
  end
  return e
end

-- Load the user file: dofile in pcall, every entry sanitized. Returns
-- entries, nil or nil, reason.
function M.load(path)
  local ok, result = pcall(dofile, path)
  if not ok then
    return nil, tostring(result)
  end
  if type(result) ~= "table" then
    return nil, "file must return a table"
  end
  local entries = {}
  for i, raw in ipairs(result) do
    local e, err = M.sanitize(raw)
    if not e then
      return nil, ("entry %d: %s"):format(i, err)
    end
    entries[#entries + 1] = e
  end
  return entries
end

function M.exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

function M.write(path, entries)
  local f = io.open(path, "w")
  if not f then
    return nil, "cannot write " .. tostring(path)
  end
  f:write(M.serialize(entries))
  f:close()
  return true
end

-- Create the file with just the header if it does not exist yet.
function M.ensure(path)
  if M.exists(path) then
    return true
  end
  return M.write(path, {})
end

-- Register entries with blightmud; each entry inside its own pcall so one
-- bad regex skips only itself. handles[i] receives the trigger handle.
function M.register_entries(trigger_add, Regex, entries, label, handles)
  for i, e in ipairs(entries) do
    local ok = pcall(function()
      local re = Regex.new(e.re, e.i and { case_insensitive = true } or nil)
      if e.sub ~= nil then
        local to = e.sub
        handles[i] = trigger_add(re, {}, function(_, line)
          line:replace(to)
        end)
      else
        handles[i] = trigger_add(re, { gag = true }, function() end)
      end
    end)
    if not ok then
      print(a("gray", "[hex] gags: skipping entry " .. i .. " (" .. label .. "): regex parse error"))
    end
  end
end

-- Load + ensure + register the user file at load time. Returns nil on
-- success or the reason the file was skipped.
function M.activate(trigger_add, Regex, trigger_remove, path)
  M.state.path = path
  M.state.trigger_add = trigger_add
  M.state.Regex = Regex
  M.state.trigger_remove = trigger_remove
  M.ensure(path)
  local entries, err = M.load(path)
  if not entries then
    M.state.entries = {}
    return err
  end
  M.state.entries = entries
  M.state.handles = {}
  M.register_entries(trigger_add, Regex, entries, "user file", M.state.handles)
  return nil
end

-- Append a validated entry, persist it, and register it live. Returns its
-- 1-based user-entry number, or nil + reason when the write failed.
function M.add(entry)
  local entries = M.state.entries
  entries[#entries + 1] = entry
  local ok, err = M.write(M.state.path, entries)
  if not ok then
    entries[#entries] = nil
    return nil, err
  end
  local h = {}
  M.register_entries(M.state.trigger_add, M.state.Regex, { entry }, "user file", h)
  M.state.handles[#entries] = h[1]
  return #entries
end

-- Remove by 1-based number or by plain-text substring of the pattern.
-- Simplest correct live update: drop every user handle, filter, rewrite,
-- re-register what is left. Returns the removed count (nil + reason on
-- write failure).
function M.remove(selector)
  for _, h in ipairs(M.state.handles) do
    if h then
      pcall(M.state.trigger_remove, h.id)
    end
  end
  local entries = M.state.entries
  local kept = {}
  if type(selector) == "number" then
    for i, e in ipairs(entries) do
      if i ~= selector then
        kept[#kept + 1] = e
      end
    end
  else
    for _, e in ipairs(entries) do
      if not e.re:find(tostring(selector), 1, true) then
        kept[#kept + 1] = e
      end
    end
  end
  local removed = #entries - #kept
  if removed == 0 then
    return 0
  end
  M.state.entries = kept
  local ok, err = M.write(M.state.path, kept)
  if not ok then
    return nil, err
  end
  M.state.handles = {}
  M.register_entries(M.state.trigger_add, M.state.Regex, kept, "user file", M.state.handles)
  return removed
end

-- One numbered line for the /hexgag listing.
function M.render_entry(n, e)
  local kind = e.sub ~= nil and "sub" or "gag"
  local flags = e.i and "  i" or "   "
  return (" %2d  %-3s%s  %s"):format(n, kind, flags, e.re)
end

return M
