#!/usr/bin/env python3
"""Convert the tt_dw TinTin++ map file into Hex's room database.

Reads discworld.map (tintin #map write format, format version 20231) plus the
gates/origins helper tables, and writes a SQLite database keyed by vnum with
the MUD's 40-hex room identifier as an indexed column. Reads third-party data
and writes only Hex's own database; run again after pulling map updates.

Usage: python3 tools/convert_map.py [--map PATH] [--gates PATH] [--origins PATH] [--out PATH]
Defaults: ~/.gitrepos/tt_dw/map/{discworld.map,gates.tin,origins.tin}, out ~/.local/share/hex/rooms.db

Room record fields (tintin #map write, empirical field map):
  R {vnum}{flags}{color}{name}{symbol}{note}{area}{data}{terrain}{extra}{weight}{room_id}
  E {dest}{name}{command}{dir_bitmask}{flag}{?}{distance}{?}{weight}   (belongs to the last R)
  (the 10th room field holds tintin list data such as {{shape}{3}}; stored raw)
"""

import argparse
import os
import sqlite3
import sys

DEFAULT_MAP = os.path.expanduser("~/.gitrepos/tt_dw/map/discworld.map")
DEFAULT_GATES = os.path.expanduser("~/.gitrepos/tt_dw/map/gates.tin")
DEFAULT_ORIGINS = os.path.expanduser("~/.gitrepos/tt_dw/map/origins.tin")
DEFAULT_OUT = os.path.expanduser("~/.local/share/hex/rooms.db")


def parse_fields(line):
    """Yield every brace-delimited field on a record line, nesting-aware.

    Tintin escapes literal braces with backslashes; nested data such as
    ``{{shape}{3}}`` is one field whose content keeps its inner braces.
    """
    fields = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == "\\":
            i += 2
            continue
        if c != "{":
            i += 1
            continue
        depth = 1
        i += 1
        buf = []
        while i < n and depth:
            c = line[i]
            if c == "\\":
                buf.append(line[i : i + 2])
                i += 2
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            buf.append(c)
            i += 1
        fields.append("".join(buf))
    return fields


def parse_map(path):
    """Parse a discworld.map file into (rooms, exits) lists of dicts.

    Exits belong to the room record that precedes them (tintin writes each
    room followed by its exit set).
    """
    rooms, exits = [], []
    current = None
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or "{" not in line:
                continue
            head = line[: line.index("{")].strip()
            fields = parse_fields(line)
            if head == "R" and len(fields) >= 12:
                vnum, flags = int(fields[0]), int(fields[1] or 0)
                color, name, symbol, note, area, data, terrain, _, weight, room_id = (
                    fields[2:12]
                )
                current = {
                    "vnum": vnum,
                    "flags": flags,
                    "color": color,
                    "name": name,
                    "symbol": symbol,
                    "note": note,
                    "area": area,
                    "data": data,
                    "terrain": terrain,
                    "weight": float(weight or 1.0),
                    "room_id": room_id or None,
                }
                rooms.append(current)
            elif head == "E" and len(fields) >= 7 and current is not None:
                exits.append(
                    {
                        "from_vnum": current["vnum"],
                        "dest": int(fields[0]),
                        "name": fields[1],
                        "command": fields[2],
                        "dir": fields[3],
                        "flag": fields[4],
                        "distance": float(fields[6] or 1.0),
                    }
                )
    return rooms, exits


def parse_tin_pairs(path):
    """Parse a #var helper table ({a}{b} pairs per line) from gates/origins."""
    pairs = []
    if not os.path.exists(path):
        return pairs
    with open(path, encoding="utf-8") as f:
        for raw in f:
            fields = parse_fields(raw.rstrip("\n"))
            for i in range(0, len(fields) - 1, 2):
                pairs.append((fields[i], fields[i + 1]))
    return pairs


def build_db(out_path, rooms, exits, gates, origins):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    if os.path.exists(out_path):
        os.remove(out_path)
    conn = sqlite3.connect(out_path)
    conn.executescript(
        """
        CREATE TABLE rooms (
            vnum INTEGER PRIMARY KEY,
            flags INTEGER,
            color TEXT, name TEXT, symbol TEXT, note TEXT,
            area TEXT, data TEXT, terrain TEXT,
            weight REAL,
            room_id TEXT
        );
        CREATE TABLE exits (
            from_vnum INTEGER, dest INTEGER,
            name TEXT, command TEXT, dir INTEGER, flag INTEGER, distance REAL
        );
        CREATE TABLE gates (vnum INTEGER, exit TEXT);
        CREATE TABLE origins (area TEXT, room_name TEXT);
        CREATE INDEX idx_rooms_roomid ON rooms(room_id);
        CREATE INDEX idx_rooms_name ON rooms(name);
        CREATE INDEX idx_exits_from ON exits(from_vnum);
        CREATE INDEX idx_exits_dest ON exits(dest);
        """
    )
    conn.executemany(
        "INSERT INTO rooms VALUES (:vnum, :flags, :color, :name, :symbol, :note, :area, :data, :terrain, :weight, :room_id)",
        rooms,
    )
    conn.executemany(
        "INSERT INTO exits VALUES (:from_vnum, :dest, :name, :command, :dir, :flag, :distance)",
        exits,
    )
    conn.executemany("INSERT INTO gates VALUES (?, ?)", gates)
    conn.executemany("INSERT INTO origins VALUES (?, ?)", origins)
    conn.commit()
    conn.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--map", default=DEFAULT_MAP)
    ap.add_argument("--gates", default=DEFAULT_GATES)
    ap.add_argument("--origins", default=DEFAULT_ORIGINS)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args(argv)

    if not os.path.exists(args.map):
        print(f"map file not found: {args.map}", file=sys.stderr)
        return 1

    rooms, exits = parse_map(args.map)
    gates = parse_tin_pairs(args.gates)
    origins = parse_tin_pairs(args.origins)
    build_db(args.out, rooms, exits, gates, origins)

    identified = sum(1 for r in rooms if r["room_id"])
    print(f"rooms:      {len(rooms)}")
    print(f"identified: {identified} (40-hex or shared-instance id)")
    print(f"exits:      {len(exits)}")
    print(f"gates:      {len(gates)}  origins: {len(origins)}")
    print(f"wrote:      {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
