"""Pack the contract-3 open-water layer of every shipped structured map into
tests/fixtures/p3d_deep_water/c3_water_layers.json, the fixture
tests/deep_water_verdict_diff.gd grafts onto the shipped cells.json (P3-D).

  python tools/pack_c3_water_layers.py <dir of contract-3 <id>_cells.json> [--merge]
  python tools/pack_c3_water_layers.py --check

Run from the Godot project folder (tfa-simultaneous-gemini-1), or pass
--project. The contract-3 files come from TG (p3-rivers or later): a headless
dump (TG tools/headless_dump.gd) of each layout map and a windowed sandbox
export (TFA_ROOT = a sandbox, never this project) of each procedural one, at
--contract 3. For every format:"structured" row of data/Maps.json whose
cell_graph exists, <dir>/<id>_cells.json must equal the shipped cells.json in
every key but tile_water / tile_body (the graft is only valid when the layer
is the one difference: anything else refuses the pack).

A map whose SHIPPED cells.json already carries tile_water / tile_body (it
ships at contract 3: the Perrow tg_hillside_* water maps since P3-T) needs no
record: the test strips that layer for its OLD load and uses the shipped file
as NEW. The pack reports such a map and skips it (its file in <dir>, if any,
is ignored; --merge drops a stale record for it), and --check lists it as ok
("shipped layer"). Every other map gets a record:
  {"layer": false, "cells_md5": M}                         (no open water), or
  {"layer": true, "cols", "rows", "tile_water", "tile_body", "cells_md5": M}
with the pair run-length encoded ([value, count] over the row-major data) and
M the md5 of the shipped cells.json text with every CR byte dropped: the test
hashes the same text and FAILs a map whose shipped file changed since.

--merge keeps the fixture's record for a map with no file in <dir> (re-pack
one re-exported map); without it every map needs a file (but one shipping its
own layer). --check packs nothing: it lists the maps whose record is missing
or whose cells_md5 no longer matches the shipped file (a map shipping its own
layer is ok whatever its record), and exits 1 when there are any.
"""
import argparse
import glob
import hashlib
import json
import os
import sys

FIXTURE = os.path.join("tests", "fixtures", "p3d_deep_water", "c3_water_layers.json")
LAYER_KEYS = ("tile_water", "tile_body")
COMMENT = (
    "P3-D: the contract-3 open-water layer (cells.json tile_water / tile_body) of every shipped structured "
    "map, run-length encoded ([value, count] over the row-major data), for tests/deep_water_verdict_diff, "
    "which grafts it onto the shipped cells.json. Made from TG contract-3 dumps (tools/headless_dump.gd for "
    "the layout maps, windowed sandbox exports for the procedural ones) whose every other cells.json key "
    "equals the shipped file. Each map's cells_md5 is the md5 of the shipped <id>_cells.json text (CR bytes "
    "dropped) the layer was checked against: a re-exported map fails the diff until it is re-packed. "
    "A map whose shipped cells.json carries its own tile_water / tile_body (contract 3, e.g. the Perrow "
    "tg_hillside_* water maps) needs no record: the diff strips that layer for OLD and uses the shipped "
    "file as NEW, and the packer skips it. "
    "Re-pack: python tools/pack_c3_water_layers.py <dir of contract-3 <id>_cells.json> [--merge] "
    "(from the project folder); python tools/pack_c3_water_layers.py --check lists the stale maps."
)


def rle(a):
    out = []
    for v in a:
        if out and out[-1][0] == v:
            out[-1][1] += 1
        else:
            out.append([v, 1])
    return out


def text_md5(path):
    """md5 of the file's text with every CR byte dropped (the test's _text_md5)."""
    with open(path, "rb") as fh:
        return hashlib.md5(fh.read().replace(b"\r", b"")).hexdigest()


def res_path(project, res):
    return os.path.join(project, res[len("res://"):]) if res.startswith("res://") else res


def shipped_maps(project):
    """[(id, shipped cells.json path)] of every structured row whose cell_graph exists."""
    with open(os.path.join(project, "data", "Maps.json"), encoding="utf-8") as fh:
        data = json.load(fh)
    out = []
    for m in data["maps"]:
        if m.get("format") != "structured":
            continue
        p = res_path(project, str(m.get("cell_graph", "")))
        if m.get("cell_graph") and os.path.isfile(p):
            out.append((str(m["id"]), p))
    return out


def shipped_layer(shipped):
    """True when the shipped cells.json already carries tile_water / tile_body (either key:
    the test then strips it for OLD and needs no record)."""
    with open(shipped, encoding="utf-8") as fh:
        cells = json.load(fh)
    return any(k in cells for k in LAYER_KEYS)


def shipped_layer_whole(shipped):
    """True when the shipped cells.json carries BOTH tile_water and tile_body (a lone key is
    malformed: the test FAILs that map, so --check must not call it ok)."""
    with open(shipped, encoding="utf-8") as fh:
        cells = json.load(fh)
    return all(k in cells for k in LAYER_KEYS)


