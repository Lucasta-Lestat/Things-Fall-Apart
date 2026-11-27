"""The canonical hand set: one greyscale gripping fist every race shares.

    python -m tools.rigkit.gen_hands guide              # clay guide + mask + frames
    python -m tools.rigkit.gen_hands gen TAG [-n 4]     # paint over the guide (Gemini)
    python -m tools.rigkit.gen_hands check TAG          # outline lock + contact sheet
    python -m tools.rigkit.gen_hands install PAINTING   # -> Rigs/hands/humanoid/
    python -m tools.rigkit.gen_hands install --clay     # ship the guide itself

docs/rigging_rewrite.md section 3.6. A hand POSE is an art swap. `open` is the hand the
race painting already has. `grip` is this fist: authored once, in greyscale, as a RIGHT
hand seen from above (wrist at the left edge, knuckles toward +x, thumb folded along the
south side). At draw time it is fitted to each race's palm frame and coloured through
that race's skin ramp (or a glove's ramp), so a new race needs no fist art and a new
glove needs no fist art. Its `grip` frame is the FRONT of the closed fingers: a held
item's hold point (the back of a sword's guard) lands there, so the guard sits against
the knuckles and the handle runs back under the hand on every race.

Same method as gen_plan: the camera and the outline are GIVEN by a rendered guide, the
model only repaints it. The fist's frames (palm, grip) are the guide's own numbers, not
measured from the painting. Prompts are phrased positively only.

Units: one PALM UNIT is the hand's half-width. The wrist seam is at u = 0, the knuckle
line at u = 2 (closing a hand does not shorten the back of the hand), the curled
fingers end near u = 2.4.
"""
import argparse
import json
import os
import shutil
import sys

import cv2
import numpy as np
from PIL import Image

from . import core
from .derive import colour_ramp, luma

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "hands")
SET_DIR = os.path.join(core.RIGS, "hands", "humanoid")
W = H = 768
PPU = 225.0                       # guide px per palm unit
WRIST = (120.0, 384.0)            # the wrist seam centre in the guide
GROUND = (58, 110, 215)           # flat key colour (gen_item's blue-dominance key)
ART_PPU = 64.0                    # installed art px per palm unit
STUB = 0.75                       # palm units of forearm kept behind the wrist seam
STUB_FADE = 0.40                  # ... and faded out over, so the fist melts into any forearm
OUTLINE_U = 0.085                 # outline weight, palm units
KNUCKLE_SHARE = 0.80              # the knuckle line, as a share of the fist's length from the wrist
FRONT_SHARE = 0.90                # the grip point (where a guard rests), same measure
GRIP_U = 2.15                     # ... on the clay guide, in palm units

# (centre u, v, height; radii u, v, height) ellipsoids, palm units. v > 0 is south (thumb side).
def _prims():
    p = []
    for u in np.linspace(-1.3, 0.2, 9):                      # forearm stub, tapering to the wrist
        p.append((u, 0.0, 0.0, 0.5, 0.74 + 0.03 * (-u), 0.55))
    p.append((1.02, -0.02, 0.0, 1.08, 0.94, 0.62))            # back of the hand
    p.append((0.45, 0.0, 0.0, 0.62, 0.80, 0.58))              # heel, bridging wrist and back
    kn = [(-0.70, 1.86, 0.25), (-0.24, 2.00, 0.28), (0.24, 2.03, 0.29), (0.70, 1.92, 0.28)]
    for v, u, r in kn:                                        # pinky .. index
        p.append((u, v, 0.34, r, r, r))                       # knuckle
        for t in np.linspace(0.0, 1.0, 4):                    # first phalanx curling down and under
            p.append((u + 0.12 + 0.20 * t, v, 0.30 - 0.42 * t, r * 0.95, r * 0.92, r * 0.9))
    for t in np.linspace(0.0, 1.0, 8):                        # thumb, folded along the south side
        p.append((0.62 + 1.38 * t, 0.84 + 0.20 * np.sin(t * np.pi * 0.9), 0.05 + 0.1 * t,
                  0.30, 0.25 - 0.03 * t, 0.26))
    return p


