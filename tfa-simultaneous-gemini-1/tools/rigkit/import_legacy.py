"""Port race art + label maps from the old generator repo into race packs.

    python -m tools.rigkit.import_legacy [--src DIR] [race ...]

Reads  <src>/godot/<race>/label_map.png and that race's source painting.
Writes Rigs/races/<race>/default/{body.png, labels.png, race.json}.

This is the one-time bridge: once a race lives in Rigs/, its label map is
edited there and `python -m tools.rigkit.build_race <race>` re-derives frames.
"""
import argparse
import os
import sys

import cv2
import numpy as np
from PIL import Image

from . import core
from .derive import LabelError, derive_frames, label_masks, silhouette

DEFAULT_SRC = r"C:\dev\Procedural Character from Scratch"
MAX_SIDE = 1024          # packs are stored at one resolution class
MARGIN = 24


def _rig_scales():
    """rig folder name -> rig_scale, from data/races.json."""
    out = {}
    races = core.load_json(os.path.join(core.ROOT, "data", "races.json"))["races"]
    for r in races:
        rid = r.get("id", r.get("name", "?"))
        body = r.get("body", {})
        scenes, scales = body.get("rig_scene"), body.get("rig_scale")
        if not isinstance(scenes, dict):
            continue
        for gender, path in scenes.items():
            folder = path.split("/")[-2]
            sc = scales.get(gender) if isinstance(scales, dict) else scales
            if sc:
                out[folder] = {"scale": float(sc), "race": rid, "gender": gender}
    return out


def _source_image(src, race):
    d = os.path.join(src, "godot", race)
    p = os.path.join(d, "source.png")
    if os.path.exists(p):
        return p
    rig = core.load_json(os.path.join(d, "rig.json"))
    for cand in (os.path.join(src, rig["image"]), os.path.join(src, "race art", rig["image"])):
        if os.path.exists(cand):
            return cand
    raise FileNotFoundError("no source art for %s (%s)" % (race, rig["image"]))


def write_pack(race, variant, art_rgb, labels_rgb, legacy_scale, meta):
    """Crop to the silhouette, normalise resolution, key the art, derive frames."""
    sil = silhouette(label_masks(labels_rgb))
    ys, xs = np.nonzero(sil)
    x0, x1 = max(xs.min() - MARGIN, 0), min(xs.max() + MARGIN + 1, sil.shape[1])
    y0, y1 = max(ys.min() - MARGIN, 0), min(ys.max() + MARGIN + 1, sil.shape[0])
    art = art_rgb[y0:y1, x0:x1]
    lab = labels_rgb[y0:y1, x0:x1]
    k = min(1.0, MAX_SIDE / float(max(art.shape[:2])))
    if k < 1.0:
        size = (int(round(art.shape[1] * k)), int(round(art.shape[0] * k)))
        art = cv2.resize(art, size, interpolation=cv2.INTER_AREA)
        lab = cv2.resize(lab, size, interpolation=cv2.INTER_NEAREST)
    masks = label_masks(lab)
    sil = silhouette(masks).astype(np.uint8)
    # soft 1px edge so the keyed body does not alias against the ground
    alpha = cv2.GaussianBlur(sil * 255, (3, 3), 0)
    alpha = np.minimum(alpha, cv2.dilate(sil, np.ones((3, 3), np.uint8)) * 255).astype(np.uint8)
    body = np.dstack([art, alpha])

    world_scale = legacy_scale / k           # world px per pack px
    frames, notes = derive_frames(lab, world_scale)
    out = core.race_dir(race, variant)
    os.makedirs(out, exist_ok=True)
    Image.fromarray(body, "RGBA").save(os.path.join(out, "body.png"), optimize=True)
    Image.fromarray(lab, "RGB").save(os.path.join(out, "labels.png"), optimize=True)
    data = {"id": race, "variant": variant, "art": "body.png", "labels": "labels.png",
            "size": [int(body.shape[1]), int(body.shape[0])],
            "world_scale": round(world_scale, 5), "facing": "south"}
    data.update(meta)
    data["notes"] = notes
    data["frames"] = frames
    core.save_json(os.path.join(out, "race.json"), data)
    return data


def import_race(src, race, scales):
    lab = np.array(Image.open(os.path.join(src, "godot", race, "label_map.png")).convert("RGB"))
    art = np.array(Image.open(_source_image(src, race)).convert("RGB"))
    if art.shape[:2] != lab.shape[:2]:
        raise LabelError("label map %s and art %s differ in size" % (lab.shape[:2], art.shape[:2]))
    info = scales.get(race)
    if info is None:
        raise LabelError("not referenced by data/races.json (no rig_scale)")
    return write_pack(race, "default", art, lab, info["scale"],
                      {"race": info["race"], "gender": info["gender"],
                       "source": "legacy generator: godot/%s" % race})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("races", nargs="*")
    ap.add_argument("--src", default=os.environ.get("RIG_LEGACY_SRC", DEFAULT_SRC))
    a = ap.parse_args(argv)
    scales = _rig_scales()
    races = a.races or sorted(scales)
    failed = 0
    for race in races:
        try:
            d = import_race(a.src, race, scales)
            print("[ok ] %-22s %4dx%-4d frames=%d %s" % (race, d["size"][0], d["size"][1], len(d["frames"]),
                                                       "; ".join(d["notes"])))
        except (LabelError, FileNotFoundError, KeyError) as e:
            failed += 1
            print("[FAIL] %-22s %s" % (race, e))
    print("%d imported, %d failed" % (len(races) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
