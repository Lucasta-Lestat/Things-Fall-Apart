"""dhampir_female corrective pass: r2_2.png -> r2k_2.png.

The painting's contour (warm grey, lum ~87) and nails (grey, lum ~125) are as grey as the 126 ground,
so install_plan.key() peels them as contact shadow. This darkens the contour band and the nail wedges
to charcoal so the key's "peeling stops at the dark outline" rule holds. Nothing else is touched.

    python tools/rigkit/out/plan/dhampir_female/prep_contour.py
    python -m tools.rigkit.install_plan tools/rigkit/out/plan/dhampir_female/r2k_2.png --race dhampir_female \
        --variant tilt15 --match dhampir_female/default --guide tools/rigkit/out/plan/dhampir_female/r2.guide
    python tools/rigkit/out/plan/dhampir_female/fix_face_label.py
"""
import os
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
DARK = np.array([45, 42, 48], np.float32)
NAIL = np.array([62, 58, 64], np.float32)

a = np.asarray(Image.open(os.path.join(HERE, "r2_2.png")).convert("RGB")).astype(np.float32)
bg = np.median(a[:24, :24].reshape(-1, 3), 0)
d = np.abs(a - bg).max(-1)
ch = a.max(-1) - a.min(-1)
lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
P = d > 12
lab, n = ndi.label(P)
P = lab == (1 + int(np.argmax(ndi.sum(P, lab, range(1, n + 1)))))
S = ndi.binary_fill_holes(ndi.binary_closing(P, iterations=1))

# contour: near-neutral, darker than the ground, within 4 px of the silhouette edge. key() mattes the
# outer 2 px of the silhouette with the colour found 2 px further in, so on pale skin a line thinner
# than 3 px is replaced by skin: the line is made solid and grown 1 px outward (GROW) so 3 px are dark.
GROW = 1
band = S & ~ndi.binary_erosion(S, iterations=4)
t = np.clip((120.0 - lum) / 8.0, 0.0, 1.0) * (band & (ch < 30))
line = t > 0.5
ring = ndi.binary_dilation(S, iterations=GROW) & ~S & ndi.binary_dilation(line, iterations=GROW + 1)
t = np.maximum(t, ring.astype(np.float32))
out = a * (1 - t[:, :, None]) + DARK * t[:, :, None]

# nails: neutral grey wedges at the fingertips (hands are the outer 130 px either side)
zone = np.zeros_like(S)
zone[:, :130] = True
zone[:, -130:] = True
nail = S & zone & (ch < 16) & (lum < 150) & ndi.binary_erosion(S, iterations=1) & (t < 0.5)
nail = ndi.binary_opening(nail, iterations=1)
w = ndi.gaussian_filter(nail.astype(np.float32), 0.7)[:, :, None]
shade = np.clip(lum / 125.0, 0.75, 1.25)[:, :, None]          # keep the nail's own modelling
out = out * (1 - w) + (NAIL * shade) * w
Image.fromarray(np.clip(np.round(out), 0, 255).astype(np.uint8)).save(os.path.join(HERE, "r2k_2.png"))
print("contour px darkened %d, nail px %d" % (int((t > 0.5).sum()), int(nail.sum())))
