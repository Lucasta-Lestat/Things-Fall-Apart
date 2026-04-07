#!/usr/bin/env python3
"""Generate 128x128 ability icons for all abilities missing icons."""

import math
import os
from PIL import Image, ImageDraw

SIZE = 128
CENTER = SIZE // 2
RADIUS = 54
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "UI", "UI Icons")


def make_canvas():
    return Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))


def draw_bg_circle(draw, color, outline_color=(30, 30, 30, 255)):
    draw.ellipse(
        [CENTER - RADIUS, CENTER - RADIUS, CENTER + RADIUS, CENTER + RADIUS],
        fill=color, outline=outline_color, width=3
    )


def save_icon(img, name):
    path = os.path.join(OUTPUT_DIR, f"ability_{name}.png")
    img.save(path, "PNG")
    print(f"  Saved {path}")


# ─── Symbol drawing functions ───


def draw_fireball():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (255, 68, 0))
    # Flame: three overlapping teardrops
    flame_color = (255, 221, 0)
    # Main flame
    d.polygon([(64, 28), (82, 72), (64, 92), (46, 72)], fill=flame_color)
    d.ellipse([46, 60, 82, 92], fill=flame_color)
    # Inner bright
    inner = (255, 255, 180)
    d.polygon([(64, 42), (74, 68), (64, 82), (54, 68)], fill=inner)
    d.ellipse([54, 64, 74, 84], fill=inner)
    return img


def draw_cloud_kill():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (68, 170, 34))
    c = (200, 255, 100)
    # Cloud puffs
    d.ellipse([36, 50, 68, 78], fill=c)
    d.ellipse([56, 46, 92, 76], fill=c)
    d.ellipse([42, 62, 86, 90], fill=c)
    # Skull eyes
    dark = (40, 80, 20)
    d.ellipse([50, 58, 60, 68], fill=dark)
    d.ellipse([68, 58, 78, 68], fill=dark)
    # Mouth
    d.line([(56, 78), (72, 78)], fill=dark, width=2)
    d.line([(60, 78), (60, 84)], fill=dark, width=2)
    d.line([(68, 78), (68, 84)], fill=dark, width=2)
    return img


def draw_ice_storm():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (68, 187, 255))
    c = (255, 255, 255)
    cx, cy = CENTER, CENTER
    # Six-armed snowflake
    for angle_deg in range(0, 360, 60):
        a = math.radians(angle_deg)
        x1 = cx + int(30 * math.cos(a))
        y1 = cy + int(30 * math.sin(a))
        d.line([(cx, cy), (x1, y1)], fill=c, width=3)
        # Cross-bars
        perp = a + math.pi / 2
        mx = cx + int(18 * math.cos(a))
        my = cy + int(18 * math.sin(a))
        bx1 = mx + int(8 * math.cos(perp))
        by1 = my + int(8 * math.sin(perp))
        bx2 = mx - int(8 * math.cos(perp))
        by2 = my - int(8 * math.sin(perp))
        d.line([(bx1, by1), (bx2, by2)], fill=c, width=2)
    d.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], fill=c)
    return img


def draw_lightning_bolt():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (255, 221, 0))
    c = (255, 255, 255)
    # Zigzag bolt
    d.polygon([
        (70, 28), (52, 58), (66, 58),
        (48, 98), (82, 62), (66, 62),
        (82, 28)
    ], fill=c, outline=(180, 150, 0), width=2)
    return img


def draw_magnetic_pull():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (119, 68, 204))
    c = (204, 187, 255)
    # Horseshoe magnet
    d.arc([40, 36, 88, 84], 0, 180, fill=c, width=6)
    d.rectangle([40, 58, 52, 88], fill=(255, 60, 60))
    d.rectangle([76, 58, 88, 88], fill=(80, 80, 255))
    # Inward arrows
    d.polygon([(58, 50), (64, 40), (70, 50)], fill=c)
    return img


