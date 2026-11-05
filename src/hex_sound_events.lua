-- hex_sound_events.lua: event -> sound mapping (design:
-- docs/phase-7-feel.md §2; stems are tt_dw file stems, all present in the
-- CC0 set copied by /hexupdate). Pure data.
--
-- sound: file stem under sound_dir; words: spoken text (TTS), nil = silent.
-- Damage words ported verbatim from tt_dw status.tin:274-282.
local M = {}

M.events = {
  { event = "core.connected", sound = "ding", words = "Connected" },
  { event = "core.disconnected", sound = "ding", words = "Disconnected" },
  { event = "chat.tell", sound = "bell", words = "Tell from {from}" },
  { event = "mission.ready", sound = "check", words = "Job market available" },
  { event = "damage", sound = "thud", words = "damage" },
}

-- hp delta -> damage words, thresholds verbatim from tt_dw status.tin
function M.damage_words(delta)
  if delta <= -500 then
    return "Youch! That hurt!"
  elseif delta <= -400 then
    return "Eeep!"
  elseif delta <= -200 then
    return "Ouch!"
  end
  return nil
end

-- template render: {from} -> payload fields
function M.render_words(template, payload)
  return (tostring(template):gsub("{(%w+)}", function(field)
    return tostring((payload or {})[field] or field)
  end))
end

return M
