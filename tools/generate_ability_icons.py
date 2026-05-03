"""Generate 10 ability icons in the existing 128x128 RGBA style.

Style observed in tfa-simultaneous-gemini-1/UI/UI Icons:
- 128x128 RGBA, transparent background
- Filled circle (theme color) with thick black outline (~4 px)
- Centered white/light glyph

Run from repo root:
    python tools/generate_ability_icons.py
"""
from __future__ import annotations
import math
import os
from PIL import Image, ImageDraw

OUT_DIR = os.path.join("tfa-simultaneous-gemini-1", "UI", "UI Icons")
SIZE = 128
CENTER = (SIZE / 2, SIZE / 2)
CIRCLE_BBOX = (4, 4, SIZE - 4, SIZE - 4)
OUTLINE = (0, 0, 0, 255)
STROKE = 4


def base_canvas(fill: tuple[int, int, int, int]) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse(CIRCLE_BBOX, fill=fill, outline=OUTLINE, width=STROKE)
    return img, d


def teardrop(d: ImageDraw.ImageDraw, cx: float, cy: float, w: float, h: float, fill, outline=OUTLINE, ow=2) -> None:
    """Draw a teardrop pointing up (rounded bottom, pointed top) centered at (cx,cy)."""
    points = []
    # Top point
    points.append((cx, cy - h / 2))
    # Right curve
    for a in range(-70, 271, 10):
        rad = math.radians(a)
        x = cx + (w / 2) * math.sin(rad)
        y = cy + (h / 2) * (0.4 + 0.6 * math.cos(rad))
        # only keep lower 270deg arc
        if a >= -70 and a <= 270:
            points.append((x, y))
    d.polygon(points, fill=fill, outline=outline)


def droplet(d: ImageDraw.ImageDraw, cx: float, cy: float, w: float, h: float, fill, outline=OUTLINE, ow=2) -> None:
    """A simple raindrop: pointed top, rounded bottom, drawn as a polygon-ish shape."""
    pts = []
    # build a teardrop using parametric
    steps = 36
    for i in range(steps + 1):
        t = i / steps
        ang = 2 * math.pi * t
        # use a teardrop curve: x = sin(t), y = cos(t)*(1-cos(t))/2 mapped
        x = math.sin(ang)
        y = -math.cos(ang) * (1 - 0.5 * (1 - math.cos(ang)))
        pts.append((cx + x * w / 2, cy + y * h / 2))
    d.polygon(pts, fill=fill, outline=outline)


def write_icon(img: Image.Image, name: str) -> None:
    out = os.path.join(OUT_DIR, f"ability_{name}.png")
    img.save(out, "PNG")
    print(f"  wrote {out}")


# -----------------------------
# bide — defensive buff (timed). Brown/gold background, white shield with a clock dot.
# -----------------------------
def make_bide() -> Image.Image:
    img, d = base_canvas((180, 140, 70, 255))
    # shield outline
    shield = [
        (64, 30), (96, 42), (96, 70), (64, 100), (32, 70), (32, 42)
    ]
    d.polygon(shield, fill=(245, 240, 220, 255), outline=OUTLINE)
    d.line([(64, 30), (64, 100)], fill=OUTLINE, width=2)
    # small clock-pip (delayed motif) at top-right corner of shield
    d.ellipse((84, 32, 104, 52), fill=(245, 240, 220, 255), outline=OUTLINE, width=2)
    d.line([(94, 36), (94, 42), (98, 46)], fill=OUTLINE, width=2)
    return img


# -----------------------------
# rain — weather, blue, falling drops
# -----------------------------
def make_rain() -> Image.Image:
    img, d = base_canvas((90, 150, 210, 255))
    # cloud silhouette
    cloud = [
        (28, 70), (28, 56), (38, 46), (52, 44), (60, 36), (76, 36), (88, 46), (100, 50), (100, 70)
    ]
    d.polygon(cloud, fill=(245, 245, 245, 255), outline=OUTLINE)
    d.ellipse((22, 50, 50, 76), fill=(245, 245, 245, 255), outline=OUTLINE, width=2)
    d.ellipse((44, 38, 80, 76), fill=(245, 245, 245, 255), outline=OUTLINE, width=2)
    d.ellipse((78, 46, 108, 76), fill=(245, 245, 245, 255), outline=OUTLINE, width=2)
    # raindrops (3)
    for cx in (44, 64, 84):
        droplet(d, cx, 96, 12, 22, (220, 240, 255, 255))
    return img


