"""Automated fit gate: every item on every race, measured against the label map.

    python -m tools.rigkit.check [--races a,b] [--items x,y] [--json report.json]

For each (race, item) it renders the fitted item alone and compares its pixels
with the race's labels:

  cover    share of the anatomy the item is supposed to hide that it does hide
           (low = skin showing / item cut off / item too small)
  spill    share of the item that lies well outside the silhouette it belongs
           to (high = floating / too big)
  stretch  along:across distortion the fit applied to the art
  clipped  the item ran off the canvas

Exit code 1 if anything FAILs. WARN is for a human to look at on the contact
sheet. The thresholds live in THRESHOLDS so tightening the gate is one edit.
"""
import argparse
import os
import sys

import cv2
import numpy as np

from . import core
from .render import RaceCanvas, item_layers

# slot -> (cover fail, cover warn, spill warn, spill fail)
THRESHOLDS = {
    "torso": (0.70, 0.86, 0.10, 0.22),
    "head": (0.60, 0.80, None, None),
    "feet": (0.55, 0.75, 0.35, 0.60),
    "hands": (0.45, 0.65, 0.40, 0.65),
    "back": (None, None, None, None),
    "main_hand": (None, None, None, None),
    "off_hand": (None, None, None, None),
    "legs": (0.55, 0.75, 0.25, 0.45),
}
STRETCH_WARN = (0.60, 1.70)
STRETCH_FAIL = (0.40, 2.50)


def _disc(shape, o, r):
    m = np.zeros(shape, np.uint8)
    cv2.circle(m, (int(round(o[0])), int(round(o[1]))), int(round(r)), 1, -1)
    return m > 0


def _target(canvas, item, side):
    """The anatomy this item should cover, and the silhouette it must stay near."""
    slot = item["slot"]
    f = canvas.data["frames"]
    pad = canvas.pad
    if slot == "torso":
        head = canvas.mask("face", "hair")
        tgt = canvas.mask("body") & ~head
        near = canvas.mask("body", "over_garment", "face", "hair", "upperarm_l", "upperarm_r")
        if item.get("sleeve") == "long":
            near |= canvas.mask("forearm_l", "forearm_r")
        return tgt, near
    if slot == "head":
        h = f["head"]
        disc = _disc(canvas.size, (h["o"][0] + pad, h["o"][1] + pad), h["lx"])
        return disc, None
    if slot == "feet":
        m = canvas.mask("foot_" + side)
        return m, m
    if slot == "hands":
        m = canvas.mask("hand_" + side)
        return m, m | canvas.mask("forearm_" + side)
    if slot == "legs":
        m = canvas.mask("leg_l", "leg_r")
        return m, m | canvas.mask("body")
    return None, None


