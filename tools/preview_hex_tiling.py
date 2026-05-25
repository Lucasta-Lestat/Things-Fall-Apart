"""Composite a scene's carved hex tiles back together in a staggered grid.

Useful sanity check: if the carved hexes were extracted correctly, re-assembling
them at their original positions should reproduce (close to) the source image
without visible seams.

Usage:
    python tools/preview_hex_tiling.py --scene forest_summer
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image

OUT_ROOT = Path("tfa-simultaneous-gemini-1") / "Assets" / "HexTiles"
HEX_WIDTH = 384


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", required=True)
    ap.add_argument("--hex-width", type=int, default=HEX_WIDTH)
    args = ap.parse_args()

    W = args.hex_width
    H = int(round(W * math.sqrt(3) / 2))
    col_pitch = 3 * W / 4
    row_pitch = H

    scene_dir = OUT_ROOT / args.scene
    files = sorted(scene_dir.glob(f"{args.scene}_c*_r*.png"))
    if not files:
        print(f"No carved hexes found in {scene_dir}")
        return 1

    # Find grid extent
    coords = []
    for f in files:
        # filename: {scene}_c{col}_r{row}.png
        stem = f.stem.removeprefix(f"{args.scene}_")
        col_s, row_s = stem.split("_")
        col = int(col_s[1:])
        row = int(row_s[1:])
        coords.append((col, row, f))
    max_col = max(c for c, _, _ in coords)
    max_row = max(r for _, r, _ in coords)

    # Composite canvas size matches the source grid extent
    canvas_w = int((W / 2) + (max_col + 1) * col_pitch + W / 2)
    canvas_h = int((H / 2) + (max_row + 1) * row_pitch + H / 2)
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (255, 255, 255, 0))

    for col, row, f in coords:
        cx = (W / 2) + col * col_pitch
        y_offset = (row_pitch / 2) if (col % 2 == 1) else 0
        cy = (H / 2) + y_offset + row * row_pitch
        tile = Image.open(f).convert("RGBA")
        left = int(round(cx - W / 2))
        top = int(round(cy - H / 2))
        canvas.alpha_composite(tile, (left, top))

    out = OUT_ROOT / "sources" / f"{args.scene}_tiled_preview.png"
    canvas.save(out, "PNG")
    print(f"Wrote tiling preview -> {out}  ({canvas_w}x{canvas_h}, {len(coords)} hexes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
