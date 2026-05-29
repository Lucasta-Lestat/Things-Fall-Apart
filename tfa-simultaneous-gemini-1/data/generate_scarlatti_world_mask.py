"""Generate a placeholder terrain mask for Maps/Scarlatti World Map.png.

The world map's MapLoader (world_map_mode = true) reads a color mask to
decide each tile's terrain. This script makes a first-pass mask by
classifying every pixel of the source image into one of the world-map
palette colors based on simple HSV/RGB heuristics:

  blue-ish        -> water     (40, 90, 200)
  saturated red   -> city      (220, 60, 40)
  dark green      -> forest    (20, 100, 30)
  bright green    -> plains    (170, 220, 90)
  golden/tan      -> farm      (210, 180, 90)
  desaturated     -> mountain  (110, 85, 60)
  otherwise       -> plains    (default)

Run from the project root or this script's folder:
    python data/generate_scarlatti_world_mask.py

Re-run after editing Scarlatti World Map.png to refresh the mask. Tweak
the mask in an image editor afterward — the palette is documented in
Structures/MapLoader.gd (color_to_world_floor).
"""

from __future__ import annotations

import colorsys
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow is required. Install with: pip install Pillow", file=sys.stderr)
    raise SystemExit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
MAPS_DIR = PROJECT_ROOT / "Maps"

SOURCE = MAPS_DIR / "Scarlatti World Map (3).png"
MASK_OUT = MAPS_DIR / "scarlatti_world_mask.png"

# Palette must match MapLoader.gd's color_to_world_floor exactly.
COLOR_PLAINS = (170, 220, 90, 255)
COLOR_FOREST = (20, 100, 30, 255)
COLOR_MOUNTAIN = (110, 85, 60, 255)
COLOR_WATER = (40, 90, 200, 255)
COLOR_CITY = (220, 60, 40, 255)
COLOR_FARM = (210, 180, 90, 255)


def classify(r: int, g: int, b: int) -> tuple[int, int, int, int]:
    """Map a source pixel to a world-terrain palette color."""
    h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
    hue_deg = h * 360.0

    # Water: blue-dominant pixels.
    if b > 110 and b > r + 20 and b > g + 10:
        return COLOR_WATER

    # City markers: saturated red/orange dots painted by the map artist.
    if r > 170 and r > g + 40 and r > b + 40 and s > 0.4:
        return COLOR_CITY

    # Mountains: low-saturation gray/brown.
    if s < 0.22 and v > 0.25:
        return COLOR_MOUNTAIN

    # Farmland: warm yellow/tan band.
    if 35 <= hue_deg <= 60 and s > 0.25 and v > 0.5:
        return COLOR_FARM

    # Forest: dark green.
    if 70 <= hue_deg <= 160 and s > 0.25 and v < 0.55:
        return COLOR_FOREST

    # Bright green -> plains.
    if 60 <= hue_deg <= 170 and s > 0.15:
        return COLOR_PLAINS

    # Fallback.
    return COLOR_PLAINS


def main() -> int:
    if not SOURCE.exists():
        print(f"ERROR: source image not found at {SOURCE}", file=sys.stderr)
        print("Drop the world-map PNG at that path and re-run.", file=sys.stderr)
        return 1

    src = Image.open(SOURCE).convert("RGBA")
    w, h = src.size
    pixels = src.load()
    out = Image.new("RGBA", (w, h))
    out_px = out.load()

    counts: dict[tuple[int, int, int, int], int] = {}
    for y in range(h):
        for x in range(w):
            r, g, b, _a = pixels[x, y]
            c = classify(r, g, b)
            out_px[x, y] = c
            counts[c] = counts.get(c, 0) + 1

    out.save(MASK_OUT)

    total = w * h
    print(f"Source:    {SOURCE} ({w}x{h})")
    print(f"Mask out:  {MASK_OUT}")
    name_for = {
        COLOR_PLAINS: "plains",
        COLOR_FOREST: "forest",
        COLOR_MOUNTAIN: "mountain",
        COLOR_WATER: "water",
        COLOR_CITY: "city",
        COLOR_FARM: "farm",
    }
    for color, count in sorted(counts.items(), key=lambda kv: -kv[1]):
        label = name_for.get(color, str(color))
        print(f"  {label:<10} {count:>10,} px ({count/total:.1%})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
