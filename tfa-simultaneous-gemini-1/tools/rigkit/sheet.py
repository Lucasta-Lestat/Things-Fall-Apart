"""Contact sheets: every race x every outfit, for review by eye.

    python -m tools.rigkit.sheet --out DIR [--races a,b] [--outfits name=item+item,...]
    python -m tools.rigkit.sheet --out DIR --frames          # anatomy overlay per race

Output goes OUTSIDE the Godot project by default (tools/rigkit/out is
.gdignore'd) so the previews are never imported as game art.
"""
import argparse
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

from . import core
from .render import RaceCanvas, compose

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
BG = (86, 92, 84)
DEFAULT_OUTFITS = [
    ("bare", []),
    ("peasant", ["peasants_stained_shirt", "leather_boot", "dagger"]),
    ("robes", ["dark_robes", "dark_hood", "red_cape"]),
    ("soldier", ["legionnaires_armor", "kettle_helm", "leather_boot", "leather_glove", "spear"]),
    ("knight", ["breastplate", "great_helm", "plate_sabaton", "plate_gauntlet", "longsword"]),
    ("scout", ["leather_armor", "adventurer_pack", "leather_boot", "dagger"]),
]


def _fit_tile(img, tile):
    """Crop to the non-background content, then letterbox into a tile."""
    h, w = img.shape[:2]
    k = min(tile[0] / w, tile[1] / h)
    small = cv2.resize(img, (max(1, int(w * k)), max(1, int(h * k))), interpolation=cv2.INTER_AREA)
    out = np.zeros((tile[1], tile[0], 3), np.uint8)
    out[:] = BG
    y = (tile[1] - small.shape[0]) // 2
    x = (tile[0] - small.shape[1]) // 2
    out[y:y + small.shape[0], x:x + small.shape[1]] = small[:, :, :3]
    return out


def _crop(img, canvas, margin=0.55):
    """Trim the padded canvas to the body plus a share of the padding."""
    p = int(canvas.pad * (1.0 - margin))
    return img[p:img.shape[0] - p, p:img.shape[1] - p]


def outfit_sheet(races, outfits, out_path, tile=(300, 210)):
    skel = core.skeleton()
    head = 22
    side = 150
    W = side + tile[0] * len(outfits)
    H = head + tile[1] * len(races)
    sheet = Image.new("RGB", (W, H), (30, 32, 30))
    dr = ImageDraw.Draw(sheet)
    for j, (name, items) in enumerate(outfits):
        dr.text((side + j * tile[0] + 6, 5), "%s: %s" % (name, " + ".join(items))[:52], fill=(230, 230, 220))
    problems = []
    for i, (race, variant) in enumerate(races):
        label = race if variant == "default" else "%s/%s" % (race, variant)
        dr.text((6, head + i * tile[1] + 6), label, fill=(230, 230, 220))
        for j, (name, items) in enumerate(outfits):
            img, _, canvas = compose(race, items, variant, skel, background=BG)
            for iid, miss in canvas.skipped:
                problems.append("%s: %s not worn (race has no %s)" % (label, iid, ", ".join(miss)))
            sheet.paste(Image.fromarray(_fit_tile(_crop(img, canvas), tile)),
                        (side + j * tile[0], head + i * tile[1]))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    sheet.save(out_path, quality=88)
    return problems


def frames_sheet(races, out_path, tile=(420, 300), cols=4):
    """Each race with its derived frames drawn on top: the anatomy the fit trusts."""
    rows = (len(races) + cols - 1) // cols
    sheet = Image.new("RGB", (tile[0] * cols, tile[1] * rows), (30, 32, 30))
    colors = {"torso": (255, 255, 255), "head": (255, 80, 80), "upperarm": (80, 160, 255),
              "forearm": (200, 90, 255), "hand": (255, 170, 210), "grip": (255, 230, 60),
              "foot": (255, 220, 40), "leg": (60, 230, 230)}
    for i, (race, variant) in enumerate(races):
        c = RaceCanvas(race, variant)
        img = np.zeros((c.body.shape[0], c.body.shape[1], 3), np.uint8)
        img[:] = BG
        a = c.body[:, :, 3:4] / 255.0
        img = (img * (1 - a) + c.body[:, :, :3] * a * 0.75 + img * a * 0.25).astype(np.uint8)
        for name, f in c.data["frames"].items():
            if name == "head_full":
                continue
            col = colors.get(name.split("_")[0], (255, 255, 255))
            o = np.array(f["o"])
            ax = np.array(f["ax"])
            perp = np.array([-ax[1], ax[0]])
            if name.startswith("grip"):
                cv2.circle(img, tuple(np.round(o).astype(int)), 5, col, -1)
                continue
            if name == "head":
                cv2.circle(img, tuple(np.round(o).astype(int)), int(f["lx"]), col, 2)
                continue
            lyn = f.get("ly_neg", f["ly"])
            u0 = -f["lx"] if name in ("torso",) or name.startswith("foot") else 0.0
            quad = [o + ax * u0 - perp * lyn, o + ax * f["lx"] - perp * lyn,
                    o + ax * f["lx"] + perp * f["ly"], o + ax * u0 + perp * f["ly"]]
            cv2.polylines(img, [np.round(quad).astype(np.int32)], True, col, 2)
            cv2.circle(img, tuple(np.round(o).astype(int)), 4, col, -1)
        t = Image.fromarray(_fit_tile(img, tile))
        ImageDraw.Draw(t).text((6, 4), race if variant == "default" else race + "/" + variant, fill=(240, 240, 230))
        sheet.paste(t, ((i % cols) * tile[0], (i // cols) * tile[1]))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    sheet.save(out_path, quality=88)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--races", default="")
    ap.add_argument("--outfits", default="")
    ap.add_argument("--frames", action="store_true")
    ap.add_argument("--per-sheet", type=int, default=13)
    a = ap.parse_args(argv)
    races = core.list_races()
    if a.races:
        want = a.races.split(",")
        races = [(r, v) for r, v in races if r in want or "%s/%s" % (r, v) in want]
    if a.frames:
        for n in range(0, len(races), 16):
            p = os.path.join(a.out, "frames_%02d.jpg" % (n // 16 + 1))
            frames_sheet(races[n:n + 16], p)
            print("wrote", p)
        return 0
    outfits = DEFAULT_OUTFITS
    if a.outfits:
        outfits = [(o.split("=")[0], [i for i in o.split("=")[1].split("+") if i]) for o in a.outfits.split(",")]
    for n in range(0, len(races), a.per_sheet):
        p = os.path.join(a.out, "outfits_%02d.jpg" % (n // a.per_sheet + 1))
        problems = outfit_sheet(races[n:n + a.per_sheet], outfits, p)
        print("wrote", p)
        for line in sorted(set(problems)):
            print("   ", line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
