"""Generate the floor and structure color masks for Maps/Colosseum.png.

The mask palette must match MapLoader.gd's color_to_floor / color_to_structure
dicts (anti-aliased pixels are tolerated up to color_tolerance = 0.15):

  Floor mask (Colosseum_mask.png):
    (192,192,192) light gray  -> stone_stairs (stadium seating ring)
    (139, 69, 19) brown       -> floor_dirt   (sandy arena)
    transparent               -> no floor     (red corner banners, outside)

  Structures mask (Colosseum_structures_mask.png):
    (128,128,128) mid gray    -> stone_wall   (the central spina)
    transparent               -> no structure

Run from the project root or this script's folder:
    python data/generate_colosseum_mask.py
Tweak geometry without editing code:
    python data/generate_colosseum_mask.py --arena-rx 530 --arena-ry 310 \
        --outer-rx 720 --outer-ry 480 --wall-x0 483 --wall-x1 1049 \
        --wall-y0 493 --wall-y1 520
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# Resolve paths relative to this script so it works from any cwd.
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent  # tfa-simultaneous-gemini-1/
MAPS_DIR = PROJECT_ROOT / "Maps"

SOURCE = MAPS_DIR / "Colosseum.png"
FLOOR_MASK = MAPS_DIR / "Colosseum_mask.png"
STRUCT_MASK = MAPS_DIR / "Colosseum_structures_mask.png"
DEBUG_OVERLAY = MAPS_DIR / "Colosseum_mask_debug.png"

COLOR_DIRT = (139, 69, 19, 255)
COLOR_STAIRS = (192, 192, 192, 255)
COLOR_WALL = (128, 128, 128, 255)
TRANSPARENT = (0, 0, 0, 0)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    # Defaults tuned for the 1536x1024 Colosseum.png. See the analysis in
    # the plan: the stadium ellipse hugs the image edges (corners stay red),
    # the arena ellipse covers the sandy oval, and the spina is the bright
    # cream rectangle whose bright top spans roughly x=[483,1049], y=[498,513].
    p.add_argument("--cx", type=int, default=None, help="center x (default: image center)")
    p.add_argument("--cy", type=int, default=None, help="center y (default: image center)")
    p.add_argument("--outer-rx", type=int, default=720, help="stadium semi-axis x")
    p.add_argument("--outer-ry", type=int, default=480, help="stadium semi-axis y")
    p.add_argument("--arena-rx", type=int, default=530, help="arena semi-axis x")
    p.add_argument("--arena-ry", type=int, default=310, help="arena semi-axis y")
    p.add_argument("--wall-x0", type=int, default=483)
    p.add_argument("--wall-x1", type=int, default=1049)
    p.add_argument("--wall-y0", type=int, default=493)
    p.add_argument("--wall-y1", type=int, default=520)
    p.add_argument("--no-debug", action="store_true", help="skip writing the debug overlay")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    if not SOURCE.exists():
        print(f"ERROR: source image not found at {SOURCE}", file=sys.stderr)
        return 1

    src = Image.open(SOURCE).convert("RGBA")
    W, H = src.size
    cx = args.cx if args.cx is not None else W // 2
    cy = args.cy if args.cy is not None else H // 2

    # --- Floor mask: outer stairs ellipse, arena ellipse painted on top.
    floor = Image.new("RGBA", (W, H), TRANSPARENT)
    fd = ImageDraw.Draw(floor)
    fd.ellipse(
        [cx - args.outer_rx, cy - args.outer_ry, cx + args.outer_rx, cy + args.outer_ry],
        fill=COLOR_STAIRS,
    )
    fd.ellipse(
        [cx - args.arena_rx, cy - args.arena_ry, cx + args.arena_rx, cy + args.arena_ry],
        fill=COLOR_DIRT,
    )
    floor.save(FLOOR_MASK)

    # --- Structures mask: just the spina rectangle.
    structs = Image.new("RGBA", (W, H), TRANSPARENT)
    sd = ImageDraw.Draw(structs)
    sd.rectangle([args.wall_x0, args.wall_y0, args.wall_x1, args.wall_y1], fill=COLOR_WALL)
    structs.save(STRUCT_MASK)

    # --- Pixel-count summary so the user can spot-check.
    import numpy as np

    fa = np.array(floor)
    sa = np.array(structs)
    stairs_px = int(((fa[:, :, 0] == 192) & (fa[:, :, 1] == 192)).sum())
    dirt_px = int(((fa[:, :, 0] == 139) & (fa[:, :, 1] == 69)).sum())
    wall_px = int(((sa[:, :, 0] == 128) & (sa[:, :, 3] == 255)).sum())
    total = W * H
    print(f"Source:           {SOURCE} ({W}x{H})")
    print(f"Floor mask:       {FLOOR_MASK}")
    print(f"  stone_stairs    {stairs_px:>10,} px  ({stairs_px/total:.1%})")
    print(f"  floor_dirt      {dirt_px:>10,} px  ({dirt_px/total:.1%})")
    print(f"  transparent     {total - stairs_px - dirt_px:>10,} px")
    print(f"Structures mask:  {STRUCT_MASK}")
    print(f"  stone_wall      {wall_px:>10,} px")

    # --- Debug overlay: blend the floor mask at 50% over the source so the
    # user can eyeball alignment. Filled regions show through tinted; the
    # red banners and stone wall area should remain untinted.
    if not args.no_debug:
        overlay = Image.alpha_composite(src, Image.eval(floor, lambda v: v // 2 if v < 255 else 128))
        # Image.eval halves alpha so the source still shows through.
        # Above is a touch awkward; redo with a clean half-alpha copy:
        ov_floor = floor.copy()
        a = ov_floor.split()[3].point(lambda v: v // 2)
        ov_floor.putalpha(a)
        overlay = Image.alpha_composite(src, ov_floor)
        # Outline the structure rectangle in bright magenta for visibility.
        od = ImageDraw.Draw(overlay)
        od.rectangle(
            [args.wall_x0, args.wall_y0, args.wall_x1, args.wall_y1],
            outline=(255, 0, 255, 255),
            width=3,
        )
        overlay.save(DEBUG_OVERLAY)
        print(f"Debug overlay:    {DEBUG_OVERLAY}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