def draw_repulsion_wave():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (119, 68, 204))
    c = (204, 187, 255)
    # Outward arcs from center
    for r in [14, 24, 34]:
        d.arc([CENTER - r, CENTER - r, CENTER + r, CENTER + r], 200, 340, fill=c, width=3)
    # Arrow tips on outer arc
    d.polygon([(38, 52), (32, 44), (28, 56)], fill=c)
    d.polygon([(90, 52), (96, 44), (100, 56)], fill=c)
    return img


def draw_gravity_well():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (60, 30, 100))
    c = (170, 130, 255)
    # Concentric circles shrinking - funnel effect
    for r in [36, 28, 20, 12]:
        d.ellipse([CENTER - r, CENTER - r + 6, CENTER + r, CENTER + r + 6], outline=c, width=2)
    # Downward arrow in center
    d.polygon([(64, 82), (54, 68), (74, 68)], fill=c)
    d.rectangle([60, 42, 68, 68], fill=c)
    return img


def draw_vortex():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (100, 190, 190))
    c = (255, 255, 255)
    # Spiral arcs
    d.arc([34, 34, 94, 94], 0, 270, fill=c, width=3)
    d.arc([42, 42, 86, 86], 90, 360, fill=c, width=3)
    d.arc([50, 50, 78, 78], 180, 450, fill=c, width=3)
    d.ellipse([58, 58, 70, 70], fill=c)
    return img


def draw_heal():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (34, 204, 68))
    c = (255, 255, 255)
    # Bold plus/cross
    d.rectangle([56, 34, 72, 94], fill=c)
    d.rectangle([36, 54, 92, 72], fill=c)
    return img


def draw_shield_bash():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (170, 136, 68))
    c = (255, 238, 204)
    # Shield shape (pentagon)
    d.polygon([
        (64, 90), (40, 60), (44, 38), (84, 38), (88, 60)
    ], fill=c, outline=(120, 90, 40), width=2)
    # Impact starburst
    star_c = (255, 255, 100)
    for angle_deg in range(0, 360, 45):
        a = math.radians(angle_deg)
        x1 = 78 + int(10 * math.cos(a))
        y1 = 44 + int(10 * math.sin(a))
        d.line([(78, 44), (x1, y1)], fill=star_c, width=2)
    return img


def draw_rage():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (204, 34, 0))
    c = (255, 102, 68)
    # Raised fist
    d.rectangle([50, 44, 78, 72], fill=c)
    d.rounded_rectangle([48, 34, 80, 50], radius=4, fill=c)
    # Knuckle lines
    bright = (255, 180, 140)
    d.rectangle([50, 72, 78, 92], fill=c)
    d.line([(56, 36), (56, 48)], fill=(180, 60, 30), width=2)
    d.line([(64, 36), (64, 48)], fill=(180, 60, 30), width=2)
    d.line([(72, 36), (72, 48)], fill=(180, 60, 30), width=2)
    # Anger lines
    d.line([(34, 36), (46, 42)], fill=bright, width=2)
    d.line([(82, 36), (94, 30)], fill=bright, width=2)
    return img


def draw_creepy_beam():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (68, 34, 102))
    c = (170, 68, 255)
    # Beam widening from left to right
    d.polygon([
        (32, 60), (32, 68),
        (96, 84), (96, 44)
    ], fill=c)
    # Inner bright core
    d.polygon([
        (32, 62), (32, 66),
        (96, 74), (96, 54)
    ], fill=(220, 170, 255))
    # Eye at source
    d.ellipse([28, 56, 42, 72], fill=(200, 100, 255), outline=(40, 20, 60), width=2)
    d.ellipse([32, 60, 38, 68], fill=(255, 255, 255))
    return img


def draw_acid_splash():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (136, 204, 0))
    c = (204, 255, 68)
    # Main droplet
    d.polygon([(64, 32), (78, 64), (64, 80), (50, 64)], fill=c)
    d.ellipse([48, 58, 80, 82], fill=c)
    # Splash drops
    d.ellipse([32, 72, 44, 84], fill=c)
    d.ellipse([84, 68, 94, 78], fill=c)
    d.ellipse([40, 84, 48, 92], fill=c)
    d.ellipse([76, 82, 86, 92], fill=c)
    return img


