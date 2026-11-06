-- tests/fixtures/gmcp/login.lua: the login-replay fixture (Phase 8 harness,
-- docs/phase-8-engineering.md §3). Raw payload STRINGS exactly as the wire
-- delivers them (name stripped by blightmud; hex_gmcp decodes the rest) --
-- the replay exercises the real json decode path, including room.map's
-- double-encoded ANSI string.
--
-- Provenance: char.vitals / room.info / room.map / room.writtenmap are
-- VERBATIM from the capture of 2026-11-06 00:31
-- (~/.local/share/hex/captures/hex-capture-20261106-003105.log). char.login
-- and char.info carry the DOCUMENTED shape ({"name"} / {"capname"}) --
-- no capture has ever contained them; the wire question stays open (the
-- guild-pack lane) and this fixture pins only the documented contract.

local MAP_RAW = '"    \\u001b[39;49m\\u001b[0m\\u001b[31m+\\u001b[39;49m\\u001b[0m     \\n    \\u001b[39;49m\\u001b[0m\\u001b[1;33m@\\u001b[39;49m\\u001b[0m     \\n"'
local VITALS = '{"alignment":"neutral","maxhp":500,"hp":500,"xp":16984,"maxgp":50,"burden":9,"gp":50}'
local ROOM_ID = "917446ff80d14cacf75b035961cc89303d3d51e9"

return {
  { event = "on_ready" },
  { event = "receive", name = "char.login", raw = '{"name":"Censant"}', documented_only = true },
  { event = "receive", name = "char.info", raw = '{"capname":"Censant"}', documented_only = true },
  { event = "receive", name = "char.vitals", raw = VITALS },
  { event = "receive", name = "room.info", raw = '{"identifier":"' .. ROOM_ID .. '","name":"Combat Crib","visibility":1,"kind":"inside"}' },
  { event = "receive", name = "room.map", raw = MAP_RAW },
  { event = "receive", name = "room.writtenmap", raw = '"A door north of here and the limit of your vision is here.\\n"' },
  -- a second vitals push after the clock advances: drives the xp-rate math
  { event = "tick", seconds = 3600 },
  { event = "receive", name = "char.vitals", raw = '{"alignment":"neutral","maxhp":500,"hp":500,"xp":25284,"maxgp":50,"burden":9,"gp":50}' },
  { event = "receive", name = "room.info", raw = '{"identifier":"' .. ROOM_ID .. '","name":"Combat Crib","visibility":1,"kind":"inside"}' },
}
