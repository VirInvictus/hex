-- tests/golden/routes.lua: route-golden pairs (docs/phase-8-engineering.md §2).
-- COMMITTED per Brandon's 2026-11-06 confirmation: rooms.db derives from
-- tt_dw's public-domain map, so the fixtures are legally clean. They are
-- still LOCAL-ONLY to RUN (the layer needs rooms.db, which CI does not
-- have); regen_goldens.py --routes checks/records them in the local ritual.
--
-- Vnums keep the pairs deterministic (name resolution is the resolver's
-- concern, pinned separately by its own tests). Two positive routes (both
-- directions of the known Drum->Djel pair exercise tie-breaking), two
-- negative routes pin the measured unreachable pins from the HEX_GOLDEN
-- suite as rendered output ("no route").

return {
  { name = "drum_to_djel", from = 4659, to = 12472 },
  { name = "djel_to_drum", from = 12472, to = 4659 },
  { name = "bp_palace_unreachable", from = 4659, to = 5898 },
  { name = "genua_unreachable", from = 4659, to = 11279 },
}
