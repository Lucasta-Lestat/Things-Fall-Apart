"""Paint a WORN item for the approved race camera, by painting over a rendered item guide.

    python -m tools.rigkit.gen_item list
    python -m tools.rigkit.gen_item guide   <item> [--proxy orc] [--tilt 15]
    python -m tools.rigkit.gen_item gen     <item> [--n 4] [--tag r1] [--note "extra positive sentence"]
    python -m tools.rigkit.gen_item check   <item> [r1]
    python -m tools.rigkit.gen_item install <item> <painting.png> [--id <item>_td]
    python -m tools.rigkit.gen_item sheet   <item>     (original vs _td on five race packs -> <item>/compare.jpg)
    python -m tools.rigkit.gen_item promote <item>     (the _td pack becomes Rigs/items/<item>; old art -> <item>/original.png)
    python -m tools.rigkit.gen_item compare [--out tools/rigkit/out/items_td]   (pilot metrics + pilot sheet)

EVERY ITEM IS A SPEC FILE: tools/rigkit/items_td/<item>.json (shell type and knobs, swatch crop of
the ORIGINAL art, prompt words). This module holds no per-item data. tools/rigkit/items_td/README.md
lists the fields. A painter tunes only its own spec file.

The race pilots' lesson, applied to items: GIVE the camera, do not ask for it. The guide is the
item's own shell, built on the SAME 3D proxy gen_plan.py paints races over and rendered by the
SAME camera (orthographic, tilted 15 degrees off vertical toward the front, T-pose). Shell types:

  torso   the trunk primitives (and arms for a sleeved garment), inflated by the cloth's clearance,
          with the neck removed and a neck opening cut where the neck leaves the trunk at this
          camera, a collar ring round it. Knobs: sleeve (sleeveless | short | long), sleeve cover /
          inflate / taper, shoulder cap, and an optional SKIRT (a robe: a wall that hangs from the
          hips to the floor round the feet, hugging the body footprint).
  bucket  a flat-topped elliptic cylinder (a great helm) round every head primitive but the ears.
  brim    a dome over the cranium and a wide flat brim (a kettle hat).
  open    a dome over the cranium, the face left open, with optional crown spikes and cheek guards.
  hood    a soft shell round the whole head with a dark face opening and a drape on the nape.
  foot    ONE foot (image left; the rig mirrors it): sole, a smooth toe cap and a short ankle cuff
          whose open top is ground (keyed out), so the wearer's leg shows through it.

BUILD. "build": "proxy" builds the shell on the proxy race's own muscles (the two accepted pilots,
shirt and great helm, were painted that way and their guides are frozen). "build": "neutral" builds a
torso shell on a tailor's form of the SAME proportions: one smooth chest instead of two pectoral
lobes, no deltoid caps. The extents (shoulder span, front and back depth) are unchanged, so the
proxy's frames still describe the shell and the fit to every race is unchanged; only the surface
the painter sees is generic, so cloth and plate stop copying an orc's chest. New torso specs use it.

ITEM FRAMES ARE NOT MEASURED FROM THE ART. They are the proxy's own anatomy: the proxy's label map,
with install_plan's label conventions (armpit shoulder seam, no leg sliver), goes through derive.py,
exactly as a painted race does, and those frames (torso, upperarm_l/r, forearm_l/r, head, foot),
moved into the item picture, are the item's frames. So fitting a _td item to a race maps the proxy's
body onto that race's body, and on a race painted over the same proxy the fit is the identity.

GROUND. The ground is a flat key colour, never the races' grey (steel and linen shadows pass through
mid-grey). It is chosen per item: "ground": "blue" | "green" | "magenta", or "auto" = the key hue
farthest from the hues of the swatch (green for a colourless swatch such as steel), so the ground
cannot be mistaken for, or bleed into, the material. The neck opening is painted as ground and keyed
out; every keyed edge is smoothed and feathered (see `key`). "tone_match" (0..1) pulls the keyed painting's mean colour and contrast
toward the swatch of the original at install, so a repaint keeps the original's colour and darkness.

This tool imports from gen_plan and install_plan and never edits them. Prompts are phrased
positively only. `gen` needs GEMINI_API_KEY.
"""
import argparse
import colorsys
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
SPECS = os.path.join(HERE, "items_td")
W, H, SS = gen_plan.W, gen_plan.H, gen_plan.SS
MARGIN = 0.035                      # gen_plan.render's default: fingertips this far from the edges
GROUNDS = {"blue": (58, 110, 215), "green": (40, 190, 70), "magenta": (225, 45, 205)}
GROUND_HUE = {"blue": 220.0, "green": 132.0, "magenta": 307.0}
GROUND = GROUNDS["blue"]            # gen_hands imports this name
NEUTRAL_WEIGHT = 0.10               # a swatch whose mean colour weight (S x V) is below this has no hue
TILT_WORDS = gen_plan.TILT_WORDS

CAMERA = (
    "rendered by an orthographic camera high above it, looking steeply down from just in front of "
    "directly overhead, leaning %s degrees toward its front: the view of a miniature's gear on a "
    "tabletop battle map. It is shaped exactly as worn by an upright figure that faces the bottom of "
    "the picture with both arms stretched straight out to the sides; the figure itself is absent, so "
    "the piece holds its worn shape on its own. ")
FINISH = (
    " Left-right symmetric, lit softly and evenly from above, the piece alone on a perfectly flat "
    "uniform %s background, RGB %d %d %d, that fills the rest of the picture%s.")
FINISH_ONE = (
    " Lit softly and evenly from above, the piece alone on a perfectly flat uniform %s background, "
    "RGB %d %d %d, that fills the rest of the picture%s.")
SWATCH = (
    " Image 2 is a small close-up swatch of this item's existing painted art, for material, colour "
    "and finish only: match its %s, its semi-realistic hand-painted brushwork with soft-edged "
    "shading, and its thin dark contour line, about three pixels thick, around the whole silhouette%s.")

SHELL_SLOT = {"torso": "torso", "bucket": "head", "brim": "head", "open": "head", "hood": "head", "foot": "feet"}
DEFAULTS = dict(build="neutral", ground="auto", tint_pct=65.0, tone_match=0.0, encloses=False, note="",
                hole_words="")


# ---------------------------------------------------------------- specs

def list_specs():
    if not os.path.isdir(SPECS):
        return []
    return sorted(f[:-5] for f in os.listdir(SPECS) if f.endswith(".json"))


def load_spec(item):
    """tools/rigkit/items_td/<item>.json with the defaults laid under it. `slot` follows the shell.
    Prompt strings may be written as a list of pieces (joined) and may hold {ground}, the key
    colour's name."""
    p = os.path.join(SPECS, item + ".json")
    if not os.path.exists(p):
        raise SystemExit("no spec %s (have: %s)" % (os.path.relpath(p, core.ROOT), ", ".join(list_specs())))
    s = dict(DEFAULTS, **core.load_json(p))
    s["item"] = item
    if s.get("shell") not in SHELL_SLOT:
        raise SystemExit("%s: \"shell\" must be one of %s" % (item, ", ".join(SHELL_SLOT)))
    s["slot"] = SHELL_SLOT[s["shell"]]
    for k in ("what", "reads", "look", "paint", "material", "hole_words", "note"):
        if isinstance(s.get(k), list):
            s[k] = "".join(s[k])
    for k in ("what", "reads", "look", "paint", "material"):
        if not s.get(k):
            raise SystemExit("%s: spec has no %r" % (item, k))
    s["swatch"] = dict(s["swatch"], box=tuple(s["swatch"]["box"]))
    return s


