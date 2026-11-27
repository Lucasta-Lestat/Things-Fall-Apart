"""Repaint a race at the TRUE top-down (plan view) camera, by painting over a rendered guide.

    python -m tools.rigkit.gen_plan guide [--race orc]
    python -m tools.rigkit.gen_plan gen   [--race orc] [--n 4] [--tag final] [--guide tint|clay] [--no-swatch]
    python -m tools.rigkit.gen_plan check [--race orc] [--tag final | image.png ...]
    python -m tools.rigkit.gen_plan dome  [--race orc] [--tag final | image.png ...]

guide   renders the race's proxy figure from RACES[race] with an orthographic camera
        straight above it and writes, to tools/rigkit/out/plan/<race>/:
            guide_clay.png    grey clay render (near-vertical light, crown highlight)
            guide_tint.png    the same render multiplied by the race's skin colour
            guide_mask.png    silhouette
            guide_labels.png  per-part label map in derive.PALETTE colours on black,
                              ready to be a pack's labels.png for `build_race`
            guide.json        measurements + the frames derive.py reads from the labels
            swatch.png        small upper-arm skin patch cut from the race's current painting
gen     asks Gemini (gemini-3-pro-image, 16:9) to paint over the guide, N times with the
        SAME prompt and inputs. Each candidate <tag>_<i>.png gets a <tag>_<i>.json
        (prompt, inputs, model); the prompt and a snapshot of the inputs are saved once
        per tag as <tag>.prompt.txt, <tag>.in1_guide.png, <tag>.in2_swatch.png.
check   per candidate: grey-keys the painting, then reports silhouette IoU against the
        guide mask, depth/span, a left-right symmetry score and how flat the grey ground
        is; writes <name>_iou.png overlays, <tag>_check.json and <tag>_heads.png, a zoomed
        head-crop contact sheet. IoU cannot see a painted-on face, so the gate also has a head
        test (head_metrics: dark strokes on the dome, dark / ivory in the band south of its rim,
        highlight offset). It is calibrated on about 20 orc images only: still LOOK at the head sheet.

dome    optional deterministic fix-up, writes <name>_dome.png and checks it: the south half of
        the skull circle is re-laid from the radial colour profile of its own north half, which
        the model always paints as clean scalp. Pixels outside the guide skull circle are kept.

The proxy is analytic primitives (ellipsoids, tapered capsules) in a world where
x = west-east, y = north-south (south = +, the figure faces south = image bottom),
z = height, and the fingertip-to-fingertip half span is 1.0. The image is the per-pixel
MAX height, so the same pass yields the silhouette and the label map.

A new race is a new RACES entry (proportions, colours, words), not new code.

What the recipe encodes (docs/rigging_rewrite.md, "Pilot 2"):
  * the guide gives the camera; the prompt never has to ask for it;
  * the skull is a plain round dome centred on the shoulder axis with only tiny
    nose-tip / tusk-tip bumps on its south rim, and the prompt names no other part of
    the face, because the model paints a face wherever the guide leaves room for one;
    on the orc even a nose nub between the tusks was painted as a brow or muzzle (11 of 13
    images), while tusks alone gave a clean dome (8 of 8), so the orc has nose=(0, 0);
  * toes are shaped in the guide (short separate toe ends); the prompt only says what
    the nubs are, because naming a feature grows it;
  * the tinted guide + a small upper-arm swatch carry the house style without carrying
    the old painting's camera.
Prompts are phrased positively only. `gen` needs GEMINI_API_KEY.
"""
import argparse
import glob
import io
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

from .derive import PALETTE, LabelError, derive_frames

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(HERE, "out", "plan")
W, H = 1376, 768            # what gemini-3-pro-image returns at 16:9
SS = 2
BG = 128
FACE_DARK_MAX, MUZZLE_DARK_MAX, HL_OFFSET_MAX = 0.004, 0.06, 0.35   # head gate; see head_metrics

# part -> derive.PALETTE name. derive's _l/_r are IMAGE left/right.
PARTS = ["background", "body", "face", "upperarm_l", "upperarm_r", "forearm_l", "forearm_r",
         "hand_l", "hand_r", "foot_l", "foot_r"]
PART_RGB = [(0, 0, 0)] + [PALETTE[n] for n in PARTS[1:]]

