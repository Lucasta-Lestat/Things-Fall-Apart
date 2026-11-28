"""Frames, the frame-to-frame fit, skin weights and the item mesh.

A FRAME is the only geometric primitive in the system:

    {"o": [x, y], "ax": [ux, uy], "lx": L, "ly": W, "ly_neg": W2 (optional)}

`o` is the origin in pixels, `ax` the unit axis, `lx` the scale along the axis
and `ly` the scale across it (`ly_neg` on the negative side, when the two sides
differ, e.g. a torso's back and front depth). The perpendicular is always
(-uy, ux), so for ax=(1,0) "across, positive" is image-down = the character's
front (every race pack faces south).

A race pack and an item both describe themselves as a set of NAMED frames
(torso, upperarm_l, head, foot_l, grip_r ...). Fitting an item to a race is
nothing more than mapping each point through the frame pair that shares a name:
normalise in the item's frame, de-normalise in the race's.

Characters/rig2/rig_fit.gd mirrors this file; tests/rig2_parity_test.tscn
checks that the two produce the same vertices.
"""
import json
import math
import os

import numpy as np

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
RIGS = os.path.join(ROOT, "Rigs")


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=1)
        f.write("\n")


def skeleton():
    return load_json(os.path.join(RIGS, "skeleton.json"))


def race_dir(race, variant="default"):
    return os.path.join(RIGS, "races", race, variant)


def load_race(race, variant="default"):
    """A variant may hold only art: missing keys fall through to `inherits`."""
    d = race_dir(race, variant)
    data = load_json(os.path.join(d, "race.json"))
    data["_dir"] = d
    parent = data.get("inherits")
    if parent:
        base = load_race(race, parent)
        merged = dict(base)
        merged.update(data)
        merged["frames"] = dict(base.get("frames", {}), **data.get("frames", {}))
        merged["_parent_dir"] = base["_dir"]
        data = merged
    return data


def race_file(race_data, key):
    """Art files resolve in the variant's folder first, then its parent's."""
    name = race_data[key]
    p = os.path.join(race_data["_dir"], name)
    if not os.path.exists(p) and "_parent_dir" in race_data:
        p = os.path.join(race_data["_parent_dir"], name)
    return p


def list_races():
    base = os.path.join(RIGS, "races")
    out = []
    if not os.path.isdir(base):
        return out
    for r in sorted(os.listdir(base)):
        if not os.path.isdir(os.path.join(base, r)):
            continue
        for v in sorted(os.listdir(os.path.join(base, r))):
            if os.path.exists(os.path.join(base, r, v, "race.json")):
                out.append((r, v))
    return out


def load_item(item):
    d = os.path.join(RIGS, "items", item)
    data = load_json(os.path.join(d, "item.json"))
    data["_dir"] = d
    return data


def list_items():
    base = os.path.join(RIGS, "items")
    if not os.path.isdir(base):
        return []
    return [i for i in sorted(os.listdir(base))
            if os.path.exists(os.path.join(base, i, "item.json"))]


# ---------------------------------------------------------------- frames

def make_frame(o, toward=None, lx=1.0, ly=1.0, ly_neg=None, ax=None):
    if ax is None:
        d = np.asarray(toward, float) - np.asarray(o, float)
        n = float(np.hypot(d[0], d[1]))
        ax = (d / n) if n > 1e-9 else np.array([1.0, 0.0])
    f = {"o": [round(float(o[0]), 2), round(float(o[1]), 2)],
         "ax": [round(float(ax[0]), 5), round(float(ax[1]), 5)],
         "lx": round(max(float(lx), 0.5), 3), "ly": round(max(float(ly), 0.5), 3)}
    if ly_neg is not None:
        f["ly_neg"] = round(max(float(ly_neg), 0.5), 3)
    return f


def mirror_frame(f, width):
    """Reflect a frame about the vertical centre line of a `width`-px image.

    Reflection flips handedness, so the mirrored frame carries `flip` and its
    perpendicular is negated: 'across, positive' stays the same anatomical side.
    """
    g = dict(f)
    g["o"] = [width - f["o"][0], f["o"][1]]
    g["ax"] = [-f["ax"][0], f["ax"][1]]
    g["flip"] = not f.get("flip", False)
    return g