# -----------------------------
# acid_rain — sickly green, falling acid drops with corrosion bubbles
# -----------------------------
def make_acid_rain() -> Image.Image:
    img, d = base_canvas((140, 180, 50, 255))
    # cloud
    d.ellipse((22, 46, 52, 74), fill=(110, 80, 30, 255), outline=OUTLINE, width=2)
    d.ellipse((42, 36, 86, 76), fill=(110, 80, 30, 255), outline=OUTLINE, width=2)
    d.ellipse((76, 44, 108, 74), fill=(110, 80, 30, 255), outline=OUTLINE, width=2)
    # acid drops (yellow-green)
    for cx in (44, 64, 84):
        droplet(d, cx, 96, 11, 20, (220, 240, 110, 255))
    # bubble dots
    for (cx, cy, r) in [(38, 110, 3), (90, 110, 4), (60, 116, 3)]:
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(220, 240, 110, 255), outline=OUTLINE, width=1)
    return img


# -----------------------------
# freezing_rain — light cyan, sleet/icicle slashes
# -----------------------------
def make_freezing_rain() -> Image.Image:
    img, d = base_canvas((150, 210, 230, 255))
    # cloud (gray)
    d.ellipse((22, 42, 52, 72), fill=(220, 230, 240, 255), outline=OUTLINE, width=2)
    d.ellipse((42, 32, 86, 72), fill=(220, 230, 240, 255), outline=OUTLINE, width=2)
    d.ellipse((76, 40, 108, 72), fill=(220, 230, 240, 255), outline=OUTLINE, width=2)
    # icicle slashes (diagonal)
    for cx in (44, 64, 84):
        d.line([(cx - 4, 80), (cx + 4, 110)], fill=(255, 255, 255, 255), width=4)
        d.line([(cx - 4, 80), (cx + 4, 110)], fill=OUTLINE, width=1)
    # snowflake glints
    for (cx, cy) in [(32, 102), (96, 100)]:
        d.line([(cx - 3, cy), (cx + 3, cy)], fill=(255, 255, 255, 255), width=2)
        d.line([(cx, cy - 3), (cx, cy + 3)], fill=(255, 255, 255, 255), width=2)
    return img


# -----------------------------
# wave_of_dysthymia — apathy cone, gray-violet, downward droopy waves
# -----------------------------
def make_wave_of_dysthymia() -> Image.Image:
    img, d = base_canvas((110, 100, 130, 255))
    # downward wave lines (3 stacked)
    for i, y0 in enumerate([42, 66, 90]):
        pts = []
        for x in range(20, 109, 4):
            t = (x - 20) / 88
            y = y0 + 6 * math.sin(t * math.pi * 2 + i)
            # droop progressively
            y += i * 2
            pts.append((x, y))
        d.line(pts, fill=(225, 220, 235, 255), width=4)
        d.line(pts, fill=OUTLINE, width=1)
    # downward arrow pip
    d.polygon([(60, 102), (68, 102), (64, 110)], fill=(225, 220, 235, 255), outline=OUTLINE)
    return img


# -----------------------------
# deny_ending — refuse death; white/gold, ankh-cross with red bar/no-symbol
# -----------------------------
def make_deny_ending() -> Image.Image:
    img, d = base_canvas((240, 220, 130, 255))
    # ankh: oval + cross
    d.ellipse((52, 26, 76, 54), fill=None, outline=(245, 245, 245, 255), width=6)
    d.ellipse((52, 26, 76, 54), outline=OUTLINE, width=2)
    # vertical bar
    d.rectangle((60, 50, 68, 100), fill=(245, 245, 245, 255), outline=OUTLINE, width=2)
    # cross bar
    d.rectangle((44, 60, 84, 70), fill=(245, 245, 245, 255), outline=OUTLINE, width=2)
    # red "no" diagonal across the bottom (denial)
    d.line([(28, 110), (100, 38)], fill=(200, 40, 40, 255), width=6)
    d.line([(28, 110), (100, 38)], fill=OUTLINE, width=1)
    return img


