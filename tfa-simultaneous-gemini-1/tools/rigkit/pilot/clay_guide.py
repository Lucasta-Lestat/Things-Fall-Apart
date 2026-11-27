"""Clay-guide pilot: render a true top-down proxy figure, then have Gemini paint over it.

    python -m tools.rigkit.pilot.clay_guide guide [--race orc]
    python -m tools.rigkit.pilot.clay_guide gen --prompt A --tag r1a [--swatch] [--guide clay|flat]
    python -m tools.rigkit.pilot.clay_guide iou <image> [...]

The proxy is analytic primitives (ellipsoids, tapered capsules) in a world where
x = west-east, y = north-south (south = +, the figure faces south), z = height,
and the fingertip-to-fingertip half span is 1.0 (so standing height is ~2.0).
The camera is orthographic straight down: the image is the per-pixel MAX height,
shaded from the height-map normal as matte clay. The same pass yields the
silhouette mask and a per-part label image for free.

Character's LEFT is image RIGHT (it faces the bottom of the picture).
"""
import argparse
import io
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(HERE, "..", "out", "overhead2", "clay_guide")
W, H = 1376, 768
SS = 2
BG = 128

LABELS = ["background", "body", "head", "upper_arm_R", "upper_arm_L", "forearm_R", "forearm_L",
          "hand_R", "hand_L", "foot_R", "foot_L"]
LABEL_RGB = [(128, 128, 128), (200, 60, 60), (240, 220, 60), (60, 160, 240), (40, 90, 200),
             (80, 220, 120), (30, 140, 70), (240, 130, 220), (160, 60, 170), (250, 150, 50), (170, 95, 20)]

# Proportions, all in half-span units. A race is one of these dicts.
RACES = {
    "orc": dict(
        shoulder_half=0.30,     # x of the shoulder joint
        delt_r=0.105,
        trunk_depth_n=0.16,     # how far the upper back reaches north of the shoulder line
        chest_depth_s=0.19,     # how far the pecs reach south
        belly_depth_s=0.215,
        belly_half=0.21,
        skull_rx=0.092, skull_ry=0.112, skull_y=0.035,
        brow=0.035, nose=0.030, tusk=0.022, ear_len=0.065,
        upper_arm_r=(0.088, 0.070), forearm_r=(0.072, 0.046),
        elbow_x=0.585, wrist_x=0.805,
        palm_rx=0.070, palm_ry=0.064, finger_r=0.0145,
        toe_y=0.275, foot_x=0.10, foot_r=0.052,
    ),
    "human": dict(
        shoulder_half=0.25, delt_r=0.08, trunk_depth_n=0.12, chest_depth_s=0.13,
        belly_depth_s=0.14, belly_half=0.17,
        skull_rx=0.080, skull_ry=0.100, skull_y=0.03,
        brow=0.018, nose=0.026, tusk=0.0, ear_len=0.0,
        upper_arm_r=(0.062, 0.052), forearm_r=(0.052, 0.036),
        elbow_x=0.57, wrist_x=0.83,
        palm_rx=0.055, palm_ry=0.048, finger_r=0.010,
        toe_y=0.20, foot_x=0.085, foot_r=0.045,
    ),
}


