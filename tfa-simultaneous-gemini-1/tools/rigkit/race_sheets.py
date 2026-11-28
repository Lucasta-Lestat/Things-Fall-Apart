"""Review sheets for the race repaint batch (docs 4.3, "Race batch").

    python -m tools.rigkit.race_sheets before_after [--status FILE.json] [--per-sheet 9]
        out/plan/races_before_after_<n>.jpg: one row per repainted race, the legacy pack on the left and
        the repaint on the right at the SAME world scale, bare.
    python -m tools.rigkit.race_sheets crowd [--status FILE.json]
        out/plan/races_crowd_after.jpg: every promoted race side by side at ONE world scale, dressed.

Which pack is "before" and which "after" is read off the folders, so the sheets can be made before or
after promotion: a race with a `legacy` variant has been promoted (legacy -> default); otherwise the
repaint is still waiting beside the default as `tilt15`.

--status is {race: "pass" | "hold" | "failed"} (default out/plan/race_batch_status.json); it only
labels the rows and, before promotion, picks the crowd.
"""
import argparse
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

from . import core
from .install_plan import measures
from .render import compose
from .sheet import BG

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "plan")
STATUS = os.path.join(OUT, "race_batch_status.json")
WAITING = ("tilt15_head", "tilt15")          # a repaint not yet promoted, most preferred first
COLOURS = {"pass": (150, 230, 150), "hold": (255, 210, 110), "failed": (255, 140, 130)}

OUTFITS = [
    ["peasants_stained_shirt", "leather_boot", "dagger"],
    ["legionnaires_armor", "kettle_helm", "leather_boot", "leather_glove", "spear"],
    ["leather_armor", "adventurer_pack", "leather_boot", "dagger"],
    ["dark_robes", "dark_hood"],
    ["breastplate", "great_helm", "plate_sabaton", "plate_gauntlet", "longsword"],
    ["nobles_blouse", "red_cape", "leather_boot"],
    ["chain_shirt", "kettle_helm", "leather_glove", "longsword"],
    ["padded_vest", "leather_boot", "spear"],
    [],
    ["chain_shirt", "golden_helm", "red_cape", "plate_sabaton", "longsword"],
]


def _has(race, variant):
    return os.path.exists(os.path.join(core.race_dir(race, variant), "race.json"))


def pair(race):
    """((race, before variant), (race, after variant)) or None when the race has no repaint."""
    if _has(race, "legacy"):
        return (race, "legacy"), (race, "default")
    for v in WAITING:
        if _has(race, v):
            return (race, "default"), (race, v)
    return None


def _item(iid):
    """Prefer a waiting top-down repaint of an item while it still sits beside the original."""
    td = iid + "_td"
    return td if os.path.exists(os.path.join(core.RIGS, "items", td, "item.json")) else iid


