-- hex_quota.lua: thief quota chip and parsing (design:
-- docs/phase-3-character.md §2; ported from tt_dw status/quota.tin).
-- Session-only state, populated passively when the player runs
-- `check quota brief` (tt_dw never sends it either); /quota refresh is the
-- explicit user alias.
--
-- Design improvement over the port: tt_dw decrements a 1 Hz tick; Hex stores
-- quota.deadline = now + seconds once and derives remaining time at render,
-- so there is no tick and no drift. Expiry announces via a one-shot
-- announce-only registry timer (a timer NEVER sends).
--
-- Pure: parse_line/time_left/chip take no blightmud globals; the runtime
-- glue below the marker owns triggers and timers.
local util = require("src.hex_util")

local M = {}

M.deps = {}
M.state = {} -- { rcpt, min, max, owed, paid, deadline }

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function cyan(t)
  return util.ansi.cyan .. t .. util.ansi.reset
end

local function yellow(t)
  return util.ansi.yellow .. t .. util.ansi.reset
end

local function red(t)
  return util.ansi.red .. t .. util.ansi.reset
end

-- --- pure core ---

-- Parse one "check quota brief" line into state. Returns true when handled.
-- All patterns are two-space indented (quota.tin:16-83); currency comes in
-- A$dollars or pence (pence / 100); missing units are 0.
function M.parse_line(state, line)
  local s = tostring(line)
  local field, value
  field, value = s:match("^  Receipts received: A%$([%d%.]+)%.$")
  if not field then
    local p = s:match("^  Receipts received: ([%d,]+)p%.$")
    if p then
      state.rcpt = tonumber((p:gsub(",", ""))) / 100
      return true
    end
  end
  if field then
    state.rcpt = tonumber(field)
    return true
  end
  value = s:match("^  Min quota: A%$([%d%.]+)%.$")
  if value then
    state.min = tonumber(value)
    return true
  end
  value = s:match("^  Max quota: A%$([%d%.]+)%.$")
  if value then
    state.max = tonumber(value)
    return true
  end
  value = s:match("^  Amount owed: A%$([%d%.]+)%.$")
  if value then
    state.owed = tonumber(value)
    return true
  end
  local p = s:match("^  Amount owed: ([%d,]+)p%.$")
  if p then
    state.owed = tonumber((p:gsub(",", ""))) / 100
    return true
  end
  value = s:match("^  Amount paid: A%$([%d%.]+)%.$")
  if value then
    state.paid = tonumber(value)
    return true
  end
  p = s:match("^  Amount paid: ([%d,]+)p%.$")
  if p then
    state.paid = tonumber((p:gsub(",", ""))) / 100
    return true
  end
  local secs = M.parse_time_left(s)
  if secs then
    state.deadline = os.time() + secs
    return true
  end
  return false
end

-- All six documented "Time left:" shapes, totalled into seconds.
function M.parse_time_left(line)
  local s = tostring(line)
  local d, h, m, sec
  d, h, m, sec = s:match("^  Time left: (%d+) days?, (%d+) hours?, (%d+) minutes?, (%d+) seconds?%.$")
  if d then
    return d * 86400 + h * 3600 + m * 60 + sec
  end
  h, m, sec = s:match("^  Time left: (%d+) hours?, (%d+) minutes?, (%d+) seconds?%.$")
  if h then
    return h * 3600 + m * 60 + sec
  end
  h, m = s:match("^  Time left: (%d+) hours?, (%d+) minutes?%.$")
  if h then
    return h * 3600 + m * 60
  end
  h, sec = s:match("^  Time left: (%d+) hours?, (%d+) seconds?%.$")
  if h then
    return h * 3600 + sec
  end
  m, sec = s:match("^  Time left: (%d+) minutes?, (%d+) seconds?%.$")
  if m then
    return m * 60 + sec
  end
  sec = s:match("^  Time left: (%d+) seconds?%.$")
  if sec then
    return tonumber(sec)
  end
  return nil