def draw_thunderwave():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (68, 136, 204))
    c = (170, 221, 255)
    # Sound wave arcs emanating outward
    for r in [16, 28, 40]:
        d.arc([CENTER - r, CENTER - r, CENTER + r, CENTER + r], -40, 40, fill=c, width=4)
    # Source circle
    d.ellipse([CENTER - 8, CENTER - 8, CENTER + 8, CENTER + 8], fill=c)
    return img


def draw_heart(d, cx, cy, size, color):
    """Draw a heart shape centered at (cx, cy)."""
    s = size
    hs = s // 2
    # Two bumps on top, point at bottom
    d.ellipse([cx - s, cy - hs, cx, cy + 2], fill=color)
    d.ellipse([cx, cy - hs, cx + s, cy + 2], fill=color)
    d.polygon([(cx - s, cy), (cx, cy + s), (cx + s, cy)], fill=color)


def draw_beguile():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (255, 68, 170))
    draw_heart(d, CENTER, CENTER, 26, (255, 170, 204))
    return img


def draw_confess():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (255, 68, 170))
    draw_heart(d, CENTER - 16, CENTER, 16, (255, 170, 204))
    draw_heart(d, CENTER + 16, CENTER, 16, (255, 170, 204))
    return img


def draw_hitch():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (255, 68, 170))
    draw_heart(d, CENTER - 18, CENTER - 4, 14, (255, 170, 204))
    draw_heart(d, CENTER + 18, CENTER - 4, 14, (255, 170, 204))
    # Chain link between them
    d.line([(CENTER - 6, CENTER + 4), (CENTER + 6, CENTER + 4)], fill=(255, 220, 240), width=3)
    d.ellipse([CENTER - 8, CENTER, CENTER - 2, CENTER + 8], outline=(255, 220, 240), width=2)
    d.ellipse([CENTER + 2, CENTER, CENTER + 8, CENTER + 8], outline=(255, 220, 240), width=2)
    return img


def draw_fatal_attraction():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (200, 30, 100))
    draw_heart(d, CENTER, CENTER, 26, (255, 100, 150))
    # Crack/break down the middle
    crack = (200, 30, 100)
    d.line([(CENTER, CENTER - 18), (CENTER - 4, CENTER - 6),
            (CENTER + 4, CENTER + 6), (CENTER, CENTER + 22)], fill=crack, width=3)
    # Skull overlay tiny
    d.ellipse([CENTER - 6, CENTER - 8, CENTER + 6, CENTER + 4], fill=(50, 0, 20))
    d.point((CENTER - 3, CENTER - 4), fill=(255, 200, 200))
    d.point((CENTER + 3, CENTER - 4), fill=(255, 200, 200))
    return img


def draw_test_confused():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (204, 136, 68))
    c = (255, 204, 136)
    # Spiral
    d.arc([40, 36, 88, 84], 0, 300, fill=c, width=4)
    d.arc([48, 44, 80, 76], 60, 360, fill=c, width=3)
    # Question mark dot
    d.ellipse([60, 86, 68, 94], fill=c)
    return img


def draw_test_frightened():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (102, 68, 34))
    c = (255, 170, 68)
    # Warning triangle
    d.polygon([(64, 34), (92, 88), (36, 88)], fill=c, outline=(80, 50, 20), width=2)
    # Exclamation mark
    dark = (80, 50, 20)
    d.rectangle([60, 48, 68, 72], fill=dark)
    d.ellipse([60, 76, 68, 84], fill=dark)
    return img


