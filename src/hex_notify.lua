-- hex_notify.lua: the event bus (design: docs/phase-6-social.md §5).
-- Blightmud has no pub/sub; this is ~40 lines of pure Lua. Subscribers run
-- on the UI thread inside a trigger callback: millisecond-scale work only,
-- and never mud.send (Phase 7's sound/TTS consumers obey the same contract).
--
-- Events so far: chat.tell, chat.club, chat.group, chat.talker, chat.shout,
-- url.captured, combat.level, mission.ready, core.connected, core.disconnected.
local M = {}

M.subscribers = {} -- id -> { event = name, cb = fn }
M.next_id = 1
M.debounce = {} -- key -> last emit time

function M.subscribe(event, cb)
  local id = M.next_id
  M.next_id = id + 1
  M.subscribers[id] = { event = event, cb = cb }
  return id
end

function M.unsubscribe(id)
  if M.subscribers[id] then
    M.subscribers[id] = nil
    return true
  end
  return false
end

-- Emit in registration order; one bad subscriber must not kill the rest.
function M.emit(event, payload)
  for id, sub in pairs(M.subscribers) do
    if sub.event == event then
      local ok, err = pcall(sub.cb, payload, event)
      if not ok then
        print("[hex] notify subscriber " .. id .. " failed (" .. event .. "): " .. tostring(err))
      end
    end
  end
end

-- Debounced emit: swallow repeats within the window per key (tpa.low and
-- friends must not spam). Pure aside from os.time, which the tests inject.
function M.emit_debounced(event, payload, seconds, key, now)
  now = now or os.time()
  local last = M.debounce[key or event]
  if last and (now - last) < seconds then
    return false
  end
  M.debounce[key or event] = now
  M.emit(event, payload)
  return true
end

function M.list()
  local out = {}
  for id, sub in pairs(M.subscribers) do
    out[#out + 1] = { id = id, event = sub.event }
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

return M