# ---------------------------------------------------------------- races
# Proportions in half-span units. "look" is the positive description of the character;
# "head_extras" says what sits on the skull's rim (only things that jut past the skull).
RACES = {
    "orc": dict(
        shoulder_half=0.30, delt_r=0.105,
        trunk_depth_n=0.165,            # upper back, north of the shoulder line
        chest_depth_s=0.212,            # pec shelf, south of the shoulder line
        belly_depth_s=0.190, belly_half=0.20, pec_half=0.128,
        skull_r=0.108, skull_y=0.004,   # round dome, centred on the shoulder axis
        nose=(0.0, 0.0), tusk=0.025, tusk_x=0.052, ear_len=0.062,
        upper_arm_r=(0.088, 0.072), forearm_r=(0.080, 0.053),
        elbow_x=0.585, wrist_x=0.805,
        palm_rx=0.070, palm_ry=0.064, finger_r=0.0145,
        foot_x=0.128, toe_y=0.238, toe_r=0.023,
        skin=(118, 136, 70), ivory=(236, 226, 196),
        swatch=dict(src="Rigs/races/orc/default/body.png", box=(630, 20, 810, 170)),
        look="an orc with olive-green skin, a bald scalp, pointed ears, heavy muscles and ivory tusk tips",
        head_extras="Two small ivory tusk points touch the outside of the dome's lower rim, set well apart, "
                    "each one a separate little cone lying on plain smooth chest skin. A pointed ear sticks "
                    "out sideways from each side of the dome.",
        skin_words="fresh saturated olive-green hue, its lighter yellow-green highlights",
        line_words="heavy, crisp, near-black green contour line",
    ),
    "human": dict(
        shoulder_half=0.25, delt_r=0.08, trunk_depth_n=0.125, chest_depth_s=0.13,
        belly_depth_s=0.120, belly_half=0.17, pec_half=0.11,
        skull_r=0.090, skull_y=0.004,
        nose=(0.011, 0.009), tusk=0.0, tusk_x=0.0, ear_len=0.0,
        upper_arm_r=(0.062, 0.052), forearm_r=(0.052, 0.036),
        elbow_x=0.57, wrist_x=0.83,
        palm_rx=0.055, palm_ry=0.048, finger_r=0.010,
        foot_x=0.085, toe_y=0.180, toe_r=0.012,
        skin=(214, 160, 120), ivory=(236, 226, 196),
        swatch=dict(src="Rigs/races/human/default/body.png", box=(700, 100, 800, 150)),
        look="a human man with light tan skin, short brown hair and an athletic build",
        head_extras="At the middle of the dome's lower rim a small rounded nose tip pokes out.",
        skin_words="warm skin hue, its lighter highlights",
        line_words="heavy, crisp, dark brown contour line",
    ),
    # Guide only so far (never painted). Small and slim with a big head: the hair cap is wider than the
    # trunk is deep, so the dome overhangs the back, and the round belly juts further south than the chest.
    "halfling": dict(
        shoulder_half=0.27, delt_r=0.075, trunk_depth_n=0.115, chest_depth_s=0.170,
        belly_depth_s=0.215, belly_half=0.20, pec_half=0.115,
        skull_r=0.185, skull_y=0.006,
        nose=(0.012, 0.009), tusk=0.0, tusk_x=0.0, ear_len=0.0,
        upper_arm_r=(0.062, 0.050), forearm_r=(0.050, 0.036),
        elbow_x=0.56, wrist_x=0.82,
        palm_rx=0.058, palm_ry=0.052, finger_r=0.011,
        foot_x=0.105, toe_y=0.228, toe_r=0.020,
        skin=(206, 152, 122), ivory=(236, 226, 196), hair=(150, 108, 62),
        swatch=dict(src="Rigs/races/halfling_male/default/body.png", box=(170, 150, 300, 260)),
        look="a halfling man with warm light skin, a soft slim build and a big head of thick wavy "
             "light-brown hair",
        dome="cap of thick wavy hair", dome_cover="hair",
        head_extras="At the middle of the dome's lower rim a small rounded nose tip touches the rim, lying "
                    "on plain smooth chest skin.",
        skin_words="warm peach skin hue, its lighter highlights",
        line_words="heavy, crisp, dark red-brown contour line",
    ),
}


