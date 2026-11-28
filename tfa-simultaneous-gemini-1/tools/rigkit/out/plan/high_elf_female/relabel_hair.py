"""high_elf_female only: rebuild the head labels of a tag's guide from the PAINTED hair colour.

The painted hair (saturated yellow) does not follow the guide's stiff hair forms, and install_plan's
head snap leaks hair onto the shoulders. This writes <tag>fix.guide{.json,_labels.png,_mask.png}
for `install_plan --guide ... --no-head-snap`.
usage: python tools/rigkit/out/plan/high_elf_female/relabel_hair.py r2 1
"""
import json, os, shutil, sys
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

D = os.path.dirname(os.path.abspath(__file__))
tag, n = sys.argv[1], sys.argv[2]
src = os.path.join(D, tag + ".guide")
dst = os.path.join(D, tag + "fix.guide")
st = json.load(open(src + ".json"))
C = {k: np.array(v) for k, v in st["label_colours"].items()}
lab = np.asarray(Image.open(src + "_labels.png").convert("RGB")).astype(int)
rgb = np.asarray(Image.open(os.path.join(D, "%s_%s.png" % (tag, n))).convert("RGB")).astype(int)
names = list(C)
dist = np.stack([np.abs(lab - C[k]).sum(-1) for k in names], -1)
idx = dist.argmin(-1)
BG = names.index("background")
_, (iy, ix) = ndi.distance_transform_edt(idx == BG, return_indices=True)
full = idx[iy, ix]                                   # every pixel: nearest guide label
H, B, F = names.index("hair"), names.index("body"), names.index("face")
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
yellow = (r > 140) & (g > 100) & (b < 0.62 * g)
yellow = ndi.binary_closing(yellow, iterations=3)    # swallow the dark strand lines
cl, cn = ndi.label(yellow)
sizes = ndi.sum(yellow, cl, range(1, cn + 1))
hair = np.isin(cl, [i + 1 for i, s in enumerate(sizes) if s > 1500])   # brows are small: stay face
zone = (full == H) | (full == B) | (full == F)
core_face = (idx == F) & (np.abs(np.arange(idx.shape[1])[None, :] - st["skull_centre"][0]) < 0.75 * st["skull_r_px"])
cy, cx = np.nonzero(core_face)
chin, x0, x1 = cy.max(), cx.min(), cx.max()
yy, xx = np.mgrid[:idx.shape[0], :idx.shape[1]]
forehead = (full == H) & ~hair & (yy <= chin) & (xx >= x0 - 6) & (xx <= x1 + 6) & (yy > st["skull_centre"][1])
out = full.copy()
out[zone & hair] = H
out[zone & ~hair & (full == H)] = B
out[forehead] = F
out[(full == F) & ~hair] = F
res = np.stack([C[k] for k in names])[out].astype(np.uint8)
Image.fromarray(res, "RGB").save(dst + "_labels.png")
shutil.copy(src + "_mask.png", dst + "_mask.png")
shutil.copy(src + ".json", dst + ".json")
print("wrote", dst)
