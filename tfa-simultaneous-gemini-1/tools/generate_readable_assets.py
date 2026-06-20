#!/usr/bin/env python3
"""Generate placeholder art for the readables system.

Outputs (relative to the tfa-simultaneous-gemini-1 project root):
  UI/readable-cursor.png   - book cursor shown when hovering a readable (32px)
  UI/book-page.png         - aged-paper background for the book/tome reading window
  Items/readable_note.png  - world sprite for note/letter/scroll readables (32px)
  Items/readable_book.png  - world sprite for book/tome readables (32px)

Intentionally simple PIL-drawn placeholders that match the journal's parchment
palette (#2c1f08 ink, #5a4225 soft ink, aged cream paper). Re-run after tweaking;
replace with final art later. Deterministic (no randomness) so output is stable.
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI_DIR = os.path.join(ROOT, "UI")
ITEMS_DIR = os.path.join(ROOT, "Items")

# Parchment / ink palette (matches QuestLogPanel browns).
INK = (44, 31, 8, 255)            # #2c1f08
INK_SOFT = (90, 66, 37, 255)      # #5a4225
PARCH_LIGHT = (232, 219, 178, 255)
PARCH_MID = (214, 196, 150, 255)
PARCH_EDGE = (150, 120, 70, 255)
COVER = (122, 70, 40, 255)        # book cover brown
COVER_DARK = (80, 45, 24, 255)


def _save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", os.path.relpath(path, ROOT))


def make_cursor(path, size=32):
    """An open book: two cream pages meeting at a dark spine, ink outline."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = float(size)
    left = [(s * 0.10, s * 0.30), (s * 0.48, s * 0.22),
            (s * 0.48, s * 0.80), (s * 0.10, s * 0.72)]
    right = [(s * 0.52, s * 0.22), (s * 0.90, s * 0.30),
             (s * 0.90, s * 0.72), (s * 0.52, s * 0.80)]
    d.polygon(left, fill=PARCH_LIGHT, outline=INK)
    d.polygon(right, fill=PARCH_LIGHT, outline=INK)
    d.line([(s * 0.50, s * 0.22), (s * 0.50, s * 0.80)], fill=INK,
           width=max(1, size // 16))
    for t in (0.40, 0.52, 0.64):
        d.line([(s * 0.16, s * t), (s * 0.44, s * (t - 0.02))], fill=INK_SOFT, width=1)
        d.line([(s * 0.56, s * (t - 0.02)), (s * 0.84, s * t)], fill=INK_SOFT, width=1)
    _save(img, path)


def make_book_bg(path, w=512, h=512):
    """Aged-paper page background with a faint center crease and border."""
    img = Image.new("RGBA", (w, h), PARCH_MID)
    d = ImageDraw.Draw(img)
    # Soft vignette toward the edges.
    for i in range(24):
        a = int(70 * (1.0 - i / 24.0))
        d.rectangle([i, i, w - 1 - i, h - 1 - i],
                    outline=(120, 95, 55, a))
    # Border frame.
    d.rectangle([6, 6, w - 7, h - 7], outline=PARCH_EDGE, width=4)
    # Center spine crease.
    d.line([(w // 2, 12), (w // 2, h - 12)], fill=(150, 120, 70, 110), width=6)
    _save(img, path)


def make_note_sprite(path, size=32):
    """A small rolled parchment / folded note world sprite."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = float(size)
    d.rectangle([s * 0.24, s * 0.16, s * 0.76, s * 0.84],
                fill=PARCH_LIGHT, outline=INK_SOFT)
    # Rolled top/bottom edges.
    d.rectangle([s * 0.20, s * 0.12, s * 0.80, s * 0.22], fill=PARCH_MID, outline=INK_SOFT)
    d.rectangle([s * 0.20, s * 0.78, s * 0.80, s * 0.88], fill=PARCH_MID, outline=INK_SOFT)
    for t in (0.34, 0.46, 0.58, 0.70):
        d.line([(s * 0.32, s * t), (s * 0.68, s * t)], fill=INK_SOFT, width=1)
    _save(img, path)


def make_book_sprite(path, size=32):
    """A small closed book world sprite (brown cover, page edge)."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = float(size)
    # Cover.
    d.rectangle([s * 0.20, s * 0.18, s * 0.80, s * 0.82], fill=COVER, outline=COVER_DARK)
    # Page edge (right side).
    d.rectangle([s * 0.72, s * 0.20, s * 0.80, s * 0.80], fill=PARCH_LIGHT, outline=COVER_DARK)
    # Spine + clasp lines.
    d.line([(s * 0.28, s * 0.18), (s * 0.28, s * 0.82)], fill=COVER_DARK, width=2)
    d.line([(s * 0.46, s * 0.34), (s * 0.64, s * 0.34)], fill=PARCH_LIGHT, width=1)
    _save(img, path)


def main():
    make_cursor(os.path.join(UI_DIR, "readable-cursor.png"))
    make_book_bg(os.path.join(UI_DIR, "book-page.png"))
    make_note_sprite(os.path.join(ITEMS_DIR, "readable_note.png"))
    make_book_sprite(os.path.join(ITEMS_DIR, "readable_book.png"))
    print("done")


if __name__ == "__main__":
    main()
