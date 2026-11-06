#!/usr/bin/env python3
"""Convert tt_dw's magic/spelldata.tin into Hex's committed spell dataset.

Dev-time tool (stdlib only): parses the read-only tt_dw clone and emits
src/hex_spelldata.lua (~130 KB). The dataset is COMMITTED (unlike rooms.db)
because /add_plugin installs must work without a tt_dw clone; shipped static
data is source, runtime data stays in ~/.local/share/hex.

Validation (docs/phase-4-magic.md §4): 117 spells; every spellcheck stage
has exactly 10 strictly ascending thresholds; every stage shorthand resolves
through spellskills; type in {Offensive, Defensive, Miscellaneous}; counts
octogram 93, tome 93, learnt_at 25. The attribution header ships verbatim.

Usage: python3 tools/convert_spelldata.py [--spelldata PATH] [--out PATH]
"""

import argparse
import os
import sys

DEFAULT_SRC = os.path.expanduser("~/.gitrepos/tt_dw/scripts/magic/spelldata.tin")
DEFAULT_OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "src",
    "hex_spelldata.lua",
)

ATTRIBUTION = [
    "-- Spell info grabbed from the wiki;",
    "-- Spellcheck skills pilfered from Quow's plugin;",
    "-- (spellcheck data needs to include stage no to work as TinTin++ var);",
]

TYPES = {"Offensive", "Defensive", "Miscellaneous"}
EXPECTED_SPELLS = 117
EXPECTED_STAGE_LEN = 10
EXPECTED_COUNTS = {"octogram": 93, "tome": 93, "learnt_at": 25}
STRING_FIELDS = (
    "name",
    "nick",
    "description",
    "type",
    "gp",
    "size",
    "octogram",
    "tome",
    "learnt_at",
    "notes",
    "components",
)


def parse_fields(line):
    """Yield every brace-delimited field on a record line, nesting-aware
    (same scanner as tools/convert_map.py; tintin escapes braces)."""
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


def depth_delta(line):
    """Net brace depth change on a line, escape-aware."""
    delta = 0
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == "\\":
            i += 2
            continue
        if c == "{":
            delta += 1
        elif c == "}":
            delta -= 1
        i += 1
    return delta


def parse_spelldata(path):
    """Parse spellskills, spellprimaries, spellinfos into dicts."""
    skills, primaries, spells, order = {}, {}, {}, []
    section = None
    depth = 0
    spell = None  # spell under construction
    pending_field = None  # a field whose value list opened ({spellcheck} {)
    stages = None  # spellcheck stage list while it is open
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if section is None:
                if stripped.startswith("#var spellskills"):
                    section, depth = "skills", depth_delta(line)
                elif stripped.startswith("#var spellprimaries"):
                    section, depth = "primaries", depth_delta(line)
                elif stripped.startswith("#var spellinfos"):
                    section, depth = "spells", depth_delta(line)
                continue
            if stripped.startswith(("#nop", "#class")) or not stripped:
                continue
            depth += depth_delta(line)
            fields = parse_fields(line)
            if depth <= 0:
                if section == "spells" and spell is not None:
                    spells[spell["nick"]] = spell
                    order.append(spell["nick"])
                section, spell, pending_field, stages = None, None, None, None
                depth = 0
                continue
            if section == "skills":
                if len(fields) >= 2:
                    skills[fields[0]] = fields[1]
            elif section == "primaries":
                if len(fields) >= 2:
                    primaries[fields[0]] = [s for s in fields[1].split(";") if s]
            elif section == "spells":
                # depth 1: spell boundary lines ({nick} opens, } closes);
                # depth >= 2: inside a spell body
                if depth == 1:
                    if fields:
                        # a spell may carry several nicknames ({cmseq cms2});
                        # the first token is the dataset key
                        spell_key = fields[0].split()[0]
                        spell = {"nick": fields[0]}
                    elif spell is not None:
                        # two upstream spells share the nickname jmc; suffix
                        # collisions deterministically
                        key = spell_key
                        while key in spells:
                            key = key + "_2"
                        spells[key] = spell
                        order.append(key)
                        spell, spell_key, pending_field, stages = None, None, None, None
                    continue
                if spell is None:
                    continue
                if pending_field == "spellcheck":
                    if fields and ":" in fields[0]:
                        num, short = fields[0].split(":", 1)
                        stages.append(
                            {
                                "stage": int(num),
                                "skill": short,
                                "thresholds": [
                                    int(x) for x in fields[1].split(";") if x
                                ],
                            }
                        )
                    else:
                        spell["spellcheck"] = stages
                        pending_field, stages = None, None
                    continue
                if len(fields) == 1 and depth >= 3:
                    # {field} { opens a sub-list (only spellcheck does)
                    pending_field = fields[0]
                    stages = [] if pending_field == "spellcheck" else None
                elif len(fields) >= 2:
                    # an unclosed brace yields an empty trailing field, so
                    # "{spellcheck} {" arrives here with two fields
                    if fields[0] == "spellcheck":
                        pending_field, stages = "spellcheck", []
                    else:
                        spell[fields[0]] = fields[1]
    return skills, primaries, spells, order


