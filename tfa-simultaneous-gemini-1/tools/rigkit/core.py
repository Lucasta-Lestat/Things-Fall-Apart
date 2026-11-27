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
