"""The hand rig's review sheet: every hand case on a few races, arm view and zoom.

    python -m tools.rigkit.hands_sheet [--races orc/tilt15_head,human,goblin_male]
                                       [--before DIR] [--out tools/rigkit/out/hands]

Each row is one case (weapon held, bare, gloved, gloved and holding). With --before
(a folder of full renders made by an older build plus meta.json, see `snapshot`) each
row shows BEFORE and AFTER side by side. Writes hands_sheet.jpg (all races) and one
hands_sheet_<race>.jpg per race.

    python -m tools.rigkit.hands_sheet snapshot DIR      # save the current renders as a BEFORE set
"""
import argparse
import json
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

from . import core
from .render import compose

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "hands")
BG = (86, 92, 84)
RACES = [("orc", "tilt15_head"), ("human", "default"), ("goblin_male", "default")]
CASES = [
    ("longsword", "longsword held", ["longsword"], None),
    ("dagger", "dagger held", ["dagger"], None),
    ("spear", "spear held (one-handed in Items.json)", ["spear"], None),
    ("bare", "bare hands", [], None),
    ("glove_open", "leather_glove, open", ["leather_glove"], None),
    ("glove_sword", "leather_glove gripping a longsword", ["leather_glove", "longsword"], None),
    ("gauntlet_open", "plate_gauntlet, open", ["plate_gauntlet"], None),
    ("gauntlet_sword", "plate_gauntlet gripping a longsword", ["plate_gauntlet", "longsword"], None),
    ("fist", "empty fist (grip pose, nothing held)", [], {"r": "grip"}),
    ("gauntlet_fist", "plate_gauntlet, empty fist", ["plate_gauntlet"], {"r": "grip"}),
]
ARM = (-24.0, 60.0, 17.0, 6.2)      # world px behind / ahead of the wrist, half height, px per world px
ZOOM = (-8.0, 20.0, 10.5, 15.0)
GAME = (-24.0, 60.0, 17.0, 1.0)     # the same arm view at in-game size


def _view(img, wrist, pad, world_scale, spec):
    back, ahead, half, ppw = spec
    k = 1.0 / world_scale                         # pack px per world px
    x0, x1 = wrist[0] + pad + back * k, wrist[0] + pad + ahead * k
    y0, y1 = wrist[1] + pad - half * k, wrist[1] + pad + half * k
    w, h = int((ahead - back) * ppw), int(2 * half * ppw)
    m = np.float32([[w / (x1 - x0), 0, -x0 * w / (x1 - x0)], [0, h / (y1 - y0), -y0 * h / (y1 - y0)]])
    interp = cv2.INTER_AREA if ppw < k else cv2.INTER_CUBIC
    return cv2.warpAffine(img[:, :, :3], m, (w, h), flags=interp, borderValue=BG)


def _tiles(img, frames, pad, world_scale):
    wrist = frames["forearm_r"]["o"][0] + frames["forearm_r"]["ax"][0] * frames["forearm_r"]["lx"], \
        frames["forearm_r"]["o"][1] + frames["forearm_r"]["ax"][1] * frames["forearm_r"]["lx"]
    arm = _view(img, wrist, pad, world_scale, ARM)
    zoom = _view(img, wrist, pad, world_scale, ZOOM)
    game = _view(img, wrist, pad, world_scale, GAME)
    gh, gw = game.shape[:2]
    arm[4:4 + gh, 4:4 + gw] = game                # inset: in-game size
    cv2.rectangle(arm, (3, 3), (4 + gw, 4 + gh), (30, 32, 30), 1)
    return np.concatenate([arm, np.full((arm.shape[0], 6, 3), 30, np.uint8),
                           cv2.resize(zoom, (int(zoom.shape[1] * arm.shape[0] / zoom.shape[0]), arm.shape[0]))], axis=1)


def snapshot(out):
    os.makedirs(out, exist_ok=True)
    meta = {}
    for r, v in RACES:
        for key, _, items, poses in CASES:
            img, _, canvas = compose(r, items, v, background=BG, poses=poses)
            Image.fromarray(img[:, :, :3]).save(os.path.join(out, "%s_%s_%s.png" % (r, v, key)))
        meta["%s/%s" % (r, v)] = {"pad": canvas.pad, "frames": canvas.data["frames"],
                                  "world_scale": canvas.data["world_scale"]}
    with open(os.path.join(out, "meta.json"), "w") as f:
        json.dump(meta, f)


def sheet(races, before, out):
    os.makedirs(out, exist_ok=True)
    meta = json.load(open(os.path.join(before, "meta.json"))) if before else {}
    blocks = []
    for r, v in races:
        rows = []
        for key, title, items, poses in CASES:
            img, _, canvas = compose(r, items, v, background=BG, poses=poses)
            after = _tiles(img, canvas.data["frames"], canvas.pad, canvas.data["world_scale"])
            bp = os.path.join(before, "%s_%s_%s.png" % (r, v, key)) if before else ""
            if bp and os.path.exists(bp):
                m = meta["%s/%s" % (r, v)]
                b = _tiles(np.asarray(Image.open(bp).convert("RGB")), m["frames"], m["pad"], m["world_scale"])
            else:
                b = np.full_like(after, 30)
            row = np.concatenate([b, np.full((after.shape[0], 14, 3), 30, np.uint8), after], axis=1)
            strip = Image.new("RGB", (row.shape[1], 20), (30, 32, 30))
            d = ImageDraw.Draw(strip)
            d.text((6, 4), "%s/%s   %s" % (r, v, title), fill=(235, 235, 225))
            d.text((b.shape[1] - 60, 4), "BEFORE", fill=(240, 150, 130))
            d.text((row.shape[1] - 50, 4), "AFTER", fill=(150, 230, 150))
            rows.append(np.concatenate([np.asarray(strip), row], axis=0))
        block = np.concatenate(rows, axis=0)
        p = os.path.join(out, "hands_sheet_%s.jpg" % (r if v == "default" else r + "_" + v))
        Image.fromarray(block).save(p, quality=90)
        print("wrote", p)
        blocks.append(block)
    p = os.path.join(out, "hands_sheet.jpg")
    Image.fromarray(np.concatenate(blocks, axis=0)).save(p, quality=88)
    print("wrote", p)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", nargs="?", default="sheet")
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--races", default="")
    ap.add_argument("--before", default=os.path.join(OUT, "before"))
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args(argv)
    if a.cmd == "snapshot":
        snapshot(a.dir or os.path.join(OUT, "before"))
        return 0
    races = RACES
    if a.races:
        races = [tuple(x.split("/")) if "/" in x else (x, "default") for x in a.races.split(",")]
    sheet(races, a.before if os.path.isdir(a.before) else "", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
