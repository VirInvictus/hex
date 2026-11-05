-- hex_data.lua: Hex-owned data paths, the quow_db migration ladder, the
-- connect-time staleness check, and /hexupdate (design:
-- docs/phase-1x-setup.md A3+A5).
--
-- Goal: daily play never depends on the tt_dw clone. Quow's database
-- downloads straight from Quow into Hex's data directory; the CC0 sounds
-- copy from the local tt_dw clone once. tt_dw stays a porting source and
-- dev-time fixture, never a runtime dependency.
--
-- Download mechanics: blightmud's core.exec is synchronous, so an in-thread
-- 18 MB pull would freeze the UI; /hexupdate spawns curl/wget DETACHED via
-- sh -c and returns immediately. A part file + mv means a failed download
-- never clobbers a good database. No timers ever run: /hexupdate again is
-- the status check.
--
-- The pure parts (resolve_quow, days_old, stale_warning, download_inner,
-- download_outer) take injected state so tests/run.lua can exercise them.
local util = require("src.hex_util")
local version = require("src.hex_version")

local M = {}

M.QUOW_URL = "https://quow.co.uk/maps/_quowmap_database.db"

-- runtime context (set by setup); defaults keep the pure parts callable.
M.deps = { config = nil }
M.warned = false -- staleness/migration hints print once per session
M.update_state = nil -- { started = os.time() } while a run is in flight

local function home()
  return (os.getenv and os.getenv("HOME")) or ""
end

function M.hex_dir()
  return home() .. "/.local/share/hex"
end

function M.owned_quow()
  return M.hex_dir() .. "/quow.db"
end

function M.part_quow()
  return M.hex_dir() .. "/quow.db.part"
end

function M.legacy_quow()
  return home() .. "/.gitrepos/tt_dw/quow/_quowmap_database.db"
end

function M.legacy_sounds()
  return home() .. "/.gitrepos/tt_dw/sound_files"
end

function M.sounds_dir()
  return M.hex_dir() .. "/sounds"
end

function M.update_log()
  return M.hex_dir() .. "/quow-update.log"
end

function M.user_agent()
  return "hex/" .. version .. " update script (https://github.com/VirInvictus/hex)"
end

-- The migration ladder (docs/phase-1x-setup.md A5): explicit /hexset value
-- wins; else Hex's own copy; else the tt_dw copy with a one-time hint; else
-- the owned path with a download hint. paths overrides for tests.
function M.resolve_quow(explicit, has_owned, has_legacy, paths)
  paths = paths or { owned = M.owned_quow(), legacy = M.legacy_quow() }
  if explicit and explicit ~= "" then
    return { path = explicit, source = "set" }
  end
  if has_owned then
    return { path = paths.owned, source = "owned" }
  end
  if has_legacy then
    return {
      path = paths.legacy,
      source = "legacy",
      hint = "Quow's database is still served from the tt_dw clone. Run /hexupdate to move it into Hex's data directory.",
    }
  end
  return {
    path = paths.owned,
    source = "missing",
    hint = "No Quow database found. Run /hexupdate to download it (~18 MB).",
  }
end

-- Whole days since mtime, or nil when the inputs make no sense.
function M.days_old(mtime, now)
  if not mtime or not now or now < mtime then
    return nil
  end
  return math.floor((now - mtime) / 86400)
end

function M.stale_warning(path, days_old)
  return {
    "[hex] Quow's database is " .. days_old .. " days old (" .. path .. ").",
    "[hex] Refresh it with: /hexupdate   (Hex never writes tt_dw's copy.)",
  }
end

-- shell single-quote, for the detached download wrapper.
local function shquote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- inner: download to a part file, then atomically move it into place.
-- kind: "curl" | "wget".
function M.download_inner(kind, ua, part, final)
  local dl
  if kind == "curl" then
    dl = ("curl -fsSL -A %s -o %s %s"):format(shquote(ua), shquote(part), shquote(M.QUOW_URL))
  else
    dl = ("wget -q -U %s -O %s %s"):format(shquote(ua), shquote(part), shquote(M.QUOW_URL))
  end
  return dl .. " && mv -f " .. shquote(part) .. " " .. shquote(final)
end

-- outer: detached so core.exec returns instead of blocking the UI thread.
function M.download_outer(inner, log)
  return ("nohup sh -c %s > %s 2>&1 &"):format(shquote(inner), shquote(log))
end

-- --- runtime glue (blightmud globals below this line) ---

function M.setup(config)
  M.deps.config = config
end

