"""Label map -> race frames.

Everything a race pack knows about its own anatomy is measured here, from the
painted label map and nothing else. (The old generator took the neck, root and
torso width from silhouette column profiles and only the arm joints from the
labels; the two sources disagreed, which is where most "floating garment" bugs
came from.)

`_l` / `_r` are IMAGE left / right, and every pack faces south (toes toward the
bottom of the picture), so `_r` is the character's left hand. Kept as-is from
the old pipeline because all 54 label maps are painted that way.
"""
import cv2
import numpy as np

from .core import make_frame

PALETTE = {
    "body": (60, 180, 75),
    "face": (230, 25, 75),
    "hair": (245, 130, 48),
    "upperarm_l": (0, 130, 200),
    "upperarm_r": (70, 190, 255),
    "forearm_l": (145, 30, 180),
    "forearm_r": (240, 50, 230),
    "hand_l": (255, 150, 200),
    "hand_r": (160, 20, 90),
    "leg_l": (0, 230, 230),
    "leg_r": (0, 100, 90),
    "foot_l": (255, 225, 25),
    "foot_r": (170, 180, 40),
    # anatomy that sits OVER worn garments (crests, fins, folded wings, tail coils)
    "over_garment": (255, 255, 255),
}
TOL = 40
HEAD_SKULL_GROW = 1.06    # inscribed circle -> skull outline
MIN_PX_FRAC = 0.00025     # ignore label specks smaller than this share of the canvas


class LabelError(Exception):
    pass


def label_masks(labels_rgb):
    """labels_rgb: HxWx3 uint8 (RGB). Returns {name: bool mask} for labels present."""
    img = labels_rgb.astype(np.int32)
    h, w = img.shape[:2]
    floor = max(40, int(MIN_PX_FRAC * h * w))
    out = {}
    for name, rgb in PALETTE.items():
        m = np.abs(img - np.array(rgb, np.int32)).sum(axis=2) <= TOL
        if int(m.sum()) >= floor:
            out[name] = m
    return out


def silhouette(masks):
    s = None
    for m in masks.values():
        s = m.copy() if s is None else (s | m)
    return s


def _seam(a, b, r=3):
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))
    touch = a & (cv2.dilate(b.astype(np.uint8), k) > 0)
    if int(touch.sum()) < 3:
        return None
    ys, xs = np.nonzero(touch)
    return np.array([xs.mean(), ys.mean()])


def _centroid(m):
    ys, xs = np.nonzero(m)
    return np.array([xs.mean(), ys.mean()])


def _radius(mask, a, b):
    """Mean half-thickness of a limb segment: area / (2 * length)."""
    length = float(np.hypot(*(b - a)))
    return float(mask.sum()) / max(2.0 * length, 1.0)