def original_art(item):
    """The pre-repaint art: the swatch, tint and tone-match source. `promote` files it as
    out/items_td/<item>/original.png when the repaint takes over Rigs/items/<item>/."""
    kept = os.path.join(OUT, item, "original.png")
    return kept if os.path.exists(kept) else os.path.join(core.RIGS, "items", item, "art.png")


def swatch_pixels(spec):
    """Opaque RGB pixels (N, 3 float) of the swatch crop of the original art."""
    a = np.array(Image.open(original_art(spec["item"])).convert("RGBA").crop(spec["swatch"]["box"])).astype(np.float32)
    px = a[a[..., 3] > 200][:, :3]
    if len(px) < 50:
        raise SystemExit("%s: swatch box %s holds almost no opaque art" % (spec["item"], spec["swatch"]["box"]))
    return px


def ground_for(spec):
    """(name, rgb, why). "auto": the key hue farthest from the swatch's hues, weighting each swatch
    pixel by its saturation x value; a swatch with no colour to speak of (steel, black cloth) takes
    green, the key a grey can least be mistaken for (green minus the larger of red and blue is zero
    on every grey)."""
    g = spec.get("ground", "auto")
    if g in GROUNDS:
        return g, GROUNDS[g], "set in the spec"
    px = swatch_pixels(spec) / 255.0
    mx, mn = px.max(1), px.min(1)
    sat = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    wt = sat * mx
    if float(wt.mean()) < NEUTRAL_WEIGHT:
        return "green", GROUNDS["green"], "colourless swatch (weight %.3f)" % float(wt.mean())
    step = max(1, len(px) // 4000)
    hue = np.array([colorsys.rgb_to_hsv(*c)[0] * 360.0 for c in px[::step]])
    w = wt[::step]
    best = None
    for name, h in GROUND_HUE.items():
        d = np.abs(hue - h) % 360.0
        d = np.minimum(d, 360.0 - d)
        score = float((d * w).sum() / w.sum())
        if best is None or score > best[1]:
            best = (name, score)
    return best[0], GROUNDS[best[0]], "mean hue distance %.0f deg from the swatch" % best[1]


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
#
# A shell function takes (spec, cam at zoom 1) and returns a dict:
#   prims    [(kind, tag, centre, radii[, (z0, z1)])] for raycast
#   frames   the proxy frames the item carries ({item frame name: proxy frame name})
#   hole     torso only: dict(y, r, z) of the neck opening
#   clip_x   torso only: |x| the sleeves are cut at
#   geo      numbers the shell's markings use
#   sigma    normal-smoothing radius (the softness of the block-out)
#   xc       x of the shell's centre when it is not on the body's centre line

def neutral_build(P, p):
    """The proxy's primitives with the trunk's muscles smoothed into a tailor's form: the two
    pectoral lobes become one chest swell of the same reach, and the deltoid caps go (the arm
    capsule already rounds the shoulder). Depths, widths and every other primitive are untouched,
    so the proxy's frames still fit the shell."""
    cs, ph, sh = p["chest_depth_s"], p["pec_half"], p["shoulder_half"]
    out = []
    done = False
    for part, c, r in P:
        if part == "body" and abs(c[2] - 1.385) < 1e-6 and abs(c[0]) > 1e-6:           # a pec
            if not done:
                out.append(("body", (0.0, cs - 0.105, 1.385), (min(ph * 2.15, sh * 0.96), 0.105, 0.115)))
                done = True
            continue
        if part == "body" and abs(c[2] - 1.535) < 1e-6 and abs(c[0]) > 1e-6:           # a deltoid cap
            continue
        out.append((part, c, r))
    assert done, "proxy layout changed: pecs not found"
    return out


def torso_shell(spec, cam):
    """A torso garment on the proxy: trunk (+ arms), a neck opening, an optional skirt."""
    p, P = cam["params"], cam["prims"]
    t = spec["inflate"]
    i_head = next(i for i, q in enumerate(P) if q[0].startswith("face"))
    neck = P[i_head - 1]
    assert neck[0] == "body" and neck[1][0] == 0 and neck[2][0] < 0.14, "proxy layout changed: neck not found"
    sh = p["shoulder_half"]
    seam = sh + 0.05
    clip_x = None
    if spec["sleeve"] == "short":
        clip_x = seam + float(spec.get("sleeve_cover", ingest.SHORT_SLEEVE_COVERS)) * (p["elbow_x"] - seam)
    elif spec["sleeve"] == "long":
        clip_x = seam + float(spec.get("sleeve_cover", ingest.LONG_SLEEVE_COVERS)) * (p["wrist_x"] - seam)
    elif spec.get("clip_half"):
        clip_x = float(spec["clip_half"]) * sh           # a sleeveless piece cut square at the arm holes
    src = [q for i, q in enumerate(P) if i != i_head - 1]
    if spec.get("build", "neutral") == "neutral":
        src = neutral_build(src, p)
    ti, tp = float(spec.get("sleeve_inflate", 0.0)), float(spec.get("sleeve_taper", 0.0))
    prims = []
    for part, c, r in src:
        if part == "body":
            if spec["sleeve"] == "sleeveless" and abs(c[0]) > spec.get("cap_x", 0.78) * sh:
                continue                                    # deltoid caps and the outer shoulder girdle
            hw = float(spec.get("hip_wide", 0.0))           # a lower rim that flares out over the hips
            if hw and abs(c[0]) < 1e-6 and c[2] < 1.2:
                prims.append(("ell", "shell", c, (r[0] + t + hw, r[1] + t, r[2] + t)))
                continue
            prims.append(("ell", "shell", c, tuple(v + t for v in r)))
            continue
        if part.startswith("upperarm_"):
            if spec["sleeve"] == "sleeveless":
                continue
        elif part.startswith("forearm_"):
            if spec["sleeve"] != "long":
                continue
        else:
            continue
        if ti or tp:                                        # a loose or belled sleeve
            k = float(np.clip((abs(c[0]) - seam) / max(clip_x - seam, 1e-6), 0.0, 1.0))
            prims.append(("ell", "shell", c, tuple(v + t + ti + v * tp * k for v in r)))
        else:
            prims.append(("ell", "shell", c, tuple(v + t for v in r)))
    sk = spec.get("skirt")
    if sk is not None:
        # a robe's skirt: a wall from the hips down to just above the floor, round the legs. Its
        # half-width follows the wider of hips and feet, its front the belly, so it hugs the body's
        # footprint (the original front-view robe flared and floated off narrow bodies).
        z_floor = p.get("floor_z", 0.70)
        fx, fw = p.get("foot_x_tilt", p["foot_x"]), p.get("foot_w", p["toe_r"] * 2.6)
        rx = max(p["belly_half"] * 0.95, fx + fw * 0.55) + t + float(sk.get("wide", 0.0))
        front = p["belly_depth_s"] - 0.03 + t + float(sk.get("front", 0.0))
        back = -(p["trunk_depth_n"] - 0.05) - t
        z0 = z_floor + float(sk.get("hem", 0.02))
        z1 = float(sk.get("top", 1.00))
        flare, n = float(sk.get("flare", 0.02)), 12
        for i in range(n):                                  # widest at the hem
            f = flare * (1.0 - i / (n - 1.0))
            za, zb = z0 + (z1 - z0) * i / n, z0 + (z1 - z0) * (i + 1) / n
            prims.append(("cyl", "shell", (0.0, (front + back) / 2 + f / 2, (za + zb) / 2),
                          (rx + f, (front - back) / 2 + f / 2, (zb - za) / 2), (za, zb)))
    hole = dict(y=neck[1][1] + float(spec.get("hole_y", 0.0)), r=neck[2][0] + spec["hole_clear"], z=neck[1][2])
    want = {"torso": "torso"}
    if spec["sleeve"] != "sleeveless":
        want.update(upperarm_l="upperarm_l", upperarm_r="upperarm_r")
    if spec["sleeve"] == "long":
        want.update(forearm_l="forearm_l", forearm_r="forearm_r")
    out = dict(prims=prims, hole=hole, clip_x=clip_x, frames=want, sigma=3.0)
    if spec.get("flange") or spec.get("rim_steps"):
        # plate details drawn into the clay: a rolled flange down each arm hole (needs clip_half),
        # and a lower rim stepped into `rim_steps` narrow bands, each `rim_step` wide
        out["geo"] = dict(kind="torso", clip_x=clip_x, flange=float(spec.get("flange", 0.0)),
                          rim_steps=int(spec.get("rim_steps", 0)), rim_step=float(spec.get("rim_step", 0.022)))
    return out


def _head_geo(cam):
    """The proxy head's numbers every helm shell starts from."""
    P = cam["prims"]
    skull = next(q for q in P if q[0] == "face:skull")
    (_, sy_, sz), (srx, sry, srz) = skull[1], skull[2]
    face = [q for q in P if q[0].startswith("face") and abs(q[1][0]) < srx * 0.75]     # ears start at 0.9 r
    return dict(sy=sy_, sz=sz, srx=srx, sry=sry, srz=srz, y_back=sy_ - sry,
                y_front=max(c[1] + r[1] for _, c, r in face), z_face=min(c[2] - r[2] for _, c, r in face))


def helm_shell(spec, cam):
    """bucket: a flat-topped elliptic cylinder round every head primitive except the ears."""
    g = _head_geo(cam)
    pad = spec["pad"]
    y_back, y_front = g["y_back"], g["y_front"]
    z_top = g["sz"] + g["srz"] + pad
    z_bot = g["z_face"] - 2 * pad
    ry = (y_front - y_back) / 2 + pad
    rx = max(g["srx"] + pad, 0.92 * ry)
    c = (0.0, (y_front + y_back) / 2, (z_top + z_bot) / 2)
    geo = dict(kind="bucket", c=c, rx=rx, ry=ry, z0=z_bot, z1=z_top, slit_z=g["sz"] - 0.15 * g["srz"], bar_x=0.11 * rx)
    return dict(prims=[("cyl", "shell", c, (rx, ry, (z_top - z_bot) / 2), (z_bot, z_top))], geo=geo,
                frames={"head": "head"}, sigma=1.0)


def brim_shell(spec, cam):
    """brim: a kettle hat. A dome over the cranium and a wide, thin, slightly dished brim at brow
    height that hides the face and ears below it."""
    g = _head_geo(cam)
    pad = float(spec.get("pad", 0.012))
    srx, sry, srz = g["srx"], g["sry"], g["srz"]
    c = (0.0, g["sy"] + float(spec.get("forward", 0.010)), g["sz"])
    k = float(spec.get("brim", 1.72))                       # brim radius over the dome's
    zb = g["sz"] - srz * float(spec.get("brim_drop", 0.30))
    th = float(spec.get("brim_thick", 0.012))
    drx, dry = srx + pad, sry + pad
    prims = [("ell", "shell", c, (drx, dry, srz * float(spec.get("crown", 1.0)) + pad))]
    n = 5                                                   # a brim that slopes down toward its edge
    slope = float(spec.get("brim_slope", 0.035))
    for i in range(n):
        f = (i + 1.0) / n
        r = 1.0 + (k - 1.0) * f
        z1 = zb - slope * f
        prims.append(("cyl", "shell", (c[0], c[1], z1 - th / 2), (drx * r, dry * r, th / 2), (z1 - th, z1)))
    geo = dict(kind="brim", c=c, rx=drx, ry=dry, zb=zb, ridge=float(spec.get("ridge", 0.010)))
    return dict(prims=prims, geo=geo, frames={"head": "head"}, sigma=1.4)


def open_shell(spec, cam):
    """open: an open-faced helm. A dome over the cranium whose rim stops at the brow, so the face
    strip stays uncovered; optional crown spikes round the rim and a cheek guard each side."""
    g = _head_geo(cam)
    pad = float(spec.get("pad", 0.012))
    srx, sry, srz = g["srx"], g["sry"], g["srz"]
    c = (0.0, g["sy"], g["sz"])
    drx, dry, drz = srx + pad, sry + pad, srz + pad
    prims = [("ell", "shell", c, (drx, dry, drz))]
    n = int(spec.get("spikes", 0))
    if n:
        ln = float(spec.get("spike_len", 0.07)) * srx / 0.108
        rise = float(spec.get("spike_rise", 0.55))          # how far a spike leans up (0 = flat outward)
        gap = np.radians(float(spec.get("spike_gap_deg", 55.0)))   # the front arc left free for the face
        zr = g["sz"] - drz * 0.25
        sb = float(spec.get("spike_base", 0.92))            # 0.92 = rooted inside the dome; 1.0 = on its surface
        for a in np.linspace(np.pi / 2 + gap, np.pi / 2 + 2 * np.pi - gap, n):
            ca, sa = float(np.cos(a)), float(np.sin(a))
            q = float(np.sqrt(max(1 - (0.25) ** 2, 0)))     # the dome's radius at height zr
            a0 = np.array([drx * q * ca * sb, c[1] + dry * q * sa * sb, zr])
            a1 = a0 + np.array([ca * ln, sa * ln, ln * rise])
            m = int(np.ceil(ln / 0.004)) + 2
            if "spike_base" in spec:                        # steep spikes: sample their true length
                m = int(np.ceil(ln * np.sqrt(1 + rise * rise) / 0.0025)) + 2
            for t_ in np.linspace(0, 1, m):
                r = 0.017 * srx / 0.108 * (1 - t_) + 0.003
                prims.append(("ell", "shell", tuple(a0 + (a1 - a0) * t_), (r, r, r)))
    ck = float(spec.get("cheek", 0.0))
    ci = float(spec.get("cheek_in", 0.0))
    if ck and ci:
        # cheek plates that hang in front of the ears and curve in round the face toward the nose,
        # stopping `cheek_gap` (share of the head's half width) short of the centre line
        yf = g["y_front"]
        gap_x = float(spec.get("cheek_gap", 0.10)) * srx
        ry_ = (yf - c[1]) * (0.86 + 0.14 * ci)
        a_end = float(np.arccos(np.clip(gap_x / (srx * 0.80), 0, 1)))
        for s_ in (-1, 1):
            for u in np.linspace(0, 1, 40):
                a = np.radians(8.0) + (a_end - np.radians(8.0)) * u
                z = g["sz"] - srz * (0.55 + 0.42 * u)
                rr = srx * 0.20 * ck * (1.0 - 0.45 * u)
                prims.append(("ell", "shell", (s_ * srx * 0.80 * float(np.cos(a)), c[1] + ry_ * float(np.sin(a)), z),
                              (rr, rr, srz * (0.50 - 0.22 * u))))
    elif ck:
        yf = g["y_front"]
        for s_ in (-1, 1):                                  # a guard hanging in front of each ear
            prims.append(("ell", "shell", (s_ * srx * 0.78, c[1] + (yf - c[1]) * 0.55, g["sz"] - srz * 0.75),
                          (srx * 0.26 * ck, (yf - c[1]) * 0.50, srz * 0.62)))
    ns = float(spec.get("nasal", 0.0))
    if ns:                                                  # a nasal bar from the brow down the nose
        yf = g["y_front"]
        for u in np.linspace(0, 1, 24):
            rr = srx * 0.085 * ns * (1.0 - 0.35 * u)
            prims.append(("ell", "shell", (0.0, c[1] + (yf - c[1]) * (0.80 + 0.22 * u), g["sz"] - srz * (0.15 + 0.80 * u)),
                          (rr, rr, srz * 0.16)))
    geo = dict(kind="open", c=c, rx=drx, ry=dry, ridge=float(spec.get("ridge", 0.0)))
    return dict(prims=prims, geo=geo, frames={"head": "head"}, sigma=1.2)


def hood_shell(spec, cam):
    """hood: soft cloth round the whole head, ears and all, falling to a drape on the nape; the
    face opening is a dark hollow on its front."""
    g = _head_geo(cam)
    pad = float(spec.get("pad", 0.020))
    srx, srz = g["srx"], g["srz"]
    y_back, y_front = g["y_back"] - pad, g["y_front"] + pad * 0.5
    z_top, z_bot = g["sz"] + srz + pad, g["z_face"] - pad
    rx = srx + pad + float(spec.get("wide", 0.012))
    ry = (y_front - y_back) / 2
    c = (0.0, (y_front + y_back) / 2, (z_top + z_bot) / 2)
    prims = [("ell", "shell", c, (rx, ry, (z_top - z_bot) / 2 * 1.08))]
    dr = float(spec.get("drape", 1.0))
    if dr:                                                  # the cowl gathering behind the neck
        prims.append(("ell", "shell", (0.0, y_back + ry * 0.30, z_bot + 0.02), (rx * 0.92 * dr, ry * 0.62, 0.075)))
    pk = float(spec.get("peak", 0.5))
    if pk:                                                  # the hood's point, at the back of the crown
        prims.append(("ell", "shell", (0.0, y_back + ry * 0.12, c[2] + (z_top - c[2]) * 0.35),
                      (rx * 0.42, ry * 0.30 * (0.6 + pk), (z_top - z_bot) * 0.28)))
    geo = dict(kind="hood", c=c, rx=rx, ry=ry, z0=z_bot, z1=z_top, open_w=float(spec.get("opening", 0.62)))
    return dict(prims=prims, geo=geo, frames={"head": "head"}, sigma=2.2)


def foot_shell(spec, cam):
    """foot: ONE boot, on the proxy's image-left foot (the rig mirrors feet items to the other
    side). Sole from heel to ball, one smooth toe cap in place of five toes, the instep, and a short
    ankle cuff round the bottom of the leg. From this camera the cuff's top is mostly under the belly."""
    p, P = cam["params"], cam["prims"]
    s = -1.0
    t = float(spec.get("inflate", 0.010))
    z0 = p.get("floor_z", 0.70)
    fx = p.get("foot_x_tilt", p["foot_x"])
    ty = p.get("toe_y_tilt", p["toe_y"] * 0.85)
    fw = p.get("foot_w", p["toe_r"] * 2.6)
    fl = p.get("foot_len", 0.25)
    tl = fw * 0.95
    heel, ball = ty - fl, ty - tl - fw * 0.30
    first = next(q for q in P if q[0] == "foot_l")
    assert abs(first[1][0] - s * fx) < 1e-6 and abs(first[1][1] - (heel + 0.045)) < 1e-6, "proxy layout changed: foot"
    prims = []
    a, b = np.array([s * fx, heel + 0.045, z0 + 0.040]), np.array([s * fx, ball - 0.01, z0 + 0.034])
    for u in np.linspace(0, 1, 24):                         # heel to ball
        r = fw * (0.72 + 0.26 * u)
        prims.append(("ell", "shell", tuple(a + (b - a) * u), (r + t, r + t, r * 0.62 + t)))
    prims.append(("ell", "shell", (s * fx, heel + 0.10, z0 + 0.075), (fw * 0.70 + t, 0.075 + t, 0.055 + t)))   # instep
    point = float(spec.get("toe_point", 0.0))               # 0 = round toe; 1 = a long pointed toe
    tip = ty + float(spec.get("toe_reach", 0.0)) + point * fw * 0.6
    cy = (ball + tip) / 2
    m = 18
    for u in np.linspace(0, 1, m):                          # the toe cap: a tapering run of ellipsoids
        w = fw * 1.02 * (1.0 - (0.30 + 0.55 * point) * u ** 1.6)
        y = ball - 0.012 + (tip - ball - w * 0.55) * u
        prims.append(("ell", "shell", (s * fx, y, z0 + 0.030), (w + t, w * 0.62 + t, 0.040 + t)))
    leg = [q for q in P if q[0] == "leg_l"][-1]
    cuff_h = float(spec.get("cuff", 0.10))
    cr = leg[2][0] + t + float(spec.get("cuff_wide", 0.012))
    cz0, cz1 = z0 + 0.05, z0 + 0.05 + cuff_h
    cc = (leg[1][0], leg[1][1], (cz0 + cz1) / 2)
    prims.append(("cyl", "shell", cc, (cr, cr, cuff_h / 2), (cz0, cz1)))
    geo = dict(kind="foot", cuff_c=cc, cuff_r=cr, cuff_z=cz1, cuff_open=float(spec.get("cuff_open", 0.74)))
    return dict(prims=prims, geo=geo, frames={"foot": "foot_l"}, sigma=1.3, xc=s * fx, one_sided=True)


SHELLS = {"torso": torso_shell, "bucket": helm_shell, "brim": brim_shell, "open": open_shell,
          "hood": hood_shell, "foot": foot_shell}


def base_colour(item, pct=65.0):
    """Median colour of the lit part of the existing art: the guide's flat tint. `pct` is the
    luminance percentile the lit part starts at (lower = the guide carries more of the art's darkness)."""
    a = np.array(Image.open(original_art(item)).convert("RGBA")).astype(np.float32)
    px = a[a[..., 3] > 200][:, :3]
    lum = px @ np.array([0.299, 0.587, 0.114], np.float32)
    px = px[lum > np.percentile(lum, pct)]
    return np.median(px, 0)


def _markings(clay, geo, mask, nrm, dep, X, Y, st, ct, k):
    """Shell markings drawn into the clay: slits, bars, ridges, openings."""
    kind = geo.get("kind")
    if kind == "torso":
        if geo.get("flange") and geo.get("clip_x"):
            d = geo["clip_x"] - np.abs(X)                      # distance in from the arm-hole edge
            fw = geo["flange"]
            band = mask & (d < fw)
            roll = np.clip(1.0 - np.abs(d / fw - 0.5) * 2.0, 0, 1)      # a rounded roll: brightest mid-band
            clay = np.where(band, clay * (0.95 + 0.30 * roll) + 26 * roll, clay)
            clay = np.where(mask & (np.abs(d - fw) < 0.0045), clay * 0.50, clay)
        if geo.get("rim_steps"):
            unit = float(X[0, 1] - X[0, 0])
            dist, (iy, ix) = ndi.distance_transform_edt(mask, return_indices=True)
            jj, ii = np.indices(mask.shape)
            below = (iy - jj) > 0.8 * np.abs(ix - ii)          # the nearest edge is the lower one
            d = dist * unit
            sw, n = geo["rim_step"], geo["rim_steps"]
            lower = mask & below & (d < sw * n)
            step = np.floor(d / sw)
            frac = d / sw - step
            clay = np.where(lower, clay * (1.10 - 0.05 * step) + 14 * np.clip(1 - np.abs(frac - 0.45) * 2.2, 0, 1), clay)
            clay = np.where(mask & below & (d < sw * n + 0.004) & (frac > 0.82) | (lower & (frac > 0.84)), clay * 0.50, clay)
    elif kind == "bucket":
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
    elif kind in ("brim", "open"):
        if geo.get("ridge"):
            # a raised ridge from front to back over the crown
            Yw = Y * ct + dep * st
            on = mask & (((X - geo["c"][0]) / geo["rx"]) ** 2 + ((Yw - geo["c"][1]) / geo["ry"]) ** 2 < 0.96)
            rid = on & (np.abs(X) < geo["ridge"])
            clay = np.where(rid, clay * 1.10 + 8, clay)
            clay = np.where(on & (np.abs(np.abs(X) - geo["ridge"]) < 0.0035), clay * 0.62, clay)
    elif kind == "hood":
        # the face opening: a dark hollow on the south face of the hood
        Yw = Y * ct + dep * st
        Z = -Y * st + dep * ct
        u = (X / (geo["rx"] * geo["open_w"])) ** 2 + ((Z - (geo["z0"] + 0.46 * (geo["z1"] - geo["z0"]))) /
                                                      (0.36 * (geo["z1"] - geo["z0"]))) ** 2
        op = mask & (Yw > geo["c"][1] + geo["ry"] * 0.30) & (u < 1.0)
        clay = np.where(op, 24 + 20 * np.clip(u, 0, 1) ** 3, clay)
        clay = np.where(mask & (Yw > geo["c"][1] + geo["ry"] * 0.30) & (u >= 1.0) & (u < 1.25), clay * 0.72, clay)
    elif kind == "foot":
        # the cuff's open top is cut out (render_item); here only its rim is drawn
        Yw = Y * ct + dep * st
        Z = -Y * st + dep * ct
        c, r = geo["cuff_c"], geo["cuff_r"]
        d = np.hypot(X - c[0], Yw - c[1]) / r
        top = mask & (np.abs(Z - geo["cuff_z"]) < 0.004) & (nrm[..., 2] > 0.9)
        clay = np.where(top & (d < geo["cuff_open"] + 0.07), clay * 0.6, clay)     # the rim's inner edge
    return clay


def render_item(item, proxy="orc", tilt=None, spec=None):
    """Returns (guide RGB image, mask image, info dict with the item's frames in guide pixels)."""
    spec = spec or load_spec(item)
    tilt = gen_plan.race_tilt(proxy, tilt)
    cam0 = camera(proxy, tilt)
    ct, st = cam0["ct"], cam0["st"]
    sh_ = SHELLS[spec["shell"]](spec, cam0)
    prims, hole, clip_x, geo = sh_["prims"], sh_.get("hole"), sh_.get("clip_x"), sh_.get("geo")
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
    xc = float(sh_.get("xc", 0.0))
    if xc:
        x_lo = min(pr[2][0] - pr[3][0] for pr in prims)
        x_hi = max(pr[2][0] + pr[3][0] for pr in prims)
        xc, xw = (x_lo + x_hi) / 2, x_hi - x_lo
    else:
        xw = 2 * (clip_x if clip_x is not None else max(abs(pr[2][0]) + pr[3][0] for pr in prims))
    px0 = cam0["scale0"] / SS
    zoom = min(0.84 * W / (xw * px0), 0.80 * H / ((max(hi) - min(lo)) * px0), 4.0)
    cam = camera(proxy, tilt, round(zoom, 3), (xc, (min(lo) + max(hi)) / 2))
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
    if geo and geo.get("kind") == "foot":
        # the cuff's open top is ground, keyed out like a collar: the wearer's leg shows through it
        Yw, Zw = Y * ct + dep * st, -Y * st + dep * ct
        c_, r_ = geo["cuff_c"], geo["cuff_r"]
        cut = mask & (np.abs(Zw - geo["cuff_z"]) < 0.004) & (nrm[..., 2] > 0.9) &             (np.hypot(X - c_[0], Yw - c_[1]) < r_ * geo["cuff_open"])
        mask &= ~cut
    hs = np.where(mask, dep, 0).astype(np.float32)
    k = cam["zoom"]
    mf = mask.astype(np.float32)
    sig = sh_.get("sigma", 1.0) * SS * k
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
        clay = _markings(clay, geo, mask, nrm, dep, X, Y, st, ct, k)
    dist_in = ndi.distance_transform_edt(mask)
    outline = np.clip(1.25 - dist_in / (2.0 * SS), 0, 1)
    clay = clay * (1 - 0.75 * outline) + 45 * 0.75 * outline
    base = base_colour(item, float(spec.get("tint_pct", 65.0))) / 205.0
    col = np.clip(base[None, None] * (clay[..., None] * 1.18), 0, 255)
    gname, ground, gwhy = ground_for(spec)
    img = np.where(mask[..., None], col, np.array(ground, np.float32)).astype(np.uint8)
    guide = Image.fromarray(img).resize((W, H), Image.LANCZOS)
    m = Image.fromarray((mask * 255).astype(np.uint8)).resize((W, H), Image.LANCZOS).point(
        lambda v: 255 if v >= 128 else 0)

    pf, body_mask, _, pstats = proxy_frames(proxy, tilt)
    frames = {}
    for name, src in sh_["frames"].items():
        f = dict(pf[src])
        o = guide_to_item(cam, f["o"])
        f["o"] = [round(float(o[0]), 2), round(float(o[1]), 2)]
        for key_ in ("lx", "ly", "ly_neg"):
            if key_ in f:
                f[key_] = round(f[key_] * k, 3)
        frames[name] = f
    info = dict(item=item, proxy=proxy, tilt_deg=tilt, zoom=k, slot=spec["slot"], frames=frames,
                ground=list(ground), px_per_unit=round(scale / SS, 3),
                proxy_head_scale=cam["params"].get("head_scale", 1.0))
    info.update(shell=spec["shell"], build=spec.get("build", "neutral") if spec["shell"] == "torso" else "proxy",
                ground_name=gname, ground_why=gwhy, one_sided=bool(sh_.get("one_sided")))
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


def make_swatch(item, out, spec=None):
    sw = (spec or load_spec(item))["swatch"]
    im = Image.open(original_art(item)).convert("RGBA")
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
    spec = load_spec(item)
    guide, m, info = render_item(item, proxy, tilt, spec)
    guide.save(os.path.join(out, "guide.png"))
    m.save(os.path.join(out, "guide_mask.png"))
    make_swatch(item, out, spec)
    with open(os.path.join(out, "guide.json"), "w") as f:
        json.dump(info, f, indent=1)
    print(json.dumps({k: info[k] for k in info if k not in ("frames",)}))
    return info


def build_prompt(item, tilt, note="", spec=None):
    s = spec or load_spec(item)
    gname, ground, _ = ground_for(s)
    deg = TILT_WORDS.get(int(round(tilt)), "%g" % tilt)
    t = ("Image 1 is a flat-colour 3D block-out of %s, " % s["what"]) + CAMERA % deg + s["reads"]
    t += ("Paint over this exact block-out to make a finished game item: %s. Keep the identical outline, "
          "position, scale and steep overhead viewpoint, tracing the silhouette precisely and keeping "
          "every form where and how large the block-out has it. %s." % (s["look"], s["paint"]))
    t += (FINISH_ONE if s["shell"] == "foot" else FINISH) % ((gname,) + tuple(ground) + (s["hole_words"],))
    t += SWATCH % (s["material"], s["hole_words"])
    for extra in (s.get("note", ""), note):
        if extra:
            t += " " + extra
    return t.replace("{ground}", gname)


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
    # one call log per item, so painters working side by side never write the same file
    log_p = os.path.join(out, "calls.json")
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

EDGE_EAT = 1.0          # px of paint next to the ground that become clear (the key-coloured fringe)
EDGE_FEATHER = 2.0      # px over which the edge then fades in


def _dominance(a, ground):
    """How much a pixel is the key colour: the key's own channel(s) above the others."""
    if ground == "green":
        return a[..., 1] - np.maximum(a[..., 0], a[..., 2])
    if ground == "magenta":
        return np.minimum(a[..., 0], a[..., 2]) - a[..., 1]
    return a[..., 2] - np.maximum(a[..., 0], a[..., 1])


def key(rgb, ground="blue", soft=False):
    """Key-colour dominance key. Returns (paint float RGB with the ground replaced by bled paint,
    alpha float 0..1).

    soft=False  the pilot's edge: a one-pixel rim whose alpha is estimated pixel by pixel (gen_hands).
    soft=True   every edge, the collar hole's included, is redrawn: the ground's outline is smoothed,
                the first EDGE_EAT px of paint beside it are cleared (that is where the key colour
                bleeds into the painting), alpha then fades in over EDGE_FEATHER px, and the faded
                band takes its colour from clean paint further in. No jagged or key-tinted fringe."""
    a = rgb.astype(np.float32)
    dom = _dominance(a, ground)
    k = 24
    corners = np.concatenate([a[:k, :k].reshape(-1, 3), a[:k, -k:].reshape(-1, 3),
                              a[-k:, :k].reshape(-1, 3), a[-k:, -k:].reshape(-1, 3)])
    bg = np.median(corners, 0)
    bdom = float(_dominance(bg, ground))
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
    if soft:
        gnd = ndi.gaussian_filter((~fg).astype(np.float32), 1.6) > 0.5
        d = ndi.distance_transform_edt(~gnd)
        t = np.clip((d - EDGE_EAT) / EDGE_FEATHER, 0.0, 1.0)
        alpha = np.where(gnd, 0.0, t * t * (3.0 - 2.0 * t)).astype(np.float32)
        clean = fg & (d >= EDGE_EAT + EDGE_FEATHER + 1.0)
        _, (iy, ix) = ndi.distance_transform_edt(~clean, return_indices=True)
        bled = a[iy, ix]
        smooth = np.stack([ndi.gaussian_filter(bled[..., c], 1.0) for c in range(3)], -1)
        return np.where(clean[:, :, None], a, smooth), alpha
    core_m = ndi.binary_erosion(fg, iterations=2)
    _, (iy, ix) = ndi.distance_transform_edt(~core_m, return_indices=True)
    F = a[iy, ix]
    rim = ndi.binary_dilation(fg, iterations=1) & ~core_m
    num = ((a - bg) * (F - bg)).sum(-1)
    den = np.maximum(((F - bg) ** 2).sum(-1), 1.0)
    alpha = np.where(core_m, 1.0, 0.0).astype(np.float32)
    alpha[rim] = np.clip(num[rim] / den[rim], 0.0, 1.0)
    return np.where(core_m[:, :, None], a, F), alpha


def tone_match(paint, alpha, ref_px, strength):
    """Pull the painting's colour toward the original's: per Lab channel, move the mean and the
    spread of the opaque paint toward those of `ref_px` (the swatch of the original art), by
    `strength` (0 = leave, 1 = match). Returns the new paint and what was done."""
    if strength <= 0:
        return paint, None
    lab = cv2.cvtColor(np.ascontiguousarray(np.clip(paint, 0, 255).astype(np.uint8)), cv2.COLOR_RGB2LAB).astype(np.float32)
    ref = cv2.cvtColor(np.clip(ref_px, 0, 255).astype(np.uint8)[None], cv2.COLOR_RGB2LAB)[0].astype(np.float32)
    sel = alpha > 0.9
    out = lab.copy()
    rep = {}
    for c, name in enumerate("Lab"):
        m0, s0 = float(lab[sel][:, c].mean()), float(lab[sel][:, c].std())
        m1, s1 = float(ref[:, c].mean()), float(ref[:, c].std())
        g = float(np.clip(s1 / max(s0, 1e-3), 0.6, 1.6))
        g = 1.0 + (g - 1.0) * strength
        out[..., c] = (lab[..., c] - m0) * g + m0 + (m1 - m0) * strength
        rep[name] = [round(m0, 1), round(m1, 1)]
    rgb = cv2.cvtColor(np.clip(out, 0, 255).astype(np.uint8), cv2.COLOR_LAB2RGB).astype(np.float32)
    return rgb, rep


def measure(path, gmask, info):
    rgb = np.asarray(Image.open(path).convert("RGB"))
    _, alpha = key(rgb, info.get("ground_name", "blue"), soft=True)
    sil = alpha >= 0.5
    r = dict(name=os.path.basename(path),
             iou=round(float((sil & gmask).sum()) / float((sil | gmask).sum()), 4))
    ys, xs = np.nonzero(sil)
    gy, gx = np.nonzero(gmask)
    r["bbox_dx_dy_dw_dh"] = [int(xs.min() - gx.min()), int(ys.min() - gy.min()),
                             int((xs.max() - xs.min()) - (gx.max() - gx.min())),
                             int((ys.max() - ys.min()) - (gy.max() - gy.min()))]
    if not info.get("one_sided"):
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
    paths = tag_paths(item, tag)
    if not paths:
        raise SystemExit("no paintings %s_<n>.png in %s" % (tag, os.path.relpath(out, core.ROOT)))
    rows = [measure(p, gmask, info) for p in paths]
    for r in rows:
        print(json.dumps(r))
    with open(os.path.join(out, tag + "_check.json"), "w") as f:
        json.dump(rows, f, indent=1)
    # contact sheet: guide + swatch + candidates, half size
    sw = Image.open(os.path.join(out, tag + ".in2_swatch.png")).convert("RGB")
    ims = [Image.open(os.path.join(out, tag + ".in1_guide.png"))] + [Image.open(p) for p in paths]
    tw, th = W // 2, H // 2
    cols = 2
    sheet = Image.new("RGB", (tw * cols, th * ((len(ims) + 1) // cols)), (20, 20, 20))
    for i, im in enumerate(ims):
        sheet.paste(im.convert("RGB").resize((tw, th), Image.LANCZOS), ((i % cols) * tw, (i // cols) * th))
        ImageDraw.Draw(sheet).text(((i % cols) * tw + 6, (i // cols) * th + 6),
                                   "guide" if i == 0 else rows[i - 1]["name"] + "  IoU %.3f" % rows[i - 1]["iou"],
                                   fill=(255, 255, 255))
    if info.get("ground_name"):                     # sheets made before the swatch inset stay as they were
        sw.thumbnail((150, 150))
        sheet.paste(sw, (tw - sw.width - 6, 6))
    sheet.save(os.path.join(out, tag + "_sheet.jpg"), quality=90)
    return rows


def install(item, painting, new_id=None, ease=1.0):
    """Key the painting, crop it, and ingest it as an item pack with the guide's proxy frames."""
    new_id = new_id or item + "_td"
    out = item_out(item)
    spec = load_spec(item)
    tag = os.path.basename(painting).rsplit("_", 1)[0]
    info = json.load(open(os.path.join(out, tag + ".guide.json")))
    gmask = np.array(Image.open(os.path.join(out, tag + ".guide_mask.png"))) > 127
    rgb = np.asarray(Image.open(painting).convert("RGB"))
    paint, alpha = key(rgb, info.get("ground_name", "blue"), soft=True)
    tm = None
    if float(spec.get("tone_match", 0.0)) > 0:
        paint, tm = tone_match(paint, alpha, swatch_pixels(spec), float(spec["tone_match"]))
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
    if spec.get("encloses"):
        meta["encloses"] = True
    if tm:
        meta["tone_match"] = {"strength": float(spec["tone_match"]), "lab_mean_from_to": tm}
    if spec["slot"] == "feet":
        meta["authored_side"] = "l"
    d = ingest.ingest(new_id, tmp, spec["slot"], frames=frames, sleeve=spec.get("sleeve"),
                      layer=spec.get("layer"), ease=ease, meta=meta)
    os.remove(tmp)
    print("wrote Rigs/items/%s  frames: %s  %s" % (new_id, ", ".join(d["frames"]), json.dumps(m)))
    return d


def promote(item, new_id=None):
    """Make the repaint the pack for the ORIGINAL id: Rigs/items/<item>/ gets the _td art, frames
    and mesh and keeps its own id, layer and `item_ids` game mapping. The old art is filed as
    out/items_td/<item>/original.png (the swatch source); the _td pack is deleted. Run a Godot
    --import afterwards."""
    import shutil
    new_id = new_id or item + "_td"
    src, dst = os.path.join(core.RIGS, "items", new_id), os.path.join(core.RIGS, "items", item)
    if not os.path.exists(os.path.join(src, "item.json")):
        raise SystemExit("no pack Rigs/items/%s to promote" % new_id)
    old, new = core.load_json(os.path.join(dst, "item.json")), core.load_json(os.path.join(src, "item.json"))
    if old.get("camera") == new.get("camera"):
        raise SystemExit("%s is already a %s pack" % (item, new.get("camera")))
    if old["slot"] != new["slot"] or set(old["frames"]) != set(new["frames"]):
        raise SystemExit("%s and %s differ in slot or frames; promote by hand" % (item, new_id))
    kept = os.path.join(item_out(item), "original.png")
    if not os.path.exists(kept):
        shutil.copyfile(os.path.join(dst, old["art"]), kept)
    new["id"] = item
    for k in ("layer", "item_ids"):
        if k in old:
            new[k] = old[k]
    out = {}
    for k in new:                      # item_ids next to the other identity keys, mesh last
        if k == "frames" and "item_ids" in new:
            out["item_ids"] = new["item_ids"]
        if k != "item_ids":
            out[k] = new[k]
    shutil.copyfile(os.path.join(src, new["art"]), os.path.join(dst, "art.png"))
    core.save_json(os.path.join(dst, "item.json"), out)
    shutil.rmtree(src)
    print("promoted %s -> Rigs/items/%s (old art kept as %s)" % (new_id, item, os.path.relpath(kept, core.ROOT)))


# ---------------------------------------------------------------- compare

PILOT = ["peasants_stained_shirt", "breastplate", "great_helm"]
RACES = [("orc", "default"), ("orc", "legacy"), ("human", "default"), ("goblin_male", "default"), ("goblin_male", "legacy"),
         ("halfling_male", "default")]
SHEET_RACES = [("orc", "default"), ("human", "default"), ("halfling_male", "default"), ("orc", "legacy"),
               ("goblin_male", "default")]
ITEM_SHEET_RACES = [("orc", "default"), ("orc", "legacy"), ("human", "default"), ("halfling_male", "default"),
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


def _tile(img, box, tile, bg):
    """Crop `box` (x0, y0, x1, y1, may run off the image) out of an RGB(A) array and scale it to `tile`."""
    x0, y0, x1, y1 = [int(round(v)) for v in box]
    pad = max(0, -x0, -y0, x1 - img.shape[1], y1 - img.shape[0])
    big = np.zeros((img.shape[0] + 2 * pad, img.shape[1] + 2 * pad, 3), np.uint8)
    big[:] = bg
    big[pad:pad + img.shape[0], pad:pad + img.shape[1]] = img[:, :, :3]
    crop = big[y0 + pad:y1 + pad, x0 + pad:x1 + pad]
    interp = cv2.INTER_AREA if crop.shape[1] > tile[0] else cv2.INTER_CUBIC
    return Image.fromarray(cv2.resize(crop, tile, interpolation=interp))


def _body_box(canvas, tile, feet=False):
    """The trunk and head of a composed race, at least 2.9 half-shoulders wide, at the tile's aspect."""
    f = canvas.data["frames"]
    t = f["torso"]
    half_w = t["lx"] * 2.9
    cx = t["o"][0] + canvas.pad
    y_top = min(f["head_full"]["o"][1] - f["head_full"]["ly"], t["o"][1] - t.get("ly_neg", t["ly"])) + canvas.pad
    y_bot = t["o"][1] + t["ly"] + canvas.pad
    if feet:
        for s in "lr":
            if "foot_" + s in f:
                y_bot = max(y_bot, f["foot_" + s]["o"][1] + f["foot_" + s]["lx"] + canvas.pad)
    cy = (y_top + y_bot) / 2.0
    half_h = max(half_w * tile[1] / tile[0], (y_bot - y_top) / 2.0 * 1.12)
    half_w = half_h * tile[0] / tile[1]
    return cx - half_w, cy - half_h, cx + half_w, cy + half_h


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
            sheet.paste(_tile(img, _body_box(canvas, tile), tile, BG), (side + j * tile[0], head + i * tile[1]))
    for j in range(1, len(races)):
        dr.line([(side + j * tile[0], 0), (side + j * tile[0], sheet.height)], fill=(30, 32, 30), width=2)
    for i in range(1, len(cols)):
        dr.line([(0, head + i * tile[1]), (sheet.width, head + i * tile[1])], fill=(30, 32, 30),
                width=6 if i % 2 == 0 else 2)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    sheet.save(out_path, quality=90)
    return out_path


def item_sheet(item, new_id=None, races=ITEM_SHEET_RACES, tile=(520, 330)):
    """tools/rigkit/out/items_td/<item>/compare.jpg: the original pack against the _td pack, each
    worn alone by five race packs. Top two rows: the whole trunk, head and feet. Bottom two rows: a
    zoomed crop on the item. A missing _td pack leaves its rows empty."""
    from .render import compose
    from .sheet import BG
    skel = core.skeleton()
    new_id = new_id or item + "_td"
    races = _present(races)
    ids = [item, new_id]
    have = [os.path.exists(os.path.join(core.RIGS, "items", i, "item.json")) for i in ids]
    side, head = 150, 26
    rows = [(0, False), (1, False), (0, True), (1, True)]
    sheet = Image.new("RGB", (side + tile[0] * len(races), head + tile[1] * len(rows)), (30, 32, 30))
    dr = ImageDraw.Draw(sheet)
    for j, (race, variant) in enumerate(races):
        dr.text((side + j * tile[0] + 6, 7), "%s/%s" % (race, variant), fill=(230, 230, 220))
    cache = {}
    for i, (which, zoomed) in enumerate(rows):
        y = head + i * tile[1]
        dr.text((6, y + 8), ("NEW (tilt15)" if which else "ORIGINAL") + ("  zoom" if zoomed else ""),
                fill=(255, 220, 140) if which else (200, 200, 190))
        dr.text((6, y + 24), ids[which] if have[which] else ids[which] + "\n(not installed)", fill=(200, 200, 190))
        if not have[which]:
            continue
        for j, (race, variant) in enumerate(races):
            if (which, j) not in cache:
                cache[(which, j)] = compose(race, [ids[which]], variant, skel, background=BG)
            img, alphas, canvas = cache[(which, j)]
            if canvas.skipped:
                dr.text((side + j * tile[0] + 8, y + 8), "cannot wear: race has no %s" % ", ".join(canvas.skipped[0][1]),
                        fill=(240, 150, 120))
                continue
            box = _body_box(canvas, tile, feet=True)
            if zoomed:
                # the union of both packs' pixels on this race, so the two zoom rows share one frame
                m = np.zeros(canvas.size, bool)
                for w2 in (0, 1):
                    if have[w2]:
                        if (w2, j) not in cache:
                            cache[(w2, j)] = compose(race, [ids[w2]], variant, skel, background=BG)
                        for _, a in cache[(w2, j)][1].get(ids[w2], []):
                            m |= a
                ys, xs = np.nonzero(m)
                if len(xs):
                    cx, cy = (xs.min() + xs.max()) / 2.0, (ys.min() + ys.max()) / 2.0
                    hw = max((xs.max() - xs.min()) / 2.0 * 1.25, (ys.max() - ys.min()) / 2.0 * 1.25 * tile[0] / tile[1], 12)
                    box = (cx - hw, cy - hw * tile[1] / tile[0], cx + hw, cy + hw * tile[1] / tile[0])
            sheet.paste(_tile(img, box, tile, BG), (side + j * tile[0], y))
    for j in range(1, len(races)):
        dr.line([(side + j * tile[0], 0), (side + j * tile[0], sheet.height)], fill=(30, 32, 30), width=2)
    for i in range(1, len(rows)):
        dr.line([(0, head + i * tile[1]), (sheet.width, head + i * tile[1])], fill=(30, 32, 30), width=6 if i == 2 else 2)
    out_path = os.path.join(item_out(item), "compare.jpg")
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
    for name in ("guide", "gen", "check", "install", "sheet", "prompt", "promote"):
        s = sub.add_parser(name)
        s.add_argument("item", choices=list_specs())
        if name in ("guide", "gen"):
            s.add_argument("--proxy", default="orc")
            s.add_argument("--tilt", type=float, default=None)
        if name == "gen":
            s.add_argument("--n", type=int, default=4)
            s.add_argument("--tag", default="r1")
            s.add_argument("--note", default="")
        if name == "check":
            s.add_argument("tag_pos", nargs="?", default=None, metavar="tag")
            s.add_argument("--tag", default="r1")
        if name == "install":
            s.add_argument("painting")
            s.add_argument("--id", default=None)
            s.add_argument("--ease", type=float, default=1.0)
        if name in ("sheet", "promote"):
            s.add_argument("--id", default=None)
    sub.add_parser("list")
    c = sub.add_parser("compare")
    c.add_argument("--out", default=OUT)
    a = ap.parse_args(argv)
    if a.cmd == "list":
        for i in list_specs():
            s = load_spec(i)
            print("%-24s %-7s %-6s ground=%s" % (i, s["shell"], s["slot"], ground_for(s)[0]))
    elif a.cmd == "guide":
        save_guide(a.item, a.proxy, a.tilt)
    elif a.cmd == "prompt":
        print(build_prompt(a.item, gen_plan.race_tilt("orc", None)))
    elif a.cmd == "gen":
        gen(a.item, a.n, a.tag, a.proxy, a.tilt, a.note)
        check(a.item, a.tag)
    elif a.cmd == "check":
        check(a.item, a.tag_pos or a.tag)
    elif a.cmd == "install":
        install(a.item, a.painting, a.id, a.ease)
    elif a.cmd == "promote":
        promote(a.item, a.id)
    elif a.cmd == "sheet":
        print("wrote", item_sheet(a.item, a.id))
    else:
        compare(a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