def _perp(f):
    ax = np.asarray(f["ax"], float)
    p = np.array([-ax[1], ax[0]])
    return -p if f.get("flip") else p


def frame_local(f, pts):
    """pts (N,2) -> normalised (U, V) in frame f."""
    p = np.asarray(pts, float) - np.asarray(f["o"], float)
    u = p @ np.asarray(f["ax"], float)
    v = p @ _perp(f)
    ly = float(f["ly"])
    lyn = float(f.get("ly_neg", ly))
    return u / float(f["lx"]), np.where(v >= 0, v / ly, v / lyn)


def frame_world(f, U, V, ease_x=1.0, ease_y=1.0):
    ly = float(f["ly"])
    lyn = float(f.get("ly_neg", ly))
    u = U * float(f["lx"]) * ease_x
    v = np.where(V >= 0, V * ly, V * lyn) * ease_y
    return np.asarray(f["o"], float) + np.outer(u, np.asarray(f["ax"], float)) + np.outer(v, _perp(f))


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------- the fit

# Limb chains a skinned slot may deform along, each listed from the body out.
CHAINS = {
    "torso": [["upperarm_l", "forearm_l"], ["upperarm_r", "forearm_r"]],
    "legs": [["leg_l"], ["leg_r"]],
}
BLEND_FRAC = 0.22        # joint blend half-width, as a fraction of the root frame's lx


def is_skinned(item, skel):
    return item.get("fit", skel["slots"][item["slot"]].get("fit", "rigid")) == "skinned"


def root_frame_name(item, skel):
    return item.get("root_frame", skel["slots"][item["slot"]]["frame"])


def skin_weights(item, skel, pts):
    """Per-point weights over the item's frames. Returns (names, W[N, len(names)]).

    Rigid items have one frame, so the weight is 1. Skinned items start at the
    slot's root frame and hand weight over to each limb frame with a smoothstep
    across the joint, measured along the LIMB's axis in item space.
    """
    frames = item["frames"]
    pts = np.asarray(pts, float)
    root = root_frame_name(item, skel)
    names = [root]
    W = [np.ones(len(pts))]
    if is_skinned(item, skel):
        fr = frames[root]
        beta = BLEND_FRAC * float(fr["lx"])
        ru, _ = frame_local(fr, pts)
        for chain in CHAINS.get(item["slot"], []):
            prev = 0                     # column this link takes its weight from
            for name in chain:
                if name not in frames:
                    break
                f = frames[name]
                t = (pts - np.asarray(f["o"], float)) @ np.asarray(f["ax"], float)
                take = smoothstep(-beta, beta, t)
                if prev == 0:            # only points on this limb's side of the body
                    side = (np.asarray(f["o"], float) - np.asarray(fr["o"], float)) @ np.asarray(fr["ax"], float)
                    take = take * ((ru * side) > 0)
                w = W[prev] * take
                W[prev] = W[prev] - w
                names.append(name)
                W.append(w)
                prev = len(W) - 1
    return names, np.stack(W, axis=1)


def ease_for(item, skel):
    return float(item.get("ease", skel["slots"][item["slot"]].get("ease", 1.0)))


def scale_mode(item, skel):
    return item.get("scale", skel["slots"][item["slot"]].get("scale", "free"))


def target_frame(item, skel, race, name, side=None):
    """The race frame an item frame lands on, with the item's scale mode applied.

    `side` retargets a one-sided item ("foot", "hand", "grip") to "_l" or "_r".
    Returns (frame, ease_x, ease_y).
    """
    fi = item["frames"][name]
    tname = name + "_" + side if (side and name == root_frame_name(item, skel)) else name
    if tname not in race["frames"]:
        raise KeyError("race %s has no frame %r" % (race.get("id"), tname))
    fr = dict(race["frames"][tname])
    ease = ease_for(item, skel)
    mode = scale_mode(item, skel)
    if mode == "uniform":
        # one scale for both axes, read off the frame's length: no distortion
        k = float(fr["lx"]) / float(fi["lx"])
        fr["ly"] = float(fi["ly"]) * k
        fr["ly_neg"] = float(fi.get("ly_neg", fi["ly"])) * k
        return fr, ease, ease
    if mode == "world":
        # held gear keeps its authored world size: lx is "rig px per world px"
        k = float(fr["lx"]) / float(fi["lx"])
        fr["ly"] = float(fi["ly"]) * k
        fr["ly_neg"] = float(fi.get("ly_neg", fi["ly"])) * k
        return fr, 1.0, 1.0
    if is_skinned(item, skel):
        return fr, 1.0, ease             # limbs keep their length, ease goes across
    return fr, ease, ease