def tile(race, variant, items, px_per_world, size, skel, anchor=0.40, anchor_x=0.5):
    """The pack dressed in `items`, at px_per_world sheet px per world px, torso origin at the tile's
    centre column and `anchor` of its height."""
    img, _, canvas = compose(race, [_item(i) for i in items], variant, skel, background=BG)
    k = px_per_world * float(canvas.data["world_scale"])
    small = cv2.resize(img[:, :, :3], None, fx=k, fy=k, interpolation=cv2.INTER_AREA if k < 1 else cv2.INTER_CUBIC)
    o = (np.array(canvas.data["frames"]["torso"]["o"]) + canvas.pad) * k
    t = np.zeros((size[1], size[0], 3), np.uint8)
    t[:] = BG
    x0, y0 = int(round(o[0] - size[0] * anchor_x)), int(round(o[1] - size[1] * anchor))
    sx0, sy0 = max(x0, 0), max(y0, 0)
    sx1, sy1 = min(x0 + size[0], small.shape[1]), min(y0 + size[1], small.shape[0])
    if sx1 > sx0 and sy1 > sy0:
        t[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = small[sy0:sy1, sx0:sx1]
    return Image.fromarray(t), canvas


def span_world(race, variant):
    d = core.load_race(race, variant)
    return measures(d["frames"])["span"] * float(d["world_scale"])


def before_after(status, per_sheet=9, size=(560, 300)):
    skel = core.skeleton()
    races = [r for r in sorted({r for r, _ in core.list_races()}) if pair(r)]
    side, head = 210, 24
    paths = []
    for n in range(0, len(races), per_sheet):
        chunk = races[n:n + per_sheet]
        sheet = Image.new("RGB", (side + 2 * size[0], head + size[1] * len(chunk)), (30, 32, 30))
        dr = ImageDraw.Draw(sheet)
        dr.text((side + 6, 6), "before (legacy painting)", fill=(230, 230, 220))
        dr.text((side + size[0] + 6, 6), "after (15 degree standard), same world scale", fill=(230, 230, 220))
        for i, race in enumerate(chunk):
            (br, bv), (ar, av) = pair(race)
            ppw = min(max(0.80 * size[0] / max(span_world(br, bv), span_world(ar, av)), 1.5), 12.0)
            y = head + i * size[1]
            st = status.get(race, "?")
            dr.text((6, y + 8), race, fill=(240, 240, 230))
            dr.text((6, y + 26), st.upper(), fill=COLOURS.get(st, (200, 200, 200)))
            dr.text((6, y + 44), "in game: %s" % ("repaint" if av == "default" else "legacy"), fill=(170, 170, 160))
            dr.text((6, y + 60), "x%.1f" % ppw, fill=(120, 120, 112))
            for j, (r, v) in enumerate(((br, bv), (ar, av))):
                t, canvas = tile(r, v, [], ppw, size, skel, anchor=0.42)
                sheet.paste(t, (side + j * size[0], y))
                dr.text((side + j * size[0] + 6, y + size[1] - 16), "%s/%s   head r %.1f world px" % (
                    r, v, canvas.data["frames"]["head"]["lx"] * float(canvas.data["world_scale"])),
                    fill=(200, 200, 190))
        p = os.path.join(OUT, "races_before_after_%d.jpg" % (n // per_sheet + 1))
        sheet.save(p, quality=90)
        paths.append(p)
        print("wrote", p)
    return paths


def crowd(status, cols=5, px_per_world=3.0, size=(700, 330)):
    """Every promoted race (before promotion: every race marked pass) at one world scale."""
    skel = core.skeleton()
    cast = []
    for race in sorted({r for r, _ in core.list_races()}):
        pr = pair(race)
        if pr is None:
            continue
        if pr[1][1] == "default" or status.get(race) == "pass":
            cast.append(pr[1])
    rows = -(-len(cast) // cols)
    sheet = Image.new("RGB", (cols * size[0], 24 + rows * size[1]), (30, 32, 30))
    dr = ImageDraw.Draw(sheet)
    dr.text((6, 6), "repainted races, one world scale (x%.1f), one camera" % px_per_world, fill=(230, 230, 220))
    for i, (race, variant) in enumerate(cast):
        t, _ = tile(race, variant, OUTFITS[i % len(OUTFITS)], px_per_world, size, skel, anchor=0.45, anchor_x=0.44)
        x, y = (i % cols) * size[0], 24 + (i // cols) * size[1]
        sheet.paste(t, (x, y))
        dr.text((x + 6, y + 4), "%s/%s" % (race, variant), fill=(240, 240, 230))
    p = os.path.join(OUT, "races_crowd_after.jpg")
    sheet.save(p, quality=90)
    print("wrote", p)
    return p


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["before_after", "crowd"])
    ap.add_argument("--status", default=STATUS)
    ap.add_argument("--per-sheet", type=int, default=9)
    a = ap.parse_args(argv)
    status = core.load_json(a.status) if os.path.exists(a.status) else {}
    if a.cmd == "before_after":
        before_after(status, a.per_sheet)
    else:
        crowd(status)
    return 0


if __name__ == "__main__":
    sys.exit(main())