def primitives(p):
    """List of (part, kind, params). part may carry a ':tag' suffix (tusk, crown)."""
    P = []
    sh = p["shoulder_half"]
    zs = 1.56  # shoulder / arm axis height

    def ell(part, c, r):
        P.append((part, "ell", (c, r)))

    def cap(part, a, b, ra, rb, z, kz=1.0):
        P.append((part, "cap", (a, b, ra, rb, z, kz)))

    # ---- trunk: a level shoulder band, with the chest as a lower shelf south of it
    n, cs, bs = p["trunk_depth_n"], p["chest_depth_s"], p["belly_depth_s"]
    ell("body", (0, 0.0, 1.32), (sh + 0.01, 0.15, 0.28))                      # rib cage
    ell("body", (0, -(n - 0.115), 1.40), (sh + 0.02, 0.115, 0.20))            # upper back / lats
    cap("body", (-sh, -0.01), (sh, -0.01), 0.10, 0.10, 1.465, 1.15)           # shoulder girdle, easing into the chest
    ell("body", (0, -0.035, 1.52), (0.20, 0.11, 0.09))                        # traps / neck root, a low swell
    for s in (-1, 1):
        ell("body", (s * (sh + 0.045), 0.0, 1.56), (p["delt_r"], p["delt_r"] + 0.005, 0.10))  # deltoid
        # pec shelf: two lobes that meet at the sternum without crossing (crossing lobes read as a hunch)
        ell("body", (s * p["pec_half"], cs - 0.085, 1.36), (p["pec_half"], 0.085, 0.10))
    ell("body", (0, cs - 0.105, 1.35), (p["pec_half"] * 0.75, 0.085, 0.10))    # sternum: shallow cleft only
    ell("body", (0, bs - 0.13, 1.08), (p["belly_half"], 0.13, 0.25))          # belly, lower still

    # ---- head: a plain round dome on the shoulder axis; only tips jut past its south rim
    r, hy = p["skull_r"], p["skull_y"]
    ell("face:skull", (0, hy, 1.86), (r, r, 0.15))
    nx, ny = p["nose"]
    if nx > 0:                                  # (0, 0): the nose stays inside the skull's outline
        ell("face", (0, hy + r + ny * 0.45, 1.72), (nx, ny, 0.03))            # nose tip
    if p["tusk"] > 0:
        for s in (-1, 1):
            tx = p["tusk_x"]
            y0 = hy + (r * r - tx * tx) ** 0.5 - 0.008
            cap("face:tusk", (s * tx, y0), (s * (tx + 0.003), y0 + p["tusk"]), 0.011, 0.002, 1.70, 0.5)
    if p["ear_len"] > 0:
        for s in (-1, 1):
            cap("face", (s * r * 0.92, hy + 0.012), (s * (r + p["ear_len"]), hy - 0.030), 0.024, 0.004, 1.78, 0.6)

    # ---- arms: dead-level bars at shoulder height; hands flat with spread fingers
    ex, wx = p["elbow_x"], p["wrist_x"]
    ua, fa = p["upper_arm_r"], p["forearm_r"]
    for s, side in ((-1, "l"), (1, "r")):                                     # image left / right
        cap("upperarm_" + side, (s * (sh + 0.05), 0), (s * ex, 0), ua[0], ua[1], zs)
        cap("forearm_" + side, (s * ex, 0), (s * wx, 0), fa[0], fa[1], zs - 0.01)
        hx = wx + p["palm_rx"] * 0.85
        hand = "hand_" + side
        ell(hand, (s * hx, 0, zs - 0.02), (p["palm_rx"], p["palm_ry"], 0.022))
        fr = p["finger_r"]
        tips = (0.962, 0.990, 1.0, 0.980)                                     # little .. index, north to south
        for i, tip in enumerate(tips):
            y0 = (i - 1.5) * fr * 2.25
            y1 = (i - 1.5) * fr * 3.1
            base = hx + p["palm_rx"] * 0.35
            cap(hand, (s * base, y0), (s * tip, y1), fr * 1.1, fr * 0.80, zs - 0.03, 0.8)
            ell(hand, (s * (base + 0.012), y0 * 1.05, zs - 0.012), (fr * 1.05, fr * 1.0, 0.012))   # knuckle
        cap(hand, (s * (hx - 0.03), p["palm_ry"] * 0.6), (s * (hx + 0.028), p["palm_ry"] + 0.036),
            fr * 1.25, fr * 0.95, zs - 0.035, 0.8)                            # thumb, toward south

        # ---- feet: only short separate toe ends peek out south of the belly
        fx, ty, tr = p["foot_x"], p["toe_y"], p["toe_r"]
        foot = "foot_" + side
        # Each toe is a peg that starts hidden under the chest and ends in a short rounded tip, so
        # only the tips show, with grey ground between neighbours. Big toe is the inner one.
        for i, (k, back) in enumerate(((1.0, 0.30), (0.84, 0.15), (0.78, 0.15), (0.72, 0.35), (0.66, 0.70))):
            tx = fx - tr * 3.4 + i * tr * 1.7
            rad = tr * k * 0.64
            cap(foot, (s * tx, ty - 0.075), (s * tx, ty - back * tr - rad), rad, rad, 0.05, 0.6)
    return P