def slot_sides(item, skel):
    """The sides an item is drawn on: [None] for centre items, else ["l","r"] or one side."""
    slot = skel["slots"][item["slot"]]
    if slot.get("sided"):
        return ["l", "r"]
    if slot.get("side"):
        return [slot["side"]]
    return [None]


def is_mirrored(item, skel, side):
    """Sided art is authored once (for `authored_side`) and mirrored onto the other
    side. Mirroring = negating V: every sided frame's axis runs along the limb, so
    'across' is the lateral direction."""
    return bool(skel["slots"][item["slot"]].get("sided")) and side != item.get("authored_side", "l")


def fit_points(item, skel, race, pts, side=None):
    """Map item-space points onto the race. Returns (xy[N,2], names, W)."""
    names, W = skin_weights(item, skel, pts)
    out = np.zeros((len(pts), 2))
    flip = is_mirrored(item, skel, side)
    for j, name in enumerate(names):
        fr, ex, ey = target_frame(item, skel, race, name, side)
        U, V = frame_local(item["frames"][name], pts)
        out += W[:, j:j + 1] * frame_world(fr, U, -V if flip else V, ex, ey)
    return out, names, W


def frame_stretch(item, skel, race, name, side=None):
    """(along, across) scale a frame pair applies. along/across is the distortion."""
    fi = item["frames"][name]
    fr, ex, ey = target_frame(item, skel, race, name, side)
    return float(fr["lx"]) * ex / float(fi["lx"]), float(fr["ly"]) * ey / float(fi["ly"])


# ---------------------------------------------------------------- the mesh

MESH_CELLS = 28


def mesh_cells(alpha, cells=MESH_CELLS):
    """The item's mesh as data: a grid origin, a cell size and the occupied cells.

    Stored in item.json by ingest so the engine never has to scan pixels, and so
    both sides build the identical mesh (same vertices in the same order).
    """
    ys, xs = np.nonzero(alpha > 8)
    x0, x1, y0, y1 = int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1
    step = round(max(4.0, max(x1 - x0, y1 - y0) / float(cells)), 3)
    nx = int(math.ceil((x1 - x0) / step))
    ny = int(math.ceil((y1 - y0) / step))
    h, w = alpha.shape
    occ = []
    for j in range(ny):
        for i in range(nx):
            cx0, cx1 = int(x0 + i * step), min(int(math.ceil(x0 + (i + 1) * step)), w)
            cy0, cy1 = int(y0 + j * step), min(int(math.ceil(y0 + (j + 1) * step)), h)
            if cx1 > cx0 and cy1 > cy0 and (alpha[cy0:cy1, cx0:cx1] > 8).any():
                occ.append([i, j])
    return {"x0": x0, "y0": y0, "step": step, "cells": occ}


def mesh_from_cells(mesh):
    """(verts[N,2] in item px, tris[M,3]) from a stored cell list. Vertices are
    numbered in first-use order, walking the cells as stored, corners clockwise
    from top-left; two triangles per cell: (a,b,c) and (a,c,d)."""
    x0, y0, step = mesh["x0"], mesh["y0"], mesh["step"]
    index = {}
    verts = []
    tris = []

    def vid(i, j):
        if (i, j) not in index:
            index[(i, j)] = len(verts)
            verts.append((x0 + i * step, y0 + j * step))
        return index[(i, j)]

    for i, j in mesh["cells"]:
        a, b, c, d = vid(i, j), vid(i + 1, j), vid(i + 1, j + 1), vid(i, j + 1)
        tris.append((a, b, c))
        tris.append((a, c, d))
    return np.array(verts, float), np.array(tris, int)