def primitives(p):
    """List of (label, kind, params). Mirrored parts are emitted for both sides."""
    P = []
    sh = p["shoulder_half"]
    zs = 1.56  # shoulder / arm axis height

    def ell(label, c, r):
        P.append((label, "ell", (c, r)))

    def cap(label, a, b, ra, rb, z, kz=1.0):
        P.append((label, "cap", (a, b, ra, rb, z, kz)))

    # trunk
    n, cs, bs = p["trunk_depth_n"], p["chest_depth_s"], p["belly_depth_s"]
    ell("body", (0, 0.0, 1.32), (sh + 0.01, 0.15, 0.28))                      # rib cage
    ell("body", (0, -(n - 0.115), 1.40), (sh + 0.02, 0.115, 0.20))            # upper back / lats
    cap("body", (-sh, -0.01), (sh, -0.01), 0.10, 0.10, 1.50, 0.8)             # shoulder girdle
    ell("body", (0, -0.03, 1.60), (0.17, 0.10, 0.10))                         # traps / neck root
    for s in (-1, 1):
        ell("body", (s * (sh + 0.045), 0.0, 1.56), (p["delt_r"], p["delt_r"] + 0.005, 0.10))  # deltoid
        ell("body", (s * 0.135, cs - 0.09, 1.38), (0.15, 0.09, 0.12))         # pec
    ell("body", (0, bs - 0.14, 1.10), (p["belly_half"], 0.14, 0.25))          # belly

    # head: a dome seen from above, crown at its centre
    sx, sy, hy = p["skull_rx"], p["skull_ry"], p["skull_y"]
    ell("head", (0, hy, 1.86), (sx, sy, 0.14))
    ell("head", (0, hy + sy * 0.86, 1.76), (sx * 0.80, p["brow"] * 0.8, 0.04))  # brow ridge: a rim under the dome
    ell("head", (0, hy + sy + 0.004, 1.72), (0.020, p["nose"] * 0.8, 0.03))   # nose tip
    if p["tusk"] > 0:
        for s in (-1, 1):
            ell("head:tusk", (s * 0.050, hy + sy + 0.004, 1.70), (0.011, p["tusk"] * 0.8, 0.03))
    if p["ear_len"] > 0:
        for s in (-1, 1):
            cap("head", (s * sx * 0.92, hy + 0.01), (s * (sx + p["ear_len"]), hy - 0.035), 0.024, 0.006, 1.80, 0.6)

    # arms: horizontal bars at shoulder height
    ex, wx = p["elbow_x"], p["wrist_x"]
    ua, fa = p["upper_arm_r"], p["forearm_r"]
    for s, side in ((-1, "R"), (1, "L")):
        cap("upper_arm_" + side, (s * (sh + 0.05), 0), (s * ex, 0), ua[0], ua[1], zs)
        cap("forearm_" + side, (s * ex, 0), (s * wx, 0), fa[0], fa[1], zs - 0.01)
        hx = wx + p["palm_rx"] * 0.85
        ell("hand_" + side, (s * hx, 0, zs - 0.02), (p["palm_rx"], p["palm_ry"], 0.022))
        fr = p["finger_r"]
        tips = (0.965, 0.992, 1.0, 0.982)  # little .. index, north to south
        for i, tip in enumerate(tips):
            y0 = (i - 1.5) * fr * 2.25
            y1 = (i - 1.5) * fr * 3.0
            cap("hand_" + side, (s * (hx + 0.02), y0), (s * tip, y1), fr, fr * 0.85, zs - 0.03, 0.8)
        cap("hand_" + side, (s * (hx - 0.03), p["palm_ry"] * 0.6), (s * (hx + 0.025), p["palm_ry"] + 0.035),
            fr * 1.25, fr, zs - 0.035, 0.8)                                   # thumb points south
        fx = p["foot_x"]
        cap("foot_" + side, (s * fx * 0.9, 0.08), (s * fx, p["toe_y"] - p["foot_r"]), p["foot_r"] * 0.85,
            p["foot_r"], 0.05, 0.6)
    return P