def render(race="orc", w=W, h=H, ss=SS, margin=0.035):
    """Returns (clay, tint, mask, label_idx, stats)."""
    p = RACES[race]
    ww, hh = w * ss, h * ss
    scale = ww * (0.5 - margin)                 # px per unit; fingertips land `margin` from each edge
    prims = primitives(p)
    y_n = -(p["trunk_depth_n"]) - 0.01
    y_s = max(p["toe_y"], p["belly_depth_s"])
    yc = (y_n + y_s) / 2                        # centre the north-south extent on the canvas
    xs = (np.arange(ww) + 0.5 - ww / 2) / scale
    ys = (np.arange(hh) + 0.5 - hh / 2) / scale + yc
    X, Y = np.meshgrid(xs, ys)
    height = np.full((hh, ww), -1.0, np.float32)
    label = np.zeros((hh, ww), np.uint8)
    tusk = np.zeros((hh, ww), bool)
    skull = np.zeros((hh, ww), bool)
    for name, kind, prm in prims:
        if kind == "ell":
            (cx, cy, cz), (rx, ry, rz) = prm
            q = 1 - ((X - cx) / rx) ** 2 - ((Y - cy) / ry) ** 2
            z = np.where(q > 0, cz + rz * np.sqrt(np.clip(q, 0, None)), -1)
        else:
            (ax, ay), (bx, by), ra, rb, cz, kz = prm
            dx, dy = bx - ax, by - ay
            t = np.clip(((X - ax) * dx + (Y - ay) * dy) / (dx * dx + dy * dy), 0, 1)
            rr = ra + (rb - ra) * t
            d2 = (X - (ax + t * dx)) ** 2 + (Y - (ay + t * dy)) ** 2
            q = rr * rr - d2
            z = np.where(q > 0, cz + kz * np.sqrt(np.clip(q, 0, None)), -1)
        win = z > height
        height[win] = z[win]
        label[win] = PARTS.index(name.split(":")[0])
        tusk[win] = name.endswith(":tusk")
        skull[win] = name.endswith(":skull")
    mask = height > -0.5

    # clay shading from the height-map normal, light almost straight down
    hs = np.where(mask, height, 0).astype(np.float32)
    hsm = ndi.gaussian_filter(hs, 1.5 * ss)
    gy, gx = np.gradient(hsm * scale * 0.55)    # 0.55: flatten relief a little so cliffs do not go black
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    L = np.array([-0.04, -0.08, 0.995]); L /= np.linalg.norm(L)
    lam = np.clip(nrm @ L, 0, 1)
    ao = np.clip((ndi.gaussian_filter(hs, 14 * ss) - hs) * 1.6, 0, 0.45)       # pits and low parts darker
    r, hy = p["skull_r"], p["skull_y"]
    rho = np.hypot(X, Y - hy) / r
    near = np.clip((rho - 1.0) / 0.9, 0, 1)     # 0 at the skull rim .. 1 from 1.9 r out
    ao *= near                                   # no dark crescent under the dome: it gets painted as a muzzle
    depth = 0.80 + 0.20 * np.clip(hs / 1.9, 0, 1)
    shade = (0.30 + 0.70 * lam) * depth * (1 - ao)
    # the block-out head recipe: explicit sphere shading on the skull, crown highlight dead centre
    sphere = np.sqrt(np.clip(1 - (rho * 0.93) ** 2, 0, 1))
    crown = np.exp(-(rho / 0.22) ** 2)          # tight bright spot at the dead centre
    shade = np.where(skull, (0.34 + 0.66 * sphere) * 0.95 + 0.26 * crown, shade)
    clay = 205 * shade
    # crease lines where one part overlaps another (depth discontinuity)
    edge = np.hypot(*np.gradient(ndi.gaussian_filter(hs, 0.8 * ss))) * scale
    crease = np.clip((edge - 1.6) / 3.0, 0, 1) * 0.35
    crease *= np.where(skull, 1.0, 0.35 + 0.65 * np.clip((rho - 1.0) / 0.45, 0, 1))   # nose / tusk tips: soft, fused to the rim
    clay *= (1 - crease)
    rim = np.exp(-(((rho - 1.0) * r * scale) / (1.6 * ss)) ** 2) * mask             # the skull's rim: one hard, strict circle
    clay = clay * (1 - 0.8 * rim) + 40 * 0.8 * rim
    dist_in = ndi.distance_transform_edt(mask)
    outline = np.clip(1.25 - dist_in / (2.4 * ss), 0, 1)   # a bold contour: the painting keeps its weight
    clay = clay * (1 - 0.75 * outline) + 45 * 0.75 * outline
    grey = np.clip(np.where(mask, clay, BG), 0, 255)
    clay_im = Image.fromarray(np.repeat(grey[..., None], 3, -1).astype(np.uint8)).resize((w, h), Image.LANCZOS)
    skin = np.array(p["skin"], np.float32) / 205.0
    ivory = np.array(p["ivory"], np.float32) / 205.0
    base = np.where(skull[..., None], np.array(p.get("hair", p["skin"]), np.float32) / 205.0, skin)
    col = np.where(tusk[..., None], ivory * 205 * 0.8 + 0.2 * clay[..., None], base * (clay[..., None] * 1.25))
    tinted = np.where(mask[..., None], np.clip(col, 0, 255), BG).astype(np.uint8)
    tint_im = Image.fromarray(tinted).resize((w, h), Image.LANCZOS)

    m = Image.fromarray((mask * 255).astype(np.uint8)).resize((w, h), Image.LANCZOS).point(lambda v: 255 if v >= 128 else 0)
    mnp = np.array(m) > 0
    lab = np.array(Image.fromarray(label).resize((w, h), Image.NEAREST)) * mnp
    holes = mnp & (lab == 0)                    # make labels and mask agree exactly after resampling
    if holes.any():
        idx = ndi.distance_transform_edt(lab == 0, return_distances=False, return_indices=True)
        lab = lab[tuple(idx)] * mnp
    ys_, xs_ = np.nonzero(mnp)
    px = scale / ss
    stats = dict(race=race, canvas=[w, h], px_per_unit=round(px, 3),
                 bbox=[int(xs_.min()), int(ys_.min()), int(xs_.max()), int(ys_.max())],
                 span_px=int(xs_.max() - xs_.min() + 1), depth_px=int(ys_.max() - ys_.min() + 1),
                 shoulder_line_y=round(h / 2 - yc * px, 2),
                 skull_centre=[round(w / 2, 2), round(h / 2 + (hy - yc) * px, 2)], skull_r_px=round(r * px, 2))
    stats["depth_over_span"] = round(stats["depth_px"] / stats["span_px"], 4)
    stats["label_colours"] = {n: list(c) for n, c in zip(PARTS, PART_RGB)}
    stats["note"] = "figure faces south (image bottom); _l/_r are IMAGE left/right, as derive.py expects"
    return clay_im, tint_im, m, lab.astype(np.uint8), stats


