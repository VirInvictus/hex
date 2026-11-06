"""Tests for tools/convert_mdtdata.py (stdlib unittest). Run from the repo root:
python3 -m unittest discover -s tests
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import convert_mdtdata as c


class TestSplitTopLevel(unittest.TestCase):
    def test_plain_alternation(self):
        self.assertEqual(c.split_top_level("a|b|c"), ["a", "b", "c"])

    def test_pipe_inside_parens_stays_in_entry(self):
        self.assertEqual(
            c.split_top_level("(deep|washed-out) ($mdt_colors)|old"),
            ["(deep|washed-out) ($mdt_colors)", "old"],
        )

    def test_empty_entries_dropped(self):
        self.assertEqual(c.split_top_level("a||b|"), ["a", "b"])


class TestParseSource(unittest.TestCase):
    def setUp(self):
        self.src = (
            "#var mdt_colors {black|white};\n"
            "#cat mdt_colors {|blue};\n"
            "#var a {Tsortean|Brindisian};\n"
            "#cat a {|(deep|washed-out) ($mdt_colors)};\n"
        )
        fd, path = tempfile.mkstemp(suffix=".tin")
        with os.fdopen(fd, "w") as f:
            f.write(self.src)
        self.colours, self.entries = c.parse_source(path)
        os.unlink(path)

    def test_colors_collected_across_var_and_cat(self):
        self.assertEqual(self.colours, ["black", "white", "blue"])

    def test_entries_bracket_aware(self):
        self.assertEqual(
            self.entries, ["Tsortean", "Brindisian", "(deep|washed-out) ($mdt_colors)"]
        )


class TestLuaStr(unittest.TestCase):
    def test_escapes_backslash_and_quote(self):
        self.assertEqual(c.lua_str("well( |-)\\w+"), '"well( |-)\\\\w+"')
        self.assertEqual(c.lua_str('d"reg'), '"d\\"reg"')


if __name__ == "__main__":
    unittest.main()
