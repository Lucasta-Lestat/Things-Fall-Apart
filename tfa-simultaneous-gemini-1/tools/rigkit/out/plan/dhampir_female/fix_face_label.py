"""dhampir_female corrective pass, run AFTER install_plan (see prep_contour.py).

install_plan's head snap only moves the head/trunk boundary; the face/hair split is the guide's, and on
this painting it left the forehead and brows as hair, a hair sliver under the chin and the jaw corners
as trunk. This re-finds the face on the painting itself: a watershed between the pale face, the dark
hair mass and the chest, on the pack's body.png. Rewrites Rigs/races/dhampir_female/tilt15/labels.png
(face / hair / body pixels round the face only) and rebuilds the pack.

    python tools/rigkit/out/plan/dhampir_female/fix_face_label.py [--debug OUT.png]
"""
import os
import sys
import cv2
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
sys.path.insert(0, ROOT)
from tools.rigkit import build_race                     # noqa: E402
from tools.rigkit.derive import PALETTE                 # noqa: E402

PACK = os.path.join(ROOT, "Rigs", "races", "dhampir_female", "tilt15")
body = np.asarray(Image.open(os.path.join(PACK, "body.png")).convert("RGBA"))
lab = np.asarray(Image.open(os.path.join(PACK, "labels.png")).convert("RGB")).copy()
rgb = body[:, :, :3]
op = body[:, :, 3] >= 128
lum = rgb.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)


def is_(name):
    return np.abs(lab.astype(np.int32) - np.array(PALETTE[name], np.int32)).sum(2) <= 40


face0, hair0, trunk0 = is_("face"), is_("hair"), is_("body")
ys, xs = np.nonzero(face0)
cx, cy = xs.mean(), ys.mean()
R = 0.5 * (xs.max() - xs.min())                          # half face width
yy, xx = np.mgrid[:lab.shape[0], :lab.shape[1]]
zone = op & (np.abs(xx - cx) < 1.6 * R) & (yy > ys.min() - 1.6 * R) & (yy < ys.max() + 1.2 * R)

# seeds
dark = op & (lum < 80)
dl, dn = ndi.label(ndi.binary_erosion(dark, iterations=2))
sizes = ndi.sum(dark, dl, range(1, dn + 1))
hair_seed = np.isin(dl, 1 + np.nonzero(sizes > 1500)[0]) & hair0
face_seed = ndi.binary_erosion(face0, iterations=3) & (lum > 150)
far = ndi.distance_transform_edt(~(face0 | hair0))
chest_seed = trunk0 & (far > 0.55 * R) & (yy > cy)
markers = np.zeros(lab.shape[:2], np.int32)
markers[~zone] = 1
markers[trunk0 & ~zone] = 1
markers[chest_seed] = 2
markers[hair_seed] = 3
markers[face_seed] = 4
img = cv2.GaussianBlur(rgb, (0, 0), 1.0)
cv2.watershed(np.ascontiguousarray(img), markers)
face = markers == 4
face = ndi.binary_closing(face, iterations=3) & zone & ~hair_seed
face = ndi.binary_fill_holes(face)                       # brows, lash lines
face = ndi.binary_opening(face, iterations=1)
fl, fn = ndi.label(face)
face = fl == (1 + int(np.argmax(ndi.sum(face, fl, range(1, fn + 1)))))
# hair strands that cross the forehead stay hair only where they are solid dark mass
face &= (face0 | hair0 | trunk0)
grow = float(face.sum()) / float(face0.sum())
if not (1.0 <= grow <= 4.0):
    raise SystemExit("face watershed implausible (area x%.2f): labels left alone" % grow)

head_was = face0 | hair0
lab[face0 & ~face] = PALETTE["hair"]                     # (does not happen in practice)
lab[face] = PALETTE["face"]
# hair-labelled pale skin left outside the face and below it (the sliver under the chin) is trunk
stray = hair0 & ~face & (lum > 140) & zone & (yy > cy)
sl, sn = ndi.label(stray)
for i in range(1, sn + 1):
    m = sl == i
    if ndi.binary_dilation(m, iterations=2)[trunk0].any():
        lab[m] = PALETTE["body"]
# hair specks cut off from the hair mass (the contour line under the jaw) join the trunk or the face
hl, hn = ndi.label(is_("hair"))
for i in range(1, hn + 1):
    m = hl == i
    if int(m.sum()) < 300:
        near = ndi.binary_dilation(m, iterations=2)
        lab[m] = PALETTE["body"] if (near & is_("body")).any() else PALETTE["face"]
Image.fromarray(lab, "RGB").save(os.path.join(PACK, "labels.png"), optimize=True)
print("face label area x%.2f" % grow)
print(build_race.build("dhampir_female", "tilt15")[1])
if "--debug" in sys.argv:
    ov = (rgb * 0.45 + lab * 0.55).astype(np.uint8)
    ov[~op] = (40, 40, 40)
    Image.fromarray(ov).save(sys.argv[sys.argv.index("--debug") + 1])
