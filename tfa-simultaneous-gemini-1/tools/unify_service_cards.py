#!/usr/bin/env python3
"""Make all service-card backgrounds use one consistent parchment.

The original Gemini-generated cards each came back with a different parchment
(varying tone, texture, edge wear). This script:
  1. Synthesizes ONE clean parchment base via Pillow (deterministic).
  2. Extracts the watermark mask from each existing service card.
  3. Composites the watermark onto the shared base in a uniform sepia tone.

The result: every card has the same paper, the same edge wear, and the same
watermark color — only the icon shape changes.

Run after `generate_service_cards.py`. Re-runnable; reads each
UI/Assets/service_cards/<svc>.png and overwrites it.
"""

import argparse
import sys
from pathlib import Path
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
CARDS_DIR = ROOT / "UI" / "Assets" / "service_cards"
ORIGINALS_DIR = CARDS_DIR / "_originals"  # raw Gemini output, never overwritten
WIDTH, HEIGHT = 512, 256

# Sepia palette pulled to match the original Gemini output midtones.
PARCHMENT_BASE = np.array([232, 213, 178], dtype=np.float32)   # warm cream
PARCHMENT_DARK = np.array([184, 158, 116], dtype=np.float32)   # worn corners
SPLOTCH_COLOR  = np.array([116, 84, 50], dtype=np.float32)     # dark sepia ink
WATERMARK_COLOR = np.array([110, 86, 56], dtype=np.float32)    # icon ink

SERVICES = [
    "smith", "alchemist", "peddler", "alewife", "barkeep", "whoremonger",
    "slavecatcher", "reverend_mother", "skipper", "wayfinder", "librarian",
    "professor", "the_house", "moneylender", "houndmaster", "hedge_witch",
    "hierophant", "venefica", "veneficus", "don", "default",
]


# ---------------------------------------------------------------------------
# Parchment synthesis
# ---------------------------------------------------------------------------

