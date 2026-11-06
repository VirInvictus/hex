-- tests/golden/synthetic.sql: authored Quow-schema rows for the synthetic
-- golden layer (docs/phase-8-engineering.md §2). Our own rows, committed.
-- Applied to a throwaway sqlite db by tools/regen_goldens.py; the committed
-- expectations under tests/golden/expected/ pin ordering (the article-
-- insensitive REPLACE), apostrophe escaping, empty fields, the sold/free/
-- loot price filters, the Shonky Shop exclusion, and the 31/61/41 result
-- caps. Column shapes mirror what the builders in src/hex_queries.lua read.

CREATE TABLE items (item_name TEXT, dollar_value TEXT, description TEXT, appraise_text TEXT, weight TEXT, special_find_note TEXT);
CREATE TABLE shop_items (room_id TEXT, item_name TEXT, sale_price TEXT);
CREATE TABLE npc_items (npc_id TEXT, item_name TEXT, sale_price TEXT);
CREATE TABLE npc_info (npc_id TEXT, npc_name TEXT, room_id TEXT);
CREATE TABLE rooms (room_id TEXT, room_short TEXT, name TEXT, area TEXT, terrain TEXT, note TEXT, map_id TEXT);

INSERT INTO rooms VALUES ('roomA', 'Temple of Cool', 'the Temple of Cool', 'Ankh-Morpork', 'inside', '', 1);
INSERT INTO rooms VALUES ('roomB', 'Shonky Shop', 'the Shonky Shop', 'Ankh-Morpork', 'inside', 'junk', 1);
INSERT INTO rooms VALUES ('roomC', 'Cabbage Warehouse', 'the Cabbage Warehouse', 'Cabbage Warehouse', 'inside', '', 41);
INSERT INTO rooms VALUES ('abc123', 'Combat Crib', 'the Combat Crib', 'Pumpkin Town', 'inside', '', 37);
INSERT INTO rooms VALUES ('it''s|pipe id', 'Pipe Room', 'the room with a pipe id', 'Ankh-Morpork', 'inside', '', 1);

-- ordering pins REPLACE(item_name, 'an ', 'a '): sorted output must be
-- 'an antique sword' BEFORE 'a sword'? No: 'an antique sword' -> 'a antique
-- sword' < 'a sword' < 'sword'. Empty fields pin the trailing-empty column.
INSERT INTO items VALUES ('sword', '5', 'a plain sword', 'it is a sword', '2lb', '');
INSERT INTO items VALUES ('a sword', '5', '', '', '', '');
INSERT INTO items VALUES ('an antique sword', '50', 'old blade', '', '1lb', '');
INSERT INTO items VALUES ('it''s a''quote', '', 'quote item', '', '', '');
INSERT INTO items VALUES ('Kleiner''s flask', '9', '', 'glassware', '', '');
INSERT INTO items VALUES ('pipe|in desc', '1', 'a|description', '', '', '');
INSERT INTO items VALUES ('cabbage (found)', '', '', '', '', 'found behind the gym in Bes Pelargic');
-- multi-term OR pins both terms matching after empty-term dropping
INSERT INTO items VALUES ('an apple', '2', 'fruit', '', '', '');
INSERT INTO items VALUES ('a banana', '1', 'fruit', '', '', '');

-- item cap fillers: item_plain searches "sword"; these push past LIMIT 31
INSERT INTO items VALUES ('cap sword 01', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 02', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 03', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 04', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 05', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 06', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 07', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 08', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 09', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 10', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 11', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 12', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 13', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 14', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 15', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 16', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 17', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 18', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 19', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 20', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 21', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 22', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 23', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 24', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 25', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 26', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 27', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 28', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 29', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 30', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 31', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 32', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 33', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 34', '1', '', '', '', '');
INSERT INTO items VALUES ('cap sword 35', '1', '', '', '', '');

INSERT INTO shop_items VALUES ('roomA', 'cabbage', '3p');
INSERT INTO shop_items VALUES ('roomA', 'free sample', '');
INSERT INTO shop_items VALUES ('roomA', 'loot crate', 'loot');
INSERT INTO shop_items VALUES ('roomA', 'found thing', 'found');
INSERT INTO shop_items VALUES ('roomB', 'shonky junk', '1p');
INSERT INTO shop_items VALUES ('roomB', 'shonky cabbage', '5p');
-- shop cap fillers: shop_union returns every roomA row; push past LIMIT 61
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 01', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 02', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 03', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 04', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 05', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 06', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 07', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 08', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 09', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 10', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 11', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 12', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 13', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 14', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 15', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 16', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 17', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 18', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 19', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 20', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 21', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 22', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 23', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 24', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 25', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 26', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 27', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 28', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 29', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 30', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 31', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 32', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 33', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 34', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 35', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 36', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 37', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 38', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 39', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 40', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 41', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 42', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 43', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 44', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 45', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 46', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 47', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 48', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 49', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 50', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 51', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 52', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 53', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 54', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 55', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 56', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 57', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 58', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 59', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 60', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 61', '1p');
INSERT INTO shop_items VALUES ('roomA', 'cap shop item 62', '1p');

INSERT INTO npc_info VALUES ('1', 'Greengrocer', 'roomA');
INSERT INTO npc_info VALUES ('2', 'Beggar', 'roomA');
INSERT INTO npc_info VALUES ('3', 'City Guard', 'roomC');
INSERT INTO npc_info VALUES ('4', 'Palace Guard', 'roomB');
INSERT INTO npc_items VALUES ('1', 'cabbage', '2p');
INSERT INTO npc_items VALUES ('2', 'free sample', 'free');
-- sources cap fillers: one npc selling many cabbage variants pushes past 41
INSERT INTO npc_items VALUES ('1', 'cabbage 01', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 02', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 03', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 04', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 05', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 06', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 07', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 08', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 09', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 10', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 11', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 12', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 13', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 14', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 15', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 16', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 17', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 18', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 19', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 20', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 21', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 22', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 23', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 24', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 25', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 26', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 27', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 28', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 29', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 30', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 31', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 32', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 33', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 34', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 35', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 36', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 37', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 38', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 39', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 40', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 41', '2p');
INSERT INTO npc_items VALUES ('1', 'cabbage 42', '2p');
