"""Draw the condition icons that were never authored.

Seven conditions shipped pointing at unrelated art (`stunned.png` alone was doing
duty for eleven of them), so a shocked, invisible or apathetic character all
showed the same "stunned" pip. This draws one icon each, in the same flat style
as the reworked set: a full-frame colour disc, transparent corners, one cream
glyph, no shading beyond a single flat accent.

Drawn rather than model-generated for the same reason as bleeding.png: the family
is flat vector shapes with a single cream fill, which raster models reproduce
inconsistently at 256px, and consistency across the pip row matters more than
individual flourish.

Disc hues follow the existing set's semantics:
  yellow-olive  electric / light      (cond_pox, cond_scarred)
  purple        mental / magical      (cond_haunted, cond_mania)
  blue          cold / concealment    (ability_ice_storm)
  slate         inert / metal         (new, closest to cond_the_jaws_that_bite)

Usage:
    python tools/make_condition_icons.py            # write all
    python tools/make_condition_icons.py --only shocked,invisible
    python tools/make_condition_icons.py --sheet out.png   # contact sheet only
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw

OUT_DIR = Path("tfa-simultaneous-gemini-1") / "UI" / "UI Icons"
SIZE = 256
SS = 4

CREAM = (241, 237, 225, 255)

DISC = {
    "shocked": (206, 190, 74),       # electric yellow-olive, sibling of cond_pox
    "infatuated": (168, 140, 196),   # mental purple
    "invisible": (129, 171, 214),    # concealment blue
    "illuminated": (222, 196, 96),   # light, warmer than shocked
    "inking": (92, 92, 104),         # ink slate
    "metallacized": (150, 156, 166), # chrome
    "apathetic": (140, 132, 156),    # drained, desaturated purple
}


def _poly(d, pts, fill):
    d.polygon(pts, fill=fill)


def draw_shocked(d, n, c, r):
    """A jagged bolt, thicker than ability_lightning_bolt's so it reads at 32px."""
    s = n * 0.30
    pts = [
        (c - s * 0.10, c - s * 1.05), (c + s * 0.72, c - s * 1.05),
        (c + s * 0.10, c - s * 0.16), (c + s * 0.62, c - s * 0.16),
        (c - s * 0.36, c + s * 1.10), (c + s * 0.02, c + s * 0.16),
        (c - s * 0.52, c + s * 0.16),
    ]
    _poly(d, pts, CREAM)


def _heart(d, cx, cy, size, fill):
    """The standard parametric heart. Built from the curve rather than from two
    circles plus a triangle: at this scale the circle-and-triangle construction
    needs its lobe spacing tuned by hand against the lobe radius, and getting it
    slightly wrong produces a blob with a spike rather than a heart."""
    pts = []
    steps = 96
    for i in range(steps):
        t = (i / steps) * 2.0 * math.pi
        x = 16.0 * (math.sin(t) ** 3)
        y = (13.0 * math.cos(t) - 5.0 * math.cos(2 * t)
             - 2.0 * math.cos(3 * t) - math.cos(4 * t))
        # curve spans roughly x in [-16,16], y in [-17,13]; y is flipped because
        # screen Y grows downward.
        pts.append((cx + x * size / 32.0, cy - y * size / 32.0))
    d.polygon(pts, fill=fill)


def draw_infatuated(d, n, c, r):
    """A large heart with a smaller one trailing it — charm. Deliberately not the
    healing cross (ability_heal) and not the skull-in-heart (fatal_attraction)."""
    _heart(d, c - n * 0.04, c - n * 0.03, n * 0.62, CREAM)
    _heart(d, c + n * 0.24, c + n * 0.22, n * 0.26, CREAM)


def draw_invisible(d, n, c, r):
    """An eye with a slash — the established 'cannot be seen' mark. Reuses
    cond_perceptive's eye silhouette so the pair reads as opposites."""
    w, h = n * 0.36, n * 0.20
    d.ellipse([c - w, c - h, c + w, c + h], fill=CREAM)
    d.ellipse([c - h * 0.62, c - h * 0.62, c + h * 0.62, c + h * 0.62], fill=DISC["invisible"] + (255,))
    # slash, with a disc-coloured shadow so it reads as cutting THROUGH the eye
    off = n * 0.055
    d.line([(c - n * 0.34 + off, c + n * 0.30 + off), (c + n * 0.34 + off, c - n * 0.30 + off)],
           fill=DISC["invisible"] + (255,), width=int(n * 0.11))
    d.line([(c - n * 0.34, c + n * 0.30), (c + n * 0.34, c - n * 0.30)],
           fill=CREAM, width=int(n * 0.075))


