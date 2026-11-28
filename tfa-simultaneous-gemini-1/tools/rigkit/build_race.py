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

import cv2
import numpy as np
from PIL import Image

from . import core
from .derive import LabelError, derive_frames, hand_parts, label_masks, skin_ramp


OVERLAY_FEATHER = 0.9    # px (sigma) the head / over-garment overlays' label edge is feathered by
BARE_GROW = 3            # px the head label is grown by, so the head's painted contour goes with it
BARE_PAD = 2             # px of untouched painting kept round the box
FEET_REACH = (2.0, 3.5)  # trunk-over-feet region, in foot half-widths either side / half-lengths north


def bare_patch(body_rgba, masks, frames):
    """The `bare` overlay (core.py, head enclosure): the head's box of the painting with the head
    removed. Under the head the trunk is plain skin, inpainted from the body around it; "under the
    head" is the torso frame's own footprint (a squarish ellipse), so ears and hair that hang past
    the trunk become nothing. Returns (RGBA crop, (x0, y0)) or None."""
    head = np.zeros(body_rgba.shape[:2], bool)
    for name in ("face", "hair"):
        if name in masks:
            head |= masks[name]
    if not head.any() or "torso" not in frames:
        return None
    h, w = head.shape
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * BARE_GROW + 1, 2 * BARE_GROW + 1))
    gone = cv2.dilate(head.astype(np.uint8), k) > 0
    ys, xs = np.nonzero(gone)
    x0, x1 = max(int(xs.min()) - BARE_PAD, 0), min(int(xs.max()) + 1 + BARE_PAD, w)
    y0, y1 = max(int(ys.min()) - BARE_PAD, 0), min(int(ys.max()) + 1 + BARE_PAD, h)
    m = 64                                              # context the fill is drawn from
    cx0, cy0, cx1, cy1 = max(x0 - m, 0), max(y0 - m, 0), min(x1 + m, w), min(y1 + m, h)
    crop = body_rgba[cy0:cy1, cx0:cx1]
    g = gone[cy0:cy1, cx0:cx1]
    # plain skin: the trunk's own colour away from its contour lines, spread smoothly under the head
    skin = masks["body"][cy0:cy1, cx0:cx1] & ~g & (crop[:, :, 3] > 200)
    skin = cv2.erode(skin.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11))) > 0
    if int(skin.sum()) < 30:
        skin = ~g & (crop[:, :, 3] > 200)
    if int(skin.sum()) < 30:
        return None
    sig = max(8.0, 0.10 * max(x1 - x0, y1 - y0))
    wt = cv2.GaussianBlur(skin.astype(np.float32), (0, 0), sig)
    mean = crop[:, :, :3][skin].astype(np.float32).mean(0)
    fill = np.zeros(crop.shape[:2] + (3,), np.float32)
    for c in range(3):
        num = cv2.GaussianBlur(np.where(skin, crop[:, :, c], 0).astype(np.float32), (0, 0), sig)
        fill[:, :, c] = np.where(wt > 0.02, num / np.maximum(wt, 1e-4), mean[c])
    yy, xx = np.mgrid[cy0:cy1, cx0:cx1]
    U, V = core.frame_local(frames["torso"], np.stack([xx.ravel(), yy.ravel()], 1).astype(float))
    under = ((np.abs(U) ** 3 + np.abs(V) ** 3) <= 1.0).reshape(g.shape)
    keep = g & under
    # the patch's own contour, where it now borders nothing
    solid = keep | (~g & (crop[:, :, 3] > 127))
    dist = cv2.distanceTransform(solid.astype(np.uint8), cv2.DIST_L2, 3)
    line = np.clip(1.0 - (dist - 1.0) / 2.5, 0.0, 1.0)[:, :, None] * 0.62
    fill = fill * (1.0 - line)
    out = crop.copy()
    out[keep, :3] = np.clip(fill[keep] + 0.5, 0, 255).astype(np.uint8)
    out[keep, 3] = 255
    out[g & ~under] = 0
    return out[y0 - cy0:y1 - cy0, x0 - cx0:x1 - cx0], (x0, y0)


def trunk_patch(body_rgba, masks, frames):
    """The `trunk` overlay (core.py, trunk over feet): the trunk's pixels around the feet, for a
    pack whose legs are hidden. Returns (RGBA crop, (x0, y0)) or None."""
    if "leg_l" in frames or "leg_r" in frames or "body" not in masks:
        return None
    h, w = masks["body"].shape
    region = np.zeros((h, w), bool)
    for s in "lr":
        f = frames.get("foot_" + s)
        if f is None:
            continue
        ox, oy, half_len, half_w = f["o"][0], f["o"][1], f["lx"], f["ly"]
        xa, xb = int(max(ox - (1 + FEET_REACH[0]) * half_w, 0)), int(min(ox + (1 + FEET_REACH[0]) * half_w, w))
        ya, yb = int(max(oy - FEET_REACH[1] * half_len, 0)), int(min(oy + half_len + 2, h))
        region[ya:yb, xa:xb] = True
    m = masks["body"] & region
    if int(m.sum()) < 20:
        return None
    ys, xs = np.nonzero(m)
    x0, x1, y0, y1 = int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1
    cut = body_rgba[y0:y1, x0:x1].copy()
    cut[:, :, 3] = np.where(m[y0:y1, x0:x1], cut[:, :, 3], 0)
    return cut, (x0, y0)


def write_overlays(folder, body_rgba, lab, frames=None):
    """Body pixels that must be drawn again ABOVE worn items: the head (over
    collars and capes) and any over-garment anatomy (crests, fins, tail coils).
    Cropped PNGs + their offset, so the engine needs no label map at runtime.
    With `frames`, also `bare` (the head's box with the head removed, shown under
    enclosing headwear) and `trunk` (the trunk round the feet, drawn over boots)."""
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
        # the label's edge is a hard staircase: feather it over about a pixel, so the head drawn
        # over a collar or a cape has a clean edge (under it the body shows the very same pixels)
        soft = cv2.GaussianBlur(m.astype(np.float32), (0, 0), OVERLAY_FEATHER)[y0:y1, x0:x1]
        soft = np.clip((soft - 0.25) / 0.5, 0.0, 1.0)
        cut[:, :, 3] = np.round(cut[:, :, 3] * soft).astype(np.uint8)
        Image.fromarray(cut, "RGBA").save(path, optimize=True)
        out[name] = {"file": name + ".png", "offset": [int(x0), int(y0)]}
    if frames is not None:
        for name, patch in (("bare", bare_patch(body_rgba, masks, frames)),
                            ("trunk", trunk_patch(body_rgba, masks, frames))):
            path = os.path.join(folder, name + ".png")
            if patch is None:
                if os.path.exists(path):
                    os.remove(path)
                continue
            Image.fromarray(patch[0], "RGBA").save(path, optimize=True)
            out[name] = {"file": name + ".png", "offset": [int(patch[1][0]), int(patch[1][1])],
                         "size": [int(patch[0].shape[1]), int(patch[0].shape[0])]}
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
        own["overlays"] = write_overlays(d, rgba, lab, merged.get("frames"))
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
    own["overlays"] = write_overlays(d, rgba, lab, frames)
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
