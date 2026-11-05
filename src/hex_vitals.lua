-- hex_vitals.lua: the vitals model fed by Discworld's char.vitals GMCP
-- message, plus the XP-rate model ported from tt_dw's status/status.tin
-- (~610-680): once xp exceeds 100 a start point is recorded, and rate =
-- (current xp + spent - start xp) / elapsed hours.
local M = {}

function M.new()
  return {
    cur = {},
    max = {},
    xp_start = nil, -- { xp = n, t = seconds }
    xp_spent = 0,
  }
end

-- Discworld's GMCP doc describes the vitals fields in prose only (hitpoints,
-- guildpoints, experience points, alignment, burden), never as JSON keys, so
-- apply() resolves each target from candidate spellings until the wire
-- format is pinned down live (/hexraw shows the raw payload).
local KEYS = {
  hp = { "hp", "hitpoints", "current_hp" },
  maxhp = { "maxhp", "max_hp", "maximum_hp", "hitpoints_max" },
  gp = { "gp", "guildpoints", "guild_points" },
  maxgp = { "maxgp", "max_gp", "maximum_gp", "guildpoints_max" },
  xp = { "xp", "experience", "experience_points" },
  burden = { "burden" },
  alignment = { "alignment" },
}

local function to_number(value)
  local n = tonumber(value)
  if n == nil then
    n = tonumber((tostring(value):gsub(",", "")))
  end
  return n
end

-- Merge a decoded char.vitals payload into state. Records freshness for
-- the combat-monitor precedence rule (Phase 6): GMCP wins; the monitor
-- fills a dead-GMCP gap, never the reverse.
function M.apply(st, vals)
  if type(vals) ~= "table" then
    return
  end
  st.last_gmcp = os.time()
  for target, candidates in pairs(KEYS) do
    for _, key in ipairs(candidates) do
      local value = vals[key]
      if value ~= nil then
        if target == "alignment" then
          st.cur.alignment = value
        elseif target == "maxhp" then
          st.max.hp = to_number(value)
        elseif target == "maxgp" then
          st.max.gp = to_number(value)
        else
          st.cur[target] = to_number(value)
        end
        break
      end
    end
  end
  if st.cur.xp and st.cur.xp > 100 and not st.xp_start then
    st.xp_start = { xp = st.cur.xp, t = os.time() }
  end
end

function M.add_spent(st, amount)
  st.xp_spent = st.xp_spent + (tonumber(amount) or 0)
end

-- True when a GMCP vitals push arrived within the window (seconds); nil
-- last_gmcp (never pushed) counts as dead so the monitor can feed.
function M.gmcp_alive(st, window)
  return st.last_gmcp ~= nil and (os.time() - st.last_gmcp) <= (window or 120)
end

-- XP per hour, or nil before the first start point / elapsed second.
function M.xp_rate(st, now)
  if not st.xp_start then
    return nil
  end
  local elapsed = (now or os.time()) - st.xp_start.t
  if elapsed <= 0 then
    return nil
  end
  local current = st.cur.xp or st.xp_start.xp
  local gained = current + st.xp_spent - st.xp_start.xp
  return math.floor(gained / elapsed * 3600)
end

-- XP-rate display color per tt_dw thresholds: good > 200k/h, ok > 100k/h,
-- poor < 10k/h.
function M.xp_rate_name(rate)
  if not rate then
    return nil
  end
  if rate > 200000 then
    return "green"
  elseif rate > 100000 then
    return "yellow"
  elseif rate < 10000 then
    return "red"
  end
  return "cyan"
end

return M