def draw_illuminated(d, n, c, r):
    """A brand: a filled dot inside a ring, throwing rays — a MARK that emits
    light, distinct from cond_blessed's plain sunburst."""
    d.ellipse([c - n * 0.17, c - n * 0.17, c + n * 0.17, c + n * 0.17], fill=CREAM)
    d.ellipse([c - n * 0.09, c - n * 0.09, c + n * 0.09, c + n * 0.09],
              fill=DISC["illuminated"] + (255,))
    for i in range(8):
        a = i * math.pi / 4.0
        x0, y0 = c + math.cos(a) * n * 0.24, c + math.sin(a) * n * 0.24
        x1, y1 = c + math.cos(a) * n * 0.40, c + math.sin(a) * n * 0.40
        d.line([(x0, y0), (x1, y1)], fill=CREAM, width=int(n * 0.055))


def draw_inking(d, n, c, r):
    """A falling ink drop over a spreading pool — the condition is ink running
    from the blade and pooling underfoot."""
    # pool
    d.ellipse([c - n * 0.34, c + n * 0.14, c + n * 0.34, c + n * 0.36], fill=CREAM)
    # splash lobes
    d.ellipse([c - n * 0.42, c + n * 0.20, c - n * 0.24, c + n * 0.33], fill=CREAM)
    d.ellipse([c + n * 0.24, c + n * 0.18, c + n * 0.44, c + n * 0.32], fill=CREAM)
    # falling drop (teardrop: bulb + tapered shoulders)
    bulb_r = n * 0.115
    bulb_cy = c - n * 0.06
    tip_y = c - n * 0.40
    span = bulb_cy - tip_y
    a = math.asin(bulb_r / span)
    tx = bulb_r * math.cos(a)
    ty = bulb_cy - bulb_r * math.sin(a)
    _poly(d, [(c, tip_y), (c - tx, ty), (c + tx, ty)], CREAM)
    d.ellipse([c - bulb_r, bulb_cy - bulb_r, c + bulb_r, bulb_cy + bulb_r], fill=CREAM)


def draw_metallacized(d, n, c, r):
    """Overlapping plates — a shell of chrome layers. Each layer slows you, so the
    glyph is literally stacked layers."""
    for i, dy in enumerate((-0.20, 0.0, 0.20)):
        y = c + n * dy
        wide = n * (0.34 - abs(dy) * 0.28)
        d.rounded_rectangle(
            [c - wide, y - n * 0.075, c + wide, y + n * 0.075],
            radius=n * 0.045, fill=CREAM,
        )
        d.rounded_rectangle(
            [c - wide + n * 0.03, y - n * 0.075 + n * 0.022,
             c + wide - n * 0.03, y + n * 0.075 - n * 0.045],
            radius=n * 0.02, fill=DISC["metallacized"] + (255,),
        )


def draw_apathetic(d, n, c, r):
    """A downturned face with heavy-lidded eyes: cannot act, only shuffle."""
    d.ellipse([c - n * 0.30, c - n * 0.30, c + n * 0.30, c + n * 0.30], fill=CREAM)
    eye_y = c - n * 0.07
    for dx in (-n * 0.125, n * 0.125):
        # half-lidded: a bar rather than a dot
        d.rounded_rectangle(
            [c + dx - n * 0.075, eye_y - n * 0.030, c + dx + n * 0.075, eye_y + n * 0.030],
            radius=n * 0.028, fill=DISC["apathetic"] + (255,),
        )
    # flat, faintly downturned mouth
    d.arc([c - n * 0.16, c + n * 0.04, c + n * 0.16, c + n * 0.26], 200, 340,
          fill=DISC["apathetic"] + (255,), width=int(n * 0.045))


DRAW = {
    "shocked": draw_shocked,
    "infatuated": draw_infatuated,
    "invisible": draw_invisible,
    "illuminated": draw_illuminated,
    "inking": draw_inking,
    "metallacized": draw_metallacized,
    "apathetic": draw_apathetic,
}


def build(name: str) -> Image.Image:
    n = SIZE * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, n - 1, n - 1], fill=DISC[name] + (255,))
    DRAW[name](d, n, n / 2.0, n / 2.0)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--sheet", default="")
    args = ap.parse_args()
    names = [s.strip() for s in args.only.split(",") if s.strip()] or list(DRAW)

    made = []
    for name in names:
        img = build(name)
        made.append((name, img))
        if not args.sheet:
            path = OUT_DIR / f"{name}.png"
            img.save(path)
            print(f"wrote {path}")

    if args.sheet:
        CELL = 150
        sh = Image.new("RGBA", (CELL * len(made), CELL + 26), (58, 58, 64, 255))
        d = ImageDraw.Draw(sh)
        for i, (name, img) in enumerate(made):
            t = img.copy()
            t.thumbnail((CELL - 16, CELL - 16))
            sh.alpha_composite(t, (i * CELL + 8, 8))
            d.text((i * CELL + 6, CELL + 6), name[:18], fill=(255, 255, 255, 255))
        sh.save(args.sheet)
        print(f"sheet -> {args.sheet}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
