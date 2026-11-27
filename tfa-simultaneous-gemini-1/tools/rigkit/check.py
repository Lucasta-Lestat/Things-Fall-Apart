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

Hands (docs/rigging_rewrite.md 3.6). A glove gets one row per side per POSE (open,
grip): cover is measured against the hand that is showing. A held item also gets
  gripped  share of its handle hidden inside the closed hand
  visible  share of the whole item that still shows

Exit code 1 if anything FAILs. WARN is for a human to look at on the contact
sheet. The thresholds live in THRESHOLDS so tightening the gate is one edit.
"""
import argparse
import os
import sys

import cv2
import numpy as np

from . import core
from .render import RaceCanvas, hand_layer, item_layers

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
# the hand rig (docs 3.6): a glove is the hand itself in another material, so it must
# cover it; a held item's handle must be inside the closed hand
GLOVE_COVER = (0.92, 0.97)          # fail below, warn below
GRIPPED = (0.50, 0.75)              # share of the handle hidden by the hand: fail below, warn below
VISIBLE_WARN = 0.35                 # share of a held item still visible
HANDLE_VS_FIST = 0.90               # handle wider than this share of the fist: WARN


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


def check_glove(canvas, item, skel, base):
    """Hand-rig rows for a glove: one per side per pose. cover = share of the SHOWING
    hand (the hand label when open, the fist when gripping) the glove hides; spill as
    for any item; stretch = along:across distortion of the back-of-hand piece."""
    race = canvas.data
    hs = core.race_hand_set(race, skel)
    half = float(race["frames"]["torso"]["lx"])
    tol = max(2, int(0.14 * half))
    kern = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * tol + 1, 2 * tol + 1))
    _, _, sw, sf = THRESHOLDS["hands"]
    rows = []
    for pose in ("open", "grip"):
        layers = item_layers(canvas, item, skel, {"l": pose, "r": pose})
        for side in core.slot_sides(item, skel):
            mask = np.zeros(canvas.size, bool)
            for _, layer, s in layers:
                if s == side:
                    mask |= layer[:, :, 3] > 24
            row = dict(base, side=side, pose=pose, status="ok", why=[])
            if pose == "open":
                tgt = canvas.mask("hand_" + side)
            else:
                tgt = hand_layer(canvas, skel, side, "grip", item["hand"]["ramp"])[:, :, 3] > 127
            near = tgt | canvas.mask("forearm_" + side, "hand_" + side)
            row["cover"] = round(float((mask & tgt).sum()) / max(float(tgt.sum()), 1.0), 3)
            if row["cover"] < GLOVE_COVER[0]:
                row["status"] = "FAIL"
                row["why"].append("covers only %d%% of the %s hand" % (100 * row["cover"], pose))
            elif row["cover"] < GLOVE_COVER[1]:
                row["status"] = "WARN"
                row["why"].append("covers %d%% of the %s hand" % (100 * row["cover"], pose))
            grown = cv2.dilate(near.astype(np.uint8), kern) > 0
            row["spill"] = round(float((mask & ~grown).sum()) / max(float(mask.sum()), 1.0), 3)
            if row["spill"] > sf:
                row["status"] = "FAIL"
                row["why"].append("%d%% floats off the arm" % (100 * row["spill"]))
            elif row["spill"] > sw and row["status"] == "ok":
                row["status"] = "WARN"
                row["why"].append("%d%% off the arm" % (100 * row["spill"]))
            row["stretch"] = 1.0
            for piece in item["hand"]["pieces"]:
                if piece["frame"] != "palm":
                    continue
                fi = piece["frames"]["palm"]
                fr = core.pose_palm(race, hs, side, pose)
                ratio = (float(fr["lx"]) / float(fi["lx"])) / (float(fr["ly"]) / float(fi["ly"]))
                row["stretch"] = round(ratio, 2)
                if not (STRETCH_FAIL[0] <= ratio <= STRETCH_FAIL[1]):
                    row["status"] = "FAIL"
                    row["why"].append("back of hand distorted x%.2f" % ratio)
                elif not (STRETCH_WARN[0] <= ratio <= STRETCH_WARN[1]) and row["status"] == "ok":
                    row["status"] = "WARN"
                    row["why"].append("back of hand stretched x%.2f" % ratio)
            row["why"] = "; ".join(row["why"])
            rows.append(row)
    return rows


def check_held(canvas, item, skel, row, side, layers):
    """Hand-rig measures for a held item (the hand is closed on it): is the handle
    inside the hand, does the business end show, does the handle fit the fist."""
    race = canvas.data
    hold = item.get("hold", {})
    if hold.get("layer") == "over":
        return
    fist = hand_layer(canvas, skel, side, "grip")[:, :, 3] > 127
    g = race["frames"]["grip_" + side]
    o = np.asarray(g["o"], float) + canvas.pad
    if not fist[int(o[1] - 2 * g["ax"][1]), int(o[0] - 2 * g["ax"][0])]:
        row["status"] = "FAIL"
        row["why"].append("hold point is outside the fist")
    body = canvas.place(canvas.body.astype(np.float32))[:, :, 3] > 127
    front = np.zeros(canvas.size, bool)
    tail = np.zeros(canvas.size, bool)
    zf, zt = core.held_layers(item, skel, race, side)
    for z, layer, s in layers:
        if s == side:
            if zt is not None and z == zt:
                tail |= layer[:, :, 3] > 24
            else:
                front |= layer[:, :, 3] > 24
    whole = front | tail
    hidden = (front & fist) | (tail & (body | fist))
    yy, xx = np.nonzero(whole)
    u = ((xx - o[0]) * g["ax"][0] + (yy - o[1]) * g["ax"][1]) / float(g["lx"])       # world px ahead of the fist front
    fist_len = float(race["frames"]["palm_" + side]["ly"]) * float(race["world_scale"]) * \
        float(core.race_hand_set(race, skel)["poses"]["grip"]["grip_u"])
    span = float(item.get("total_length", 0.0)) * (hold.get("handle", [0, 0])[1] - hold.get("handle", [0, 0])[0])
    reach = min(span, fist_len) if span > 0 else fist_len
    band = (u <= 0) & (u >= -reach)
    if band.any():
        row["gripped"] = round(float(hidden[yy[band], xx[band]].mean()), 3)
        if row["gripped"] < GRIPPED[0]:
            row["status"] = "FAIL"
            row["why"].append("only %d%% of the handle is inside the hand" % (100 * row["gripped"]))
        elif row["gripped"] < GRIPPED[1] and row["status"] == "ok":
            row["status"] = "WARN"
            row["why"].append("%d%% of the handle is inside the hand" % (100 * row["gripped"]))
    row["visible"] = round(float((whole & ~hidden).sum()) / max(float(whole.sum()), 1.0), 3)
    ahead = (u > 0.5)
    if not (ahead.any() and (~hidden[yy[ahead], xx[ahead]]).any()):
        row["status"] = "FAIL"
        row["why"].append("nothing shows beyond the fist")
    elif row["visible"] < VISIBLE_WARN and row["status"] == "ok":
        row["status"] = "WARN"
        row["why"].append("only %d%% of the item shows" % (100 * row["visible"]))
    fist_w = 2.0 * float(race["frames"]["palm_" + side]["ly"]) * float(race["world_scale"])
    if hold.get("width") and hold["width"] > HANDLE_VS_FIST * fist_w and row["status"] == "ok":
        row["status"] = "WARN"
        row["why"].append("handle %.1f wide, fist %.1f" % (hold["width"], fist_w))


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
    if slot == "hands" and all(core.glove_ok(item, race, s) for s in core.slot_sides(item, skel)):
        return check_glove(canvas, item, skel, base)
    layers = item_layers(canvas, item, skel)
    seen = set()
    for z, layer, side in layers:
        if slot in ("main_hand", "off_hand"):
            if side in seen:
                continue                 # front and tail are one item: one row
            seen.add(side)
            layer = np.maximum.reduce([l for _, l, s in layers if s == side])
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
            if core.hand_rig_ok(race, side) and core.race_hand_set(race, skel) is not None:
                check_held(canvas, item, skel, row, side, layers)
            else:
                g = race["frames"]["grip_" + side]["o"]
                hand = canvas.mask("hand_" + side)
                if not hand[int(g[1]) + canvas.pad, int(g[0]) + canvas.pad]:
                    row["status"] = "FAIL"
                    row["why"].append("grip is outside the hand")
                row["why"].append("no hand rig: item lies on the open hand")
                if row["status"] == "ok":
                    row["status"] = "WARN"
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
