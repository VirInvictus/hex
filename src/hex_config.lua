-- hex_config.lua: namespaced persistence on blightmud's global store.
-- blightmud's store is a flat string-to-string KV shared by every plugin,
-- so all keys are prefixed "hex." and values are JSON.
local M = {}

local PREFIX = "hex."

-- Defaults resolved lazily: os.getenv("HOME") may be unavailable, in which
-- case /hexset quow_db <path> is the escape hatch.
function M.defaults()
  local home = os.getenv and os.getenv("HOME") or ""
  return {
    quow_db = home .. "/.gitrepos/tt_dw/quow/_quowmap_database.db",
    rooms_db = home .. "/.local/share/hex/rooms.db",
  }
end

local options = nil

function M.options()
  if options then
    return options
  end
  options = M.defaults()
  local raw = store.disk_read(PREFIX .. "options")
  if raw then
    local ok, saved = pcall(json.decode, raw)
    if ok and type(saved) == "table" then
      for k, v in pairs(saved) do
        options[k] = v
      end
    end
  end
  return options
end

function M.get(key, default)
  return M.options()[key] or default
end

-- A saved /hexset value vs the merged defaults: nil when the key was never
-- explicitly set. hex_data's migration ladder needs the distinction.
function M.explicit(key)
  local raw = store.disk_read(PREFIX .. "options")
  if not raw then
    return nil
  end
  local ok, saved = pcall(json.decode, raw)
  if ok and type(saved) == "table" then
    return saved[key]
  end
  return nil
end

function M.set(key, value)
  local opts = M.options()
  opts[key] = value
  store.disk_write(PREFIX .. "options", json.encode(opts))
  return opts[key]
end

function M.set_alt(name)
  store.session_write(PREFIX .. "alt", name)
end

function M.alt()
  return store.session_read(PREFIX .. "alt")
end

return M
