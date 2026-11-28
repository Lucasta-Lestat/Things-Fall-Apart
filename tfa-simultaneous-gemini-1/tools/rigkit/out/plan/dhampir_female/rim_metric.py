"""Share of a pack's 2 px silhouette rim that is bright (i.e. not contour). python rim_metric.py race/variant ..."""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
for p in sys.argv[1:]:
    im = np.asarray(Image.open("Rigs/races/%s/body.png" % p).convert("RGBA")).astype(np.float32)
    op = im[:, :, 3] >= 128
    lum = im[:, :, :3] @ np.array([0.299, 0.587, 0.114], np.float32)
    for w in (1, 2, 3):
        rim = op & ~ndi.binary_erosion(op, iterations=w)
        print("%-28s rim %d px: bright(lum>150) %.2f  dark(lum<90) %.2f  median lum %.0f" % (
            p, w, float((lum[rim] > 150).mean()), float((lum[rim] < 90).mean()), float(np.median(lum[rim]))))
