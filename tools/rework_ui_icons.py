"""Rework the 256x256 UI icon families (ability_* / cond_*) for in-game legibility.

Those icons were authored as a cream/parchment SQUARE containing a smaller
coloured CIRCLE with a glyph inside it. In the game the cream square reads as an
ugly opaque box behind every buff pip, and the glyph is small enough inside its
circle that a 32px HUD pip is hard to identify at a glance.

This pass rewrites each icon to:
  1. drop the cream square entirely (transparent outside the disc),
  2. grow the coloured disc so it is inscribed in the full frame -- i.e. the
     former cream margin becomes backing colour,
  3. scale the glyph up to fill a fixed fraction of the disc.

Everything is derived from the art itself; nothing is hand-tuned per icon.

Re-running is safe: a reworked icon has transparent corners, which analyse()
rejects, so it is skipped rather than shrunk a second time. No sidecar copies are
kept -- the icons are tracked in git, so the undo is:
    git checkout -- "tfa-simultaneous-gemini-1/UI/UI Icons"

Usage:
    python tools/rework_ui_icons.py --preview out.png  # contact sheet only
    python tools/rework_ui_icons.py --only cond_pox,ability_heal
    python tools/rework_ui_icons.py --apply            # write the icons
"""
from __future__ import annotations

import argparse
import glob
import os
from pathlib import Path

import numpy as np
from scipy import ndimage
from PIL import Image, ImageDraw

ICON_DIR = Path("tfa-simultaneous-gemini-1") / "UI" / "UI Icons"

# Fraction of the disc DIAMETER the glyph's longest side is scaled to occupy.
# 0.72 keeps a comfortable ring of backing colour visible so the icon still reads
# as a coloured pip rather than an edge-to-edge glyph.
GLYPH_FILL = 0.72
# Never enlarge a glyph by more than this; a tiny detailed glyph blown up 4x just
# magnifies its own antialiasing.
MAX_UPSCALE = 2.2
# Colour distance under which two RGB triples count as "the same paint".
COLOR_TOL = 30
# Supersampling factor for the redraw, so the new disc edge is properly smooth.
SS = 4