-- File existence via io (blightmud loads the full Lua stdlib).
function M.exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- mtime via stat; Linux -c first, macOS -f on non-zero exit. exec is
-- injectable for tests; defaults to blightmud's synchronous core.exec.
function M.stat_mtime(path, exec)
  exec = exec or core.exec
  local r = exec({ "stat", "-c", "%Y", path })
  if r:code() == 0 then
    return tonumber((r:stdout():gsub("%s", "")))
  end
  r = exec({ "stat", "-f", "%m", path })
  if r:code() == 0 then
    return tonumber((r:stdout():gsub("%s", "")))
  end
  return nil
end

function M.downloader_kind(exec)
  exec = exec or core.exec
  for _, kind in ipairs({ "curl", "wget" }) do
    local r = exec({ "sh", "-c", "command -v " .. kind })
    if r:code() == 0 and util.trim(r:stdout()) ~= "" then
      return kind
    end
  end
  return nil
end

-- One-time copy of the CC0 sound set from the local tt_dw clone. Runs at
-- /hexupdate time, independent of the database download. Remote sound
-- fetching waits for Phase 7, the first consumer.
function M.ensure_sounds()
  local src, dst = M.legacy_sounds(), M.sounds_dir()
  if M.exists(dst .. "/bell.mp3") then
    return
  end
  if not M.exists(src) then
    print(util.ansi.gray .. "[hex] sounds: tt_dw clone not found; skip (Phase 7 will fetch its own)" .. util.ansi.reset)
    return
  end
  core.exec({ "mkdir", "-p", M.hex_dir() })
  local r = core.exec({ "cp", "-r", src, dst })
  if r:code() == 0 then
    print(util.ansi.gray .. "[hex] sounds: copied the CC0 set to " .. dst .. util.ansi.reset)
  else
    print(util.ansi.gray .. "[hex] sounds: copy failed: " .. r:stderr() .. util.ansi.reset)
  end
end

-- Start a detached download (caller has checked none is in flight).
function M.update_start()
  core.exec({ "mkdir", "-p", M.hex_dir() })
  local kind = M.downloader_kind()
  if not kind then
    print(util.ansi.gray .. "[hex] neither curl nor wget found; install one and retry" .. util.ansi.reset)
    return
  end
  local inner = M.download_inner(kind, M.user_agent(), M.part_quow(), M.owned_quow())
  core.exec({ "sh", "-c", M.download_outer(inner, M.update_log()) })
  M.update_state = { started = os.time() }
  print(util.ansi.gray .. "[hex] download started (~18 MB). Run /hexupdate again to check." .. util.ansi.reset)
end

-- A finished run: make the owned copy explicit (ladder step 1), report age.
function M.update_finish()
  M.update_state = nil
  local config = M.deps.config
  if config then
    config.set("quow_db", M.owned_quow())
  end
  local days = M.days_old(M.stat_mtime(M.owned_quow()), os.time())
  local line = "[hex] Quow's database downloaded to " .. M.owned_quow()
  if days then
    line = line .. " (" .. days .. " days old)"
  end
  print(util.ansi.gray .. line .. "." .. util.ansi.reset)
end

-- /hexupdate: status check first, download start second.
function M.update()
  local in_flight = M.update_state and M.exists(M.part_quow())
  if in_flight then
    print(
      util.ansi.gray
        .. "[hex] download in progress ("
        .. (os.time() - M.update_state.started)
        .. "s); log: "
        .. M.update_log()
        .. util.ansi.reset
    )
    return
  end
  if M.update_state then
    -- the shell finished between two /hexupdate calls
    local mt = M.stat_mtime(M.owned_quow())
    if not M.exists(M.part_quow()) and mt and mt >= M.update_state.started then
      M.update_finish()
      return
    end
    M.update_state = nil -- stale marker; start fresh below
  end
  M.update_start()
  M.ensure_sounds()
end

-- Connect-time check, once per session: migration hints (A5) and the
-- staleness warning (A3). Client-side prints only; nothing is sent.
function M.on_connect()
  if M.warned then
    return
  end
  M.warned = true
  local config = M.deps.config
  if not config then
    return
  end
  local gray = util.ansi.gray
  local resolved = M.resolve_quow(config.explicit("quow_db"), M.exists(M.owned_quow()), M.exists(M.legacy_quow()))
  if resolved.hint then
    print(gray .. "[hex] " .. resolved.hint .. util.ansi.reset)
  end
  if resolved.source == "missing" then
    return
  end
  local days = M.days_old(M.stat_mtime(resolved.path), os.time())
  local threshold = tonumber(config.get("quow_stale_days", 60)) or 60
  if days and days > threshold then
    for _, line in ipairs(M.stale_warning(resolved.path, days)) do
      print(gray .. line .. util.ansi.reset)
    end
  end
end

return M