def draw_test_panicked():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (102, 68, 34))
    c = (255, 170, 68)
    # Double exclamation !!
    d.rectangle([48, 36, 56, 72], fill=c)
    d.ellipse([48, 78, 56, 86], fill=c)
    d.rectangle([72, 36, 80, 72], fill=c)
    d.ellipse([72, 78, 80, 86], fill=c)
    # Motion lines
    d.line([(34, 44), (42, 48)], fill=c, width=2)
    d.line([(34, 64), (42, 62)], fill=c, width=2)
    d.line([(86, 44), (94, 40)], fill=c, width=2)
    d.line([(86, 64), (94, 68)], fill=c, width=2)
    return img


def draw_test_sickened():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (136, 136, 34))
    c = (204, 204, 68)
    # Sick face
    d.ellipse([40, 38, 88, 86], fill=c, outline=(100, 100, 20), width=2)
    # X eyes
    dark = (100, 100, 20)
    d.line([(50, 52), (58, 60)], fill=dark, width=3)
    d.line([(58, 52), (50, 60)], fill=dark, width=3)
    d.line([(70, 52), (78, 60)], fill=dark, width=3)
    d.line([(78, 52), (70, 60)], fill=dark, width=3)
    # Wavy mouth
    d.arc([46, 66, 58, 78], 0, 180, fill=dark, width=2)
    d.arc([58, 66, 70, 78], 180, 360, fill=dark, width=2)
    d.arc([70, 66, 82, 78], 0, 180, fill=dark, width=2)
    return img


def draw_test_nauseated():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (136, 136, 34))
    c = (204, 204, 68)
    # Face with green tinge
    green_face = (160, 200, 80)
    d.ellipse([40, 38, 88, 86], fill=green_face, outline=(100, 100, 20), width=2)
    dark = (80, 100, 20)
    # Squeezed-shut eyes
    d.arc([48, 50, 62, 62], 0, 180, fill=dark, width=3)
    d.arc([66, 50, 80, 62], 0, 180, fill=dark, width=3)
    # Open mouth (shocked/retching)
    d.ellipse([54, 68, 74, 82], fill=dark)
    d.ellipse([56, 70, 72, 80], fill=(120, 160, 50))
    return img


def draw_test_animal_magnetism():
    img = make_canvas()
    d = ImageDraw.Draw(img)
    draw_bg_circle(d, (34, 136, 68))
    c = (136, 255, 136)
    # Paw print: 4 small toe circles + 1 larger pad
    d.ellipse([46, 40, 58, 52], fill=c)  # toe 1
    d.ellipse([62, 36, 74, 48], fill=c)  # toe 2
    d.ellipse([76, 42, 88, 54], fill=c)  # toe 3
    d.ellipse([84, 54, 94, 66], fill=c)  # toe 4 (outer)
    # Main pad
    d.ellipse([48, 56, 82, 88], fill=c)
    return img


ABILITY_GENERATORS = {
    "fireball": draw_fireball,
    "cloud_kill": draw_cloud_kill,
    "ice_storm": draw_ice_storm,
    "lightning_bolt": draw_lightning_bolt,
    "magnetic_pull": draw_magnetic_pull,
    "repulsion_wave": draw_repulsion_wave,
    "gravity_well": draw_gravity_well,
    "vortex": draw_vortex,
    "heal": draw_heal,
    "shield_bash": draw_shield_bash,
    "rage": draw_rage,
    "creepy_beam": draw_creepy_beam,
    "acid_splash": draw_acid_splash,
    "thunderwave": draw_thunderwave,
    "beguile": draw_beguile,
    "confess": draw_confess,
    "hitch": draw_hitch,
    "fatal_attraction": draw_fatal_attraction,
    "test_confused": draw_test_confused,
    "test_frightened": draw_test_frightened,
    "test_panicked": draw_test_panicked,
    "test_sickened": draw_test_sickened,
    "test_nauseated": draw_test_nauseated,
    "test_animal_magnetism": draw_test_animal_magnetism,
}


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print(f"Generating {len(ABILITY_GENERATORS)} ability icons to {OUTPUT_DIR}")
    for ability_id, gen_func in ABILITY_GENERATORS.items():
        img = gen_func()
        save_icon(img, ability_id)
    print("Done!")


if __name__ == "__main__":
    main()
