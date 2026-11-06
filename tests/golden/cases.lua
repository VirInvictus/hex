-- tests/golden/cases.lua: golden-test inputs (docs/phase-8-engineering.md §2).
-- Committed data covering every builder branch: plain/anchors/wildcards/
-- exact/field-prefix/multi-term item queries, npc bare + room filter, the
-- shop union, the three source flags, where/zone lookups, and escaping
-- (apostrophes and pipes, the result-field separator).
--
-- Design note: the phase-8 doc sketched cases.json, but the Lua-side dump
-- helper would then need a JSON parser; cases.lua keeps the zero-dependency
-- rule. Same content, plainer plumbing.

return {
  { name = "item_plain", kind = "item", input = "sword" },
  { name = "item_anchors", kind = "item", input = "^apple$" },
  { name = "item_wildcards", kind = "item", input = "sw?rd*" },
  { name = "item_exact_quote", kind = "item", input = "it's a'quote", exact = true },
  { name = "item_field_prefixes", kind = "item", input = "desc:shiny, mat:iron, sheat:drum" },
  { name = "item_multi_term_or", kind = "item", input = "apple, , banana" },
  { name = "npc_bare", kind = "npc", input = "guard" },
  { name = "npc_room_filter", kind = "npc", input = "room:abc123 it's" },
  -- shop_union exercises the synthetic rows (roomA); shop_real pins a real
  -- 40-hex id for the recorded layer (synthetic-layer output is empty there)
  { name = "shop_union", kind = "shop", room_id = "roomA" },
  { name = "shop_real", kind = "shop", room_id = "917446ff80d14cacf75b035961cc89303d3d51e9" },
  { name = "sources_all", kind = "sources", input = "cabbage" },
  { name = "sources_sold", kind = "sources", input = "cabbage", flag = "sold" },
  { name = "sources_free", kind = "sources", input = "cabbage", flag = "free" },
  { name = "sources_loot", kind = "sources", input = "cabbage", flag = "loot" },
  { name = "where_escaping", kind = "where", room_id = "it's|pipe id", db = "hex_rooms" },
  { name = "zone_lookup", kind = "zone", room_id = "abc123" },
}
