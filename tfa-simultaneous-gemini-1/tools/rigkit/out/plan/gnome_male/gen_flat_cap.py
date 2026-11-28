"""gnome_male only: run gen_plan.gen with the cap's shading flattened in the tinted guide.
The Lambert gradient on the smooth cone reads as a glossy highlight and the model copies it.
Usage (project folder): python tools/rigkit/out/plan/gnome_male/gen_flat_cap.py <tag> <n> [guide-only]
"""
import os, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.getcwd())
from tools.rigkit import gen_plan as gp

_orig = gp.save_guide


def save_guide(race, tilt=None):
    st = _orig(race, tilt)
    path = os.path.join(gp.race_out(race), gp.guide_prefix(gp.race_tilt(race, tilt)) + "_tint.png")
    a = np.array(Image.open(path).convert("RGB")).astype(np.float32)
    hat = np.array(gp.RACES[race]["colours"]["hat"], np.float32)
    red = (a[..., 0] > 1.8 * a[..., 1]) & (a[..., 0] > 1.8 * a[..., 2])
    L = np.clip(a[..., 0] / (hat[0] * 1.25), 0, 1)          # the guide's own shade on the cap
    f = np.minimum(L / 0.45, 1.0) * 0.80 + np.clip(L - 0.45, 0, 1) * 0.30   # keep outline/creases, flatten the rest
    out = np.where(red[..., None], np.clip(hat[None, None] * 1.25 * f[..., None], 0, 255), a)
    Image.fromarray(out.astype(np.uint8)).save(path)
    return st


gp.save_guide = save_guide
if __name__ == "__main__":
    if len(sys.argv) > 3:
        save_guide("gnome_male")
    else:
        gp.gen("gnome_male", int(sys.argv[2]), sys.argv[1])