def check_pair(canvas, item, skel):
    """Returns a list of result rows for one race x item."""
    race = canvas.data
    slot = item["slot"]
    rows = []
    miss = core.missing_frames(item, skel, race)
    base = {"race": race["id"], "variant": race.get("variant", "default"), "item": item["id"], "slot": slot}
    if miss:
        optional = all(m.startswith(("leg_", "foot_")) for m in miss)
        rows.append(dict(base, status="n/a" if optional else "FAIL",
                         why="race has no %s" % ", ".join(miss)))
        return rows
    half = float(race["frames"]["torso"]["lx"])
    tol = max(2, int(0.14 * half))
    kern = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * tol + 1, 2 * tol + 1))
    cf, cw, sw, sf = THRESHOLDS[slot]
    root = core.root_frame_name(item, skel)
    for z, layer, side in item_layers(canvas, item, skel):
        mask = layer[:, :, 3] > 24
        row = dict(base, side=side or "", status="ok", why=[])
        area = int(mask.sum())
        if area == 0:
            row.update(status="FAIL", why="item drew nothing")
            rows.append(row)
            continue
        tgt, near = _target(canvas, item, side)
        if tgt is not None and int(tgt.sum()) > 0:
            row["cover"] = round(float((mask & tgt).sum()) / float(tgt.sum()), 3)
            if cf is not None and row["cover"] < cf:
                row["status"] = "FAIL"
                row["why"].append("covers only %d%%" % (100 * row["cover"]))
            elif cw is not None and row["cover"] < cw:
                row["status"] = "WARN"
                row["why"].append("covers %d%%" % (100 * row["cover"]))
        if near is not None and sw is not None:
            grown = cv2.dilate(near.astype(np.uint8), kern) > 0
            row["spill"] = round(float((mask & ~grown).sum()) / float(area), 3)
            if row["spill"] > sf:
                row["status"] = "FAIL"
                row["why"].append("%d%% floats off the body" % (100 * row["spill"]))
            elif row["spill"] > sw and row["status"] == "ok":
                row["status"] = "WARN"
                row["why"].append("%d%% off the body" % (100 * row["spill"]))
        if core.scale_mode(item, skel) == "free":
            along, across = core.frame_stretch(item, skel, race, root, side)
            ratio = along / across
            row["stretch"] = round(ratio, 2)
            if not (STRETCH_FAIL[0] <= ratio <= STRETCH_FAIL[1]):
                row["status"] = "FAIL"
                row["why"].append("art distorted x%.2f" % ratio)
            elif not (STRETCH_WARN[0] <= ratio <= STRETCH_WARN[1]) and row["status"] == "ok":
                row["status"] = "WARN"
                row["why"].append("art stretched x%.2f" % ratio)
        if slot in ("main_hand", "off_hand"):
            g = race["frames"]["grip_" + side]["o"]
            hand = canvas.mask("hand_" + side)
            if not hand[int(g[1]) + canvas.pad, int(g[0]) + canvas.pad]:
                row["status"] = "FAIL"
                row["why"].append("grip is outside the hand")
        if mask[0].any() or mask[-1].any() or mask[:, 0].any() or mask[:, -1].any():
            if slot not in ("main_hand", "off_hand"):
                row["status"] = "FAIL"
                row["why"].append("runs off the canvas")
        row["why"] = "; ".join(row["why"])
        rows.append(row)
    return rows


def run(races, items):
    skel = core.skeleton()
    loaded = [core.load_item(i) for i in items]
    rows = []
    for race, variant in races:
        canvas = RaceCanvas(race, variant)
        need = [n for n in skel["required_frames"] if n not in canvas.data["frames"]]
        if need:
            rows.append({"race": race, "variant": variant, "item": "-", "slot": "-", "status": "FAIL",
                         "why": "race pack lacks required frames: %s" % ", ".join(need)})
            continue
        for item in loaded:
            rows.extend(check_pair(canvas, item, skel))
    return rows


def summarise(rows, out=sys.stdout):
    counts = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    by_item = {}
    for r in rows:
        by_item.setdefault(r["item"], {}).setdefault(r["status"], []).append(r)
    print("%-26s %5s %5s %5s %5s   worst" % ("item", "ok", "WARN", "FAIL", "n/a"), file=out)
    for item in sorted(by_item):
        d = by_item[item]
        bad = d.get("FAIL", []) + d.get("WARN", [])
        worst = ""
        if bad:
            b = bad[0]
            worst = "%s%s: %s" % (b["race"], ("/" + b["side"]) if b.get("side") else "", b["why"])
        print("%-26s %5d %5d %5d %5d   %s" % (item, len(d.get("ok", [])), len(d.get("WARN", [])),
                                             len(d.get("FAIL", [])), len(d.get("n/a", [])), worst[:70]), file=out)
    print("TOTAL  " + "  ".join("%s=%d" % kv for kv in sorted(counts.items())), file=out)
    return counts


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--races", default="")
    ap.add_argument("--items", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--list", action="store_true", help="print every WARN/FAIL row")
    a = ap.parse_args(argv)
    races = core.list_races()
    if a.races:
        want = a.races.split(",")
        races = [(r, v) for r, v in races if r in want or "%s/%s" % (r, v) in want]
    items = a.items.split(",") if a.items else core.list_items()
    rows = run(races, items)
    counts = summarise(rows)
    if a.list:
        for r in rows:
            if r["status"] in ("WARN", "FAIL"):
                print("  %-4s %-20s %-24s %s %s" % (r["status"], r["race"], r["item"], r.get("side", ""), r["why"]))
    if a.json:
        core.save_json(a.json, {"counts": counts, "rows": rows})
    return 1 if counts.get("FAIL") else 0


if __name__ == "__main__":
    sys.exit(main())