def make_parchment(seed: int = 42) -> np.ndarray:
    rng = np.random.default_rng(seed)
    # Start with a base color slightly warmer in the center, darker at corners.
    yy, xx = np.meshgrid(np.linspace(-1, 1, HEIGHT), np.linspace(-1, 1, WIDTH), indexing="ij")
    radial = np.sqrt(xx ** 2 + yy ** 2)
    radial = np.clip(radial / 1.15, 0.0, 1.0)
    radial = (radial ** 1.4)[:, :, None]
    base = PARCHMENT_BASE[None, None, :] * (1 - radial) + PARCHMENT_DARK[None, None, :] * radial

    # Fine paper grain. Pre-blur so the texture looks like fibers, not static.
    grain = rng.normal(0, 4.0, (HEIGHT, WIDTH, 1))
    grain_img = Image.fromarray((grain[:, :, 0] * 8 + 128).clip(0, 255).astype(np.uint8))
    grain_img = grain_img.filter(ImageFilter.GaussianBlur(radius=1.4))
    grain_arr = (np.array(grain_img, dtype=np.float32) - 128.0) / 8.0
    base = base + grain_arr[:, :, None] * 1.5

    # Edge darkening (vignette feels like worn paper).
    edge = np.maximum(np.abs(yy), np.abs(xx))
    edge = np.clip((edge - 0.78) / 0.22, 0.0, 1.0)[:, :, None]
    base = base * (1 - edge * 0.20)

    # A handful of small ink splotches near the edges (never near center).
    img = Image.fromarray(base.clip(0, 255).astype(np.uint8))
    for _ in range(int(rng.integers(5, 9))):
        # Pick a position outside the central 60% of the canvas.
        while True:
            cx = int(rng.integers(8, WIDTH - 8))
            cy = int(rng.integers(8, HEIGHT - 8))
            if abs(cx - WIDTH // 2) > WIDTH * 0.30 or abs(cy - HEIGHT // 2) > HEIGHT * 0.30:
                break
        r = int(rng.integers(3, 8))
        alpha = float(rng.integers(40, 95)) / 255.0
        c = SPLOTCH_COLOR
        # Draw a circular splotch via numpy mask (faster, no jagged edges).
        ys, xs = np.ogrid[-r:r + 1, -r:r + 1]
        d2 = xs * xs + ys * ys
        m = (d2 <= r * r).astype(np.float32) * (1.0 - np.sqrt(np.clip(d2, 0, r * r)) / r)
        y0, y1 = max(0, cy - r), min(HEIGHT, cy + r + 1)
        x0, x1 = max(0, cx - r), min(WIDTH, cx + r + 1)
        my0 = y0 - (cy - r); mx0 = x0 - (cx - r)
        my1 = my0 + (y1 - y0); mx1 = mx0 + (x1 - x0)
        mblock = m[my0:my1, mx0:mx1, None] * alpha
        arr = np.array(img, dtype=np.float32)
        arr[y0:y1, x0:x1] = arr[y0:y1, x0:x1] * (1 - mblock) + c[None, None, :] * mblock
        img = Image.fromarray(arr.clip(0, 255).astype(np.uint8))

    return np.array(img, dtype=np.float32)


# ---------------------------------------------------------------------------
# Watermark extraction & composition
# ---------------------------------------------------------------------------

def extract_watermark_mask(card_path: Path) -> np.ndarray:
    """Return a HxW float [0,1] mask of how strongly each pixel should be
    darkened on the destination parchment to recreate the icon."""
    src = np.array(Image.open(card_path).convert("RGB").resize((WIDTH, HEIGHT)), dtype=np.float32)

    # Parchment reference = the brightest 5% of pixels' average. Using corners
    # fails when worn-edge vignettes darken them more than the icon does
    # (e.g. smith.png), pulling the reference too low.
    brightness = src.mean(axis=2)
    threshold = np.percentile(brightness, 95)
    mask_bright = brightness >= threshold
    src_parchment = src[mask_bright].mean(axis=0) if mask_bright.any() else src.mean(axis=(0, 1))

    # Darkness = how much darker each pixel is than this card's parchment.
    delta = (src_parchment[None, None, :] - src).clip(min=0).mean(axis=2)

    # Normalize so the icon's darkest stroke maps to ~1.0; small noise stays low.
    # Use a gentler floor so cards with subtle ink still register.
    p99 = np.percentile(delta, 99.5)
    if p99 < 1e-3:
        return np.zeros((HEIGHT, WIDTH), dtype=np.float32)
    mask = np.clip(delta / max(p99, 12.0), 0.0, 1.0)

    # Suppress edge wear — the worn corner darkening shouldn't be treated as icon.
    yy, xx = np.meshgrid(np.linspace(-1, 1, HEIGHT), np.linspace(-1, 1, WIDTH), indexing="ij")
    radial = np.sqrt(xx ** 2 + yy ** 2)
    edge_falloff = 1.0 - np.clip((radial - 0.55) / 0.45, 0.0, 1.0) ** 1.5
    mask = mask * edge_falloff

    # Mild gamma so the icon body (which is uniformly dark in the original)
    # stays solid instead of fading toward its center pixels.
    mask = np.power(mask, 0.85)

    # Slight blur to smooth jagged AI-output edges.
    mask_img = Image.fromarray((mask * 255).clip(0, 255).astype(np.uint8))
    mask_img = mask_img.filter(ImageFilter.GaussianBlur(radius=0.5))
    return np.array(mask_img, dtype=np.float32) / 255.0


def composite(parchment: np.ndarray, mask: np.ndarray, watermark_alpha: float = 0.42) -> np.ndarray:
    a = (mask * watermark_alpha)[:, :, None]
    out = parchment * (1 - a) + WATERMARK_COLOR[None, None, :] * a
    return out.clip(0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated service ids to rebuild")
    parser.add_argument("--watermark-alpha", type=float, default=0.42,
                        help="strength of icon ink against the parchment, 0..1")
    parser.add_argument("--seed", type=int, default=42,
                        help="parchment synthesis seed")
    args = parser.parse_args()

    targets = SERVICES
    if args.only:
        wanted = set(args.only.split(","))
        targets = [s for s in SERVICES if s in wanted]

    parchment = make_parchment(args.seed)
    parchment_img = Image.fromarray(parchment.clip(0, 255).astype(np.uint8))
    parchment_img.save(CARDS_DIR / "_parchment_base.png", "PNG")
    print(f"Wrote shared parchment to {CARDS_DIR / '_parchment_base.png'}")

    fails = []
    for svc in targets:
        src = ORIGINALS_DIR / f"{svc}.png"
        if not src.exists():
            # Fall back to the live card if no backup exists yet.
            src = CARDS_DIR / f"{svc}.png"
        if not src.exists():
            print(f"[skip] {svc}: no source card at {src}")
            continue
        mask = extract_watermark_mask(src)
        merged = composite(parchment, mask, args.watermark_alpha)
        Image.fromarray(merged).save(CARDS_DIR / f"{svc}.png", "PNG")
        print(f"[merged] {svc}")

    if fails:
        print(f"Failed: {fails}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