def render(race="orc", w=W, h=H, ss=SS, margin=0.035, tint_skin=(116, 132, 76)):
    p = RACES[race]
    ww, hh = w * ss, h * ss
    scale = ww * (0.5 - margin)                 # px per unit; fingertips land `margin` from each edge
    prims = primitives(p)
    # centre the figure's north-south extent on the canvas
    y_n = -(p["trunk_depth_n"]) - 0.01
    y_s = max(p["toe_y"], p["belly_depth_s"])
    yc = (y_n + y_s) / 2
    xs = (np.arange(ww) + 0.5 - ww / 2) / scale
    ys = (np.arange(hh) + 0.5 - hh / 2) / scale + yc
    X, Y = np.meshgrid(xs, ys)
    height = np.full((hh, ww), -1.0, np.float32)
    label = np.zeros((hh, ww), np.uint8)
    tusk = np.zeros((hh, ww), bool)
    for name, kind, prm in prims:
        if kind == "ell":
            (cx, cy, cz), (rx, ry, rz) = prm
            q = 1 - ((X - cx) / rx) ** 2 - ((Y - cy) / ry) ** 2
            z = np.where(q > 0, cz + rz * np.sqrt(np.clip(q, 0, None)), -1)
        else:
            (ax, ay), (bx, by), ra, rb, cz, kz = prm
            dx, dy = bx - ax, by - ay
            t = np.clip(((X - ax) * dx + (Y - ay) * dy) / (dx * dx + dy * dy), 0, 1)
            r = ra + (rb - ra) * t
            d2 = (X - (ax + t * dx)) ** 2 + (Y - (ay + t * dy)) ** 2
            q = r * r - d2
            z = np.where(q > 0, cz + kz * np.sqrt(np.clip(q, 0, None)), -1)
        win = z > height
        height[win] = z[win]
        label[win] = LABELS.index(name.split(":")[0])
        tusk[win] = name.endswith(":tusk")
    mask = height > -0.5

    # clay shading from the height-map normal
    hs = np.where(mask, height, 0).astype(np.float32)
    hsm = ndi.gaussian_filter(hs, 1.5 * ss)
    gy, gx = np.gradient(hsm * scale * 0.55)    # 0.55: flatten relief a little so cliffs do not go black
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    L = np.array([-0.12, -0.18, 0.97]); L /= np.linalg.norm(L)
    lam = np.clip(nrm @ L, 0, 1)
    ao = np.clip((ndi.gaussian_filter(hs, 14 * ss) - hs) * 1.6, 0, 0.45)       # pits and low parts darker
    depth = 0.80 + 0.20 * np.clip(hs / 1.9, 0, 1)
    shade = (0.30 + 0.70 * lam) * depth * (1 - ao)
    clay = 205 * shade
    # crease lines where one part overlaps another (depth discontinuity)
    edge = np.hypot(*np.gradient(ndi.gaussian_filter(hs, 0.8 * ss))) * scale
    crease = np.clip((edge - 1.6) / 3.0, 0, 1) * 0.35
    clay *= (1 - crease)
    # soft dark outline + faint contact shadow on the ground
    dist_in = ndi.distance_transform_edt(mask)
    outline = np.clip(1 - dist_in / (2.2 * ss), 0, 1)
    clay = clay * (1 - 0.75 * outline) + 45 * 0.75 * outline
    img = np.where(mask, clay, BG).astype(np.float32)
    img = np.clip(img, 0, 255)
    rgb = np.repeat(img[..., None], 3, -1).astype(np.uint8)
    # tinted variant: the same clay multiplied by a flat skin colour, tusks ivory
    skin = np.array(tint_skin, np.float32) / 205.0
    ivory = np.array((236, 226, 196), np.float32) / 205.0
    col = np.where(tusk[..., None], ivory, skin) * (clay[..., None] * 1.25)
    tinted = np.where(mask[..., None], np.clip(col, 0, 255), BG).astype(np.uint8)
    tinted_im = Image.fromarray(tinted).resize((w, h), Image.LANCZOS)

    im = Image.fromarray(rgb).resize((w, h), Image.LANCZOS)
    m = Image.fromarray((mask * 255).astype(np.uint8)).resize((w, h), Image.LANCZOS).point(lambda v: 255 if v >= 128 else 0)
    lab = Image.fromarray(label).resize((w, h), Image.NEAREST)
    lab_np = np.array(lab) * (np.array(m) > 0)
    # make labels and mask agree exactly after resampling
    holes = (np.array(m) > 0) & (lab_np == 0)
    if holes.any():
        idx = ndi.distance_transform_edt(lab_np == 0, return_distances=False, return_indices=True)
        lab_np = lab_np[tuple(idx)] * (np.array(m) > 0)
    ys_, xs_ = np.nonzero(np.array(m))
    stats = dict(race=race, canvas=[w, h], px_per_unit=scale / ss,
                 bbox=[int(xs_.min()), int(ys_.min()), int(xs_.max()), int(ys_.max())],
                 span_px=int(xs_.max() - xs_.min() + 1), depth_px=int(ys_.max() - ys_.min() + 1))
    stats["depth_over_span"] = round(stats["depth_px"] / stats["span_px"], 4)
    stats["labels"] = {n: i for i, n in enumerate(LABELS)}
    stats["note"] = "figure faces south (image bottom); character LEFT is image RIGHT"
    return im, m, lab_np.astype(np.uint8), stats, tinted_im


def save_guide(race, out=OUT):
    os.makedirs(out, exist_ok=True)
    im, m, lab, stats, tinted = render(race)
    tinted.save(os.path.join(out, "%s_guide_tint.png" % race))
    im.save(os.path.join(out, "%s_guide_clay.png" % race))
    m.save(os.path.join(out, "%s_guide_mask.png" % race))
    Image.fromarray(lab).save(os.path.join(out, "%s_guide_labels_idx.png" % race))
    Image.fromarray(np.array(LABEL_RGB, np.uint8)[lab]).save(os.path.join(out, "%s_guide_labels.png" % race))
    with open(os.path.join(out, "%s_guide.json" % race), "w") as f:
        json.dump(stats, f, indent=1)
    print(json.dumps(stats))
    return stats