def race_out(race):
    d = os.path.join(OUT, race)
    os.makedirs(d, exist_ok=True)
    return d


def make_swatch(race, out):
    """A tight patch of the current painting's upper arm: colour and line only, no camera cue."""
    sw = RACES[race]["swatch"]
    im = Image.open(os.path.join(ROOT, sw["src"])).convert("RGBA")
    bg = Image.new("RGBA", im.size, (BG, BG, BG, 255))
    bg.alpha_composite(im)
    c = bg.convert("RGB").crop(sw["box"])
    c = c.resize((c.width * 3, c.height * 3), Image.LANCZOS)
    p = os.path.join(out, "swatch.png")
    c.save(p)
    return p


def save_guide(race):
    out = race_out(race)
    clay, tint, m, lab, stats = render(race)
    clay.save(os.path.join(out, "guide_clay.png"))
    tint.save(os.path.join(out, "guide_tint.png"))
    m.save(os.path.join(out, "guide_mask.png"))
    lab_rgb = np.array(PART_RGB, np.uint8)[lab]
    Image.fromarray(lab_rgb).save(os.path.join(out, "guide_labels.png"))
    make_swatch(race, out)
    try:                                        # prove the label map feeds derive.py as it stands
        frames, notes = derive_frames(lab_rgb, 1.0)
        stats["derive"] = dict(ok=True, frames=sorted(frames), notes=notes,
                               head=frames["head"], torso=frames["torso"])
    except LabelError as e:
        stats["derive"] = dict(ok=False, error=str(e))
    with open(os.path.join(out, "guide.json"), "w") as f:
        json.dump(stats, f, indent=1)
    print(json.dumps({k: stats[k] for k in ("bbox", "span_px", "depth_px", "depth_over_span",
                                             "shoulder_line_y", "skull_centre", "skull_r_px")}))
    print("derive:", "ok, %d frames; %s" % (len(stats["derive"]["frames"]), stats["derive"]["notes"])
          if stats["derive"]["ok"] else "FAIL " + stats["derive"]["error"])
    return stats


# ---------------------------------------------------------------- prompt

def build_prompt(race, guide="tint", swatch=True):
    p = RACES[race]
    what = "a flat-colour 3D sculpt" if guide == "tint" else "a grey clay sculpt"
    dome = p.get("dome", "smooth scalp")        # what the top of the head is covered with; last word = its noun
    cover = p.get("dome_cover", "skin")
    t = (
        "Image 1 is %s of a game character, rendered by an orthographic camera hovering directly above "
        "the top of its head and looking straight down at the floor: a plan view, like a miniature seen "
        "from above on a tabletop battle map. The figure stands bolt upright with both arms stretched "
        "straight out to the sides. "
        "The round dome in the centre is the top of its skull, like a smooth ball seen from above: the "
        "whole circle, rim to rim, is one unbroken %s shaded as a sphere, with the crown and a "
        "single soft highlight at the dead centre of the circle, equally far from every rim. The dark "
        "rim line of the circle all the way round is the widest part of the skull, and its lower half is "
        "exactly as round, smooth and plain as its upper half, a mirror image of it. %s "
        "The wide horizontal band running through the dome is the tops of the shoulders, the trapezius "
        "and the upper back. The level bars to the left and right are the arms seen from above, ending "
        "in flat hands with the backs of the hands, the knuckles and the spread fingers facing the "
        "camera. The rounded shelf below the shoulder band is the top surface of the chest seen from "
        "above, and the ten separate short rounded pegs at the very bottom, five on each side, are the "
        "tips of the toes on the floor far below, peeking out from under the chest. "
        "Paint this exact sculpt as a finished game character: %s. Keep the identical outline, pose, "
        "proportions, position, scale and straight-down viewpoint, tracing the silhouette precisely and "
        "keeping every shape exactly where and how large the sculpt has it. Paint the dome as a %s "
        "filling the entire perfect circle, one even curve of %s from the top rim to the bottom "
        "rim: the %s inside the circle is the same unmarked %s everywhere, and the circle's dark rim "
        "line stays a true circle. Paint the shoulder band as trapezius, deltoid and "
        "shoulder-blade muscles seen from above, the arms as level bars of biceps and forearm muscle, "
        "and each hand with five well-formed fingers, knuckles and fingernails. Paint each short peg at "
        "the bottom as one separate small toe tip, ten in all, each with grey background on both sides of "
        "it and a short dull nail plate on its top a little lighter than the skin. Bare unclothed "
        "base body, left-right symmetric, lit evenly from directly above, on a perfectly flat uniform "
        "mid-grey background, RGB 128 128 128, that fills the rest of the picture."
    ) % (what, dome, p["head_extras"], p["look"], dome, cover, cover, dome.split()[-1])
    if swatch:
        t += (
            " Image 2 is a small close-up swatch of this character's painted skin, for colour and finish "
            "only: match its %s, its smooth cel-like painted shading with a few broad soft-edged "
            "highlights per muscle, mirrored left and right, every highlight a lighter tint of the skin hue, "
            "and its %s of varying thickness around the whole silhouette and around the dome, as thick as "
            "the sculpt's own outline and crisp everywhere, with thinner dark lines separating the muscles, "
            "across the whole figure."
        ) % (p["skin_words"], p["line_words"])
    return t