def record(shipped, c3):
    """The fixture record for one map, or raise ValueError when the c3 file is not the
    shipped file plus (at most) the layer. main() never calls it for a map whose shipped
    file carries the layer (shipped_layer: no record); the check below guards other callers."""
    with open(shipped, encoding="utf-8") as fh:
        a = json.load(fh)
    with open(c3, encoding="utf-8") as fh:
        b = json.load(fh)
    tw, tb = b.get("tile_water"), b.get("tile_body")
    rest = {k: v for k, v in b.items() if k not in LAYER_KEYS}
    if any(k in a for k in LAYER_KEYS):
        raise ValueError("the shipped file already carries tile_water / tile_body")
    if rest != a:
        diff = sorted(k for k in set(a) | set(rest) if a.get(k) != rest.get(k))
        raise ValueError("differs from the shipped file outside tile_water / tile_body: %s" % ", ".join(diff))
    md5 = text_md5(shipped)
    if tw is None and tb is None:
        return {"layer": False, "cells_md5": md5}
    if tw is None or tb is None:
        raise ValueError("carries only one of tile_water / tile_body")
    if tw.get("cols") != tb.get("cols") or tw.get("rows") != tb.get("rows") \
            or not (len(tw.get("data", [])) == len(tb.get("data", [])) == tw.get("cols", 0) * tw.get("rows", 0)):
        raise ValueError("tile_water / tile_body are not a matching cols x rows pair")
    return {"layer": True, "cols": tw["cols"], "rows": tw["rows"],
            "tile_water": rle(tw["data"]), "tile_body": rle(tb["data"]), "cells_md5": md5}


def check(project, fixture):
    with open(fixture, encoding="utf-8") as fh:
        recs = json.load(fh).get("maps", {})
    bad = 0
    for mid, shipped in shipped_maps(project):
        rec = recs.get(mid)
        if shipped_layer(shipped) and not shipped_layer_whole(shipped):
            print("MALFORMED %s: the shipped cells.json carries only one of tile_water / tile_body" % mid)
            bad += 1
        elif shipped_layer(shipped):
            print("ok %s: shipped layer%s" % (mid, " (its record is unused: --merge drops it)" if rec is not None else ""))
        elif rec is None:
            print("MISSING %s: no record (re-pack it)" % mid)
            bad += 1
        elif rec.get("cells_md5") != text_md5(shipped):
            print("STALE %s: cells_md5 %s, the shipped file is %s (re-pack it)" % (mid, rec.get("cells_md5"),
                                                                               text_md5(shipped)))
            bad += 1
        else:
            print("ok %s" % mid)
    print("%d stale, missing or malformed" % bad)
    return 1 if bad else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("c3_dir", nargs="?", help="dir of contract-3 <id>_cells.json")
    ap.add_argument("--project", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="the TFA Godot project folder (default: this script's)")
    ap.add_argument("--out", help="fixture path (default: the project's %s)" % FIXTURE)
    ap.add_argument("--merge", action="store_true", help="keep the fixture's record for a map with no c3 file")
    ap.add_argument("--check", action="store_true", help="list stale or missing records; pack nothing")
    args = ap.parse_args(argv)
    out = args.out or os.path.join(args.project, FIXTURE)
    if args.check:
        return check(args.project, out)
    if not args.c3_dir:
        ap.error("the contract-3 dir is required (or --check)")
    old = {}
    if args.merge and os.path.isfile(out):
        with open(out, encoding="utf-8") as fh:
            old = json.load(fh).get("maps", {})
    maps = {}
    layered = set()
    errors = 0
    for mid, shipped in shipped_maps(args.project):
        c3 = os.path.join(args.c3_dir, "%s_cells.json" % mid)
        if shipped_layer(shipped):
            # the test reads the shipped layer itself: no record (a stale one is dropped)
            layered.add(mid)
            print("skipped %s: the shipped cells.json carries tile_water / tile_body, no record needed%s%s" % (
                mid, "; its c3 file is ignored" if os.path.isfile(c3) else "",
                "; dropped its record" if mid in old else ""))
            continue
        if not os.path.isfile(c3):
            if mid in old:
                maps[mid] = old[mid]
                print("kept %s (no c3 file)" % mid)
            else:
                print("ERROR %s: no %s" % (mid, c3))
                errors += 1
            continue
        try:
            maps[mid] = record(shipped, c3)
        except ValueError as e:
            print("ERROR %s: %s" % (mid, e))
            errors += 1
            continue
        print("packed %s: %s" % (mid, "layer %dx%d" % (maps[mid]["cols"], maps[mid]["rows"])
                                 if maps[mid]["layer"] else "no open water"))
    extra = sorted(os.path.basename(f)[:-len("_cells.json")] for f in glob.glob(os.path.join(args.c3_dir, "*_cells.json"))
                   if os.path.basename(f)[:-len("_cells.json")] not in maps
                   and os.path.basename(f)[:-len("_cells.json")] not in layered)
    if extra:
        print("ignored (no shipped structured map): %s" % ", ".join(extra))
    if errors:
        print("%d error(s): nothing written" % errors)
        return 1
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"_comment": COMMENT, "maps": dict(sorted(maps.items()))}, fh, separators=(",", ":"))
        fh.write("\n")
    print("%d maps -> %s (%d bytes)" % (len(maps), out, os.path.getsize(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