end

-- 1d 2:03 / 9m / 9m5s, per tt_dw's chip shapes (quota.tin:94-111).
function M.fmt_remaining(secs)
  if not secs or secs < 0 then
    return "0s"
  end
  if secs >= 86400 then
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    return d .. "d " .. h .. ":" .. string.format("%02d", math.floor((secs % 3600) / 60))
  elseif secs >= 3600 then
    return math.floor(secs / 3600) .. ":" .. string.format("%02d", math.floor((secs % 3600) / 60))
  elseif secs >= 600 then
    return math.floor(secs / 60) .. "m"
  end
  return math.floor(secs / 60) .. "m" .. (secs % 60) .. "s"
end

-- The chip (quota.tin:85-129): [Q:$max-$rcpt=$left] + O:$owed! + time;
-- red when over quota, yellow while under min, cyan otherwise.
function M.chip(state, now)
  if not state.max then
    return nil
  end
  local rcpt = state.rcpt or 0
  local left = state.max - rcpt
  local color = cyan
  if left < 0 then
    color = red
  elseif rcpt < (state.min or 0) then
    color = yellow
  end
  local out = " " .. color("[Q:$" .. M.fmt_num(state.max) .. "-$" .. M.fmt_num(rcpt) .. "=$" .. M.fmt_num(left) .. "]")
  if state.owed and state.owed > 0 then
    out = out .. red(" O:$" .. M.fmt_num(state.owed) .. "!")
  end
  out = out .. " " .. gray(M.fmt_remaining((state.deadline or now) - now))
  return out
end

-- integers stay bare, fractions keep two decimals (A$131.56 chips as 131.56)
function M.fmt_num(v)
  if not v then
    return "?"
  end
  if v % 1 == 0 then
    return tostring(math.floor(v))
  end
  return string.format("%.2f", v)
end

-- --- runtime glue (blightmud globals below this line) ---

function M.setup(deps)
  M.deps = deps
  M.state = {}
end

local function in_room_like_quota()
  -- quota brief runs anywhere; no gating (tt_dw gates nothing here either)
  return true
end

function M.register(trigger_add, Regex)
  local T = function(re, opts, cb)
    return trigger_add(Regex.new(re), opts, cb)
  end
  -- capture the value tail and rebuild the canonical two-space-indented
  -- line, so the runtime path goes through the same tested parser
  local patterns = {
    "^  Receipts received: (.+)$",
    "^  Min quota: (.+)$",
    "^  Max quota: (.+)$",
    "^  Amount owed: (.+)$",
    "^  Amount paid: (.+)$",
    "^  Time left: (.+)$",
  }
  for _, re in ipairs(patterns) do
    T(re, {}, function(matches)
      -- quota brief runs anywhere; tt_dw gates nothing here either
      local label = re:match("^  (.-): ")
      local was_expired = M.state.max and M.state.deadline and M.state.deadline <= os.time()
      if M.parse_line(M.state, "  " .. label .. ": " .. matches[2]) then
        M.arm_expiry(was_expired)
      end
    end)
  end
end

-- Announce expiry exactly once per quota period (announce-only timer).
function M.arm_expiry(was_expired)
  if not M.deps.timer_add or not M.state.deadline then
    return
  end
  if was_expired and M.state.deadline <= os.time() then
    -- already past: announce immediately, reset receipts like tt_dw's tick
    M.state.rcpt = 0
    print(yellow("[hex] *** Quota reset! ***"))
    return
  end
  if M.expire_handle then
    pcall(M.deps.timer_remove, M.expire_handle.id)
  end
  local delay = math.max(1, M.state.deadline - os.time() + 1)
  M.expire_handle = M.deps.timer_add(delay, 1, function()
    if M.state.deadline and M.state.deadline <= os.time() then
      M.state.rcpt = 0
      print(yellow("[hex] *** Quota reset! ***"))
      M.expire_handle = nil
    end
  end)
end

return M
