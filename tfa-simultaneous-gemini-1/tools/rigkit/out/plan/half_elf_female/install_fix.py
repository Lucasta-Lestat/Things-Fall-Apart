"""half_elf_female only: install a painting with two repairs to install_plan.key's matte, without
editing shared code (the stock key is wrapped, not changed).

    python tools/rigkit/out/plan/half_elf_female/install_fix.py tools/rigkit/out/plan/half_elf_female/r1_4.png

1. Ground left between the fingers. key() closes the silhouette by 2 px, which fills the tip of the
   narrow V of ground at each finger web, and its contact-shadow peel may not reach into the guide's
   silhouette. Here: opaque pixels that still have the ground's colour and connect to the outside are
   made transparent.
2. Broken contour on pale skin. key() mattes the rim as alpha = (obs - ground).(F - ground) with F the
   paint 2 px inside. On skin LIGHTER than the ground a dark contour pixel lies on the other side of the
   ground from F, so its alpha comes out 0 and the line is eaten in dashes. Here: rim pixels darker than
   the ground get alpha from their own darkness and keep their own colour.
"""
import os
import sys

import numpy as np
from scipy import ndimage as ndi

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
sys.path.insert(0, ROOT)
from tools.rigkit import install_plan as ip          # noqa: E402

_stock_key = ip.key


def key(rgb, gmask=None):
    out, alpha, info = _stock_key(rgb, gmask)
    a = rgb.astype(np.float32)
    bg = np.array(info["ground_rgb"], np.float32)
    d = np.abs(a - bg).max(-1)
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    bl = float(bg @ np.array([0.299, 0.587, 0.114], np.float32))
    chroma = a.max(-1) - a.min(-1)
    # 2. the contour line in the rim
    fg = alpha > 0
    rim = ndi.binary_dilation(alpha >= 0.5, iterations=2) & ~ndi.binary_erosion(alpha >= 0.5, iterations=3)
    line_a = np.clip((bl - lum) / 55.0, 0.0, 1.0)
    fix = rim & (lum < bl - 12) & (chroma < 70) & (line_a > alpha)
    # only where the dark pixel belongs to the figure's own line: next to solid figure
    fix &= ndi.binary_dilation(alpha >= 0.5, iterations=1)
    alpha = alpha.copy()
    out = out.copy()
    alpha[fix] = line_a[fix]
    un = bg + (a - bg) / np.maximum(line_a[..., None], 0.2)
    out[fix] = np.clip(un, 0, 255)[fix]
    # 1. ground-coloured pockets open to the outside
    solid = alpha >= 0.5
    groundlike = solid & (d < 16)
    seed = ndi.binary_dilation(~solid, iterations=2) & groundlike
    pocket = ndi.binary_propagation(seed, mask=groundlike)
    lab, n = ndi.label(pocket)
    keep = np.zeros_like(pocket)
    for i in range(1, n + 1):
        m = lab == i
        if m.sum() >= 4:
            keep |= m
    alpha[keep] = 0.0
    edge = ndi.binary_dilation(keep, iterations=1) & ~keep & (alpha > 0) & (lum > bl - 12) & (chroma < 14)
    alpha[edge] = 0.0
    info = dict(info, fingers_ground_px=int(keep.sum()), contour_rim_px=int(fix.sum()), key_wrapper="install_fix.py")
    return out, alpha, info


ip.key = key

if __name__ == "__main__":
    painting = sys.argv[1]
    rep = ip.install(painting, "half_elf_female", "tilt15", match="half_elf_female/default",
                     debug=sys.argv[2] if len(sys.argv) > 2 else None)
    for k in ("size", "world_scale", "guide_iou", "key", "notes", "build"):
        print(k, rep[k])