def missing_frames(item, skel, race):
    """Race frames this item needs and the race does not have (empty = wearable)."""
    root = root_frame_name(item, skel)
    out = []
    for side in slot_sides(item, skel):
        for name in item["frames"]:
            t = name + "_" + side if (side and name == root) else name
            if t not in race["frames"]:
                out.append(t)
    return out


# ---------------------------------------------------------------- hands (docs 3.6)
#
# A hand has a POSE. "open" is the hand in the race painting; "grip" is the shared
# fist of the race's hand set (Rigs/hands/<set>), fitted to the race's palm frame and
# coloured through the race's skin ramp. Holding anything closes that hand: the open
# hand's cells are hidden, the fist is drawn OVER the item, and whatever of the item
# lies behind its hold point is drawn under the body (palm down, a haft runs under
# the forearm). A glove is the showing hand drawn again through the glove's own
# colour ramp, plus rigid cuff / back-of-hand pieces cut from the glove's art.

TAIL_BACK = 2.0          # world px behind the hold point where a held item's tail starts
PART_OVERLAP = 0.5       # px each cut-out quad is grown by, so neighbours leave no crack


def hand_set(name="humanoid"):
    """The hand set's data (with "_dir"), or None when it is not installed."""
    d = os.path.join(RIGS, "hands", name)
    p = os.path.join(d, "hand.json")
    if not os.path.exists(p):
        return None
    data = load_json(p)
    data["_dir"] = d
    return data


def race_hand_set(race, skel):
    return hand_set(race.get("hand_set", skel.get("hands", {}).get("default_set", "humanoid")))


def hand_rig_ok(race, side):
    """True when this race side can show hand poses (built with the hand rig)."""
    return ("palm_" + side in race["frames"] and "wrist_" + side in race["frames"]
            and "hand_" + side in race.get("parts", {}) and "skin" in race)


def fit_frame(fi, fr, pts, ease=1.0, flip=False, uniform=""):
    """Map points from frame fi onto frame fr. `uniform` = "lx" or "ly" uses ONE scale,
    read off that axis (no distortion); "" scales the two axes independently."""
    g = dict(fr)
    if uniform == "lx":
        k = float(fr["lx"]) / float(fi["lx"])
        g["ly"] = float(fi["ly"]) * k
        g["ly_neg"] = float(fi.get("ly_neg", fi["ly"])) * k
    elif uniform == "ly":
        k = float(fr["ly"]) / float(fi["ly"])
        g["lx"] = float(fi["lx"]) * k
        g["ly_neg"] = float(fi.get("ly_neg", fi["ly"])) * k
    U, V = frame_local(fi, pts)
    return frame_world(g, U, -V if flip else V, ease, ease)


def pose_palm(race, hs, side, pose):
    """The palm frame a pose shows on this race side. Open: the race's own. Grip: the
    same origin, axis and half-width, with the knuckle line where the fist's is."""
    f = dict(race["frames"]["palm_" + side])
    if pose == "grip" and hs is not None:
        fp = hs["poses"]["grip"]["frames"]["palm"]
        f["lx"] = float(fp["lx"]) * float(f["ly"]) / float(fp["ly"])
    return f


def fist_points(race, hs, side, pts):
    """The hand set's fist vertices on this race side (uniform, by the half-width)."""
    fp = hs["poses"]["grip"]["frames"]["palm"]
    return fit_frame(fp, race["frames"]["palm_" + side], pts, 1.0, side != hs.get("authored_side", "r"), "ly")


def glove_piece_points(piece, skel, race, hs, side, pose, pts, authored_side="r"):
    """A glove piece's vertices on this race side in this pose. The cuff rides the wrist
    frame at one scale; the back of the hand maps wrist to wrist, knuckles to knuckles
    and edge to edge on the pose's palm frame."""
    spec = skel["slots"]["hands"]["pieces"][piece["name"]]
    fi = piece["frames"][piece["frame"]]
    flip = side != authored_side
    if piece["frame"] == "wrist":
        return fit_frame(fi, race["frames"]["wrist_" + side], pts, float(spec.get("ease", 1.0)), flip, "lx")
    return fit_frame(fi, pose_palm(race, hs, side, pose), pts, float(spec.get("ease", 1.0)), flip, "")


