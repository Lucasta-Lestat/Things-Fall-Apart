"""Paint a WORN item for the approved race camera, by painting over a rendered item guide.

    python -m tools.rigkit.gen_item guide   <item> [--proxy orc] [--tilt 15]
    python -m tools.rigkit.gen_item gen     <item> [--n 4] [--tag r1] [--note "extra positive sentence"]
    python -m tools.rigkit.gen_item check   <item> --tag r1
    python -m tools.rigkit.gen_item install <item> <painting.png> [--id <item>_td]
    python -m tools.rigkit.gen_item compare [--out tools/rigkit/out/items_td]   (metrics + pilot sheet)

The race pilots' lesson, applied to items: GIVE the camera, do not ask for it. The guide is the
garment's own shell, built on the SAME 3D proxy gen_plan.py paints races over and rendered by the
SAME camera (orthographic, tilted 15 degrees off vertical toward the front, T-pose):

  torso   the proxy's trunk primitives (and upper arms for a sleeved garment), inflated by the cloth's
          clearance, with the neck primitive removed and a neck opening cut where the neck leaves the
          trunk at this camera, a collar ring round it. The upper back shows north of the opening
          because the camera sees it, not because a prompt asked for it.
  head    an elliptic cylinder (a great helm) that encloses every head primitive of the proxy except
          the ears: cranium, brow, nose, jaw and tusks.

ITEM FRAMES ARE NOT MEASURED FROM THE ART. They are the proxy's own anatomy: the proxy's label map,
with install_plan's label conventions (armpit shoulder seam, no leg sliver), goes through derive.py,
exactly as a painted race does, and those frames (torso, upperarm_l/r, head), moved into the item
picture, are the item's frames. So fitting a _td item to a race maps the proxy's body onto that
race's body, and on a race painted over the same proxy the fit is the identity. The item stays
race-agnostic: one painting, fitted to every race by the frames.

The ground is a flat blue, not the races' grey: steel and linen shadows pass through mid-grey, and
a blue-dominance key (blue far above red and green) cannot eat them. The neck opening is painted as
ground and keyed out, so the wearer's own neck (or the garment underneath) shows through it.

This tool imports from gen_plan and install_plan and never edits them. Prompts are phrased
positively only. `gen` needs GEMINI_API_KEY.
"""
import argparse
import json
import os
import shutil
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

from . import core, gen_plan, ingest, install_plan
from .derive import derive_frames

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "items_td")
W, H, SS = gen_plan.W, gen_plan.H, gen_plan.SS
MARGIN = 0.035                      # gen_plan.render's default: fingertips this far from the edges
GROUND = (58, 110, 215)             # flat key colour; see the module docstring
TILT_WORDS = gen_plan.TILT_WORDS

CAMERA = (
    "rendered by an orthographic camera high above it, looking steeply down from just in front of "
    "directly overhead, leaning %s degrees toward its front: the view of a miniature's gear on a "
    "tabletop battle map. It is shaped exactly as worn by an upright figure that faces the bottom of "
    "the picture with both arms stretched straight out to the sides; the figure itself is absent, so "
    "the piece holds its worn shape on its own. ")
FINISH = (
    " Left-right symmetric, lit softly and evenly from above, the piece alone on a perfectly flat "
    "uniform blue background, RGB %d %d %d, that fills the rest of the picture%s.")
SWATCH = (
    " Image 2 is a small close-up swatch of this item's existing painted art, for material, colour "
    "and finish only: match its %s, its semi-realistic hand-painted brushwork with soft-edged "
    "shading, and its thin dark contour line, about three pixels thick, around the whole silhouette%s.")