def validate(skills, spells, order):
    errors = []
    if len(spells) != EXPECTED_SPELLS:
        errors.append(f"expected {EXPECTED_SPELLS} spells, got {len(spells)}")
    counts = {"octogram": 0, "tome": 0, "learnt_at": 0}
    for nick in order:
        sp = spells[nick]
        if sp.get("type") not in TYPES:
            errors.append(f"{nick}: bad type {sp.get('type')!r}")
        for field in EXPECTED_COUNTS:
            if field in sp:
                counts[field] += 1
        for st in sp.get("spellcheck") or []:
            if st["skill"] not in skills:
                errors.append(f"{nick}: unresolved shorthand {st['skill']!r}")
            t = st["thresholds"]
            if len(t) != EXPECTED_STAGE_LEN:
                errors.append(f"{nick} stage {st['stage']}: {len(t)} thresholds")
            if any(t[i] >= t[i + 1] for i in range(len(t) - 1)):
                errors.append(f"{nick} stage {st['stage']}: not strictly ascending")
    for field, expected in EXPECTED_COUNTS.items():
        if counts[field] != expected:
            errors.append(f"{field}: expected {expected}, got {counts[field]}")
    return errors


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def emit(skills, primaries, spells, order):
    out = []
    out.extend(ATTRIBUTION)
    out.append(
        "-- Generated by tools/convert_spelldata.py from tt_dw's magic/spelldata.tin"
    )
    out.append(
        "-- (public domain); committed so /add_plugin installs work without the clone."
    )
    out.append(
        "-- Do not hand-edit: regenerate. 117 spells; spellcheck stages carry the ten"
    )
    out.append(
        "-- ascending bonus thresholds (5th = 50% point, 1st = fail, 10th = success)."
    )
    out.append("local M = {}")
    out.append("")
    out.append("M.spellskills = {")
    for short in sorted(skills):
        out.append(f"  {short} = {lua_str(skills[short])},")
    out.append("}")
    out.append("")
    out.append("M.spellprimaries = {")
    for key in primaries:
        list_items = ", ".join(lua_str(s) for s in primaries[key])
        out.append(f"  [{lua_str(key)}] = {{ {list_items} }},")
    out.append("}")
    out.append("")
    out.append("M.order = {")
    for nick in order:
        out.append(f"  {lua_str(nick)},")
    out.append("}")
    out.append("")
    out.append("M.spells = {")
    for nick in order:
        sp = spells[nick]
        out.append(f"  [{lua_str(nick)}] = {{")
        for field in STRING_FIELDS:
            if field in sp:
                out.append(f"    {field} = {lua_str(sp[field])},")
        stages = sp.get("spellcheck") or []
        if stages:
            out.append("    spellcheck = {")
            for st in stages:
                thresholds = ", ".join(str(t) for t in st["thresholds"])
                out.append(
                    f"      {{ stage = {st['stage']}, skill = {lua_str(st['skill'])}, thresholds = {{ {thresholds} }} }},"
                )
            out.append("    },")
        out.append("  },")
    out.append("}")
    out.append("")
    out.append("return M")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--spelldata", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args(argv)

    if not os.path.exists(args.spelldata):
        print(f"spelldata.tin not found: {args.spelldata}", file=sys.stderr)
        return 1

    skills, primaries, spells, order = parse_spelldata(args.spelldata)
    errors = validate(skills, spells, order)
    if errors:
        for e in errors:
            print(f"validation: {e}", file=sys.stderr)
        return 1

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(emit(skills, primaries, spells, order))
    stage_count = sum(len(spells[n].get("spellcheck") or []) for n in order)
    print(
        f"spells: {len(spells)}  stages: {stage_count}  skills: {len(skills)}  primaries: {len(primaries)}"
    )
    print(f"wrote:  {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
