"""human_female only: the painted hair is smaller than the guide's hair lumps, so guide 'hair' pixels
that were painted as skin (beside the face, on the shoulders) would be drawn above shirts and robes.
Writes <tag>fix_{labels,mask}.png + <tag>fix.json: the tag's guide with the hair label re-cut on the
painted hair colour. Install with:  install_plan <painting> ... --guide tools/rigkit/out/plan/human_female/<tag>fix
Usage: python tools/rigkit/out/plan/human_female/fix_hair_labels.py r1 3"""
import os, sys, shutil
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
sys.path.insert(0, os.getcwd())
from tools.rigkit.gen_plan import PALETTE

here = os.path.dirname(os.path.abspath(__file__))
tag, n = sys.argv[1], sys.argv[2]
rgb = np.asarray(Image.open(os.path.join(here, "%s_%s.png" % (tag, n))).convert("RGB")).astype(np.float32)
lab = np.asarray(Image.open(os.path.join(here, tag + ".guide_labels.png")).convert("RGB")).copy()
if rgb.shape[:2] != lab.shape[:2]:
    raise SystemExit("size mismatch")
col = lambda name: np.array(PALETTE[name], np.uint8)
is_ = lambda name: (lab == col(name)).all(-1)
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
sat = (r - b) / np.maximum(r, 1.0)
fig = np.abs(rgb - 128.0).max(-1) > 14                      # not ground
hairc = (sat > 0.48) & (r > 90) & (r - g > 45)              # copper hair; skin is sat ~0.25
ghair = is_("hair")
near = ndi.binary_dilation(ghair | is_("face"), iterations=30)
hair = ndi.binary_closing(hairc & near, iterations=4)
hair = ndi.binary_fill_holes(hair)
cc, k = ndi.label(hair)
if k > 1:
    hair = cc == (1 + int(np.argmax(ndi.sum(hair, cc, range(1, k + 1)))))
hair = ndi.binary_dilation(hair, iterations=3) & fig & near  # take the dark contour round the hair
hair &= ~(is_("face") & ~ndi.binary_dilation(hairc, iterations=2))   # keep painted face skin as face
out = lab.copy()
lost = ghair & ~hair                                        # guide hair painted as skin: nearest other label
other = (lab.sum(-1) > 0) & ~ghair
_, (iy, ix) = ndi.distance_transform_edt(~other, return_indices=True)
out[lost] = lab[iy[lost], ix[lost]]
out[hair & (out.sum(-1) > 0)] = col("hair")
pre = os.path.join(here, tag + "fix")
Image.fromarray(out).save(pre + "_labels.png")
shutil.copyfile(os.path.join(here, tag + ".guide_mask.png"), pre + "_mask.png")
shutil.copyfile(os.path.join(here, tag + ".guide.json"), pre + ".json")
print("hair px guide %d -> %d; relabelled to skin %d" % (ghair.sum(), (out == col("hair")).all(-1).sum(), lost.sum()))