ITEMS = {
    "peasants_stained_shirt": dict(
        slot="torso", sleeve="short", layer=1, inflate=0.016, hole_clear=0.012, ring_r=0.012,
        swatch=dict(box=(170, 230, 520, 560)),
        what="a single empty garment, a loose short-sleeved shirt",
        reads="The wide band across the top is the shirt lying over the tops of the shoulders and the "
              "upper back. The round opening in the middle of that band is the neck opening seen from "
              "above, a clean round hole with a low collar band around it, and the plain blue background "
              "shows through it. The two level bars to the left and right are the short sleeves over the "
              "upper arms, each ending in a straight open cuff. Below the shoulder band is the front of "
              "the shirt over the chest and belly, seen from steeply above and strongly foreshortened, "
              "ending in the rounded hem at the bottom. ",
        look="a humble peasant's shirt of rough homespun linen in faded off-white and beige, well worn, "
             "with dirt smudges and brown stains",
        paint="Turn the simple forms into believable cloth: soft creases running from the collar over "
              "the shoulders, loose folds along the sleeves gathering at the cuffs, a stitched seam "
              "where each sleeve joins the body, a short laced slit just below the neck opening, and "
              "gentle folds across the chest down to a plain stitched hem",
        material="faded beige linen hue with its brown stains and lighter worn highlights",
        hole_words=" and the round neck opening"),
    "breastplate": dict(
        slot="torso", sleeve="sleeveless", layer=4, inflate=0.012, hole_clear=0.016, ring_r=0.015,
        cap_x=0.50, swatch=dict(box=(8, 55, 80, 185)),
        what="a single piece of body armour, a steel cuirass made of a breastplate and a back plate",
        reads="The wide band across the top is the armour over the tops of the shoulders and the upper "
              "back: the upper edge of the back plate and the two shoulder straps. The round opening in "
              "the middle of that band is the neck opening seen from above, a clean round hole cut straight "
              "through the armour with a rolled steel rim around it: the plain flat blue background fills "
              "the entire circle from rim to rim. The left and right ends of the piece are the outer "
              "edges of the shoulder straps and of the two plates, solid steel seen from above. Below the shoulder band is the "
              "breastplate over the chest and belly, seen from steeply above and strongly foreshortened, "
              "ending in the waist flange at the bottom. ",
        look="a polished steel cuirass, sturdy and plain, with brushed-metal highlights",
        paint="Turn the simple forms into believable plate armour: one smooth fitted chest plate with a "
              "soft central ridge, a rolled steel rim around the neck opening, a buckled leather strap lying over each shoulder "
              "and joining the breastplate to the back plate, the top surface of the armour continuous "
              "solid steel from the left edge to the right edge, a row of small rivets along the edges, "
              "and a flared waist flange along the bottom",
        material="cool grey polished steel with its bright brushed highlights and dark blue-grey shadows",
        hole_words=" and the round neck opening"),
    "great_helm": dict(
        slot="head", pad=0.014, swatch=dict(box=(8, 150, 120, 320)),
        what="a single helmet, a great helm: a closed steel bucket helmet with a flat top",
        reads="The large oval that fills most of the picture is the helmet's flat top plate seen from "
              "above. The curved band along its bottom edge is the front wall of the helmet, seen from "
              "steeply above and strongly foreshortened: across it runs the narrow dark eye slit, and a "
              "raised vertical reinforcing bar crosses the slit at the centre, making a cross. ",
        look="a plain great helm of grey hammered steel, with a flat top plate, a narrow eye slit and a "
             "cross-shaped reinforcing bar on its front",
        paint="Turn the simple forms into believable hammered steel: the flat top plate with a soft "
              "sheen and a riveted seam around its rim, the front wall curving away to both sides, the "
              "eye slit a narrow black opening, the cross-shaped bar raised and riveted, and a few small "
              "round breathing holes below the slit",
        material="grey hammered steel with its soft pale highlights and dark shadows",
        hole_words=""),
}


# ---------------------------------------------------------------- camera and proxy

def camera(proxy, tilt, zoom=1.0, centre=None):
    """gen_plan.render's camera for `proxy`, optionally zoomed about a world/screen centre.
    Returns dict(scale px-per-unit at SS, xc, yc screen centre, ct, st)."""
    p = gen_plan.tilt_params(gen_plan.RACES[proxy], True)
    ct, st = float(np.cos(np.radians(tilt))), float(np.sin(np.radians(tilt)))
    prims = gen_plan.primitives(gen_plan.RACES[proxy], True)
    cen = np.array([c for _, c, _ in prims])
    rad = np.array([q for _, _, q in prims])
    syc = cen[:, 1] * ct - cen[:, 2] * st
    ext = np.sqrt((rad[:, 1] * ct) ** 2 + (rad[:, 2] * st) ** 2)
    yc0 = (float((syc - ext).min()) + float((syc + ext).max())) / 2
    scale0 = W * SS * (0.5 - MARGIN)
    cam = dict(scale0=scale0, yc0=yc0, ct=ct, st=st, zoom=zoom, scale=scale0 * zoom,
               xc=0.0 if centre is None else centre[0], yc=yc0 if centre is None else centre[1],
               prims=prims, params=p)
    return cam


def guide_to_item(cam, xy):
    """A point in gen_plan guide pixels (zoom 1, W x H) -> this camera's pixels."""
    xy = np.asarray(xy, float)
    k = cam["zoom"]
    sx = (xy[..., 0] - W / 2.0) * SS / cam["scale0"]
    sy = (xy[..., 1] - H / 2.0) * SS / cam["scale0"] + cam["yc0"]
    return np.stack([(sx - cam["xc"]) * cam["scale"] / SS + W / 2.0,
                     (sy - cam["yc"]) * cam["scale"] / SS + H / 2.0], -1)