# -----------------------------
# psych_up — copy/buff, blue-purple, up-arrow with double sparkle
# -----------------------------
def make_psych_up() -> Image.Image:
    img, d = base_canvas((110, 130, 210, 255))
    # up arrow (chunky)
    d.polygon([(64, 24), (92, 56), (76, 56), (76, 100), (52, 100), (52, 56), (36, 56)],
              fill=(245, 245, 250, 255), outline=OUTLINE)
    # second smaller up arrow behind (offset, indicates double/copy)
    d.polygon([(96, 70), (110, 86), (102, 86), (102, 108), (90, 108), (90, 86), (82, 86)],
              fill=(200, 215, 245, 255), outline=OUTLINE)
    # spark
    cx, cy = 30, 38
    for dx, dy in [(-6, 0), (6, 0), (0, -6), (0, 6)]:
        d.line([(cx, cy), (cx + dx, cy + dy)], fill=(255, 255, 255, 255), width=2)
    return img


# -----------------------------
# fire_spin — fire AoE wreathing, red-orange with swirling flame
# -----------------------------
def make_fire_spin() -> Image.Image:
    img, d = base_canvas((220, 60, 30, 255))
    # spiral flame: a teardrop + curl
    flame = [
        (64, 20), (82, 36), (90, 60), (84, 84), (64, 100), (44, 84), (38, 60), (46, 36)
    ]
    d.polygon(flame, fill=(255, 200, 60, 255), outline=OUTLINE)
    # inner curl
    d.arc((46, 48, 82, 92), start=0, end=270, fill=(255, 110, 40, 255), width=6)
    d.arc((46, 48, 82, 92), start=0, end=270, fill=OUTLINE, width=1)
    # tip highlight
    d.polygon([(64, 28), (74, 48), (54, 48)], fill=(255, 240, 160, 255), outline=OUTLINE)
    return img


# -----------------------------
# bumper_crop — nature/grass, green, wheat-like bundle
# -----------------------------
def make_bumper_crop() -> Image.Image:
    img, d = base_canvas((90, 170, 80, 255))
    # central stalk
    d.line([(64, 30), (64, 110)], fill=(220, 180, 90, 255), width=4)
    d.line([(64, 30), (64, 110)], fill=OUTLINE, width=1)
    # wheat/leaves on each side, paired
    for y in (48, 64, 80):
        # left leaf
        d.polygon([(64, y), (40, y - 10), (44, y), (40, y + 8)], fill=(220, 200, 100, 255), outline=OUTLINE)
        # right leaf
        d.polygon([(64, y), (88, y - 10), (84, y), (88, y + 8)], fill=(220, 200, 100, 255), outline=OUTLINE)
    # top tuft
    d.polygon([(64, 22), (54, 36), (64, 30), (74, 36)], fill=(245, 220, 120, 255), outline=OUTLINE)
    return img


# -----------------------------
# alms_of_the_vein — necrotic/drain. Dark red bg, blood drop with thin vein lines
# -----------------------------
def make_alms_of_the_vein() -> Image.Image:
    img, d = base_canvas((110, 30, 40, 255))
    # large blood drop
    droplet(d, 64, 68, 40, 60, (220, 50, 60, 255))
    # highlight stripe
    d.line([(58, 56), (58, 78)], fill=(255, 200, 200, 200), width=3)
    # vein branches
    for (x0, y0, x1, y1) in [(36, 100, 50, 92), (50, 92, 46, 102), (92, 100, 78, 92), (78, 92, 82, 102)]:
        d.line([(x0, y0), (x1, y1)], fill=(80, 10, 20, 255), width=3)
    return img


GENERATORS = {
    "bide": make_bide,
    "rain": make_rain,
    "acid_rain": make_acid_rain,
    "freezing_rain": make_freezing_rain,
    "wave_of_dysthymia": make_wave_of_dysthymia,
    "deny_ending": make_deny_ending,
    "psych_up": make_psych_up,
    "fire_spin": make_fire_spin,
    "bumper_crop": make_bumper_crop,
    "alms_of_the_vein": make_alms_of_the_vein,
}


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, fn in GENERATORS.items():
        img = fn()
        write_icon(img, name)


if __name__ == "__main__":
    main()
