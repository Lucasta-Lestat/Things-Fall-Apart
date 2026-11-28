"""A procedural re-skin variant: the parent's painting recoloured on the parent's canvas.

    python -m tools.rigkit.reskin <race> <variant> [--parent default] [--tint 0.975,0.985,0.86]

Each pixel becomes its luminance times the tint (the default is the grey-green `orc/ashen` demo).
Writes Rigs/races/<race>/<variant>/body.png and a race.json holding only {"inherits", "variant",
"art", "source"}, then runs build_race, which adds the overlays and the skin ramp. A painted re-skin
is the same thing with a hand-made body.png (docs 3.2).
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

from . import build_race, core


def reskin(race, variant, parent="default", tint=(0.975, 0.985, 0.86)):
    base = core.load_race(race, parent)
    rgba = np.asarray(Image.open(core.race_file(base, "art")).convert("RGBA")).astype(np.float32)
    lum = rgba[:, :, :3] @ np.array([0.299, 0.587, 0.114], np.float32)
    out = rgba.copy()
    out[:, :, :3] = np.clip(lum[:, :, None] * np.array(tint, np.float32), 0, 255)
    d = core.race_dir(race, variant)
    os.makedirs(d, exist_ok=True)
    for name in os.listdir(d):                       # overlays of an earlier canvas
        if name.endswith(".png"):
            os.remove(os.path.join(d, name))
    Image.fromarray(np.round(out).astype(np.uint8), "RGBA").save(os.path.join(d, "body.png"), optimize=True)
    core.save_json(os.path.join(d, "race.json"), {
        "inherits": parent, "variant": variant, "art": "body.png",
        "source": "procedural recolour of %s/%s (demo of a re-skin variant)" % (race, parent)})
    _, msg = build_race.build(race, variant)
    print("[ok ] %s/%s  %s" % (race, variant, msg))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("race")
    ap.add_argument("variant")
    ap.add_argument("--parent", default="default")
    ap.add_argument("--tint", default="0.975,0.985,0.86")
    a = ap.parse_args(argv)
    reskin(a.race, a.variant, a.parent, tuple(float(v) for v in a.tint.split(",")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