def raycast(prims, cam):
    """prims: [(kind, tag, centre xyz, radii xyz[, (z0, z1)])], kind "ell" or "cyl" (vertical elliptic
    cylinder between z0 and z1 with a flat top). Returns dep (distance toward the camera, -1e9 = miss),
    unit normals, tag index (0 = miss) and the tag list. Same projection as gen_plan.render."""
    ct, st, scale = cam["ct"], cam["st"], cam["scale"]
    ww, hh = W * SS, H * SS
    xs = ((np.arange(ww) + 0.5 - ww / 2) / scale + cam["xc"]).astype(np.float32)
    ys = ((np.arange(hh) + 0.5 - hh / 2) / scale + cam["yc"]).astype(np.float32)
    dep = np.full((hh, ww), -1e9, np.float32)
    nrm = np.zeros((hh, ww, 3), np.float32)
    nrm[..., 2] = 1
    tag = np.zeros((hh, ww), np.uint8)
    tags = [None]
    for pr in prims:
        kind, name, (cx, cy, cz), (rx, ry, rz) = pr[:4]
        if name not in tags:
            tags.append(name)
        if kind == "ell":
            sy0 = cy * ct - cz * st
            ey = float(np.sqrt((ry * ct) ** 2 + (rz * st) ** 2))
            ylo, yhi = sy0 - ey, sy0 + ey
        else:
            z0, z1 = pr[4]
            ylo, yhi = (cy - ry) * ct - z1 * st, (cy + ry) * ct - z0 * st
        i0 = max(int(np.floor((cx - rx - cam["xc"]) * scale + ww / 2)) - 1, 0)
        i1 = min(int(np.ceil((cx + rx - cam["xc"]) * scale + ww / 2)) + 1, ww)
        j0 = max(int(np.floor((ylo - cam["yc"]) * scale + hh / 2)) - 1, 0)
        j1 = min(int(np.ceil((yhi - cam["yc"]) * scale + hh / 2)) + 1, hh)
        if i1 <= i0 or j1 <= j0:
            continue
        sx, sy = np.meshgrid(xs[i0:i1], ys[j0:j1])
        if kind == "ell":
            ox, oy, oz = (sx - cx) / rx, (sy * ct - cy) / ry, (-sy * st - cz) / rz
            dy, dz = st / ry, ct / rz
            a = dy * dy + dz * dz
            b = oy * dy + oz * dz
            disc = b * b - a * (ox * ox + oy * oy + oz * oz - 1)
            hit = disc > 0
            lam = (-b + np.sqrt(np.clip(disc, 0, None))) / a
            n3 = np.stack([ox / rx, (oy + lam * dy) / ry, (oz + lam * dz) / rz], -1)
        else:
            q = 1 - ((sx - cx) / rx) ** 2
            lam_t = (z1 + sy * st) / ct                      # the flat top
            y_t = sy * ct + lam_t * st
            top = (q > 0) & (((y_t - cy) / ry) ** 2 <= q)
            y_s = cy + ry * np.sqrt(np.clip(q, 0, None))     # the wall's camera-facing (south) side
            lam_s = (y_s - sy * ct) / st
            z_s = -sy * st + lam_s * ct
            side = (q > 0) & (z_s >= z0) & (z_s <= z1) & ~top
            hit = top | side
            lam = np.where(top, lam_t, lam_s)
            n3 = np.where(top[..., None], np.array([0, 0, 1.0], np.float32),
                          np.stack([(sx - cx) / rx ** 2, (y_s - cy) / ry ** 2, np.zeros_like(sx)], -1))
        sub = dep[j0:j1, i0:i1]
        win = hit & (lam > sub)
        if not win.any():
            continue
        sub[win] = lam[win]
        n = n3[win]
        nrm[j0:j1, i0:i1][win] = n / np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-6)
        tag[j0:j1, i0:i1][win] = tags.index(name)
    return dep, nrm, tag, tags, xs, ys


def proxy_frames(proxy, tilt):
    """The proxy's frames in gen_plan guide pixels, by the route a painted race takes: guide labels ->
    install_plan's label conventions -> derive.py. Returns (frames, guide mask, label index)."""
    _, _, m, lab, stats = gen_plan.render(proxy, tilt=tilt)
    mask = np.array(m) > 0
    rgb = np.array(gen_plan.PART_RGB, np.uint8)[lab]
    notes = []
    idx = install_plan.label_index(rgb)
    idx = install_plan.fix_shoulders(idx, notes)
    idx = install_plan.drop_legs(idx, notes)
    idx = install_plan.voronoi(idx)
    idx[~mask] = 0
    frames, _ = derive_frames(install_plan.RGB[idx], 1.0)
    return frames, mask, idx, stats


# ---------------------------------------------------------------- shells

def torso_shell(spec, cam):
    """(prims, hole dict, clip_x) for a torso garment on the proxy."""
    p, P = cam["params"], cam["prims"]
    t = spec["inflate"]
    i_head = next(i for i, q in enumerate(P) if q[0].startswith("face"))
    neck = P[i_head - 1]
    assert neck[0] == "body" and neck[1][0] == 0 and neck[2][0] < 0.14, "proxy layout changed: neck not found"
    sh = p["shoulder_half"]
    prims = []
    for i, (part, c, r) in enumerate(P):
        if i == i_head - 1:
            continue
        if part == "body":
            if spec["sleeve"] == "sleeveless" and abs(c[0]) > spec.get("cap_x", 0.78) * sh:
                continue                                    # deltoid caps and the outer shoulder girdle
        elif part.startswith("upperarm_"):
            if spec["sleeve"] == "sleeveless":
                continue
        elif part.startswith("forearm_"):
            if spec["sleeve"] != "long":
                continue
        else:
            continue
        prims.append(("ell", "shell", c, tuple(v + t for v in r)))
    clip_x = None
    seam = sh + 0.05
    if spec["sleeve"] == "short":
        clip_x = seam + ingest.SHORT_SLEEVE_COVERS * (p["elbow_x"] - seam)
    elif spec["sleeve"] == "long":
        clip_x = seam + ingest.LONG_SLEEVE_COVERS * (p["wrist_x"] - seam)
    hole = dict(y=neck[1][1], r=neck[2][0] + spec["hole_clear"], z=neck[1][2])
    return prims, hole, clip_x


def helm_shell(spec, cam):
    """A flat-topped elliptic cylinder round every head primitive except the ears."""
    P = cam["prims"]
    skull = next(q for q in P if q[0] == "face:skull")
    (_, sy_, sz), (srx, sry, srz) = skull[1], skull[2]
    pad = spec["pad"]
    face = [q for q in P if q[0].startswith("face") and abs(q[1][0]) < srx * 0.75]     # ears start at 0.9 r
    y_back = sy_ - sry
    y_front = max(c[1] + r[1] for _, c, r in face)
    z_top = sz + srz + pad
    z_bot = min(c[2] - r[2] for _, c, r in face) - 2 * pad
    ry = (y_front - y_back) / 2 + pad
    rx = max(srx + pad, 0.92 * ry)
    c = (0.0, (y_front + y_back) / 2, (z_top + z_bot) / 2)
    geo = dict(c=c, rx=rx, ry=ry, z0=z_bot, z1=z_top, slit_z=sz - 0.15 * srz, bar_x=0.11 * rx)
    return [("cyl", "shell", c, (rx, ry, (z_top - z_bot) / 2), (z_bot, z_top))], geo