def ramp_colour(lum, stops, ramp):
    """Luminance (0..1, any shape) -> RGB 0..1 through a four-stop ramp: `stops` are the
    source's outline/shadow/mid/light luminances, `ramp` the colours they become.
    Mirrored by Characters/rig2/rig_ramp.gdshader."""
    lum = np.asarray(lum, float)
    ramp = np.asarray(ramp, float)
    out = np.zeros(lum.shape + (3,))
    out[...] = ramp[0]
    for i in range(3):
        t = np.clip((lum - stops[i]) / max(stops[i + 1] - stops[i], 1e-4), 0.0, 1.0)
        seg = ramp[i] + (ramp[i + 1] - ramp[i]) * t[..., None]
        out = np.where((lum >= stops[i])[..., None], seg, out)
    return out


def part_quads(part, overlap=PART_OVERLAP):
    """A stored cut-out as quads [(x0, y0, x1, y1)], one per run, in pack px."""
    s = float(part["step"])
    return [(i0 * s - overlap, j * s - overlap, i1 * s + overlap, (j + 1) * s + overlap)
            for j, i0, i1 in part["runs"]]


def part_bbox(part):
    s = float(part["step"])
    runs = part["runs"]
    return (min(r[1] for r in runs) * s, min(r[0] for r in runs) * s,
            max(r[2] for r in runs) * s, (max(r[0] for r in runs) + 1) * s)


def rest_quads(size, parts, overlap=PART_OVERLAP):
    """The body with the given cut-outs removed, as quads. Whole-height slabs between
    the cut-outs' column ranges, slabs above and below each, and the gaps between the
    runs inside. Returns None when two cut-outs share columns (the body is then drawn
    whole and no hand can be hidden)."""
    w, h = float(size[0]), float(size[1])
    boxes = sorted((part_bbox(p), p) for p in parts)
    out = []
    x = 0.0
    for (bx0, by0, bx1, by1), p in boxes:
        if bx0 < x:
            return None
        if bx0 > x:
            out.append((x - overlap, -overlap, bx0 + overlap, h + overlap))
        bx1 = min(bx1, w)
        if by0 > 0:
            out.append((bx0 - overlap, -overlap, bx1 + overlap, by0 + overlap))
        if by1 < h:
            out.append((bx0 - overlap, by1 - overlap, bx1 + overlap, h + overlap))
        s = float(p["step"])
        rows = {}
        for j, i0, i1 in p["runs"]:
            rows.setdefault(j, []).append((i0, i1))
        j = int(round(by0 / s))
        while j * s < by1:
            cur = bx0
            for i0, i1 in sorted(rows.get(j, [])):
                if i0 * s > cur:
                    out.append((cur - overlap, j * s - overlap, i0 * s + overlap, (j + 1) * s + overlap))
                cur = i1 * s
            if cur < bx1:
                out.append((cur - overlap, j * s - overlap, bx1 + overlap, (j + 1) * s + overlap))
            j += 1
        x = bx1
    if x < w:
        out.append((x - overlap, -overlap, w + overlap, h + overlap))
    return out


def held_tail(item, mesh):
    """Per mesh cell: True when the cell lies well behind the item's hold point (its
    `grip` frame origin, which sits at the front of the fist), i.e. on the pommel/butt
    side. Those cells are drawn under the body when the item's hold says tail "under".
    The cut is TAIL_BACK world px behind the hold point, so it is hidden by the fist."""
    f = item["frames"]["grip"]
    x0, y0, step = mesh["x0"], mesh["y0"], mesh["step"]
    c = np.array([(x0 + (i + 0.5) * step, y0 + (j + 0.5) * step) for i, j in mesh["cells"]], float)
    return ((c - np.asarray(f["o"], float)) @ np.asarray(f["ax"], float)) < -TAIL_BACK * float(f["lx"])


def held_layers(item, skel, race, side):
    """How a held item is layered on this race side: (front z, tail z or None).
    tail z None = the item is drawn in one piece."""
    slot = skel["slots"][item["slot"]]
    hold = item.get("hold", {})
    if not hand_rig_ok(race, side):
        return slot["z"], None
    if hold.get("layer") == "over":
        return slot.get("over_z", slot["z"]), None
    if hold.get("tail", "under") == "under" and "hold" in item:
        return slot["z"], slot.get("tail_z", slot["z"])
    return slot["z"], None


