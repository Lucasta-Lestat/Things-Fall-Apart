"""Reproducible install of cerebrals_male/tilt15 (run from the project folder):

    python tools/rigkit/out/plan/cerebrals_male/install_tilt15.py [PAINTING [GUIDE_PREFIX]]

A plain install_plan run has two defects on this race, and shared code was off limits to the
painter, so this wrapper works around both. Each is a candidate fix for install_plan itself
(cerebrals_female needs the same).

1. Dashed contour. install_plan.key() recolours the outer 2 px of the silhouette with the paint
   2 px further in. This race's contour line is about 3 px thick, so on every shallow diagonal the
   sample alternates between line and skin and the outline comes out as dashes (fingers, forearms,
   feet). Workaround: the contour is padded 1 px outward first (<tag>_<n>_contour.png), so the rim
   samples line everywhere. Silhouette grows by under 1 pack px.

2. Trunk-labelled ring round the cranium. snap_head()'s watershed gives the cranium's own contour
   line to the "not head" side wherever the head overhangs open ground, and those pixels fall back
   to the trunk label. Workaround: the pack is installed once without the head snap (head label =
   the guide's, rim included) and once with it; trunk pixels of the snapped map that the unsnapped
   map calls head AND that lie within RING px of the open ground go back to the head label. The
   snapped jaw / eye-corner boundary against the chest is kept.
"""
import os
import sys

sys.path.insert(0, os.getcwd())
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

from tools.rigkit import build_race, core, install_plan as ip

HERE = os.path.dirname(os.path.abspath(__file__))
RACE, VARIANT, MATCH = "cerebrals_male", "tilt15", "cerebrals_male/default"
PAD, RING = 1, 7


def pad_contour(src, gmask_path, dst, pad=PAD):
    g = Image.open(gmask_path).convert("L")
    im = Image.open(src).convert("RGB")
    if im.size != g.size:
        im = im.resize(g.size, Image.LANCZOS)
    a = np.asarray(im).astype(np.float32)
    gm = np.asarray(g) > 127
    k = 24
    bg = np.median(np.concatenate([a[:k, :k].reshape(-1, 3), a[:k, -k:].reshape(-1, 3),
                                   a[-k:, :k].reshape(-1, 3), a[-k:, -k:].reshape(-1, 3)]), 0)
    d = np.abs(a - bg).max(-1)
    chroma = a.max(-1) - a.min(-1)
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    fg = (chroma > 14) | (d > 45)
    fg = ndi.binary_fill_holes(ndi.binary_closing(fg, iterations=1)) & ndi.binary_dilation(gm, iterations=12)
    fg = ndi.binary_opening(fg, iterations=1)
    lab, n = ndi.label(fg)
    fg = lab == (1 + int(np.argmax(ndi.sum(fg, lab, range(1, n + 1)))))
    depth = ndi.distance_transform_edt(fg)
    line = fg & (lum < 80) & (depth <= 4)                    # the dark contour itself
    dist, (iy, ix) = ndi.distance_transform_edt(~line, return_indices=True)
    ring = (ndi.binary_dilation(fg, iterations=pad) & ~fg) | (fg & (depth <= 1.5) & ~line)
    ring &= dist <= 4.5
    out = a.copy()
    out[ring] = a[iy, ix][ring]
    Image.fromarray(out.astype(np.uint8)).save(dst)
    return int(ring.sum())


def main():
    painting = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "r2_1.png")
    guide = sys.argv[2] if len(sys.argv) > 2 else ip.guide_prefix_for(painting)
    padded = painting[:-4] + "_contour.png"
    n = pad_contour(painting, guide + "_mask.png", padded)
    print("contour padded: %d px -> %s" % (n, padded))
    out = core.race_dir(RACE, VARIANT)
    lp = os.path.join(out, "labels.png")
    ip.install(padded, RACE, VARIANT, guide=guide, match=MATCH, head_snap=False)
    plain = np.asarray(Image.open(lp).convert("RGB")).copy()
    r = ip.install(padded, RACE, VARIANT, guide=guide, match=MATCH)
    lab = np.asarray(Image.open(lp).convert("RGB")).copy()
    alpha = np.asarray(Image.open(os.path.join(out, "body.png")).convert("RGBA"))[:, :, 3]
    face, body = np.array(ip.PALETTE["face"]), np.array(ip.PALETTE["body"])
    near_ground = ndi.distance_transform_edt(alpha >= 128) <= RING
    ring = (lab == body).all(-1) & (plain == face).all(-1) & near_ground
    lab[ring] = face
    Image.fromarray(lab, "RGB").save(lp, optimize=True)
    path = os.path.join(out, "race.json")
    data = core.load_json(path)
    data["source"] += "; installed by tools/rigkit/out/plan/cerebrals_male/install_tilt15.py"
    data["install"]["label_fixes"].append(
        "contour: line padded %d px outward before keying (%d px), else key() dashes a 3 px line" % (PAD, n))
    data["install"]["label_fixes"].append(
        "head: %d px of cranium contour ring the head snap gave to the trunk relabelled face "
        "(install_tilt15.py; a plain install_plan run loses this)" % int(ring.sum()))
    core.save_json(path, data)
    _, msg = build_race.build(RACE, VARIANT)
    print("world_scale %.5f  guide IoU %.3f  ring %d px  (%s)" % (r["world_scale"], r["guide_iou"], int(ring.sum()), msg))
    for note in data["install"]["label_fixes"]:
        print("   " + note)
    for name, v in r["match_ratios"].items():
        print("   %-10s %.5f (%.1f pack px)" % (name, v, r["measures_px"][name]))


if __name__ == "__main__":
    main()
