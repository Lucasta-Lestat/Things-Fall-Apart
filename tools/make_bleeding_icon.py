"""Draw the missing `bleeding` condition icon.

The bleeding condition had no art of its own and was pointed at
`UI Icons/weakened.png` (a flexed bicep), so a bleeding character showed a
"weak" pip. This draws a matching icon in the same flat style as the rest of the
reworked set: a full-frame colour disc, transparent corners, a cream glyph
occupying roughly the same share of the disc as its neighbours.

Deliberately drawn rather than generated: the icon family is flat vector-style
shapes with one cream fill and no shading, which a raster image model reproduces
inconsistently. Palette is sampled from the existing icons (ability_rage's
salmon-red is the family's "hostile red"; the cream is the shared glyph fill).

Usage:
    python tools/make_bleeding_icon.py
"""
from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path("tfa-simultaneous-gemini-1") / "UI" / "UI Icons" / "bleeding.png"
SIZE = 256
SS = 4  # supersample, then downsample once for clean curves

# Sampled from the existing family.
CREAM = (241, 237, 225, 255)
# A deeper, more clotted red than ability_rage's (232,129,112) so "bleeding"
# reads as an injury rather than as anger, while staying in the same palette.
DISC = (198, 92, 84, 255)
SHADOW = (170, 72, 66, 255)  # subtle inner depth on the droplet


def droplet(d: ImageDraw.ImageDraw, cx: float, cy: float, h: float, fill) -> None:
    """A classic teardrop: circular bulb at the bottom, straight shoulders
    tapering to a point at the top."""
    r = h * 0.34            # bulb radius
    bulb_cy = cy + h * 0.5 - r
    tip_y = cy - h * 0.5
    # Tangent point where the straight sides meet the bulb: for a tip on the
    # bulb's vertical axis at distance L above the centre, the tangent is at
    # angle asin(r / L) off vertical.
    span = bulb_cy - tip_y
    if span <= r:
        d.ellipse([cx - r, bulb_cy - r, cx + r, bulb_cy + r], fill=fill)
        return
    a = math.asin(r / span)
    tx = r * math.cos(a)
    ty = bulb_cy - r * math.sin(a)
    d.polygon([(cx, tip_y), (cx - tx, ty), (cx + tx, ty)], fill=fill)
    d.ellipse([cx - r, bulb_cy - r, cx + r, bulb_cy + r], fill=fill)


def main() -> int:
    n = SIZE * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, n - 1, n - 1], fill=DISC)

    c = n / 2.0
    # One dominant droplet slightly above centre, with two smaller falling drops
    # offset below — reads as "bleeding" (ongoing) rather than "a drop of blood".
    droplet(d, c, c - n * 0.045, n * 0.52, CREAM)
    droplet(d, c - n * 0.215, c + n * 0.235, n * 0.20, CREAM)
    droplet(d, c + n * 0.205, c + n * 0.275, n * 0.145, CREAM)

    # A small crescent inside the main bulb, in the disc colour, gives the flat
    # shape the same hint of volume the other icons have.
    r = n * 0.52 * 0.34
    bulb_cy = (c - n * 0.045) + n * 0.52 * 0.5 - r
    d.ellipse(
        [c - r * 0.52, bulb_cy - r * 0.60, c + r * 0.78, bulb_cy + r * 0.62],
        fill=SHADOW,
    )
    d.ellipse(
        [c - r * 0.90, bulb_cy - r * 0.86, c + r * 0.52, bulb_cy + r * 0.44],
        fill=CREAM,
    )

    img.resize((SIZE, SIZE), Image.LANCZOS).save(OUT)
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