def hand_poses(items, skel, race):
    """{"l": pose, "r": pose} for a race wearing `items` (loaded item dicts): a hand is
    "grip" when a held item occupies it, or is the support hand of a two-handed item."""
    poses = {"l": "open", "r": "open"}
    for item in items:
        slot = skel["slots"][item["slot"]]
        if item["slot"] in ("main_hand", "off_hand"):
            poses[slot["side"]] = item.get("hold", {}).get("pose", "grip")
            if int(item.get("hold", {}).get("hands", 1)) == 2:
                poses["l" if slot["side"] == "r" else "r"] = "grip"
    return {s: (p if hand_rig_ok(race, s) else "open") for s, p in poses.items()}


def glove_cut(hs):
    """Art x (px) left of which a GLOVED fist is not drawn: just behind the wrist line."""
    fp = hs["poses"]["grip"]["frames"]["palm"]
    return float(fp["o"][0]) - 0.12 * float(fp["ly"])


def glove_ok(item, race, side):
    """True when a hands item can use the hand rig on this side (else the legacy
    one-image fit to the hand frame is used)."""
    return "hand" in item and hand_rig_ok(race, side)


# ---------------------------------------------------------------- head enclosure, trunk over feet
#
# ENCLOSING HEADWEAR. An item pack may say `"encloses": true` (a great helm, a deep hood): while
# it is worn the wearer's head is not drawn at all, so ears, jaw, tusks and long noses cannot
# stick out of it. build_race writes the overlay `bare` for that: the head's bounding box of the
# body painting with the head's pixels replaced by plain skin where the trunk is under the head
# and by nothing elsewhere. The body is drawn with that box cut out (`cut_rect`), and the box is
# drawn either from the painting (normal) or from `bare` (enclosed); the `head` overlay is hidden.
#
# TRUNK OVER FEET. On a pack whose legs are hidden the feet peek out from under the belly, and a
# boot is larger than the foot it covers. build_race writes the overlay `trunk`: the trunk's own
# pixels around the feet, drawn again above feet items (body_layers.trunk_over_feet) and below
# everything else that is worn, so the trunk hides the part of a boot that is under it.

def encloses(items):
    """True when any of the loaded item dicts encloses the head."""
    return any(bool(i.get("encloses")) for i in items)


def head_box(race):
    """(x0, y0, x1, y1) of the `bare` overlay in pack px, or None when the pack has none."""
    b = race.get("overlays", {}).get("bare")
    if not b:
        return None
    return (float(b["offset"][0]), float(b["offset"][1]),
            float(b["offset"][0] + b["size"][0]), float(b["offset"][1] + b["size"][1]))


def cut_rect(quads, box):
    """Quads with the rectangle `box` removed. A quad that overlaps it is split into up to four,
    in this order: above, below, left, right."""
    bx0, by0, bx1, by1 = box
    out = []
    for x0, y0, x1, y1 in quads:
        if x1 <= bx0 or x0 >= bx1 or y1 <= by0 or y0 >= by1:
            out.append((x0, y0, x1, y1))
            continue
        if y0 < by0:
            out.append((x0, y0, x1, by0))
        if y1 > by1:
            out.append((x0, by1, x1, y1))
        ya, yb = max(y0, by0), min(y1, by1)
        if x0 < bx0:
            out.append((x0, ya, bx0, yb))
        if x1 > bx1:
            out.append((bx1, ya, x1, yb))
    return out


def body_quads(race, skel):
    """The quads the body polygon is drawn with: the painting minus the open hands (hand rig) and
    minus the head box (enclosing headwear). None = nothing to cut, the body is one sprite."""
    w, h = float(race["size"][0]), float(race["size"][1])
    rest = None
    if race_hand_set(race, skel) is not None and all(hand_rig_ok(race, s) for s in "lr"):
        rest = rest_quads(race["size"], [race["parts"]["hand_l"], race["parts"]["hand_r"]])
    box = head_box(race)
    if rest is None and box is None:
        return None
    if rest is None:
        rest = [(0.0, 0.0, w, h)]
    if box is not None:
        rest = cut_rect(rest, box)
    return rest