def base_colour(item):
    """Median colour of the lit part of the existing art: the guide's flat tint."""
    a = np.array(Image.open(os.path.join(core.RIGS, "items", item, "art.png")).convert("RGBA")).astype(np.float32)
    px = a[a[..., 3] > 200][:, :3]
    lum = px @ np.array([0.299, 0.587, 0.114], np.float32)
    px = px[lum > np.percentile(lum, 65)]
    return np.median(px, 0)


def render_item(item, proxy="orc", tilt=None):
    """Returns (guide RGB image, mask image, info dict with the item's frames in guide pixels)."""
    spec = ITEMS[item]
    tilt = gen_plan.race_tilt(proxy, tilt)
    cam0 = camera(proxy, tilt)
    ct, st = cam0["ct"], cam0["st"]
    hole = clip_x = geo = None
    if spec["slot"] == "torso":
        prims, hole, clip_x = torso_shell(spec, cam0)
    else:
        prims, geo = helm_shell(spec, cam0)
    # centre the zoomed camera on the shell's projected box
    lo, hi = [], []
    for pr in prims:
        (cx, cy, cz), (rx, ry, rz) = pr[2], pr[3]
        if pr[0] == "ell":
            e = float(np.sqrt((ry * ct) ** 2 + (rz * st) ** 2))
            lo.append(cy * ct - cz * st - e); hi.append(cy * ct - cz * st + e)
        else:
            lo.append((cy - ry) * ct - pr[4][1] * st); hi.append((cy + ry) * ct - pr[4][0] * st)
    # ... and zoom so the piece fills the canvas (a helmet is a sixth of the span at zoom 1)
    xw = 2 * (clip_x if clip_x is not None else max(abs(pr[2][0]) + pr[3][0] for pr in prims))
    px0 = cam0["scale0"] / SS
    zoom = min(0.84 * W / (xw * px0), 0.80 * H / ((max(hi) - min(lo)) * px0), 4.0)
    cam = camera(proxy, tilt, round(zoom, 3), (0.0, (min(lo) + max(hi)) / 2))
    scale = cam["scale"]
    if hole:
        # the collar plane is the shell's own surface at the neck axis (two fixed-point steps)
        dep, _, _, _, xs, ys = raycast(prims, cam)
        for _ in range(3):
            sy = hole["y"] * ct - hole["z"] * st
            j = int(np.clip(round((sy - cam["yc"]) * scale + H * SS / 2), 0, H * SS - 1))
            lam = float(dep[j, W * SS // 2])
            if lam > -1e8:
                hole["z"] = -sy * st + lam * ct
        rr = spec["ring_r"]
        for a in np.linspace(0, 2 * np.pi, 72, endpoint=False):
            R = hole["r"] + rr * 0.7
            prims.append(("ell", "ring", (R * np.cos(a), hole["y"] + R * np.sin(a), hole["z"] + rr * 0.2),
                          (rr, rr, rr)))
    dep, nrm, tag, tags, xs, ys = raycast(prims, cam)
    mask = dep > -1e8
    X, Y = np.meshgrid(xs, ys)
    if clip_x is not None:
        mask &= np.abs(X) <= clip_x
    if hole:
        hy = hole["y"] * ct - hole["z"] * st
        inside = (X / hole["r"]) ** 2 + ((Y - hy) / (hole["r"] * ct)) ** 2 <= 1
        cut = inside & mask & (tag != tags.index("ring"))
        mask &= ~cut
    else:
        cut = np.zeros_like(mask)
    hs = np.where(mask, dep, 0).astype(np.float32)
    k = cam["zoom"]
    mf = mask.astype(np.float32)
    sig = (3.0 if spec["slot"] == "torso" else 1.0) * SS * k
    wsum = np.maximum(ndi.gaussian_filter(mf, sig), 1e-4)
    ns = np.stack([ndi.gaussian_filter(nrm[..., i] * mf, sig) / wsum for i in range(3)], -1)
    ns /= np.maximum(np.linalg.norm(ns, axis=-1, keepdims=True), 1e-6)
    L = np.array([-0.05, 0.30, 0.95]); L /= np.linalg.norm(L)
    lam = np.clip(ns @ L, 0, 1)
    ao = np.clip((ndi.gaussian_filter(hs, 12 * SS * k) - hs) * 0.7, 0, 0.28)
    clay = 205 * (0.36 + 0.64 * lam) * (1 - ao)
    edge = np.hypot(*np.gradient(ndi.gaussian_filter(hs, 0.8 * SS))) * scale
    clay *= 1 - np.clip((edge - 1.4 * k) / (3.0 * k), 0, 1) * 0.50
    if geo:
        # markings on the front wall: eye slit, and a raised cross bar (lighter, dark-edged)
        Z = -Y * st + dep * ct
        wall = mask & (nrm[..., 2] < 0.5)
        dz = np.abs(Z - geo["slit_z"])
        band = wall & (dz < 0.030)
        bar = wall & (np.abs(X) < geo["bar_x"])
        clay = np.where(band | bar, clay * 1.12 + 10, clay)
        rim = (wall & (np.abs(dz - 0.030) < 0.004)) | (wall & (np.abs(np.abs(X) - geo["bar_x"]) < 0.004))
        clay = np.where(rim, clay * 0.55, clay)
        clay = np.where(wall & (dz < 0.009) & ~bar, 26, clay)
        top_rim = mask & (nrm[..., 2] >= 0.5) & (ndi.distance_transform_edt(nrm[..., 2] >= 0.5) < 2.2 * SS)
        clay = np.where(top_rim, clay * 0.6, clay)
    dist_in = ndi.distance_transform_edt(mask)
    outline = np.clip(1.25 - dist_in / (2.0 * SS), 0, 1)
    clay = clay * (1 - 0.75 * outline) + 45 * 0.75 * outline
    base = base_colour(item) / 205.0
    col = np.clip(base[None, None] * (clay[..., None] * 1.18), 0, 255)
    img = np.where(mask[..., None], col, np.array(GROUND, np.float32)).astype(np.uint8)
    guide = Image.fromarray(img).resize((W, H), Image.LANCZOS)
    m = Image.fromarray((mask * 255).astype(np.uint8)).resize((W, H), Image.LANCZOS).point(
        lambda v: 255 if v >= 128 else 0)

    pf, body_mask, _, pstats = proxy_frames(proxy, tilt)
    want = ["head"] if spec["slot"] == "head" else ["torso"] + (
        [] if spec["sleeve"] == "sleeveless" else ["upperarm_l", "upperarm_r"]) + (
        ["forearm_l", "forearm_r"] if spec["sleeve"] == "long" else [])
    frames = {}
    for name in want:
        f = dict(pf[name])
        o = guide_to_item(cam, f["o"])
        f["o"] = [round(float(o[0]), 2), round(float(o[1]), 2)]
        for key in ("lx", "ly", "ly_neg"):
            if key in f:
                f[key] = round(f[key] * k, 3)
        frames[name] = f
    info = dict(item=item, proxy=proxy, tilt_deg=tilt, zoom=k, slot=spec["slot"], frames=frames,
                ground=list(GROUND), px_per_unit=round(scale / SS, 3),
                proxy_head_scale=cam["params"].get("head_scale", 1.0))
    if spec["slot"] == "torso":
        info["sleeve"] = spec["sleeve"]
        # where the collar hole sits in the torso frame (normalised U, V; V < 0 = toward the back)
        hc = np.array([[W / 2.0 + (0 - cam["xc"]) * scale / SS, H / 2.0 + (hy - cam["yc"]) * scale / SS]])
        U, V = core.frame_local(frames["torso"], hc)
        t = frames["torso"]
        info["collar"] = dict(centre_px=[round(float(hc[0, 0]), 2), round(float(hc[0, 1]), 2)],
                              r_px=round(hole["r"] * scale / SS, 2), U=round(float(U[0]), 4), V=round(float(V[0]), 4),
                              r_over_half_shoulder=round(hole["r"] * scale / SS / t["lx"], 4),
                              world=dict(y=round(hole["y"], 4), z=round(hole["z"], 4), r=round(hole["r"], 4)))
        hf = dict(pf["head"])
        ho = guide_to_item(cam, hf["o"])
        info["proxy_head_in_item_px"] = dict(o=[round(float(ho[0]), 2), round(float(ho[1]), 2)], r=round(hf["lx"] * k, 2))
    # self-test: the camera here is gen_plan's camera
    bp = [("ell", part.split(":")[0], c, r) for part, c, r in cam0["prims"]]
    bdep = raycast(bp, cam0)[0] > -1e8
    bm = np.array(Image.fromarray((bdep * 255).astype(np.uint8)).resize((W, H), Image.LANCZOS)) >= 128
    info["camera_iou_vs_gen_plan"] = round(float((bm & body_mask).sum()) / float((bm | body_mask).sum()), 4)
    return guide, m, info


def item_out(item):
    d = os.path.join(OUT, item)
    os.makedirs(d, exist_ok=True)
    return d


def make_swatch(item, out):
    sw = ITEMS[item]["swatch"]
    im = Image.open(os.path.join(core.RIGS, "items", item, "art.png")).convert("RGBA")
    bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
    bg.alpha_composite(im)
    c = bg.convert("RGB").crop(sw["box"])
    k = max(1, int(round(420.0 / max(c.size))))
    c = c.resize((c.width * k, c.height * k), Image.LANCZOS)
    p = os.path.join(out, "swatch.png")
    c.save(p)
    return p


def save_guide(item, proxy="orc", tilt=None):
    out = item_out(item)
    guide, m, info = render_item(item, proxy, tilt)
    guide.save(os.path.join(out, "guide.png"))
    m.save(os.path.join(out, "guide_mask.png"))
    make_swatch(item, out)
    with open(os.path.join(out, "guide.json"), "w") as f:
        json.dump(info, f, indent=1)
    print(json.dumps({k: info[k] for k in info if k not in ("frames",)}))
    return info


def build_prompt(item, tilt, note=""):
    s = ITEMS[item]
    deg = TILT_WORDS.get(int(round(tilt)), "%g" % tilt)
    t = ("Image 1 is a flat-colour 3D block-out of %s, " % s["what"]) + CAMERA % deg + s["reads"]
    t += ("Paint over this exact block-out to make a finished game item: %s. Keep the identical outline, "
          "position, scale and steep overhead viewpoint, tracing the silhouette precisely and keeping "
          "every form where and how large the block-out has it. %s." % (s["look"], s["paint"]))
    t += FINISH % (GROUND + (s["hole_words"],))
    t += SWATCH % (s["material"], s["hole_words"])
    if note:
        t += " " + note
    return t


def gen(item, n, tag, proxy="orc", tilt=None, note=""):
    from .gen_overhead import generate, _part
    out = item_out(item)
    info = save_guide(item, proxy, tilt)
    prompt = build_prompt(item, info["tilt_deg"], note)
    with open(os.path.join(out, "%s.prompt.txt" % tag), "w", encoding="utf-8") as f:
        f.write(prompt)
    for src, dst in (("guide.png", "in1_guide.png"), ("swatch.png", "in2_swatch.png"),
                     ("guide_mask.png", "guide_mask.png"), ("guide.json", "guide.json")):
        shutil.copyfile(os.path.join(out, src), os.path.join(out, "%s.%s" % (tag, dst)))
    parts = [{"text": prompt}, _part(os.path.join(out, tag + ".in1_guide.png"), max_side=1376),
             _part(os.path.join(out, tag + ".in2_swatch.png"))]
    log_p = os.path.join(OUT, "calls.json")
    log = json.load(open(log_p)) if os.path.exists(log_p) else []
    made = []
    for i in range(1, n + 1):
        name = "%s_%d" % (tag, i)
        try:
            raw, model = generate(parts)
        except RuntimeError as e:
            raw = None
            print("[FAIL] %s: %s" % (name, e))
        log.append("%s/%s%s" % (item, name, "" if raw else " FAILED"))
        with open(log_p, "w") as f:
            json.dump(log, f)
        if raw is None:
            continue
        p = os.path.join(out, name + ".png")
        with open(p, "wb") as f:
            f.write(raw)
        im = Image.open(p).convert("RGB")
        if im.size != (W, H):
            im = im.resize((W, H), Image.LANCZOS)
        im.save(p)
        made.append(p)
        print("[ok ] %s via %s" % (p, model))
    return made


# ---------------------------------------------------------------- key, check, install

def key(rgb):
    """Blue-dominance key. Returns (paint float RGB with the ground replaced by bled paint,
    alpha float 0..1)."""
    a = rgb.astype(np.float32)
    dom = a[..., 2] - np.maximum(a[..., 0], a[..., 1])
    k = 24
    corners = np.concatenate([a[:k, :k].reshape(-1, 3), a[:k, -k:].reshape(-1, 3),
                              a[-k:, :k].reshape(-1, 3), a[-k:, -k:].reshape(-1, 3)])
    bg = np.median(corners, 0)
    bdom = float(bg[2] - max(bg[0], bg[1]))
    fg = dom < 0.45 * bdom
    fg = ndi.binary_opening(fg, iterations=1)
    lab, n = ndi.label(fg)
    if not n:
        raise ValueError("nothing but ground in the painting")
    sizes = ndi.sum(fg, lab, range(1, n + 1))
    fg = np.isin(lab, 1 + np.nonzero(sizes >= 0.02 * sizes.max())[0])
    holes, hn = ndi.label(~fg)                      # specks of ground inside the paint are paint
    hs = ndi.sum(~fg, holes, range(1, hn + 1))
    fg |= np.isin(holes, 1 + np.nonzero(hs < 60)[0])
    core_m = ndi.binary_erosion(fg, iterations=2)
    _, (iy, ix) = ndi.distance_transform_edt(~core_m, return_indices=True)
    F = a[iy, ix]
    rim = ndi.binary_dilation(fg, iterations=1) & ~core_m
    num = ((a - bg) * (F - bg)).sum(-1)
    den = np.maximum(((F - bg) ** 2).sum(-1), 1.0)
    alpha = np.where(core_m, 1.0, 0.0).astype(np.float32)
    alpha[rim] = np.clip(num[rim] / den[rim], 0.0, 1.0)
    return np.where(core_m[:, :, None], a, F), alpha


def measure(path, gmask, info):
    rgb = np.asarray(Image.open(path).convert("RGB"))
    _, alpha = key(rgb)
    sil = alpha >= 0.5
    r = dict(name=os.path.basename(path),
             iou=round(float((sil & gmask).sum()) / float((sil | gmask).sum()), 4))
    ys, xs = np.nonzero(sil)
    gy, gx = np.nonzero(gmask)
    r["bbox_dx_dy_dw_dh"] = [int(xs.min() - gx.min()), int(ys.min() - gy.min()),
                             int((xs.max() - xs.min()) - (gx.max() - gx.min())),
                             int((ys.max() - ys.min()) - (gy.max() - gy.min()))]
    r["symmetry"] = round(float((sil & sil[:, ::-1]).sum()) / float((sil | sil[:, ::-1]).sum()), 4)
    if "collar" in info:
        c = info["collar"]
        yy, xx = np.mgrid[0:H, 0:W]
        hole = ((xx - c["centre_px"][0]) / c["r_px"]) ** 2 + ((yy - c["centre_px"][1]) / (c["r_px"] * 0.966)) ** 2 <= 1
        r["hole_open"] = round(float((hole & ~sil).sum()) / float(hole.sum()), 3)
        filled = ndi.binary_fill_holes(sil) & ~sil
        r["hole_px_vs_guide"] = round(float(filled.sum()) / float(hole.sum()), 3)
    ov = np.zeros((H, W, 3), np.uint8)
    ov[sil & gmask] = (200, 200, 200)
    ov[sil & ~gmask] = (230, 70, 70)
    ov[~sil & gmask] = (70, 120, 240)
    Image.fromarray(ov).save(path[:-4] + "_iou.png")
    return r


def tag_paths(item, tag):
    out = item_out(item)
    return sorted(os.path.join(out, f) for f in os.listdir(out)
                  if f.startswith(tag + "_") and f[len(tag) + 1:-4].isdigit() and f.endswith(".png"))


def check(item, tag):
    out = item_out(item)
    info = json.load(open(os.path.join(out, tag + ".guide.json")))
    gmask = np.array(Image.open(os.path.join(out, tag + ".guide_mask.png"))) > 127
    rows = [measure(p, gmask, info) for p in tag_paths(item, tag)]
    for r in rows:
        print(json.dumps(r))
    with open(os.path.join(out, tag + "_check.json"), "w") as f:
        json.dump(rows, f, indent=1)
    # contact sheet: guide + candidates, half size
    ims = [Image.open(os.path.join(out, tag + ".in1_guide.png"))] + [Image.open(p) for p in tag_paths(item, tag)]
    tw, th = W // 2, H // 2
    cols = 2
    sheet = Image.new("RGB", (tw * cols, th * ((len(ims) + 1) // cols)), (20, 20, 20))
    for i, im in enumerate(ims):
        sheet.paste(im.convert("RGB").resize((tw, th), Image.LANCZOS), ((i % cols) * tw, (i // cols) * th))
        ImageDraw.Draw(sheet).text(((i % cols) * tw + 6, (i // cols) * th + 6),
                                   "guide" if i == 0 else rows[i - 1]["name"] + "  IoU %.3f" % rows[i - 1]["iou"],
                                   fill=(255, 255, 255))
    sheet.save(os.path.join(out, tag + "_sheet.jpg"), quality=90)
    return rows


def install(item, painting, new_id=None, ease=1.0):
    """Key the painting, crop it, and ingest it as an item pack with the guide's proxy frames."""
    new_id = new_id or item + "_td"
    out = item_out(item)
    tag = os.path.basename(painting).rsplit("_", 1)[0]
    info = json.load(open(os.path.join(out, tag + ".guide.json")))
    gmask = np.array(Image.open(os.path.join(out, tag + ".guide_mask.png"))) > 127
    rgb = np.asarray(Image.open(painting).convert("RGB"))
    paint, alpha = key(rgb)
    m = measure(painting, gmask, info)
    ys, xs = np.nonzero(alpha > 0.02)
    pad = 4
    x0, y0 = max(int(xs.min()) - pad, 0), max(int(ys.min()) - pad, 0)
    x1, y1 = min(int(xs.max()) + 1 + pad, W), min(int(ys.max()) + 1 + pad, H)
    a8 = np.clip(np.round(alpha[y0:y1, x0:x1] * 255), 0, 255).astype(np.uint8)
    a8[a8 < 6] = 0
    art = np.dstack([np.clip(np.round(paint[y0:y1, x0:x1]), 0, 255).astype(np.uint8), a8])
    tmp = os.path.join(out, new_id + "_art.png")
    Image.fromarray(art, "RGBA").save(tmp, optimize=True)
    frames = {}
    for name, f in info["frames"].items():
        g = dict(f)
        g["o"] = [round(f["o"][0] - x0, 2), round(f["o"][1] - y0, 2)]
        frames[name] = g
    meta = {"camera": "tilt%g" % info["tilt_deg"],
            "source": "gen_item paint-over: %s/%s (proxy %s, guide IoU %.3f); frames are the proxy's, not measured"
                      % (item, os.path.basename(painting), info["proxy"], m["iou"])}
    if "collar" in info:
        meta["collar"] = {k: info["collar"][k] for k in ("U", "V", "r_over_half_shoulder")}
    spec = ITEMS[item]
    d = ingest.ingest(new_id, tmp, spec["slot"], frames=frames, sleeve=spec.get("sleeve"),
                      layer=spec.get("layer"), ease=ease, meta=meta)
    print("wrote Rigs/items/%s  frames: %s  %s" % (new_id, ", ".join(d["frames"]), json.dumps(m)))
    return d


# ---------------------------------------------------------------- compare

PILOT = ["peasants_stained_shirt", "breastplate", "great_helm"]
RACES = [("orc", "tilt15"), ("orc", "tilt15_head"), ("orc", "default"), ("human", "default"), ("goblin_male", "default"),
         ("halfling_male", "default")]
SHEET_RACES = [("orc", "tilt15"), ("orc", "tilt15_head"), ("human", "default"), ("halfling_male", "default"), ("orc", "default"),
               ("goblin_male", "default")]


def _present(races):
    return [rv for rv in races if os.path.exists(os.path.join(core.race_dir(*rv), "race.json"))]


def metrics(races=RACES, items=PILOT):
    from .check import check_pair
    from .render import RaceCanvas, item_layers
    skel = core.skeleton()
    rows = []
    for race, variant in _present(races):
        canvas = RaceCanvas(race, variant)
        head = canvas.mask("face", "hair")
        for base in items:
            for iid in (base, base + "_td"):
                if not os.path.exists(os.path.join(core.RIGS, "items", iid, "item.json")):
                    continue
                it = core.load_item(iid)
                for r in check_pair(canvas, it, skel):
                    r = dict(r)
                    if it["slot"] == "head" and r.get("status") != "n/a":
                        _, layer, _ = item_layers(canvas, it, skel)[0]
                        m = layer[:, :, 3] > 24
                        r["head_label_cover"] = round(float((m & head).sum()) / float(head.sum()), 3)
                    if it["slot"] == "torso":
                        al, ac = core.frame_stretch(it, skel, canvas.data, "torso")
                        r["along"], r["across"] = round(al, 3), round(ac, 3)
                    rows.append(r)
    return rows


def pilot_sheet(out_path, races=SHEET_RACES, items=PILOT, tile=(560, 330)):
    from .render import compose
    from .sheet import BG
    skel = core.skeleton()
    races = _present(races)
    side, head = 150, 26
    cols = [(i, s) for i in items for s in ("", "_td")]
    sheet = Image.new("RGB", (side + tile[0] * len(races), head + tile[1] * len(cols)), (30, 32, 30))
    dr = ImageDraw.Draw(sheet)
    for j, (race, variant) in enumerate(races):
        dr.text((side + j * tile[0] + 6, 7), "%s/%s" % (race, variant), fill=(230, 230, 220))
    for i, (base, suf) in enumerate(cols):
        iid = base + suf
        dr.text((6, head + i * tile[1] + 8), "NEW (tilt15)" if suf else "OLD (front view)", fill=(255, 220, 140) if suf else (200, 200, 190))
        dr.text((6, head + i * tile[1] + 24), iid.replace("_stained", "\n_stained"), fill=(200, 200, 190))
        for j, (race, variant) in enumerate(races):
            img, _, canvas = compose(race, [iid], variant, skel, background=BG)
            f = canvas.data["frames"]
            t = f["torso"]
            # frame the trunk and head: at least 2.9 half-shoulders wide
            half_w = t["lx"] * 2.9
            cx = t["o"][0] + canvas.pad
            y_top = min(f["head_full"]["o"][1] - f["head_full"]["ly"], t["o"][1] - t.get("ly_neg", t["ly"])) + canvas.pad
            y_bot = t["o"][1] + t["ly"] + canvas.pad
            cy = (y_top + y_bot) / 2.0
            half_h = max(half_w * tile[1] / tile[0], (y_bot - y_top) / 2.0 * 1.12)
            half_w = half_h * tile[0] / tile[1]
            x0, x1 = int(round(cx - half_w)), int(round(cx + half_w))
            y0, y1 = int(round(cy - half_h)), int(round(cy + half_h))
            pad = max(0, -x0, -y0, x1 - img.shape[1], y1 - img.shape[0])
            big = np.zeros((img.shape[0] + 2 * pad, img.shape[1] + 2 * pad, 3), np.uint8)
            big[:] = BG
            big[pad:pad + img.shape[0], pad:pad + img.shape[1]] = img[:, :, :3]
            crop = big[y0 + pad:y1 + pad, x0 + pad:x1 + pad]
            interp = cv2.INTER_AREA if crop.shape[1] > tile[0] else cv2.INTER_CUBIC
            sheet.paste(Image.fromarray(cv2.resize(crop, tile, interpolation=interp)),
                        (side + j * tile[0], head + i * tile[1]))
    for j in range(1, len(races)):
        dr.line([(side + j * tile[0], 0), (side + j * tile[0], sheet.height)], fill=(30, 32, 30), width=2)
    for i in range(1, len(cols)):
        dr.line([(0, head + i * tile[1]), (sheet.width, head + i * tile[1])], fill=(30, 32, 30),
                width=6 if i % 2 == 0 else 2)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    sheet.save(out_path, quality=90)
    return out_path


def compare(out_dir):
    rows = metrics()
    core.save_json(os.path.join(out_dir, "pilot_metrics.json"), {"rows": rows})
    print("%-22s %-28s %-5s %6s %6s %7s %6s %6s %6s  %s" % ("race", "item", "stat", "cover", "spill", "stretch",
                                                            "along", "across", "headL", "why"))
    for r in rows:
        print("%-22s %-28s %-5s %6s %6s %7s %6s %6s %6s  %s" % (
            "%s/%s" % (r["race"], r["variant"]), r["item"], r["status"], r.get("cover", ""), r.get("spill", ""),
            r.get("stretch", ""), r.get("along", ""), r.get("across", ""), r.get("head_label_cover", ""), r.get("why", "")))
    print("wrote", pilot_sheet(os.path.join(out_dir, "pilot_sheet.jpg")))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("guide", "gen", "check", "install"):
        s = sub.add_parser(name)
        s.add_argument("item", choices=sorted(ITEMS))
        if name in ("guide", "gen"):
            s.add_argument("--proxy", default="orc")
            s.add_argument("--tilt", type=float, default=None)
        if name == "gen":
            s.add_argument("--n", type=int, default=4)
            s.add_argument("--tag", default="r1")
            s.add_argument("--note", default="")
        if name == "check":
            s.add_argument("--tag", default="r1")
        if name == "install":
            s.add_argument("painting")
            s.add_argument("--id", default=None)
            s.add_argument("--ease", type=float, default=1.0)
    c = sub.add_parser("compare")
    c.add_argument("--out", default=OUT)
    a = ap.parse_args(argv)
    if a.cmd == "guide":
        save_guide(a.item, a.proxy, a.tilt)
    elif a.cmd == "gen":
        gen(a.item, a.n, a.tag, a.proxy, a.tilt, a.note)
        check(a.item, a.tag)
    elif a.cmd == "check":
        check(a.item, a.tag)
    elif a.cmd == "install":
        install(a.item, a.painting, a.id, a.ease)
    else:
        compare(a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