def render_guide():
    """Returns (clay RGB uint8, mask bool, height float)."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    u = (xx - WRIST[0]) / PPU
    v = (yy - WRIST[1]) / PPU
    z = np.full((H, W), -9.0, np.float32)
    for cu, cv_, cz, ru, rv, rz in _prims():
        d = 1.0 - ((u - cu) / ru) ** 2 - ((v - cv_) / rv) ** 2
        z = np.maximum(z, np.where(d > 0, cz + rz * np.sqrt(np.maximum(d, 0)), -9.0))
    mask = z > -8.0
    zs = cv2.GaussianBlur(np.where(mask, z, 0.0), (0, 0), 2.0)
    gy, gx = np.gradient(zs * PPU)
    nrm = np.dstack([-gx, -gy, np.ones_like(gx)])
    nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
    light = np.array([-0.35, -0.45, 0.82])
    lam = np.clip(nrm @ (light / np.linalg.norm(light)), 0, 1)
    shade = 0.36 + 0.5 * lam
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    edge = mask & ~(cv2.erode(mask.astype(np.uint8), k) > 0)
    crease = mask & (cv2.Laplacian(zs, cv2.CV_32F, ksize=5) > 0.06)
    shade = np.where(crease, shade * 0.78, shade)
    shade = np.where(edge, 0.12, shade)
    clay = np.zeros((H, W, 3), np.uint8)
    clay[:] = GROUND
    g = np.clip(shade * 255, 0, 255).astype(np.uint8)
    clay[mask] = np.dstack([g, g, g])[mask]
    return clay, mask, z


def guide_frames():
    """The fist's frames in guide px: palm (wrist origin, lx = ly = one palm unit) and
    grip (the front of the closed fingers, GRIP_U palm units out)."""
    return {"palm": core.make_frame(WRIST, ax=(1.0, 0.0), lx=PPU, ly=PPU),
            "grip": core.make_frame((WRIST[0] + GRIP_U * PPU, WRIST[1]), ax=(1.0, 0.0), lx=PPU, ly=PPU)}


def save_guide():
    os.makedirs(OUT, exist_ok=True)
    clay, mask, _ = render_guide()
    Image.fromarray(clay).save(os.path.join(OUT, "guide.png"))
    Image.fromarray((mask * 255).astype(np.uint8)).save(os.path.join(OUT, "guide_mask.png"))
    core.save_json(os.path.join(OUT, "guide.json"), {"frames": guide_frames(), "ppu": PPU, "ground": list(GROUND)})
    return clay, mask


PROMPT = (
    "Image 1 is a clay model of a clenched right fist with its wrist, seen from directly above "
    "on a flat blue background. Repaint image 1 as a finished hand-painted game sprite of that "
    "same fist. Keep the exact outline, size and position of the clay model. The back of the hand "
    "faces the viewer, the wrist enters from the left edge, the four knuckles run down the right "
    "side with the fingers curled under them, and the thumb lies folded along the lower edge. "
    "Paint it as a greyscale study in neutral mid-grey skin: soft painterly shading, rounded "
    "knuckles, gentle tendon ridges on the back of the hand, a clean dark outline of even weight "
    "like the line work in image 2, matte finish, light from the upper left. "
    "The background stays the same flat uniform blue, RGB %d %d %d, filling the rest of the picture." % GROUND)


def make_swatch():
    """A greyscale patch of painted forearm: carries line weight and brush finish only."""
    race = core.load_race("orc", "tilt15")
    body = Image.open(core.race_file(race, "art")).convert("RGBA")
    f = race["frames"]["forearm_r"]
    x, y = int(f["o"][0]), int(f["o"][1])
    crop = body.crop((x - 20, y - 70, x + 150, y + 70))
    bg = Image.new("RGBA", crop.size, GROUND + (255,))
    bg.alpha_composite(crop)
    g = np.asarray(bg.convert("RGB")).copy()
    a = np.asarray(crop)[:, :, 3] > 40
    grey = (luma(g) * 255).astype(np.uint8)
    g[a] = np.dstack([grey, grey, grey])[a]
    p = os.path.join(OUT, "swatch.png")
    Image.fromarray(g).resize((crop.width * 3, crop.height * 3), Image.LANCZOS).save(p)
    return p


def gen(tag, n):
    from .gen_overhead import generate, _part
    save_guide()
    sw = make_swatch()
    with open(os.path.join(OUT, "%s.prompt.txt" % tag), "w", encoding="utf-8") as f:
        f.write(PROMPT)
    parts = [{"text": PROMPT}, _part(os.path.join(OUT, "guide.png")), _part(sw)]
    log_p = os.path.join(OUT, "calls.json")
    log = json.load(open(log_p)) if os.path.exists(log_p) else []
    for i in range(1, n + 1):
        name = "%s_%d" % (tag, i)
        try:
            raw, model = generate(parts)
        except RuntimeError as e:
            raw = None
            print("[FAIL] %s: %s" % (name, e))
        log.append(name + ("" if raw else " FAILED"))
        with open(log_p, "w") as f:
            json.dump(log, f)
        if raw is None:
            continue
        p = os.path.join(OUT, name + ".png")
        with open(p, "wb") as f:
            f.write(raw)
        im = Image.open(p).convert("RGB")
        if im.size != (W, H):
            im = im.resize((W, H), Image.LANCZOS)
        im.save(p)
        print("[ok ] %s via %s (Gemini calls so far: %d)" % (p, model, len(log)))


def key(rgb):
    from .gen_item import key as blue_key
    return blue_key(rgb)


def check(tag):
    gmask = np.asarray(Image.open(os.path.join(OUT, "guide_mask.png"))) > 127
    paths = sorted(p for p in os.listdir(OUT) if p.startswith(tag + "_") and p.endswith(".png"))
    tiles = [np.asarray(Image.open(os.path.join(OUT, "guide.png")).convert("RGB"))]
    for p in paths:
        rgb = np.asarray(Image.open(os.path.join(OUT, p)).convert("RGB"))
        _, alpha = key(rgb)
        sil = alpha >= 0.5
        iou = float((sil & gmask).sum()) / float((sil | gmask).sum())
        sat = float(np.ptp(rgb[sil].astype(int), axis=1).mean())
        print("%-16s IoU %.3f  mean chroma %.1f %s" % (p, iou, sat, "" if iou >= 0.9 else " <-- outline drifted"))
        tiles.append(rgb)
    sheet = np.concatenate([cv2.resize(t, (384, 384), interpolation=cv2.INTER_AREA) for t in tiles], axis=1)
    out = os.path.join(OUT, "%s_sheet.jpg" % tag)
    Image.fromarray(sheet).save(out, quality=90)
    print("wrote", out)


def measure_fist(rgb):
    """Where the fist sits in a painting. The model keeps the guide's pose but re-frames
    and re-proportions it (IoU 0.55-0.76 over two sets), so the fist's frames are read
    off the painted outline instead of the guide: the wrist is the narrowest column
    behind the hand, the front is the rightmost paint, and the palm unit is half the
    hand's greatest width. Returns {"wrist": (x, y), "unit": px, "length_u": palm units
    from wrist to front, "alpha": float mask}."""
    _, alpha = key(rgb)
    sil = alpha >= 0.5
    cols = np.nonzero(sil.any(axis=0))[0]
    front = int(cols.max())
    th = sil.sum(axis=0).astype(float)
    ths = np.convolve(th, np.ones(15) / 15.0, mode="same")
    # the hand is the last bulge: walk back from the front to the thinnest column
    peak = int(front - np.argmax(ths[front::-1][:int(0.45 * W)]))
    lo = max(int(cols.min()) + 8, peak - int(0.45 * W))
    wx = lo + int(np.argmin(ths[lo:peak]))
    unit = float(th[wx:front + 1].max()) / 2.0
    mids = [(np.nonzero(sil[:, x])[0].min() + np.nonzero(sil[:, x])[0].max()) / 2.0
            for x in range(wx + (front - wx) // 3, front - (front - wx) // 6)]
    return {"wrist": (float(wx), float(np.mean(mids))), "unit": unit,
            "length_u": (front - wx) / unit, "wrist_u": float(th[wx]) / 2.0 / unit, "alpha": alpha}


def install(painting=None):
    """Key, grey, crop, fade the stub; write Rigs/hands/humanoid/{grip.png, hand.json}."""
    gmask = np.asarray(Image.open(os.path.join(OUT, "guide_mask.png"))) > 127
    if painting is None:
        clay, mask, _ = render_guide()
        rgb, alpha, src = clay.astype(np.float32), mask.astype(np.float32), "clay guide (gen_hands.render_guide)"
        iou = 1.0
        wrist, ppu, grip_u, wrist_u, length_u = WRIST, PPU, GRIP_U, 0.76, 2.4
    else:
        raw = np.asarray(Image.open(painting).convert("RGB"))
        rgb, alpha = key(raw)
        sil = alpha >= 0.5
        iou = float((sil & gmask).sum()) / float((sil | gmask).sum())
        src = "gen_hands paint-over: %s" % os.path.basename(painting)
        m = measure_fist(raw)
        wrist, ppu, grip_u = m["wrist"], m["unit"], round(FRONT_SHARE * m["length_u"], 3)
        length_u = m["length_u"]
        wrist_u = round(m["wrist_u"], 3)
    grey = luma(rgb) * 255.0
    # A painted outline is ~1.5% of the fist wide and vanishes at pack size (a fist is
    # 40-80 px there). Re-ink the rim to the weight the race paintings use.
    solid = np.pad(alpha >= 0.5, ((0, 0), (40, 0)), mode="edge").astype(np.uint8)
    rim = cv2.distanceTransform(solid, cv2.DIST_L2, 5)[:, 40:] / ppu
    dark = float(np.percentile(grey[alpha >= 0.9], 1.5))
    ink = np.clip(1.0 - rim / OUTLINE_U, 0.0, 1.0) ** 0.7
    grey = grey * (1.0 - ink) + dark * ink
    # fade the forearm stub out toward the elbow
    xs = (np.arange(W) - wrist[0]) / ppu
    fade = np.clip((xs + STUB) / STUB_FADE, 0.0, 1.0)
    alpha = alpha * fade[None, :]
    k = ART_PPU / ppu
    x0 = max(int(wrist[0] - STUB * ppu), 0)
    ys, xs_ = np.nonzero(alpha > 0.02)
    y0, y1, x1 = max(int(ys.min()) - 4, 0), int(ys.max()) + 5, int(xs_.max()) + 5
    crop = np.dstack([grey, grey, grey, alpha * 255.0])[y0:y1, x0:x1]
    size = (int(round(crop.shape[1] * k)), int(round(crop.shape[0] * k)))
    pm = crop.copy()
    pm[:, :, :3] *= pm[:, :, 3:4] / 255.0
    small = cv2.resize(pm, size, interpolation=cv2.INTER_AREA)
    a = np.maximum(small[:, :, 3:4], 1e-3)
    out = np.dstack([np.clip(small[:, :, :3] * 255.0 / a, 0, 255), np.clip(small[:, :, 3], 0, 255)]).astype(np.uint8)
    os.makedirs(SET_DIR, exist_ok=True)
    Image.fromarray(out, "RGBA").save(os.path.join(SET_DIR, "grip.png"), optimize=True)
    o = ((wrist[0] - x0) * k, (wrist[1] - y0) * k)
    # palm: ly = one palm unit (the half-width), lx = wrist -> knuckle line
    frames = {"palm": core.make_frame(o, ax=(1.0, 0.0), lx=KNUCKLE_SHARE * length_u * ART_PPU, ly=ART_PPU),
              "grip": core.make_frame((o[0] + grip_u * ART_PPU, o[1]), ax=(1.0, 0.0), lx=ART_PPU, ly=ART_PPU)}
    ramp = colour_ramp(out[:, :, :3], out[:, :, 3] > 230)
    data = {"id": "humanoid", "authored_side": "r", "unit": "one palm unit = the hand's half-width",
            "poses": {"grip": {"art": "grip.png", "size": [size[0], size[1]], "frames": frames,
                               "grip_u": grip_u, "wrist_u": wrist_u, "stops": ramp["stops"],
                               "mesh": core.mesh_cells(out[:, :, 3], cells=14),
                               "source": src, "guide_iou": round(iou, 4)}}}
    core.save_json(os.path.join(SET_DIR, "hand.json"), data)
    print("installed %s  (IoU %.3f, %dx%d, stops %s)" % (SET_DIR, iou, size[0], size[1], ramp["stops"]))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["guide", "gen", "check", "install"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("-n", type=int, default=4)
    ap.add_argument("--clay", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "guide":
        save_guide()
        print("wrote", os.path.join(OUT, "guide.png"))
    elif a.cmd == "gen":
        gen(a.arg or "fist", a.n)
    elif a.cmd == "check":
        check(a.arg or "fist")
    else:
        install(None if a.clay else a.arg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