# ---------------------------------------------------------------- measuring

def key_mask(path, size=(W, H), thr=30):
    """Foreground of a painting on flat grey: colour distance from the corner-estimated ground."""
    im = Image.open(path).convert("RGB").resize(size, Image.LANCZOS)
    a = np.asarray(im).astype(np.float32)
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
    return fg


def iou(path, race="orc", out=OUT):
    g = np.asarray(Image.open(os.path.join(out, "%s_guide_mask.png" % race))) > 0
    f = key_mask(path)
    inter, union = (g & f).sum(), (g | f).sum()
    ys, xs = np.nonzero(f)
    span, depth = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
    res = dict(image=os.path.basename(path), iou=round(float(inter / union), 4),
               span_px=int(span), depth_px=int(depth), depth_over_span=round(float(depth / span), 4),
               outside_guide=round(float((f & ~g).sum() / f.sum()), 4),
               guide_uncovered=round(float((g & ~f).sum() / g.sum()), 4))
    # overlay for eyeballing: green = both, red = painting outside guide, blue = guide left empty
    ov = np.full(g.shape + (3,), 128, np.uint8)
    ov[g & f] = (90, 170, 90); ov[f & ~g] = (220, 60, 60); ov[g & ~f] = (60, 90, 220)
    Image.fromarray(ov).save(os.path.splitext(path)[0] + "_iou.png")
    return res


# ---------------------------------------------------------------- painting

PROMPTS = {
    "A": (
        "Image 1 is a grey clay sculpt of a muscular humanoid, photographed by a camera hovering directly "
        "above it and looking straight down at the ground: a plan view, like a miniature seen from above on "
        "a tabletop map. The figure stands upright with both arms stretched straight out to the sides. The "
        "round dome in the centre is the top of its bald skull, with the crown at the centre of the dome. The "
        "thin strip on the lower edge of the dome is the brow ridge, the nose tip and two tusk tips jutting "
        "forward. The wide horizontal band is the tops of the shoulders and upper back; the bars to the left "
        "and right are the arms seen from above, ending in flat hands with the backs of the hands facing the "
        "camera. The rounded bulge below the shoulders is the chest and belly seen from above, and the two "
        "small bumps at the bottom are the toe tips. "
        "Paint this exact clay figure as a finished game character: an orc with olive-green skin, bald scalp, "
        "pointed ears, heavy muscles and ivory tusk tips. Keep the identical outline, pose, proportions, "
        "position, scale and straight-down viewpoint of the clay figure, tracing its silhouette precisely. "
        "Paint the dome as a smooth bald green scalp seen from above with a soft highlight on the crown. Paint "
        "the shoulder band as trapezius, deltoid and shoulder-blade muscles seen from above. Hand-painted "
        "semi-realistic game-art style with soft shading and a soft dark outline, lit evenly from above, on "
        "the same flat uniform mid-grey background. Bare unclothed base body, left-right symmetric."
    ),
}
PROMPTS["B"] = (
    "Image 1 is a clay sculpt of a muscular orc, photographed by a camera hovering directly above the top of "
    "its head and looking straight down at the ground: a plan view, like a miniature seen from above on a "
    "tabletop battle map. The figure stands upright with both arms stretched straight out to the sides. "
    "The egg-shaped dome in the centre is the top of its bald skull: the whole dome, from its upper edge to "
    "its lower edge, is one unbroken smooth scalp, with the crown and a single soft highlight at its centre. "
    "The brow ridge is the narrow shadowed rim along the lower edge of the dome; just beyond that rim sit a "
    "small nose-tip bump and two ivory tusk points, and these three tiny shapes are all of the face that the "
    "overhead camera reaches. The pointed ears stick out sideways from the dome. The wide horizontal band is "
    "the tops of the shoulders, the trapezius and the upper back; the bars to the left and right are the arms "
    "seen from above, ending in flat hands with the backs of the hands and knuckles facing the camera. The "
    "rounded shelf below the shoulder band is the top surface of the chest and belly seen from above, and the "
    "two small bumps at the bottom are the toe tips. "
    "Paint this exact sculpt as a finished game character: an orc with olive-green skin, bald scalp, pointed "
    "ears, heavy muscles and ivory tusk tips. Keep the identical outline, pose, proportions, position, scale "
    "and straight-down viewpoint, tracing the silhouette precisely and keeping every shape exactly where the "
    "sculpt has it. Paint the dome as a smooth bald green scalp filling the entire egg shape. Paint the "
    "shoulder band as trapezius, deltoid and shoulder-blade muscles seen from above. Hand-painted "
    "semi-realistic game-art style with soft shading and a soft dark outline, lit evenly from directly above, "
    "on the same flat uniform mid-grey background. Bare unclothed base body, left-right symmetric."
)
PROMPTS["B_swatch"] = PROMPTS["B"] + (
    " Image 2 is a small close-up swatch of this orc's painted skin, for colour and finish only: match its "
    "fresh saturated olive-green hue, its lighter yellow-green highlights, its smooth cel-like painted "
    "shading with clean muscle-separation lines, and its crisp dark green outline, across the whole figure. "
    "Give each foot five clearly painted toes seen from above."
)
PROMPTS["C_swatch"] = PROMPTS["B"] + (
    " Image 2 is a small close-up swatch of this orc's painted skin, for colour and finish only: match its "
    "fresh saturated olive-green hue, its lighter yellow-green highlights, its smooth cel-like painted "
    "shading with clean muscle-separation lines, and its crisp dark green outline, across the whole figure. "
    "The nose tip and the two tusk points rest directly against the chest surface, and smooth chest skin "
    "continues immediately beyond them. The two toe-tip bumps keep exactly the small size and position they "
    "have in the sculpt, each painted as a row of short toe ends with toenails."
)
PROMPTS["A_swatch"] = PROMPTS["A"] + (
    " Image 2 is a small swatch of the skin to use: match its olive-green colour, its painted brushwork, "
    "its shading softness and its dark outline colour."
)