def gen(race, n, tag, guide="tint", swatch=True, text=None):
    from .gen_overhead import generate, _part
    out = race_out(race)
    gsrc = os.path.join(out, "guide_%s.png" % guide)
    if not os.path.exists(gsrc):
        save_guide(race)
    prompt = text or build_prompt(race, guide, swatch)
    with open(os.path.join(out, "%s.prompt.txt" % tag), "w", encoding="utf-8") as f:
        f.write(prompt)
    # snapshot the inputs: the guide changes between rounds, the candidates must keep theirs
    in1 = os.path.join(out, "%s.in1_guide.png" % tag)
    shutil.copyfile(gsrc, in1)
    shutil.copyfile(os.path.join(out, "guide_mask.png"), os.path.join(out, "%s.guide_mask.png" % tag))
    shutil.copyfile(os.path.join(out, "guide_labels.png"), os.path.join(out, "%s.guide_labels.png" % tag))
    shutil.copyfile(os.path.join(out, "guide.json"), os.path.join(out, "%s.guide.json" % tag))
    inputs = [in1]
    parts = [{"text": prompt}, _part(in1, max_side=1376)]
    if swatch:
        in2 = os.path.join(out, "%s.in2_swatch.png" % tag)
        shutil.copyfile(make_swatch(race, out), in2)
        parts.append(_part(in2))
        inputs.append(in2)
    log_p = os.path.join(out, "calls.json")
    log = json.load(open(log_p)) if os.path.exists(log_p) else []
    made = []
    for i in range(1, n + 1):
        name = "%s_%d" % (tag, i)
        try:
            raw, model = generate(parts)
        except RuntimeError as e:               # a refused / empty answer still spent a call
            raw = None
            print("[FAIL] %s: %s" % (name, e))
        log.append(name if raw else name + " FAILED")
        with open(log_p, "w") as f:
            json.dump(log, f)
        if raw is None:
            continue
        p = os.path.join(out, name + ".png")
        with open(p, "wb") as f:
            f.write(raw)
        with open(os.path.join(out, name + ".json"), "w") as f:
            json.dump(dict(prompt=prompt, inputs=[os.path.basename(x) for x in inputs], model=model,
                           race=race, guide=guide, swatch=swatch), f, indent=1)
        print("[ok ] %s via %s %s  (Gemini calls so far: %d)" % (p, model, Image.open(io.BytesIO(raw)).size, len(log)))
        made.append(p)
    if made:
        check(race, made, tag)
    return made


# ---------------------------------------------------------------- check

def key_mask(a):
    """Foreground of a painting on flat grey. a: HxWx3 float. Returns (mask, ground colour)."""
    k = 24
    corners = np.concatenate([a[:k, :k].reshape(-1, 3), a[:k, -k:].reshape(-1, 3),
                              a[-k:, :k].reshape(-1, 3), a[-k:, -k:].reshape(-1, 3)])
    bg = np.median(corners, 0)
    d = np.abs(a - bg).max(-1)
    chroma = a.max(-1) - a.min(-1)
    fg = (chroma > 14) | (d > 45)       # coloured skin, or the dark outline / bright tusks
    fg = ndi.binary_opening(fg, iterations=1)
    lab, n = ndi.label(fg)
    if n:
        sizes = ndi.sum(fg, lab, range(1, n + 1))
        fg = lab == (1 + int(np.argmax(sizes)))
    fg = ndi.binary_fill_holes(ndi.binary_closing(fg, iterations=2))
    return fg, bg


