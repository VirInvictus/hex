-- hex_missions.lua: mission tracking engine (design: docs/phase-3-character.md
-- §1; ported from tt_dw scripts/missions/*.tin). Per-alt persistence on the
-- disk store; boards and current-mission pointers are session state.
--
-- Invariants carried: announce-only timers (a timer NEVER sends); every
-- send lives in a user-alias handler (/apply, /dl); nil-guarded parsers.
-- Pure core (xp math, completion stats, timer sweep, chip, comparator) is
-- unit-tested; the runtime glue below the marker owns blightmud globals.
local util = require("src.hex_util")
local data = require("src.hex_missiondata")
local notify = require("src.hex_notify")

local M = {}

local TRAVEL_DEFAULT = 60 -- config mission_travel_time, tt_dw settings/default.tin:140
local RESET_DELAY = 3600 -- every completion re-arms the mission an hour later
local ANNOUNCE_WINDOW = 6 * 3600 -- no login spam for resets older than this

M.deps = {}
M.state = {} -- per-alt: short -> { start, est_time, avg_time, min_time, max_time, total_count, resets = {}, data }
M.learned = nil -- difficult-letter XP once the real value is seen
M.session = { board = { market = {}, letters = {}, sausages = { plain = {}, spiced = {} }, sausage_list = nil } }

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

local function green(t)
  return util.ansi.green .. t .. util.ansi.reset
end

local function red(t)
  return util.ansi.red .. t .. util.ansi.reset
end

-- --- pure core ---

function M.label(short)
  if short:find("^market_") then
    return data.jobs[short:sub(8)] or short
  elseif short:find("^letter_") then
    local id = short:sub(8)
    for letter, lid in pairs(data.letters) do
      if lid == id then
        return "Letter: " .. data.tletters[letter]
      end
    end
    return short
  elseif short == "plain_sausages" then
    return "Sausages (plain)"
  elseif short == "spiced_sausages" then
    return "Sausages (spiced)"
  elseif short == "theodor_hackett" then
    return "Theodor Hackett"
  elseif short == "pennie_laced" then
    return "Pennie Laced"
  end
  return short
end

function M.count(short, missions)
  local st = (missions or M.state)[short]
  return st and st.resets and #st.resets or 0
end

-- XP the mission gives next time (missions.tin:277-300): base halves per
-- pending reset; sausages use the per-critter table, else per-dollar with
-- the A$25 default payout.
function M.xp_for(short, count, learned, dollars, critter)
  local base = data.xp[short] or 0
  if short:find("_sausages$") then
    local kind = short:sub(1, -10) -- "plain" | "spiced" (strips "_sausages")
    if critter and data.sausage_xp[kind] and data.sausage_xp[kind][critter] then
      base = data.sausage_xp[kind][critter]
    else
      if not dollars or tonumber(dollars) <= 0 then
        dollars = 25
      end
      base = base * dollars
    end
  elseif short == "letter_difficult" and learned then
    base = learned
  end
  local halves = 2 ^ (count or 0)
  return math.floor(base / halves + 0.5)
end

-- XP/hour estimate (missions.tin:305-313): xp / (est_time + travel) hours.
function M.rate_for(short, missions, learned, travel)
  local st = missions and missions[short]
  if not st or not st.est_time or st.est_time <= 0 then
    return 0
  end
  travel = travel or TRAVEL_DEFAULT
  local xp = M.xp_for(short, M.count(short, missions), learned)
  return math.floor(xp / (st.est_time + travel) * 3600 + 0.5)
end

-- Completion stats (missions.tin:315-357): duration only when start known;
-- EMA for the rate estimate, arithmetic mean for avg, min/max tracking.
-- Mutates the mission's state entry; returns what the caller should print.
-- The XP math counts st.resets as it stands when called, so the caller adds
-- the new reset AFTER this (tt_dw announces with the pre-append count too).
function M.apply_completion(st, dur, rewarded)
  local count = st.resets and #st.resets or 0
  if st.est_time then
    st.est_time = math.floor((dur + st.est_time) / 2)
    st.avg_time = math.floor((dur + st.avg_time * st.total_count) / (st.total_count + 1))
    if dur < st.min_time then
      st.min_time = dur
    end
    if dur > st.max_time then
      st.max_time = dur
    end
  else
    st.est_time = dur
    st.avg_time = dur
    st.min_time = dur
    st.max_time = dur
  end
  local out = {}
  out.xp = rewarded or M.xp_for(st._short, count)
  out.full_xp = M.xp_for(st._short, count)
  out.rate = math.floor(out.xp / dur * 3600 + 0.5)
  return out
end

-- Timer sweep (missions.tin:225-268): prune expired resets; announce a
-- mission whose pending count just reached zero only when the reset expired
-- inside the window (login-spam prevention). Mutates; returns the shorts to
-- announce and the next future reset for re-arming.
function M.check_timers(missions, now, window)
  window = window or ANNOUNCE_WINDOW
  local announce, next_reset = {}, nil
  for short, st in pairs(missions) do
    if type(st) == "table" and st.resets then
      local kept = {}
      for _, t in ipairs(st.resets) do
        if t > now then
          kept[#kept + 1] = t
          if not next_reset or t < next_reset then
            next_reset = t
          end
        elseif t > now - window then
          -- announce only when the last pending reset for this mission
          -- expired (checked after the sweep, below)
          announce[short] = true
        end
      end
      st.resets = kept
    end
  end
  local out = {}
  for short in pairs(announce) do
    local st = missions[short]
    if not st.resets or #st.resets == 0 then
      out[#out + 1] = short
    end
  end
  table.sort(out)
  return out, next_reset
end

-- Status chip: minutes to the next reset (design §1.6 "[M:32m]").
function M.chip(missions, now)
  local next_reset = nil
  for _, st in pairs(missions or {}) do
    if type(st) == "table" and st.resets then
      for _, t in ipairs(st.resets) do
        if t > now and (not next_reset or t < next_reset) then
          next_reset = t
        end
      end
    end
  end
  if not next_reset then
    return nil
  end
  local mins = math.max(1, math.ceil((next_reset - now) / 60))
  return "[M:" .. mins .. "m]"
end

-- The /missions ordering (design §1.6's resolution): rated before unrated,
-- then rate descending, then XP descending. (tt_dw's comparator comment and
-- code disagree about direction; Hex takes the player-useful reading.)
function M.compare(a, b)
  if a.rate ~= b.rate then
    return (a.rate or 0) > (b.rate or 0)
  end
  return (a.xp or 0) > (b.xp or 0)
end

function M.fmt_dur(secs)
  if not secs or secs < 0 then
    return "?"
  end
  if secs < 60 then
    return secs .. "s"
  elseif secs < 3600 then
    return math.floor(secs / 60) .. "m" .. (secs % 60) .. "s"
  end
  return math.floor(secs / 3600) .. "h" .. math.floor((secs % 3600) / 60) .. "m"
end

-- --- runtime glue (blightmud globals below this line) ---

function M.setup(deps)
  M.deps = deps
  M.load_if_needed()
  M.check_timers_runtime()
end

function M.load_if_needed()
  local alt = M.deps.config and M.deps.config.alt() or nil
  if M.alt_loaded == alt then
    return
  end
  M.alt_loaded = alt
  M.state = {}
  M.learned = nil
  M.session = { board = { market = {}, letters = {}, sausages = { plain = {}, spiced = {} }, sausage_list = nil } }
  if not alt then
    return
  end
  local raw = store.disk_read("hex.missions." .. alt)
  if raw then
    local ok, saved = pcall(json.decode, raw)
    if ok and type(saved) == "table" then
      M.learned = saved._learned
      for k, v in pairs(saved) do
        if k ~= "_learned" then
          M.state[k] = v
        end
      end
    end
  end
  M.check_timers_runtime()
end

function M.save()
  local alt = M.deps.config and M.deps.config.alt() or nil
  if not alt then
    return
  end
  local blob = { _learned = M.learned }
  for k, v in pairs(M.state) do
    blob[k] = v
  end
  store.disk_write("hex.missions." .. alt, json.encode(blob))
end

local function in_room(id)
  return M.deps.room and M.deps.room.id == id
end

function M.start(short, mission_data)
  M.state[short] = M.state[short] or {}
  local st = M.state[short]
  st.start = os.time()
  st.data = mission_data
  M.save()
  local learned = short == "letter_difficult" and M.learned or nil
  print(green("[hex] Mission: " .. M.label(short) .. " started, will give " .. M.xp_for(short, M.count(short), learned) .. "xp"))
end

function M.cancel(short)
  local st = M.state[short]
  if st then
    st.start = nil
    st.data = nil
    M.save()
  end
end

function M.complete(short, rewarded)
  local st = M.state[short]
  if st and st.start then
    local dur = os.time() - st.start
    st._short = short
    st.total_count = (st.total_count or 0) + 1
    local out = M.apply_completion(st, dur, rewarded)
    local pretty = tostring(out.xp) .. "xp"
    if out.full_xp and out.xp < out.full_xp then
      pretty = pretty .. " (" .. math.floor(100 * out.xp / out.full_xp + 0.5) .. "%)"
    end
    print(
      red("[hex] Mission") .. ": " .. green(M.label(short)) .. " gave " .. green(pretty) .. " in " .. M.fmt_dur(dur) .. ": " .. out.rate .. "/hr."
    )
    st.resets = st.resets or {}
    st.resets[#st.resets + 1] = os.time() + RESET_DELAY
    st.start = nil
    st.data = nil
    st._short = nil
    M.save()
    M.check_timers_runtime()
  end
end

-- Sweep + announce + re-arm (announce-only; a timer NEVER sends).
function M.check_timers_runtime()
  local now = os.time()
  local announce, next_reset = M.check_timers(M.state, now)
  for _, short in ipairs(announce) do
    print(red("[hex] Mission") .. ": " .. green(M.label(short)) .. " has been reset!")
    notify.emit("mission.ready", { short = short, label = M.label(short) })
  end
  M.save()
  if next_reset and M.deps.timer_add then
    -- the previous sweep timer dies first, so re-arming never doubles up
    if M.sweep_handle then
      pcall(M.deps.timer_remove, M.sweep_handle.id)
    end
    M.sweep_handle = M.deps.timer_add(1 + next_reset - now, 1, function()
      M.check_timers_runtime()
    end)
  end
end

function M.register(trigger_add, Regex)
  local T = function(re, opts, cb)
    return trigger_add(Regex.new(re), opts, cb)
  end

  -- job market (gated on the job market room)
  T("^Basic Jobs:$", {}, function()
    if in_room(data.JOB_MARKET_ID) then
      M.session.board.market = {}
    end
  end)
  T("^\\s*([BMH][A-F])\\) (.+)$", {}, function(matches)
    if not in_room(data.JOB_MARKET_ID) then
      return
    end
    local short = data.job_short(util.trim(matches[3]))
    if short then
      M.session.board.market[matches[2]:upper()] = short
    end
  end)
  T("^Mr Werks hands you an official employment writ\\.$", {}, function()
    if M.session.market_apply then
      M.session.market = M.session.market_apply
      M.session.market_apply = nil
      M.start("market_" .. M.session.market)
    else
      print(red("[hex] Job market:") .. gray(" don't know which mission we applied for! /missions pending <id> to fix"))
    end
  end)
  T("^You have been awarded ([\\d,]+) experience points for .*completing this job\\.$", {}, function(matches)
    if M.session.market then
      local xp = tonumber((matches[2]:gsub(",", "")))
      M.complete("market_" .. M.session.market, xp)
      M.session.market = nil
    end
  end)
  T("^The time has expired on your present job\\.$", {}, function()
    if M.session.market then
      print(gray("[hex] Mission expired: " .. M.label("market_" .. M.session.market)))
      M.cancel("market_" .. M.session.market)
      M.session.market = nil
    end
  end)
  T("^Mr Werks exclaims to you: Resigning your job!$", {}, function()
    if M.session.market then
      M.cancel("market_" .. M.session.market)
      M.session.market = nil
    end
    M.available_announce("Job market available", "job_market_reset")
  end)
  T("^You open your mouth up widely and pop the official employment writ into your mouth\\.$", {}, function()
    M.session.market = nil
    M.session.market_apply = nil
  end)

  -- dead letters (gated on the dead letter office)
  T("^After checking each pigeonhole, you see some letters are waiting to be delivered in the pigeonholes labelled:$", {}, function()
    if in_room(data.DEAD_LETTER_ID) then
      M.session.board.letters = {}
    end
  end)
  T("^DL([A-I]): (.+)$", {}, function(matches)
    if not in_room(data.DEAD_LETTER_ID) then
      return
    end
    if not M.session.letter then
      M.session.board.letters[matches[2]] = data.letters[matches[2]]
    end
  end)
  T("^Frank grabs a.+ letter from one of the pigeonholes and hands it to you\\.$", {}, function()
    if not in_room(data.DEAD_LETTER_ID) then
      return
    end
    if M.session.next_letter then
      M.session.letter = M.session.next_letter
      M.session.next_letter = nil
      M.start("letter_" .. M.session.letter)
    else
      print(red("[hex] Dead letter office:") .. gray(" don't know which letter we offered to deliver!"))
    end
  end)
  T("^You offer to give a.+ letter to Frank\\.$", {}, function()
    if M.session.letter then
      M.cancel("letter_" .. M.session.letter)
      M.session.letter = nil
      M.available_announce("Dead letter available", "dead_letter_reset")
    end
  end)
  T("^You have been awarded ([\\d,]+) experience points for delivering this letter\\.$", {}, function(matches)
    -- the difficult customer's real XP replaces the 40000 guess, once
    if M.session.letter == "difficult" and not M.learned then
      local xp = tonumber((matches[2]:gsub(",", "")))
      if xp then
        M.learned = xp
        M.save()
      end
    end
  end)
  T("^As you were too late, you are not paid a bonus for the delivery\\.$", {}, function()
    M.session.letter_late_until = os.time() + 10
  end)
  T("^You deliver the.+ letter to ", {}, function()
    if M.session.letter then
      if not (M.session.letter_late_until and os.time() < M.session.letter_late_until) then
        M.complete("letter_" .. M.session.letter)
      end
      M.session.letter_late_until = nil
      M.session.letter = nil
    end
  end)

  -- sausages (gated on the sausage shop)
  T("^You have .+ to deliver ([\\d,]+) fresh (.+) sausages to Sam Slager\\.$", {}, function(matches)
    if not in_room(data.SAUSAGES_ID) then
      return
    end
    local critter = util.trim(matches[3]):match("(%S+)%s*$"):lower()
    local kind = M.session.board.sausages.plain[critter] and "plain"
      or M.session.board.sausages.spiced[critter] and "spiced"
    if kind then
      M.session.sausage = kind
      M.start(kind .. "_sausages", { critter = critter, dollars = matches[2] })
    else
      print(red("[hex] Sam Slager wants unknown critter: " .. critter))
    end
  end)
  T("^Sam Slager says to you: I'll have to take care of this one later\\.$", {}, function()
    if M.session.sausage then
      M.cancel(M.session.sausage .. "_sausages")
      M.session.sausage = nil
      M.available_announce("Sausage mission available", "sausages_reset")
    end
  end)
  T("^You have been awarded ([\\d,]+) experience points for completing this order\\.$", {}, function(matches)
    if M.session.sausage then
      local xp = tonumber((matches[2]:gsub(",", "")))
      M.complete(M.session.sausage .. "_sausages", xp)
      M.session.sausage = nil
    end
  end)
  T("^Written in pinned notes:$", {}, function()
    if in_room(data.SAUSAGES_ID) then
      M.session.board.sausages = { plain = {}, spiced = {} }
      M.session.board.sausage_list = nil
    end
  end)
  T("^Plain:\\s*$", {}, function()
    if in_room(data.SAUSAGES_ID) then
      M.session.board.sausage_list = "plain"
    end
  end)
  T("^Flavoured:\\s*$", {}, function()
    if in_room(data.SAUSAGES_ID) then
      M.session.board.sausage_list = "spiced"
    end
  end)
  T("^(.+?) +([\\d,]+) sausages +A\\$(\\d+)\\.(\\d+)$", {}, function(matches)
    if not in_room(data.SAUSAGES_ID) or not M.session.board.sausage_list then
      return
    end
    local critter = util.trim(matches[2]):lower()
    M.session.board.sausages[M.session.board.sausage_list][critter] = matches[3]
  end)
  T("^Only fresh sausages from the sausage machine in the back room, please\\.$", {}, function()
    if in_room(data.SAUSAGES_ID) then
      M.session.board.sausage_list = nil
    end
  end)

  -- side missions
  T("^Theodor Hackett says to you: Be so kind to make and bring me an iconograph of (.+) in (.+)\\.$", {}, function()
    M.start("theodor_hackett")
  end)
  T("^You give an iconograph to Theodor Hackett\\.$", {}, function()
    M.complete("theodor_hackett")
  end)
  T("^You have 30 minutes to find Miss Pennie's .+ within the town of Ohulan Cutash\\.$", {}, function()
    M.start("pennie_laced")
  end)
  T("^You return Miss Pennie's .+ as promised\\.$", {}, function()
    M.complete("pennie_laced")
  end)
end

-- The 600 s "available" announces are session-only one-shot timers.
function M.available_announce(text, key)
  if not M.deps.timer_add then
    return
  end
  M.announce_handles = M.announce_handles or {}
  if M.announce_handles[key] then
    pcall(M.deps.timer_remove, M.announce_handles[key].id)
  end
  M.announce_handles[key] = M.deps.timer_add(600, 1, function()
    print(green("[hex] " .. text .. "."))
    notify.emit("mission.ready", { source = key })
    M.announce_handles[key] = nil
  end)
end

return M
