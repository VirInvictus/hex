"""Tests for tools/convert_map.py (stdlib unittest). Run from the repo root:
python3 -m unittest discover -s tests
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import convert_map  # noqa: E402

SAMPLE = """V 20231
F 1
L {legend}
R {1}{0}{}{path to an unusual cottage}{}{}{Agnes Nitt's Cottage}{}{street}{}{1.000}{98abb82010ec2737bcb6c560532cb20c8aca6398}
E {2}{n}{n}{1}{0}{}{1.000}{}{0.00}
R {42}{0}{<fca>}{Ephebian Embassy}{}{services: money changer}{Ankh-Morpork}{services: bank}{inside}{}{1.000}{a1e08c1c268466b4718a7fbd2254d93466aa32ea}
E {1}{s}{s}{4}{0}{}{1.000}{}{0.00}
R {5097}{0}{<bba>}{Library}{ }{}{Unseen University Library}{}{inside}{{shape}{3}}{1.000}{UULibrary}
"""


class TestParseFields(unittest.TestCase):
    def test_simple_fields(self):
        self.assertEqual(
            convert_map.parse_fields("{1}{0}{}{name}"), ["1", "0", "", "name"]
        )

    def test_nested_field_keeps_inner_braces(self):
        self.assertEqual(
            convert_map.parse_fields("{{shape}{3}}{x}"), ["{shape}{3}", "x"]
        )

    def test_escaped_brace_stays_in_field(self):
        self.assertEqual(convert_map.parse_fields(r"{a\{b}{c}"), ["a\\{b", "c"])


class TestParseMap(unittest.TestCase):
    def setUp(self):
        fd, path = tempfile.mkstemp(suffix=".map")
        with os.fdopen(fd, "w") as f:
            f.write(SAMPLE)
        self.rooms, self.exits = convert_map.parse_map(path)
        os.unlink(path)

    def test_room_count_and_identity(self):
        self.assertEqual(len(self.rooms), 3)
        self.assertEqual(
            self.rooms[0]["room_id"], "98abb82010ec2737bcb6c560532cb20c8aca6398"
        )
        self.assertEqual(self.rooms[1]["area"], "Ankh-Morpork")

    def test_room_details(self):
        self.assertEqual(self.rooms[0]["terrain"], "street")
        # the nested {{shape}{3}} sits in the mystery 10th field; it must not
        # corrupt the parse (terrain/weight/room_id all stay in place)
        self.assertEqual(self.rooms[2]["terrain"], "inside")
        self.assertEqual(self.rooms[2]["weight"], 1.0)

    def test_exits_attach_to_preceding_room(self):
        self.assertEqual(len(self.exits), 2)
        self.assertEqual(self.exits[0]["from_vnum"], 1)
        self.assertEqual(self.exits[0]["dest"], 2)
        self.assertEqual(self.exits[1]["from_vnum"], 42)

    def test_shared_instance_id_is_kept(self):
        self.assertEqual(self.rooms[2]["room_id"], "UULibrary")

    def test_extra_field_keeps_tintin_list(self):
        self.assertEqual(self.rooms[2]["extra"], "{shape}{3}")


class TestTinPairs(unittest.TestCase):
    def test_pairs(self):
        fd, path = tempfile.mkstemp(suffix=".tin")
        with os.fdopen(fd, "w") as f:
            f.write("#var MAP_GATES {\n{1}{north}\n{5}{east}\n}\n")
        self.assertEqual(
            convert_map.parse_tin_pairs(path), [("1", "north"), ("5", "east")]
        )
        os.unlink(path)


class TestBuildDb(unittest.TestCase):
    def test_roundtrip(self):
        fd, out = tempfile.mkstemp(suffix=".db")
        os.unlink(out)
        rooms, exits = (
            [
                {
                    "vnum": 1,
                    "flags": 0,
                    "color": "",
                    "name": "cottage",
                    "symbol": "",
                    "note": "",
                    "area": "AM",
                    "data": "",
                    "terrain": "street",
                    "extra": "",
                    "weight": 1.0,
                    "room_id": "a" * 40,
                }
            ],
            [
                {
                    "from_vnum": 1,
                    "dest": 2,
                    "name": "n",
                    "command": "n",
                    "dir": 1,
                    "flag": 0,
                    "distance": 1.0,
                }
            ],
        )
        convert_map.build_db(out, rooms, exits, [("1", "north")], [("AM", "cottage")])
        import sqlite3

        conn = sqlite3.connect(out)
        self.assertEqual(conn.execute("SELECT count(*) FROM rooms").fetchone()[0], 1)
        self.assertEqual(
            conn.execute("SELECT room_id FROM rooms").fetchone()[0], "a" * 40
        )
        self.assertEqual(conn.execute("SELECT count(*) FROM exits").fetchone()[0], 1)
        conn.close()
        os.unlink(out)


if __name__ == "__main__":
    unittest.main()
