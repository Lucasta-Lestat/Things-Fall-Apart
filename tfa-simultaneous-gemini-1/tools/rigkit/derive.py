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


PALM_AXIS_MAX_DEG = 25.0  # palm axis further than this off the forearm -> use the forearm axis
PALM_MIN_WORLD = 1.5      # a palm circle smaller than this many world px is not a usable hand
PART_STEP = 2             # px; the grid the hand cut-out is stored on
PART_REACH = 6            # px; painted outline just outside the hand label still belongs to the hand


def hand_frames(m, s, wrist, forearm_ax, world_scale, grip_u, wrist_u=1.0):
    """The pose-independent hand anatomy of side `s` (docs/rigging_rewrite.md 3.6):

      palm_<s>   origin at the wrist seam, the forearm's axis; measured with the largest
                 circle inside the hand label: ly = the hand's half-width (that circle's
                 radius, or more when the wrist is so thick that the hand set's fist
                 would be narrower than it: `wrist_u` is that fist's wrist half-width
                 in palm units), lx = the
                 distance to the knuckle line (the far side of that circle). Finger
                 spread, finger count and claws cannot move it.
      wrist_<s>  same origin, FOREARM axis, lx = ly = half the wrist's width: where
                 glove cuffs sit.
      grip_<s>   where a held item's hold point goes: `grip_u` half-widths out along
                 the palm axis (the front of the closed fist), lx = px per world px.

    Returns ({name: frame}, note or None); no frames when the hand cannot be measured.
    """
    fo, ha = m["forearm_" + s], m["hand_" + s]
    dist = cv2.distanceTransform(ha.astype(np.uint8), cv2.DIST_L2, 5)
    _, r, _, loc = cv2.minMaxLoc(dist)
    if r * world_scale < PALM_MIN_WORLD:
        return {}, "hand_%s: palm not measurable (%.1f px): no grip pose on this side" % (s, r)
    c = np.array(loc, float)
    # The palm continues the forearm. (The line from the wrist to the palm circle is
    # pulled toward the thumb by 5-15 degrees, and the line to the furthest fingertip
    # swings with the finger spread; a held blade would inherit either error.)
    ax = forearm_ax
    note = None
    d = c - wrist
    if float(d @ forearm_ax) < np.cos(np.radians(PALM_AXIS_MAX_DEG)) * float(np.hypot(*d)):
        note = "hand_%s: the painted hand bends more than %d deg off the forearm" % (s, PALM_AXIS_MAX_DEG)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    ys, xs = np.nonzero(fo & (cv2.dilate(ha.astype(np.uint8), k) > 0))
    v = (np.stack([xs, ys], axis=1) - wrist) @ np.array([-forearm_ax[1], forearm_ax[0]])
    hw = float(np.percentile(v, 98) - np.percentile(v, 2)) / 2.0 if len(v) >= 3 else r
    half = max(float(r), hw / wrist_u)    # the fist must not be narrower than the wrist it sits on
    knuckle = float(np.clip(float((c - wrist) @ ax) + float(r), 0.8 * half, 2.6 * half))
    out = {"palm_" + s: make_frame(wrist, ax=ax, lx=knuckle, ly=half),
           "wrist_" + s: make_frame(wrist, ax=forearm_ax, lx=hw, ly=hw)}
    kk = 1.0 / world_scale
    out["grip_" + s] = make_frame(wrist + ax * half * grip_u, ax=ax, lx=kk, ly=kk)
    return out, note


def hand_parts(labels_rgb):
    """The open hands as cut-outs of body.png: {"hand_l": {"step", "runs"}, ...}.

    A run is [row, first column, last column + 1] on a PART_STEP grid from (0, 0). A cell
    belongs to a hand when it holds any pixel that is nearer the hand label than any other
    label (within PART_REACH), so the painted outline goes with the hand. Hiding the cells
    hides the open hand; drawing them through a colour ramp gloves it."""
    m = label_masks(labels_rgb)
    h, w = labels_rgb.shape[:2]
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * PART_REACH + 1, 2 * PART_REACH + 1))
    other = np.zeros((h, w), bool)
    for name, mask in m.items():
        if not name.startswith("hand_"):
            other |= mask
    out = {}
    for s in ("l", "r"):
        if "hand_" + s not in m:
            continue
        reg = (cv2.dilate(m["hand_" + s].astype(np.uint8), k) > 0) & ~other
        ny, nx = -(-h // PART_STEP), -(-w // PART_STEP)
        pad = np.zeros((ny * PART_STEP, nx * PART_STEP), bool)
        pad[:h, :w] = reg
        occ = pad.reshape(ny, PART_STEP, nx, PART_STEP).any(axis=(1, 3))
        runs = []
        for j in np.nonzero(occ.any(axis=1))[0]:
            row = np.concatenate([[0], occ[j].astype(np.int8), [0]])
            d = np.diff(row)
            for a, b in zip(np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]):
                runs.append([int(j), int(a), int(b)])
        out["hand_" + s] = {"step": PART_STEP, "runs": runs}
    return out


def luma(rgb):
    a = np.asarray(rgb, float)
    return (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]) / 255.0


RAMP_PCT = (2.0, 22.0, 55.0, 93.0)     # outline, shadow, mid, light


def colour_ramp(rgb, sel):
    """Four (luminance stop, colour) pairs of the selected pixels: the painting's own
    outline, shadow, mid and light tones. Returns {"stops": [4], "ramp": [[r,g,b] x 4]}.
    A hand drawn through core.apply_ramp(src stops -> dst ramp) keeps its shading and
    line work and changes material."""
    px = np.asarray(rgb, float)[sel]
    lum = luma(px)
    order = np.argsort(lum)
    stops, ramp = [], []
    for p in RAMP_PCT:
        lo = int(len(order) * max(p - 4.0, 0.0) / 100.0)
        hi = max(int(len(order) * min(p + 4.0, 100.0) / 100.0), lo + 1)
        pick = order[lo:hi]
        st = float(lum[pick].mean())
        if stops and st <= stops[-1] + 0.01:
            st = stops[-1] + 0.01
        stops.append(round(st, 4))
        ramp.append([round(float(c) / 255.0, 4) for c in px[pick].mean(axis=0)])
    return {"stops": stops, "ramp": ramp}


def skin_ramp(body_rgba, labels_rgb):
    """The race's skin tones, read off the hands of its own painting (the pixels a
    glove recolours, and the ones a fist replaces)."""
    m = label_masks(labels_rgb)
    sel = np.zeros(labels_rgb.shape[:2], bool)
    for name in ("hand_l", "hand_r"):
        if name in m:
            sel |= m[name]
    sel &= body_rgba[:, :, 3] > 230
    if int(sel.sum()) < 50:
        return None
    return colour_ramp(body_rgba[:, :, :3], sel)


def derive_frames(labels_rgb, world_scale, grip_u=None, wrist_u=1.0):
    """Returns (frames, notes). Raises LabelError when a required label is missing.

    `grip_u` (from the hand set, see hands.py) turns on the hand rig frames palm_*,
    wrist_* and the fist-centred grip_*; without it the pack keeps the old grip only."""
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
        if grip_u is not None:
            fax = (wrist - elbow) / max(float(np.hypot(*(wrist - elbow))), 1e-6)
            extra, note = hand_frames(m, s, wrist, fax, world_scale, grip_u, wrist_u)
            frames.update(extra)
            if note:
                notes.append(note)

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
