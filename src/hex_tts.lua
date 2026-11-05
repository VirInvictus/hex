-- hex_tts.lua: the speech consumer (design: docs/phase-7-feel.md §3, ~50
-- lines). Every tts.* except is_available() must gate on is_available()
-- — ungated calls print UI errors on non-TTS builds. Never speaks raw MUD
-- lines (blightmud's own /tts on covers that); /hexsay is user-initiated.
local events = require("src.hex_sound_events")

local M = {}

M.deps = {}

function M.available()
  return tts ~= nil and tts.is_available ~= nil and tts.is_available()
end

local function enabled()
  local cfg = M.deps.config
  return cfg and cfg.get("tts", false) or false
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function speak(text)
  if not M.available() then
    return false
  end
  tts.speak(text)
  return true
end

-- subscribe the same event table; per event: availability gate -> option
-- gate -> template render -> speak
function M.register(subscribe)
  for _, mapping in ipairs(events.events) do
    if mapping.words then
      subscribe(mapping.event, function(payload)
        if not enabled() or not M.available() then
          return
        end
        local text = events.render_words(mapping.words, payload)
        if mapping.event == "damage" and payload and payload.delta then
          local words = events.damage_words(payload.delta)
          if words then
            text = words
          end
        end
        speak(text)
      end)
    end
  end
end

-- /hexsay: works whenever TTS is available, regardless of the option
function M.cmd_say(text)
  if not M.available() then
    print("[hex] tts is not available in this blightmud build (/tts on enables it if compiled in)")
    return
  end
  speak(trim(text or ""))
end

return M