def derive_frames(labels_rgb, world_scale):
    """Returns (frames, notes). Raises LabelError when a required label is missing."""
    m = label_masks(labels_rgb)
    notes = []
    for need in ("body", "upperarm_l", "upperarm_r", "forearm_l", "forearm_r", "hand_l", "hand_r"):
        if need not in m:
            raise LabelError("label map has no %r region" % need)
    trunk = m["body"] | m.get("over_garment", np.zeros_like(m["body"]))
    frames = {}
    sh = {}
    for s in ("l", "r"):
        up, fo, ha = m["upperarm_" + s], m["forearm_" + s], m["hand_" + s]
        shoulder = _seam(up, trunk)
        elbow = _seam(up, fo)
        wrist = _seam(fo, ha)
        if shoulder is None or elbow is None or wrist is None:
            raise LabelError("arm %s: labels do not touch (shoulder/elbow/wrist seam missing)" % s)
        ys, xs = np.nonzero(ha)
        d = (xs - wrist[0]) ** 2 + (ys - wrist[1]) ** 2
        tip = np.array([xs[d.argmax()], ys[d.argmax()]], float)
        sh[s] = shoulder
        frames["upperarm_" + s] = make_frame(shoulder, elbow, np.hypot(*(elbow - shoulder)), _radius(up, shoulder, elbow))
        frames["forearm_" + s] = make_frame(elbow, wrist, np.hypot(*(wrist - elbow)), _radius(fo, elbow, wrist))
        frames["hand_" + s] = make_frame(wrist, tip, np.hypot(*(tip - wrist)), _radius(ha, wrist, tip))
        # held gear: origin in the palm, axis along the hand, lx = rig px per world px
        palm = _centroid(ha)
        k = 1.0 / world_scale
        frames["grip_" + s] = make_frame(palm, palm + (tip - wrist), k, k)

    # torso: origin midway between the shoulders, axis along the shoulder line,
    # across = how far the trunk reaches toward the back (-) and the front (+)
    o = (sh["l"] + sh["r"]) / 2.0
    half = float(np.hypot(*(sh["r"] - sh["l"]))) / 2.0
    ax = (sh["r"] - sh["l"]) / (2.0 * half)
    perp = np.array([-ax[1], ax[0]])
    ys, xs = np.nonzero(m["body"])
    p = np.stack([xs, ys], axis=1) - o
    u, v = p @ ax, p @ perp
    inside = np.abs(u) <= half
    if int(inside.sum()) < 50:
        raise LabelError("no body pixels between the shoulders")
    front = float(np.percentile(v[inside], 99.5))
    back = float(-np.percentile(v[inside], 0.5))
    frames["torso"] = make_frame(o, ax=ax, lx=half, ly=max(front, 1.0), ly_neg=max(back, 1.0))
    # back: the trunk's rear edge, where capes and packs hang from. Facing south,
    # the back is up-screen, so a back item shows only what pokes out past this line.
    frames["back"] = make_frame(o - perp * back, ax=ax, lx=half, ly=max(back, 1.0))

    # head: a circle fitted to the cranium. Opening strips strands and braids;
    # the width is read off the upper part so a beard does not widen the helmet.
    head = None
    for name in ("face", "hair"):
        if name in m:
            head = m[name] if head is None else (head | m[name])
    if head is None:
        raise LabelError("label map has neither face nor hair")
    # The largest circle that fits inside the head label: ears, horns, beards and
    # stray locks stick OUT of it, so they cannot inflate a helmet.
    dist = cv2.distanceTransform(head.astype(np.uint8), cv2.DIST_L2, 5)
    _, r, _, _ = cv2.minMaxLoc(dist)
    # several circles nearly as large usually fit (skull + beard, skull + mane):
    # the skull is the one nearest the top of the head, i.e. furthest from the chest
    ny, nx = np.nonzero(dist >= 0.88 * r)
    keep = ny <= np.percentile(ny, 30)
    cx, cy = float(nx[keep].mean()), float(ny[keep].mean())
    r = float(dist[int(round(cy)), int(round(cx))]) * HEAD_SKULL_GROW
    ys, xs = np.nonzero(head)
    top, bot = int(ys.min()), int(ys.max())
    height = float(bot - top + 1)
    frames["head"] = make_frame((cx, cy), ax=(1.0, 0.0), lx=r, ly=r)
    frames["head_full"] = make_frame(((xs.min() + xs.max()) / 2.0, (top + bot) / 2.0), ax=(1.0, 0.0),
                                     lx=(xs.max() - xs.min() + 1) / 2.0, ly=height / 2.0)

    for s in ("l", "r"):
        if "foot_" + s in m:
            ys, xs = np.nonzero(m["foot_" + s])
            # axis heel -> toe (south), so "across" is the lateral direction on both feet
            frames["foot_" + s] = make_frame(((xs.min() + xs.max()) / 2.0, (ys.min() + ys.max()) / 2.0),
                                             ax=(0.0, 1.0), lx=(ys.max() - ys.min() + 1) / 2.0,
                                             ly=(xs.max() - xs.min() + 1) / 2.0)
        else:
            notes.append("no foot_%s label: feet items cannot be worn" % s)
        if "leg_" + s in m and "foot_" + s in m:
            leg = m["leg_" + s]
            ys, xs = np.nonzero(leg)
            hip = np.array([np.median(xs[ys <= ys.min() + 2]), ys.min()], float)
            fy, fx = np.nonzero(m["foot_" + s])
            ankle = np.array([fx[fy <= fy.min() + 2].mean(), fy.min()], float)
            frames["leg_" + s] = make_frame(hip, ankle, np.hypot(*(ankle - hip)), _radius(leg, hip, ankle))
    if "leg_l" not in frames or "leg_r" not in frames:
        frames.pop("leg_l", None)
        frames.pop("leg_r", None)
        notes.append("legs not visible from above: leg items are hidden on this race")
    return frames, notes
