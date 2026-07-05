#!/usr/bin/env python3
"""Process the top-down rat reference into a swarm sprite.

- Flood-fills the flat gray background to transparent (edge-connected only,
  so similar grays inside the rat are preserved).
- Autocrops to the rat.
- Rotates so the rat's "forward" (its nose) points to +X (screen right),
  which is the canonical heading the boid renderer rotates from.
- Downscales to a swarm-friendly resolution.

Output: tfa-simultaneous-gemini-1/art/creatures/rat_brown.png
"""
from __future__ import annotations
import os
from collections import deque
from PIL import Image

SRC = r"C:\dev\Procedural Character from Scratch\race variety\rat brown.png"
DST = r"C:\dev\Things-Fall-Apart-Local\tfa-simultaneous-gemini-1\art\creatures\rat_brown.png"

# How close to the sampled background color a pixel must be to count as background.
BG_TOLERANCE = 28
# Longest side of the final sprite, in px (mesh/scale sets actual in-world size).
TARGET_LONG_SIDE = 192
# Rotate the cropped art by this many degrees CCW so forward(nose) -> +X.
# Source has the nose pointing DOWN (+Y); CCW 90 maps down -> right(+X).
FORWARD_ROTATION_CCW = 90


def sample_bg(img: Image.Image) -> tuple[int, int, int]:
    """Average the four corners to estimate the background color."""
    w, h = img.size
    pts = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]
    r = g = b = 0
    for x, y in pts:
        px = img.getpixel((x, y))
        r += px[0]; g += px[1]; b += px[2]
    n = len(pts)
    return (r // n, g // n, b // n)


def flood_key(img: Image.Image, bg: tuple[int, int, int], tol: int) -> Image.Image:
    """Edge-connected flood fill: clear pixels reachable from the border that
    are within `tol` of the background color. Leaves interior pixels intact."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    tol2 = tol * tol
    visited = bytearray(w * h)
    q: deque[tuple[int, int]] = deque()

    def is_bg(x: int, y: int) -> bool:
        c = px[x, y]
        dr = c[0] - bg[0]; dg = c[1] - bg[1]; db = c[2] - bg[2]
        return dr * dr + dg * dg + db * db <= tol2

    for x in range(w):
        for y in (0, h - 1):
            if not visited[y * w + x] and is_bg(x, y):
                q.append((x, y)); visited[y * w + x] = 1
    for y in range(h):
        for x in (0, w - 1):
            if not visited[y * w + x] and is_bg(x, y):
                q.append((x, y)); visited[y * w + x] = 1

    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not visited[ny * w + nx]:
                visited[ny * w + nx] = 1
                if is_bg(nx, ny):
                    q.append((nx, ny))
    return img


def main() -> None:
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    img = Image.open(SRC).convert("RGBA")
    bg = sample_bg(img)
    print(f"source {img.size}  bg~{bg}")

    img = flood_key(img, bg, BG_TOLERANCE)

    # Autocrop to the non-transparent content with a small margin.
    bbox = img.getbbox()
    if bbox:
        pad = 8
        l, t, r, b = bbox
        l = max(0, l - pad); t = max(0, t - pad)
        r = min(img.width, r + pad); b = min(img.height, b + pad)
        img = img.crop((l, t, r, b))
    print(f"cropped {img.size}")

    # Orient forward -> +X.
    if FORWARD_ROTATION_CCW:
        img = img.rotate(FORWARD_ROTATION_CCW, expand=True, resample=Image.BICUBIC)

    # Downscale.
    long_side = max(img.size)
    if long_side > TARGET_LONG_SIDE:
        scale = TARGET_LONG_SIDE / long_side
        new = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
        img = img.resize(new, Image.LANCZOS)

    img.save(DST)
    print(f"saved {DST}  {img.size}")


if __name__ == "__main__":
    main()
