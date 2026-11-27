"""Re-derive a race pack's frames from its own label map.

    python -m tools.rigkit.build_race [race[/variant] ...]      (default: all)

Run after editing labels.png, or after dropping a new variant folder in
Rigs/races/<race>/. A variant folder needs only:

    race.json   {"inherits": "default"}            re-skin: same silhouette, new body.png
    race.json   {"inherits": "default", "labels": "labels.png"}   new build: own labels too

Frames listed in "pinned" are hand-set and are left alone.
"""
import os
import sys

import numpy as np
from PIL import Image

from . import core
from .derive import LabelError, derive_frames, hand_parts, label_masks, skin_ramp


def write_overlays(folder, body_rgba, lab):
    """Body pixels that must be drawn again ABOVE worn items: the head (over
    collars and capes) and any over-garment anatomy (crests, fins, tail coils).
    Cropped PNGs + their offset, so the engine needs no label map at runtime."""
    masks = label_masks(lab)
    out = {}
    groups = {"head": ("face", "hair"), "over": ("over_garment",)}
    for name, labels in groups.items():
        m = np.zeros(lab.shape[:2], bool)
        for l in labels:
            if l in masks:
                m |= masks[l]
        path = os.path.join(folder, name + ".png")
        if not m.any():
            if os.path.exists(path):
                os.remove(path)
            continue
        ys, xs = np.nonzero(m)
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        cut = body_rgba[y0:y1, x0:x1].copy()
        cut[:, :, 3] = np.where(m[y0:y1, x0:x1], cut[:, :, 3], 0)
        Image.fromarray(cut, "RGBA").save(path, optimize=True)
        out[name] = {"file": name + ".png", "offset": [int(x0), int(y0)]}
    return out


def hand_rig(own, merged, body_rgba, lab, relabelled):
    """The hand rig's race data (docs 3.6): the skin ramp of THIS body, and, when the
    pack has its own labels, the open-hand cut-outs. Returns the (grip_u, wrist_u) to
    derive with ((None, 1) when no hand set is installed: the pack then keeps the old
    grip only)."""
    hs = core.race_hand_set(merged, core.skeleton())
    if hs is None:
        return None, 1.0
    skin = skin_ramp(body_rgba, lab)
    if skin is not None:
        own["skin"] = skin
    if relabelled:
        own["parts"] = hand_parts(lab)
    return float(hs["poses"]["grip"]["grip_u"]), float(hs["poses"]["grip"].get("wrist_u", 1.0))


def build(race, variant):
    d = core.race_dir(race, variant)
    path = os.path.join(d, "race.json")
    own = core.load_json(path)
    merged = core.load_race(race, variant)
    if "labels" not in own and own.get("inherits"):
        # pure re-skin: frames come from the parent, nothing to derive
        body = Image.open(core.race_file(merged, "art"))
        if list(body.size) != list(merged["size"]):
            raise LabelError("re-skin body.png is %s, parent is %s: paint it on the parent's canvas "
                             "or give the variant its own labels.png" % (body.size, merged["size"]))
        lab = np.array(Image.open(core.race_file(merged, "labels")).convert("RGB"))
        rgba = np.array(body.convert("RGBA"))
        own["overlays"] = write_overlays(d, rgba, lab)
        hand_rig(own, merged, rgba, lab, False)
        core.save_json(path, own)
        return core.load_race(race, variant), "re-skin of %s" % own["inherits"]
    lab = np.array(Image.open(core.race_file(merged, "labels")).convert("RGB"))
    body = Image.open(core.race_file(merged, "art"))
    if body.size != (lab.shape[1], lab.shape[0]):
        raise LabelError("body.png %s and labels.png %s differ in size" % (body.size, lab.shape[1::-1]))
    rgba = np.array(body.convert("RGBA"))
    grip_u, wrist_u = hand_rig(own, merged, rgba, lab, True)
    frames, notes = derive_frames(lab, float(merged["world_scale"]), grip_u, wrist_u)
    for name in own.get("pinned", []):
        frames[name] = own["frames"][name]
    own["overlays"] = write_overlays(d, rgba, lab)
    own["size"] = [int(lab.shape[1]), int(lab.shape[0])]
    own["notes"] = notes
    own["frames"] = frames
    core.save_json(path, own)
    return core.load_race(race, variant), "derived %d frames" % len(frames)


def main(argv=None):
    args = (argv if argv is not None else sys.argv[1:])
    targets = [tuple(a.split("/")) if "/" in a else (a, None) for a in args]
    todo = [(r, v) for r, v in core.list_races()
            if not targets or (r, v) in targets or (r, None) in targets]
    failed = 0
    for r, v in todo:
        try:
            _, msg = build(r, v)
            print("[ok ] %-28s %s" % (r + "/" + v, msg))
        except (LabelError, FileNotFoundError, KeyError) as e:
            failed += 1
            print("[FAIL] %-28s %s" % (r + "/" + v, e))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
