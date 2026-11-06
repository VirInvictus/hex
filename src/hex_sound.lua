-- hex_sound.lua: the sound consumer (design: docs/phase-7-feel.md §2).
-- Subscribes hex_sound_events to the notify bus; plays through
-- blightmud's audio.play_sfx (cargo feature ON by default; no runtime
-- probe exists, so /hexoptions sound on runs a preflight and prints one
-- courtesy line about non-default builds).
--
-- Defaults OFF (deliberate divergence from tt_dw: a terminal client is
-- frequently SSH'd or at work, and Hex bundles no files). Sound dir
-- defaults to Hex's own CC0 copy (~/.local/share/hex/sounds, installed by
-- /hexupdate), falling back to the tt_dw clone in the preflight message.
--
-- Pure: dir/option resolution and the words table live in hex_sound_events
-- and helpers here; deps.play is injectable for tests.
local util = require("src.hex_util")
local events = require("src.hex_sound_events")

local M = {}

M.deps = {}
M.warned = {} -- stem -> warned once

local function gray(t)
  return util.ansi.gray .. t .. util.ansi.reset
end

function M.sound_dir()
  local cfg = M.deps.config
  local from_cfg = cfg and cfg.get("sound_dir")
  if from_cfg and from_cfg ~= "" then
    return from_cfg
  end
  local home = (os.getenv and os.getenv("HOME")) or ""
  -- Hex's own CC0 copy first (installed by /hexupdate), tt_dw fallback
  local owned = home .. "/.local/share/hex/sounds"
  if M.deps.file_exists and M.deps.file_exists(owned .. "/bell.mp3") then
    return owned
  end
  return home .. "/.gitrepos/tt_dw/sound_files"
end

local function enabled()
  local cfg = M.deps.config
  return cfg and cfg.get("sound", false) or false
end

local function volume()
  local cfg = M.deps.config
  return tonumber(cfg and cfg.get("sound_volume", 1.0)) or 1.0
end

local function exists(path)
  if M.deps.file_exists then
    return M.deps.file_exists(path)
  end
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- play one stem; missing file warns once and then disables that mapping
function M.play(stem)
  if not stem or stem == "" then
    return false
  end
  local path = M.sound_dir() .. "/" .. stem .. ".mp3"
  if not exists(path) then
    if not M.warned[stem] then
      M.warned[stem] = true
      print(gray("[hex] sound missing: " .. path .. " (that mapping is muted until it exists)"))
    end
    return false
  end
  local play = M.deps.play
  if play then
    local vol = volume()
    local opts = (vol and vol ~= 1.0) and { amplify = vol } or nil
    pcall(play, path, opts)
  end
  return true
end

function M.setup(deps)
  M.deps = deps
end

-- subscribe every event in the table; handlers no-op when sound is off
-- (the notify bus contract: never sends, millisecond-scale)
function M.register(subscribe)
  for _, mapping in ipairs(events.events) do
    subscribe(mapping.event, function(payload)
      if not enabled() then
        return
      end
      if mapping.sound then
        M.play(mapping.sound)
      end
      if mapping.words and M.deps.tts_speak then
        local text = events.render_words(mapping.words, payload)
        local dmg_words = mapping.event == "damage" and payload and payload.delta and events.damage_words(payload.delta)
        if dmg_words then
          text = dmg_words
        end
        M.deps.tts_speak(text)
      end
    end)
  end
end

-- /hexoptions sound on preflight: check what CAN be checked
function M.preflight()
  local dir = M.sound_dir()
  if not exists(dir .. "/bell.mp3") then
    print(gray("[hex] sound preflight: no mp3 set found in " .. dir .. "; /hexupdate installs Hex's own copy"))
    return
  end
  print(gray("[hex] sound preflight: sound set found in " .. dir))
  print(gray("[hex] note: non-default blightmud builds may lack the audio feature; playback is best-effort"))
end

-- /hexsound test: play each mapped stem once
function M.test()
  local played = {}
  for _, mapping in ipairs(events.events) do
    if mapping.sound and not played[mapping.sound] then
      played[mapping.sound] = true
      M.play(mapping.sound)
    end
  end
  print(gray("[hex] sound test played (sound on required; volume " .. tostring(volume()) .. ")"))
end

return M
