-- hex_registry.lua: remembers every trigger/alias handle Hex creates, keyed
-- by blightmud's globally-unique ids, so a reload can remove exactly what the
-- previous load registered (the handle list survives /script reset through
-- the session store; Trigger/Alias objects expose .id, trigger.remove(id)
-- searches all groups).
local M = {}

local KEY = "hex.handles"

local function load_handles()
  local raw = store.session_read(KEY)
  if raw then
    local ok, list = pcall(json.decode, raw)
    if ok and type(list) == "table" then
      return list
    end
  end
  return {}
end

local function save_handles(list)
  store.session_write(KEY, json.encode(list))
end

function M.record(kind, handle)
  if type(handle) == "table" and handle.id ~= nil then
    local list = load_handles()
    list[#list + 1] = { kind = kind, id = handle.id }
    save_handles(list)
  end
  return handle
end

function M.reap()
  for _, h in ipairs(load_handles()) do
    if h.kind == "trigger" then
      pcall(trigger.remove, h.id)
    elseif h.kind == "timer" then
      -- announce-only timers (mission resets, quota expiry) must die with
      -- their load too, or /hexreload doubles every pending timer
      pcall(timer.remove, h.id)
    else
      pcall(alias.remove, h.id)
    end
  end
  save_handles({})
end

return M
