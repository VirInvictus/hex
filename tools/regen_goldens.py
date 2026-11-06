#!/usr/bin/env python3
"""Golden-test engine for Hex's Quow query builders (docs/phase-8-engineering.md §2).

Three layers:
  * SQL goldens (committed, byte-exact builder output)      --check
  * synthetic row goldens (committed rows + expectations)   --check --synthetic
  * recorded row goldens (real Quow DB, LOCAL-ONLY)         --check --recorded

The builders are never re-implemented here: tools/dump_golden_sql.lua prints
each case's SQL and this tool diffs/runs it. Row execution deliberately goes
through the sqlite3 CLI (batch, pipe-joined rows) because that is the exact
form production gets from blightmud's core.exec; Python's sqlite3 module
would hand back tuples and defeat the parity.

Recorded goldens live in tests/golden/recorded/ (gitignored): Quow's
database is third-party data, so only local runs touch it. Their provenance
header pins the DB fingerprint; --check --recorded warns on mismatch (Quow
was refreshed) and --strict fails on it (the pre-tag ritual).

Usage (from the repo root):
  python3 tools/regen_goldens.py --check                  # SQL layer
  python3 tools/regen_goldens.py --check --synthetic      # + synthetic rows (CI)
  python3 tools/regen_goldens.py --record --synthetic     # (re)author sql/ + expected/
  python3 tools/regen_goldens.py --check --recorded       # local, real Quow DB
  python3 tools/regen_goldens.py --record --recorded      # after a Quow refresh
  python3 tools/regen_goldens.py --check --recorded --strict
  python3 tools/regen_goldens.py --recorded-db <path>
"""

import argparse
import datetime
import difflib
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "tests" / "golden"
SQL_DIR = GOLDEN / "sql"
EXPECTED_DIR = GOLDEN / "expected"
RECORDED_DIR = GOLDEN / "recorded"
ROUTES_DIR = GOLDEN / "routes"
SYNTHETIC_SQL = GOLDEN / "synthetic.sql"
ROUTES_RUNNER = GOLDEN / "run_routes.lua"
DUMP_HELPER = ROOT / "tools" / "dump_golden_sql.lua"
DEFAULT_QUOW_DB = os.path.expanduser("~/.local/share/hex/quow.db")
DEFAULT_ROOMS_DB = os.path.expanduser("~/.local/share/hex/rooms.db")
RECORDED_MAX_AGE_DAYS = 60

PROVENANCE_HEADER = (
    "# recorded golden: {name}\n"
    "# recorded: {stamp}\n"
    "# tool: sqlite3 CLI via tools/regen_goldens.py\n"
    "# sqlite3: {sqlite3_version}\n"
    "# db: {db_path}\n"
    "# db sha256 (16 hex): {fingerprint}\n"
    "# db size: {db_size} bytes\n"
)


def lua_binary():
    """Resolve a Lua interpreter: runners install lua5.4, locals may only
    have lua (the dump helper is version-agnostic)."""
    for name in ("lua5.4", "lua"):
        path = shutil.which(name)
        if path:
            return path
    sys.exit("no lua interpreter found (need lua5.4 or lua on PATH)")


def dump_sql():
    """Get {name: (db, sql)} from the Lua helper (single source of builder truth)."""
    result = subprocess.run(
        [lua_binary(), str(DUMP_HELPER)],
        check=False,
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"dump helper failed:\n{result.stderr}")
    cases = {}
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        name, db, sql = line.split("\t", 2)
        cases[name] = (db, sql)
    return cases


def sqlite3_run(db_path, sql):
    """Run SQL through the sqlite3 CLI exactly as production's core.exec does."""
    result = subprocess.run(
        ["sqlite3", "-batch", str(db_path)],
        check=False,
        input=sql,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"sqlite3 failed on {db_path}:\n{result.stderr}")
    return result.stdout


