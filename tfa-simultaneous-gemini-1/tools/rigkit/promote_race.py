"""Make a repainted race pack the race's default, keeping the old painting as a variant.

    python -m tools.rigkit.promote_race <race> [<race> ...] [--from tilt15] [--drop tilt15,...]

For each race:  <race>/default  ->  <race>/legacy      (nothing is lost; comparisons stay possible)
                <race>/<from>   ->  <race>/default
Godot's .import files move with their PNGs and have their paths rewritten. --drop removes other
variants of the race that the promotion makes pointless (an earlier pilot of the same repaint).

Refused when <race>/legacy already exists, or when <from> inherits from default (it would then
inherit from itself). Re-skin variants that inherit `default` (orc/ashen) are listed: they were
painted on the OLD canvas and must be made again on the new one (tools.rigkit.reskin).

Afterwards: build_race, check, export_parity, and one Godot --import.
"""
import argparse
import os
import shutil
import sys

from . import core


def _retarget(folder, race, old, new):
    """Rewrite res:// paths in a moved folder's .import files and the pack's variant name."""
    a, b = "/races/%s/%s/" % (race, old), "/races/%s/%s/" % (race, new)
    for name in os.listdir(folder):
        if name.endswith(".import"):
            p = os.path.join(folder, name)
            with open(p, "r", encoding="utf-8", newline="") as f:
                text = f.read()
            if a in text:
                with open(p, "w", encoding="utf-8", newline="") as f:
                    f.write(text.replace(a, b))
    p = os.path.join(folder, "race.json")
    data = core.load_json(p)
    data["variant"] = new
    if new == "default":
        data["promoted_from"] = old
    core.save_json(p, data)


def promote(race, src="tilt15", drop=()):
    base = os.path.join(core.RIGS, "races", race)
    d_default, d_legacy, d_src = (os.path.join(base, v) for v in ("default", "legacy", src))
    if os.path.exists(d_legacy):
        raise SystemExit("%s/legacy exists: already promoted" % race)
    for d in (d_default, d_src):
        if not os.path.exists(os.path.join(d, "race.json")):
            raise SystemExit("no pack %s" % os.path.relpath(d, core.ROOT))
    if core.load_json(os.path.join(d_src, "race.json")).get("inherits"):
        raise SystemExit("%s/%s inherits from another variant; make it a standalone pack first" % (race, src))
    os.rename(d_default, d_legacy)
    os.rename(d_src, d_default)
    _retarget(d_legacy, race, "default", "legacy")
    _retarget(d_default, race, src, "default")
    for v in drop:
        d = os.path.join(base, v)
        if os.path.isdir(d):
            shutil.rmtree(d)
            print("      removed %s/%s" % (race, v))
    stale = []
    for v in sorted(os.listdir(base)):
        p = os.path.join(base, v, "race.json")
        if v not in ("default", "legacy") and os.path.exists(p) and core.load_json(p).get("inherits") == "default":
            stale.append(v)
    print("[ok ] %s: %s -> default, old default -> legacy" % (race, src))
    for v in stale:
        print("      %s/%s inherits default and was made for the OLD painting: make it again" % (race, v))
    return stale


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("races", nargs="+")
    ap.add_argument("--from", dest="src", default="tilt15")
    ap.add_argument("--drop", default="")
    a = ap.parse_args(argv)
    for r in a.races:
        promote(r, a.src, [v for v in a.drop.split(",") if v])
    return 0


if __name__ == "__main__":
    sys.exit(main())