def make_swatch(out=OUT):
    """A tight patch of the old orc's upper arm: colour and brushwork only, no camera cue."""
    p = os.path.join(out, "orc_skin_swatch.png")
    if os.path.exists(p):
        return p
    src = os.path.join(ROOT, "Rigs", "races", "orc", "default", "body.png")
    im = Image.open(src).convert("RGBA")
    bg = Image.new("RGBA", im.size, (128, 128, 128, 255)); bg.alpha_composite(im)
    box = (700, 118, 800, 168)
    sw = bg.convert("RGB").crop(box).resize((400, 200), Image.LANCZOS)
    p = os.path.join(out, "orc_skin_swatch.png")
    sw.save(p)
    return p


def gen(prompt_key, tag, guide="clay", swatch=False, race="orc", out=OUT, text=None):
    sys.path.insert(0, ROOT)
    from tools.rigkit.gen_overhead import generate, _part
    gpath = os.path.join(out, "%s_guide_%s.png" % (race, guide))
    prompt = text or PROMPTS[prompt_key]
    parts = [{"text": prompt}, _part(gpath, max_side=1376)]
    inputs = [gpath]
    if swatch:
        sp = make_swatch(out)
        parts.append(_part(sp)); inputs.append(sp)
    raw, model = generate(parts)
    p = os.path.join(out, "%s_%s.png" % (race, tag))
    with open(p, "wb") as f:
        f.write(raw)
    with open(os.path.join(out, "%s_%s.json" % (race, tag)), "w") as f:
        json.dump(dict(prompt=prompt, inputs=inputs, model=model), f, indent=1)
    print("[ok ]", p, "via", model, Image.open(io.BytesIO(raw)).size)
    print(json.dumps(iou(p, race, out)))
    return p


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("guide"); g.add_argument("--race", default="orc")
    n = sub.add_parser("gen")
    n.add_argument("--prompt", default="A"); n.add_argument("--tag", required=True)
    n.add_argument("--guide", default="clay"); n.add_argument("--swatch", action="store_true")
    n.add_argument("--race", default="orc"); n.add_argument("--text-file", default="")
    i = sub.add_parser("iou"); i.add_argument("images", nargs="+"); i.add_argument("--race", default="orc")
    a = ap.parse_args(argv)
    if a.cmd == "guide":
        save_guide(a.race)
    elif a.cmd == "gen":
        text = open(a.text_file, encoding="utf-8").read().strip() if a.text_file else None
        gen(a.prompt, a.tag, a.guide, a.swatch, a.race, text=text)
    else:
        for p in a.images:
            print(json.dumps(iou(p, a.race)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
