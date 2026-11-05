-- hex_urls.lua: URL catching and recall (design: docs/phase-6-social.md §4;
-- pattern and false-positive guards ported from tt_dw's util/links.tin:52-64).
-- Pure: matches/guards/ring; runtime glue owns the trigger and commands.
--
-- Click-to-copy is an upstream blightmud gap (no clipboard/OSC 52 anywhere);
-- /url prints for terminal-native click, /url open <n> shells out through
-- core.exec behind an opt-in flag (core.exec is synchronous on the UI thread).
local util = require("src.hex_util")
local notify = require("src.hex_notify")

local M = {}

M.PATTERN = "(?:https?://.)?(?:www\\.)?[-a-zA-Z0-9@:%._+~#=]{2,256}\\.[a-z]{2,6}\\b[-a-zA-Z0-9@:%_+.~#?&/=]*"

M.ring = {} -- most recent first, deduped, cap = M.deps.config urls.keep (50)

local function keep()
  return tonumber(M.deps.config and M.deps.config.get("urls_keep", 50)) or 50
end

-- The links.tin:59-64 false-positive guards, in order. Lua patterns here
-- (no alternation), so the extension and skill lists become loops.
local FILE_EXTS = { "db", "log", "map", "mp3", "sh", "tin", "txt" }
local SKILL_ROOTS = { "adventuring", "covert", "crafts", "faith", "fighting", "magic", "people" }
local SKILL_SHORTS = { "ad", "co", "cr", "fa", "fi", "ma", "pe" }

function M.is_url(candidate)
  local s = tostring(candidate)
  if not s:match("^http") then
    for _, ext in ipairs(FILE_EXTS) do
      if s:match("%." .. ext .. "$") then
        return false -- a filename
      end
    end
  end
  if s:find(".starturtle.net", 1, true) then
    return false -- the MUD's own address (paths included)
  end
  -- Lua quantifiers cannot follow a capture group, so the skill shapes are
  -- plain prefix + one-or-more dot-parts checks
  for _, root in ipairs(SKILL_ROOTS) do
    if s:match("^" .. root .. "%.[a-z]") then
      return false -- a full skill name
    end
  end
  for _, short in ipairs(SKILL_SHORTS) do
    if s:match("^" .. short .. "%.[a-z][a-z]+") then
      return false -- a short skill prefix
    end
  end
  if s:find("..", 1, true) then
    return false -- probably not a URL after all
  end
  if #s < 10 then
    return false -- too short to trust
  end
  return true
end

-- Find the first URL-looking substring that passes the guards. Lua word
-- scan (the Rust trigger does its own matching at runtime): split on
-- whitespace, trim trailing punctuation, require a domain-shaped head.
function M.extract(line)
  for word in tostring(line):gmatch("%S+") do
    local candidate = word:gsub("[)%],.'\"]+$", ""):gsub("^[%(\"']", "")
    if candidate:match("^https?://") or candidate:match("^www%.") or candidate:match("^[%w%-_%.]+%.[a-z][a-z]+") then
      if M.is_url(candidate) then
        return candidate
      end
    end
  end
  return nil
end

-- Most-recent-first, deduped.
function M.remember(url)
  for i, existing in ipairs(M.ring) do
    if existing == url then
      table.remove(M.ring, i)
      break
    end
  end
  table.insert(M.ring, 1, url)
  while #M.ring > keep() do
    table.remove(M.ring)
  end
  notify.emit("url.captured", { url = url })
end

-- Runtime glue: one trigger, re-extract in the callback (registry-friendly).
function M.setup(deps)
  M.deps = deps
end

function M.register(trigger_add, Regex)
  trigger_add(Regex.new(M.PATTERN), {}, function(matches, line)
    -- re-extract from the line so the guards run on the full context
    local url = M.extract(matches[1])
    if url then
      M.remember(url)
    end
    return line
  end)
end

-- /urls [pattern]: recall list (glob per urls.tin:44-53).
function M.cmd_list(pattern)
  if #M.ring == 0 then
    print(util.ansi.gray .. "[hex] no URLs caught yet" .. util.ansi.reset)
    return
  end
  local like = pattern and pattern ~= "" and util.glob_to_like(util.glob_wildcards(pattern)) or nil
  print(util.ansi.bold .. "URLs" .. util.ansi.reset .. util.ansi.gray .. "  newest first; /url <n> prints bare for terminal click" .. util.ansi.reset)
  for i, url in ipairs(M.ring) do
    if not like or url:find(like, 1, true) then
      print((" %2d. %s"):format(i, url))
    end
  end
end

-- /url <n> prints bare; /url open <n> shells out behind the opt-in flag.
function M.cmd_open(args)
  local do_open = args:match("^open%s+(.+)$")
  local n = tonumber(do_open or args)
  if not n or not M.ring[n] then
    print(util.ansi.gray .. "[hex] no such URL; /urls to list" .. util.ansi.reset)
    return
  end
  if do_open then
    if not M.deps.config.get("urls_open_allowed", false) then
      print(util.ansi.gray .. "[hex] /url open is disabled; /hexset urls_open_allowed true to allow (it blocks the UI thread briefly)" .. util.ansi.reset)
      return
    end
    local r = core.exec({ "xdg-open", M.ring[n] })
    if r:code() ~= 0 then
      print(util.ansi.red .. "[hex] xdg-open failed: " .. r:stderr() .. util.ansi.reset)
    end
    return
  end
  print(M.ring[n])
end

return M