def measure(path, gmask, write_overlay=True, stats=None, face_lab=None):
    a = np.asarray(Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS)).astype(np.float32)
    f, bg = key_mask(a)
    g = gmask
    ys, xs = np.nonzero(f)
    span, depth = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
    # symmetry about the painting's own centre column: silhouette overlap and colour agreement
    cx = int(round((xs.min() + xs.max() + 1) / 2.0))
    half = min(cx, W - cx)
    lf, rf = f[:, cx - half:cx][:, ::-1], f[:, cx:cx + half]
    la, ra = a[:, cx - half:cx][:, ::-1], a[:, cx:cx + half]
    both = lf & rf
    sym_shape = float(both.sum()) / max(float((lf | rf).sum()), 1.0)
    sym_colour = 1.0 - float(np.abs(la - ra).mean(-1)[both].mean()) / 255.0
    ground = a[~ndi.binary_dilation(f, iterations=6)]
    res = dict(image=os.path.basename(path),
               iou=round(float((g & f).sum()) / float((g | f).sum()), 4),
               span_px=int(span), depth_px=int(depth), depth_over_span=round(float(depth) / span, 4),
               outside_guide=round(float((f & ~g).sum()) / f.sum(), 4),
               guide_uncovered=round(float((g & ~f).sum()) / g.sum(), 4),
               symmetry_shape=round(sym_shape, 4), symmetry_colour=round(sym_colour, 4),
               centre_x_offset_px=int(cx - W // 2),
               ground_rgb=[int(round(v)) for v in ground.mean(0)],
               ground_std=round(float(ground.std(0).max()), 2))
    res["auto_pass"] = bool(res["iou"] >= 0.93 and 0.18 <= res["depth_over_span"] <= 0.26
                            and res["symmetry_shape"] >= 0.93
                            and max(abs(v - BG) for v in res["ground_rgb"]) <= 10)
    if stats is not None and face_lab is not None:
        res.update(head_metrics(a, stats, face_lab))
        res["head_pass"] = bool(res["face_dark"] <= FACE_DARK_MAX and res["muzzle_dark"] <= MUZZLE_DARK_MAX
                                and np.hypot(res["hl_dx"], res["hl_dy"]) <= HL_OFFSET_MAX * stats["skull_r_px"])
        res["auto_pass"] = bool(res["auto_pass"] and res["head_pass"])
    if write_overlay:   # green = both, red = painting outside the guide, blue = guide left empty
        ov = np.full(g.shape + (3,), 128, np.uint8)
        ov[g & f] = (90, 170, 90); ov[f & ~g] = (220, 60, 60); ov[g & ~f] = (60, 90, 220)
        Image.fromarray(ov).save(os.path.splitext(path)[0] + "_iou.png")
    return res


def head_metrics(a, stats, face_lab):
    """What IoU cannot see. a: HxWx3 float painting; face_lab: bool map of the guide's head label.
    face_dark   share of the dome inside 0.82 r that is a dark stroke against its surroundings:
                brows, eye sockets, a mouth line (a plain scalp scores about 0)
    muzzle_dark share of the band just south of the rim (outside the guide's own nose / tusk pixels)
                that is dark line or ivory: a lip band, a jaw, extra teeth
    hl_dx/dy    offset in px of the dome's highlight from the skull centre (+y = south)"""
    cx, cy = stats["skull_centre"]
    r = stats["skull_r_px"]
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    dx, dy = xx - cx + 0.5, yy - cy + 0.5
    rho = np.hypot(dx, dy) / r
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    lines = (lum - ndi.gaussian_filter(lum, 6)) < -9          # dark strokes against their surroundings
    face_dark = float(lines[rho < 0.82].mean())
    inner = rho < 0.8
    thr = np.percentile(lum[inner], 92)
    hot = inner & (lum >= thr)
    band = (rho > 1.07) & (rho < 1.5) & (dy > 0) & (np.abs(dx) < dy * 1.2)
    band &= ~ndi.binary_dilation(face_lab, iterations=5)
    ref = np.median(lum[band])
    ivory = (a.min(-1) > 150) & ((a.max(-1) - a.min(-1)) < 70)
    muzzle = float(((lum < 0.62 * ref) | ivory)[band].mean())
    return dict(face_dark=round(face_dark, 4), muzzle_dark=round(muzzle, 4),
                hl_dx=round(float(dx[hot].mean()), 1), hl_dy=round(float(dy[hot].mean()), 1))


def _tag_of(path):
    b = os.path.splitext(os.path.basename(path))[0]
    if b.endswith("_dome"):
        b = b[:-5]
    return b.rsplit("_", 1)[0]


def heal_dome(path, stats, dst=None):
    """Deterministic head fix-up: make the south half of the skull circle as plain as its north half.

    From straight above, under vertical light, a skull is radially symmetric, and the model always
    paints the NORTH half of the dome as clean scalp. So the radial colour profile is read from the
    north half (median over angle, the ear sectors left out) and laid over the south half, blending
    in just below the equator. Everything outside the guide skull circle (nose tip, tusk tips, ears,
    chest) is left as painted."""
    a = np.asarray(Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS)).astype(np.float32)
    cx, cy = stats["skull_centre"]
    r = stats["skull_r_px"]
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    dx, dy = xx - cx + 0.5, yy - cy + 0.5
    rho = np.hypot(dx, dy)
    ang = np.degrees(np.arctan2(-dy, dx))                   # 90 = north
    rmax = r * 1.05
    nb = 64
    prof = np.zeros((nb + 1, 3), np.float32)
    north = (ang > 25) & (ang < 155)
    for i in range(nb + 1):
        lo, hi = (i - 0.6) * rmax / nb, max((i + 0.6) * rmax / nb, 2.0)
        sel = north & (rho >= lo) & (rho < hi)
        if not sel.any():
            sel = (rho >= lo) & (rho < hi) & (dy < 0)
        prof[i] = np.median(a[sel], 0)
    t = np.clip(rho / rmax * nb, 0, nb)
    i0 = np.floor(t).astype(int)
    i1 = np.minimum(i0 + 1, nb)
    radial = prof[i0] * (1 - (t - i0))[..., None] + prof[i1] * (t - i0)[..., None]
    south = np.clip((dy / r - 0.02) / 0.45, 0, 1)           # 0 at the equator, 1 from 0.47 r south
    south = south * south * (3 - 2 * south)
    inside = np.clip((r * 1.035 - rho) / 2.0, 0, 1)         # stop just past the painted rim line
    wgt = (south * inside)[..., None]
    out = a * (1 - wgt) + radial * wgt
    dst = dst or os.path.splitext(path)[0] + "_dome.png"
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(dst)
    return dst


def dome(race, paths):
    out = race_out(race)
    made = []
    for p in paths:
        sj = os.path.join(os.path.dirname(p), _tag_of(p) + ".guide.json")
        stats = json.load(open(sj if os.path.exists(sj) else os.path.join(out, "guide.json")))
        made.append(heal_dome(p, stats))
        print("[ok ]", made[-1])
    return made