def _dist(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Per-pixel euclidean RGB distance from an (H,W,3) array to one colour.

    float32, NOT int16: a squared channel difference reaches 255**2 = 65025,
    which overflows int16 and wraps NEGATIVE, so the sum goes negative and sqrt
    yields NaN. Every NaN then fails `> tolerance`, silently dropping exactly the
    pixels MOST different from the reference colour — which deleted the yellow
    out of the lightning bolt while leaving its cream outline behind.
    """
    d = a.astype(np.float32) - np.asarray(b, dtype=np.float32)
    return np.sqrt((d * d).sum(axis=-1))


def _modal_color(px: np.ndarray) -> np.ndarray:
    """Dominant colour of an (N,3) sample, via coarse quantisation. Modal, not
    mean: a mean smears the glyph's colour into the disc's across the
    antialiased boundary between them."""
    q = (px // 12).astype(np.int32)
    keys = q[:, 0] * 10000 + q[:, 1] * 100 + q[:, 2]
    uniq, counts = np.unique(keys, return_counts=True)
    sel = keys == uniq[counts.argmax()]
    return np.median(px[sel], axis=0).astype(np.uint8)


def _background_mask(rgb: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """Pixels belonging to the pale backing the icon was authored on.

    NOT "whatever colour the corners are": at least one icon
    (ability_test_frightened) is a WHITE outer border around a CREAM inner
    square, and white-vs-cream is further apart than the colour tolerance — so a
    single corner-sampled reference left the cream square counted as artwork,
    the disc radius blew up to the whole frame, and the detector then picked
    cream as the "disc" and the real purple disc as the "glyph", inverting the
    icon. Instead: pale AND desaturated AND reachable from the border. The
    connectivity requirement is what keeps a cream GLYPH (the heal cross), which
    is pale and desaturated too but enclosed by the disc, out of the mask.
    """
    pale = (rgb.min(axis=-1) > 200) & ((rgb.max(axis=-1) - rgb.min(axis=-1)) < 34)
    pale &= alpha > 128
    lbl, n = ndimage.label(pale)
    if n == 0:
        return np.zeros(pale.shape, dtype=bool)
    edge = np.concatenate([lbl[0], lbl[-1], lbl[:, 0], lbl[:, -1]])
    touching = set(int(v) for v in np.unique(edge) if v != 0)
    if not touching:
        return np.zeros(pale.shape, dtype=bool)
    return np.isin(lbl, list(touching))


def analyse(img: Image.Image):
    """Pull the disc colour, the disc geometry and the glyph mask out of one
    authored icon. Returns None if it isn't the expected 'pale square + colour
    disc' layout, or if the result would be untrustworthy -- refusing is always
    better than silently inverting an icon."""
    img = img.convert("RGBA")
    a = np.array(img)
    h, w = a.shape[:2]
    rgb, alpha = a[..., :3], a[..., 3]

    # Already hand-authored with transparency (or already reworked): leave alone.
    corners = [a[1, 1], a[1, w - 2], a[h - 2, 1], a[h - 2, w - 2]]
    if sum(1 for c in corners if c[3] > 200) < 3:
        return None

    background = _background_mask(rgb, alpha)
    if background.sum() < (h * w) * 0.01:
        return None                      # no pale surround: not this layout
    if background.sum() > (h * w) * 0.80:
        return None                      # almost all background: no disc to find

    # The disc is the largest opaque, non-background blob.
    paint = (~background) & (alpha > 128)
    lbl, n = ndimage.label(paint)
    if n == 0:
        return None
    sizes = ndimage.sum(paint, lbl, range(1, n + 1))
    disc_blob = lbl == (int(np.argmax(sizes)) + 1)
    if disc_blob.sum() < (h * w) * 0.12:
        return None                      # nothing disc-sized here

    ys, xs = np.nonzero(disc_blob)
    cy, cx = ys.mean(), xs.mean()
    radius = float(np.sqrt(disc_blob.sum() / np.pi))

    yy0, xx0 = np.mgrid[0:h, 0:w]
    rr0 = np.sqrt((yy0 - cy) ** 2 + (xx0 - cx) ** 2)
    # GUARD: is that blob actually a DISC? `weaken.png` is a bicep drawn on a pale
    # pink square: the square floods as background, the ARM becomes the largest
    # paint blob, and the rework then treated skin tone as the backing colour and
    # the arm's own outlines as the glyph — producing a peach disc with a few
    # stray strokes on it. A real disc is solidly filled near its centre (the
    # glyph is part of the same connected blob, so it counts too); an arm, a
    # boot or any other silhouette is not.
    core = rr0 < radius * 0.85
    if core.sum() == 0 or disc_blob[core].mean() < 0.92:
        return None

    # Thin annulus just inside the rim: disc colour only, since glyphs are
    # centred and do not reach the edge.
    yy, xx = np.mgrid[0:h, 0:w]
    rr = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2)
    ring = disc_blob & (rr > radius * 0.80) & (rr < radius * 0.95)
    if ring.sum() < 50:
        ring = disc_blob & (rr > radius * 0.6)
    if ring.sum() < 10:
        return None
    disc_color = _modal_color(rgb[ring])

    # GUARD: if the "disc" came out as pale as the surround, the segmentation
    # went wrong and reworking would wreck the icon. This is the exact signature
    # of the ability_test_frightened failure. Refuse instead.
    if int(disc_color.min()) > 200 and int(disc_color.max() - disc_color.min()) < 34:
        return None

    # Glyph = opaque paint inside the disc that is not disc colour. Cream glyphs
    # survive because the test is against the DISC colour, not against "pale".
    #
    # 0.90, not 0.99: the original disc's own ANTIALIASED RIM blends disc colour
    # into the cream surround, so those edge pixels differ from the modal disc
    # colour and were being collected as "glyph". Pasted into the redrawn icon
    # they showed up as a faint circular seam floating inside the new, larger
    # disc (visible on ability_force_march). Authored glyphs are centred and
    # reach ~0.8r at most, so cutting at 0.90r drops the rim without clipping art.
    inside = rr < radius * 0.90
    glyph = inside & (alpha > 128) & (_dist(rgb, disc_color) > COLOR_TOL)
    if glyph.sum() < 20:
        return None
    # A "glyph" occupying most of the disc means disc/glyph got swapped.
    if glyph.sum() > disc_blob.sum() * 0.72:
        return None
    return {
        "disc_color": disc_color,
        "center": (cx, cy),
        "radius": radius,
        "glyph": glyph,
        "rgba": a,
    }


def rework(img: Image.Image) -> Image.Image | None:
    info = analyse(img)
    if info is None:
        return None
    a = info["rgba"]
    h, w = a.shape[:2]
    glyph = info["glyph"]
    disc = tuple(int(v) for v in info["disc_color"])

    # Crop the glyph out with its own colours, alpha = the glyph mask softened by
    # the source alpha so antialiased edges survive the resize.
    ys, xs = np.nonzero(glyph)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    patch = a[y0:y1, x0:x1].copy()
    patch[..., 3] = (glyph[y0:y1, x0:x1] * 255).astype(np.uint8)
    glyph_img = Image.fromarray(patch, "RGBA")

    # New disc fills the frame. Target glyph size is a fixed share of it.
    out_r = min(w, h) / 2.0
    target = 2.0 * out_r * GLYPH_FILL
    longest = max(glyph_img.width, glyph_img.height)
    scale = min(target / longest, MAX_UPSCALE)
    new_size = (max(1, round(glyph_img.width * scale)), max(1, round(glyph_img.height * scale)))

    # Redraw supersampled so the new rim is smooth, then downsample once.
    canvas = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    ImageDraw.Draw(canvas).ellipse(
        [0, 0, w * SS - 1, h * SS - 1], fill=disc + (255,)
    )
    big_glyph = glyph_img.resize((new_size[0] * SS, new_size[1] * SS), Image.LANCZOS)
    canvas.alpha_composite(
        big_glyph,
        ((w * SS - big_glyph.width) // 2, (h * SS - big_glyph.height) // 2),
    )
    return canvas.resize((w, h), Image.LANCZOS)


def targets(only: list[str] | None) -> list[Path]:
    out = []
    for p in sorted(ICON_DIR.glob("*.png")):
        if p.name.endswith(".orig.png"):
            continue
        if only and p.stem not in only:
            continue
        out.append(p)
    return out


def source_of(p: Path) -> Path:
    """Repeat runs are made safe by analyse() rejecting already-reworked art
    (transparent corners), not by keeping a pristine copy around."""
    return p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--preview", default="")
    args = ap.parse_args()
    only = [s.strip() for s in args.only.split(",") if s.strip()] or None

    done, skipped = [], []
    for p in targets(only):
        src = source_of(p)
        img = Image.open(src)
        out = rework(img)
        if out is None:
            skipped.append(p.name)
            continue
        done.append((p, Image.open(src).convert("RGBA"), out))

    print(f"reworked {len(done)}, skipped {len(skipped)} (not the cream-square layout)")

    if args.preview:
        pairs = done[: 12]
        CELL = 150
        sheet = Image.new("RGBA", (CELL * len(pairs), CELL * 2 + 30), (58, 58, 64, 255))
        d = ImageDraw.Draw(sheet)
        for i, (p, before, after) in enumerate(pairs):
            for row, im in ((0, before), (1, after)):
                t = im.copy()
                t.thumbnail((CELL - 16, CELL - 16))
                sheet.alpha_composite(t, (i * CELL + 8, row * CELL + 8))
            d.text((i * CELL + 8, CELL * 2 + 8), p.stem[:18], fill=(255, 255, 255, 255))
        d.text((6, 2), "TOP = before", fill=(255, 220, 160, 255))
        d.text((6, CELL + 2), "BOTTOM = after", fill=(160, 255, 200, 255))
        sheet.save(args.preview)
        print(f"preview -> {args.preview}")

    if args.apply:
        for p, _before, after in done:
            after.save(p)
        print(f"wrote {len(done)} icon(s)")
        print('undo: git checkout -- "tfa-simultaneous-gemini-1/UI/UI Icons"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
