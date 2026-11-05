-- hex_rooms.lua: current-room tracking fed by room.info GMCP. The 40-hex
-- identifier is the join key between the MUD, Hex's rooms.db and Quow's
-- database. Pure state helpers; database execution lives in hex_commands.
local M = {}

function M.new()
  return { id = nil, name = nil, terrain = nil, previous = nil }
end

-- Merge a decoded room.info payload. Wire format confirmed live (2026-11-05):
-- {"identifier": "40-hex", "name": "...", "visibility": 1, "kind": "inside"}
-- the MUD calls the terrain "kind"; 'terrain'/'room_id' stay accepted as
-- fallbacks.
function M.update(st, data)
  if type(data) ~= "table" then
    return
  end
  local id = data.identifier or data.room_id
  if id and id ~= st.id then
    st.previous = st.id
  end
  if id then
    st.id = id
  end
  if data.name then
    st.name = data.name
  end
  if data.kind or data.terrain then
    st.terrain = data.kind or data.terrain
  end
end

return M