def diff_note(path, expected_text, actual_text):
    delta = difflib.unified_diff(
        expected_text.splitlines(keepends=True),
        actual_text.splitlines(keepends=True),
        fromfile=f"{path} (committed)",
        tofile=f"{path} (actual)",
    )
    return "".join(delta)


def strip_provenance(text):
    return "".join(
        line for line in text.splitlines(keepends=True) if not line.startswith("# ")
    )


def db_fingerprint(db_path):
    digest = hashlib.sha256()
    with open(db_path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()[:16], os.path.getsize(db_path)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--check", action="store_true", help="verify committed goldens (SQL layer)"
    )
    ap.add_argument(
        "--synthetic", action="store_true", help="include the synthetic row layer"
    )
    ap.add_argument(
        "--record", action="store_true", help="(re)author goldens instead of checking"
    )
    ap.add_argument(
        "--recorded",
        action="store_true",
        help="include the recorded layer (local Quow DB)",
    )
    ap.add_argument(
        "--routes",
        action="store_true",
        help="include the route layer (committed fixtures; needs rooms.db to run)",
    )
    ap.add_argument(
        "--recorded-db", default=DEFAULT_QUOW_DB, help="path to the real Quow DB"
    )
    ap.add_argument(
        "--rooms-db",
        default=DEFAULT_ROOMS_DB,
        help="path to Hex's rooms.db (the where_escaping case targets it)",
    )
    ap.add_argument(
        "--strict",
        action="store_true",
        help="fail (not warn) on a stale recorded fingerprint",
    )
    args = ap.parse_args()
    if not (args.check or args.record):
        ap.error("nothing to do: pass --check and/or --record")

    cases = dump_sql()
    failures = []

    # --- layer 1: SQL goldens (byte-exact builder output) ---
    for name, (_db, sql) in cases.items():
        path = SQL_DIR / f"{name}.sql"
        if args.record:
            SQL_DIR.mkdir(parents=True, exist_ok=True)
            path.write_text(sql, encoding="utf-8")
            print(f"recorded sql: {name}")
        else:
            if not path.exists():
                failures.append(
                    f"sql golden missing: {path} (run --record --synthetic)"
                )
            elif path.read_text(encoding="utf-8") != sql:
                failures.append(
                    f"sql golden drifted: {name}\n{diff_note(path, path.read_text(encoding='utf-8'), sql)}"
                )

    # --- layer 2: synthetic rows through the sqlite3 CLI ---
    if args.synthetic:
        with tempfile.TemporaryDirectory() as tmp:
            db_path = pathlib.Path(tmp) / "synthetic.db"
            sqlite3_run(db_path, SYNTHETIC_SQL.read_text(encoding="utf-8"))
            for name, (_db, sql) in cases.items():
                out = sqlite3_run(db_path, sql)
                path = EXPECTED_DIR / f"{name}.txt"
                if args.record:
                    EXPECTED_DIR.mkdir(parents=True, exist_ok=True)
                    path.write_text(out, encoding="utf-8")
                    print(f"recorded synthetic: {name}")
                else:
                    if not path.exists():
                        failures.append(f"synthetic expectation missing: {path}")
                    elif path.read_text(encoding="utf-8") != out:
                        failures.append(
                            f"synthetic golden drifted: {name}\n{diff_note(path, path.read_text(encoding='utf-8'), out)}"
                        )

    # --- layer 3: recorded rows against the real databases (local-only) ---
    # each case runs against the db production routes it to: the cases' db
    # tag is "quow" (default) or "hex_rooms" (build_where_query reads Hex's
    # own rooms.db, whose schema differs from Quow's)
    if args.recorded:
        dbs = {
            "quow": args.recorded_db,
            "hex_rooms": args.rooms_db,
        }
        for tag, path_db in dbs.items():
            if not os.path.exists(path_db):
                sys.exit(f"recorded layer: {tag} DB not found at {path_db}")
        fingerprints = {tag: db_fingerprint(path_db) for tag, path_db in dbs.items()}
        age_days = (
            datetime.datetime.now()
            - datetime.datetime.fromtimestamp(os.path.getmtime(args.recorded_db))
        ).days
        if age_days > RECORDED_MAX_AGE_DAYS:
            print(
                f"warning: Quow DB is {age_days} days old (staleness threshold {RECORDED_MAX_AGE_DAYS})"
            )
        sqlite3_version = subprocess.run(
            ["sqlite3", "--version"], check=False, capture_output=True, text=True
        ).stdout.split()[0]
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        RECORDED_DIR.mkdir(parents=True, exist_ok=True)
        for name, (db_tag, sql) in cases.items():
            db_path = dbs.get(db_tag)
            if db_path is None:
                sys.exit(f"case {name}: unknown db tag '{db_tag}'")
            out = sqlite3_run(db_path, sql)
            fingerprint, db_size = fingerprints[db_tag]
            header = PROVENANCE_HEADER.format(
                name=name,
                stamp=stamp,
                sqlite3_version=sqlite3_version,
                db_path=db_path,
                fingerprint=fingerprint,
                db_size=db_size,
            )
            path = RECORDED_DIR / f"{name}.txt"
            if args.record:
                path.write_text(header + out, encoding="utf-8")
                print(f"recorded: {name}")
                continue
            if not path.exists():
                failures.append(
                    f"recorded golden missing: {path} (run --record --recorded once, locally)"
                )
                continue
            committed = path.read_text(encoding="utf-8")
            committed_fp = ""
            for line in committed.splitlines():
                if line.startswith("# db sha256"):
                    committed_fp = line.rsplit(" ", 1)[1]
            if committed_fp != fingerprint:
                msg = f"recorded fingerprint changed: {name} (db sha {committed_fp} -> {fingerprint}; DB refreshed?)"
                if args.strict:
                    failures.append(msg)
                else:
                    print(
                        f"warning: {msg} (rerun --record --recorded and REVIEW THE DIFF)"
                    )
            body_diff = diff_note(path, strip_provenance(committed), out)
            if body_diff:
                failures.append(f"recorded output drifted: {name}\n{body_diff}")

    # --- layer 4: route goldens (committed fixtures; local-only to RUN) ---
    # rooms.db derives from tt_dw's public-domain map, so the fixtures are
    # committable (confirmed 2026-11-06), but running them needs rooms.db,
    # which CI does not have: this layer rides the local ritual beside the
    # recorded one, not the CI gate.
    if args.routes:
        if not os.path.exists(args.rooms_db):
            sys.exit(
                f"route layer: rooms.db not found at {args.rooms_db} (pass --rooms-db)"
            )
        result = subprocess.run(
            [lua_binary(), str(ROUTES_RUNNER), args.rooms_db],
            check=False,
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            sys.exit(f"route runner failed:\n{result.stderr}")
        sections = {}
        current = None
        for line in result.stdout.splitlines():
            if line.startswith("=== ") and line.endswith(" ==="):
                current = line[4:-4]
                sections[current] = []
            elif current:
                sections[current].append(line)
        ROUTES_DIR.mkdir(parents=True, exist_ok=True)
        for name, lines in sections.items():
            path = ROUTES_DIR / f"{name}.txt"
            out = "\n".join(lines) + "\n"
            if args.record:
                path.write_text(out, encoding="utf-8")
                print(f"recorded route: {name}")
            elif not path.exists():
                failures.append(f"route golden missing: {path} (run --record --routes)")
            elif path.read_text(encoding="utf-8") != out:
                failures.append(
                    f"route golden drifted: {name}\n{diff_note(path, path.read_text(encoding='utf-8'), out)}"
                )

    if failures:
        print(f"\n{len(failures)} golden failure(s):", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        sys.exit(1)
    print("goldens ok")


if __name__ == "__main__":
    main()