def head_sheet(paths, stats, guide_path, dst, zoom=3):
    """Guide + every candidate, cropped to the head and zoomed, with the shoulder line
    and the guide's skull circle drawn on a second row for the eye check."""
    cx, cy = stats["skull_centre"]
    r = stats["skull_r_px"]
    half_w, up, down = int(r * 2.3), int(r * 1.6), int(r * 2.3)
    box = (int(cx - half_w), int(cy - up), int(cx + half_w), int(cy + down))
    cw, ch = (box[2] - box[0]) * zoom, (box[3] - box[1]) * zoom
    items = [("guide", guide_path)] + [(os.path.splitext(os.path.basename(p))[0], p) for p in paths]
    sheet = Image.new("RGB", (cw * len(items), ch * 2 + 22), (40, 40, 40))
    d = ImageDraw.Draw(sheet)
    for i, (name, p) in enumerate(items):
        c = Image.open(p).convert("RGB").resize((W, H), Image.LANCZOS).crop(box).resize((cw, ch), Image.LANCZOS)
        sheet.paste(c, (i * cw, 22))
        c2 = c.copy()
        d2 = ImageDraw.Draw(c2)
        sy = (stats["shoulder_line_y"] - box[1]) * zoom
        d2.line([0, sy, cw, sy], fill=(255, 60, 60), width=1)
        ox, oy = (cx - box[0]) * zoom, (cy - box[1]) * zoom
        d2.ellipse([ox - r * zoom, oy - r * zoom, ox + r * zoom, oy + r * zoom], outline=(255, 255, 0))
        sheet.paste(c2, (i * cw, 22 + ch))
        d.text((i * cw + 4, 4), name, fill=(255, 255, 255))
    sheet.save(dst)
    return dst


def check(race, paths, tag=None):
    out = race_out(race)
    res = []
    for p in paths:
        pre = os.path.join(os.path.dirname(p), _tag_of(p))
        snap = pre + ".guide_mask.png"          # the guide this candidate was painted on
        gm = snap if os.path.exists(snap) else os.path.join(out, "guide_mask.png")
        gl = pre + ".guide_labels.png" if os.path.exists(pre + ".guide_labels.png") else os.path.join(out, "guide_labels.png")
        gj = pre + ".guide.json" if os.path.exists(pre + ".guide.json") else os.path.join(out, "guide.json")
        face = (np.asarray(Image.open(gl).convert("RGB")) == np.array(PALETTE["face"], np.uint8)).all(-1)
        r = measure(p, np.asarray(Image.open(gm).convert("L")) > 0, stats=json.load(open(gj)), face_lab=face)
        res.append(r)
        print(json.dumps(r))
    name = (tag or _tag_of(paths[0])) + ("_dome" if paths[0].endswith("_dome.png") else "")
    tag = tag or _tag_of(paths[0])
    sj = os.path.join(out, tag + ".guide.json")
    stats = json.load(open(sj if os.path.exists(sj) else os.path.join(out, "guide.json")))
    gp = os.path.join(out, tag + ".in1_guide.png")
    sheet = head_sheet(paths, stats, gp if os.path.exists(gp) else os.path.join(out, "guide_tint.png"),
                       os.path.join(out, name + "_heads.png"))
    with open(os.path.join(out, name + "_check.json"), "w") as f:
        json.dump(res, f, indent=1)
    print("head sheet:", sheet)
    print("auto gate passed %d of %d (the head still needs the eye check)" % (sum(r["auto_pass"] for r in res), len(res)))
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("guide"); g.add_argument("--race", default="orc")
    n = sub.add_parser("gen")
    n.add_argument("--race", default="orc"); n.add_argument("--n", type=int, default=4)
    n.add_argument("--tag", default="final"); n.add_argument("--guide", default="tint", choices=["tint", "clay"])
    n.add_argument("--no-swatch", action="store_true")
    n.add_argument("--text-file", default="", help="use this prompt instead of the built one")
    c = sub.add_parser("check")
    c.add_argument("images", nargs="*"); c.add_argument("--race", default="orc"); c.add_argument("--tag", default="")
    d = sub.add_parser("dome")
    d.add_argument("images", nargs="*"); d.add_argument("--race", default="orc"); d.add_argument("--tag", default="")
    a = ap.parse_args(argv)
    if a.cmd in ("check", "dome") and not a.images:
        if not a.tag:
            ap.error("%s needs --tag or image paths" % a.cmd)
        a.images = sorted(q for q in glob.glob(os.path.join(race_out(a.race), a.tag + "_*.png"))
                          if os.path.basename(q)[len(a.tag) + 1:-4].isdigit())
    if a.cmd == "dome":
        check(a.race, dome(a.race, a.images), a.tag or None)
    elif a.cmd == "guide":
        save_guide(a.race)
    elif a.cmd == "gen":
        text = open(a.text_file, encoding="utf-8").read().strip() if a.text_file else None
        gen(a.race, a.n, a.tag, a.guide, not a.no_swatch, text)
    else:
        check(a.race, a.images, a.tag or None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
