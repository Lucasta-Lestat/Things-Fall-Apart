"""Generate default-mouse-cursor options in the game's existing cursor style.

The game already ships four 32px hover cursors in `tfa-simultaneous-gemini-1/UI/`
(attack / pickup / talking / readable). They share a look: a single flat
silhouette, cream/off-white fill, dark brown ink outline, no shading gradients,
readable at 32 pixels. This script asks gemini-3-pro-image-preview for a matching
DEFAULT pointer, using those four PNGs as style references.

Each candidate is generated large, background-keyed to transparency by floodfill
from the corners (same trick as tools/isolate_icons.py), trimmed to its alpha
bounding box, and downscaled to 32px on the long edge.

Outputs go to tools/_cursor_raw/ (nothing lands in the game until you pick one):
    <name>_raw.png    the untouched model output
    <name>.png        32px, transparent, ready to drop into UI/
    _contact.png      all candidates composited on a mid-grey strip

Usage:
    python tools/generate_cursor.py
    python tools/generate_cursor.py --only arrow,gauntlet
    python tools/generate_cursor.py --list
"""
from __future__ import annotations

import argparse
import base64 as b64
import io
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from google import genai
from google.genai import types
from PIL import Image, ImageDraw

MODEL = os.environ.get("CURSOR_MODEL", "gemini-3-pro-image-preview")
UI_DIR = Path("tfa-simultaneous-gemini-1") / "UI"
OUT_DIR = Path("tools") / "_cursor_raw"
REFERENCE_NAMES = ["attack-cursor.png", "pickup-cursor.png",
                   "talking-cursor.png", "readable-cursor.png"]
MAX_RETRIES = 4
TARGET_PX = 32
# Floodfill marker. Must NOT be the background colour itself — ImageDraw.floodfill
# is a no-op when the seed pixel already equals the fill value. Pure green never
# appears in this palette.
SENTINEL = (0, 255, 0)

STYLE = (
    "A single mouse-cursor icon for a medieval fantasy tactics game, drawn to "
    "match the four reference images exactly. Shared house style: ONE flat "
    "silhouette shape, filled solid cream/bone off-white, wrapped in a bold even "
    "dark-brown ink outline about 2 pixels thick. Completely flat — solid fill "
    "only, hand-inked woodcut feel. The shape is chunky and simple with clean "
    "silhouette gaps, so it stays legible when shrunk to 32 by 32 pixels. The "
    "icon fills the frame corner to corner and floats alone on a flat pure "
    "magenta background, colour 255 0 255, with the magenta reaching every edge "
    "of the frame. Square image. Just the one icon: no text, no border, no "
    "drop shadow, no ground, no second object."
)


@dataclass
class Candidate:
    name: str
    prompt: str
    # Style references for this candidate. Empty = the four shipped UI cursors.
    # Later candidates point at earlier *generated* cursors instead, so the new
    # set converges on its own look rather than the older mixed one.
    refs: tuple[Path, ...] = ()


CANDIDATES: list[Candidate] = [
    Candidate("arrow",
        "The icon is a classic pointer ARROW aimed at the upper-left corner of "
        "the frame: a sharp triangular arrowhead with a straight tapering tail, "
        "the whole thing tilted so the point sits in the top-left. Cream fill, "
        "dark brown outline. It reads instantly as an ordinary mouse pointer, "
        "just hand-inked instead of crisp vector."),
    Candidate("gauntlet",
        "The icon is an armoured GAUNTLET pointing: a mailed fist in profile "
        "with the index finger extended toward the upper-left corner, thumb "
        "tucked up, a flared cuff at the wrist. Cream fill, dark brown outline, "
        "a few short outline strokes marking the knuckle plates and the cuff "
        "edge. Same drawing hand as the reference pointing-hand cursor."),
    Candidate("dagger",
        "The icon is a slim DAGGER held point-up-left: a narrow leaf-shaped "
        "blade with a straight crossguard and a short wrapped grip with a round "
        "pommel, tilted so the blade tip reaches the top-left corner. Cream "
        "fill, dark brown outline. Same drawing hand as the reference sabre "
        "cursor but shorter, blunter and more compact."),
    Candidate("quill",
        "The icon is a QUILL PEN nib-down-left: a tapered feather with a soft "
        "notched vane along one side and a sharpened writing nib at the tip, "
        "tilted so the nib reaches the lower-left. Cream fill, dark brown "
        "outline, two or three short outline strokes suggesting the feather "
        "barbs. Same drawing hand as the reference book cursor."),

    # Pickup restyle — matched to the arrow/dagger/quill set above rather than to
    # the older shipped cursors, so the whole set ends up on one palette.
    Candidate("pickup_grab",
        "The icon is an open GRABBING HAND reaching down to pick something up: "
        "a bare hand seen from the side, fingers curled and spread as if about "
        "to close on an object just below, thumb opposed, wrist at the lower "
        "right. Cream fill, dark brown outline, short outline strokes between "
        "the fingers so the digits stay separable at small size.",
        refs=(OUT_DIR / "arrow_raw.png", OUT_DIR / "dagger_raw.png",
              OUT_DIR / "quill_raw.png")),
    Candidate("pickup_pinch",
        "The icon is a HAND PINCHING: a bare hand seen from the side with "
        "thumb and index finger meeting in a pinch at the upper left, the "
        "remaining three fingers folded into the palm, wrist at the lower "
        "right. Cream fill, dark brown outline, short outline strokes marking "
        "the folded knuckles.",
        refs=(OUT_DIR / "arrow_raw.png", OUT_DIR / "dagger_raw.png",
              OUT_DIR / "quill_raw.png")),
    Candidate("pickup_glove",
        "The icon is an open GLOVED HAND reaching down to pick something up, "
        "matching the reference pointing gauntlet's construction: fingers "
        "curled and spread as if about to close on an object below, a flared "
        "cuff at the wrist in the lower right. Cream fill, dark brown outline, "
        "a few short strokes for the knuckle plates and the cuff edge.",
        refs=(OUT_DIR / "gauntlet_raw.png", OUT_DIR / "arrow_raw.png",
              OUT_DIR / "dagger_raw.png")),

    # Second pass: the pinch, reoriented downward like the cursor it replaces,
    # plus a book to take over the "Read" action from the quill.
    Candidate("pinch_down",
        "The icon is a HAND PINCHING DOWNWARD. The wrist enters from the TOP of "
        "the frame and the hand hangs down, thumb and index finger meeting in a "
        "pinch at the BOTTOM of the frame as if lifting a small object off the "
        "ground below. The other three fingers are folded into the palm. Cream "
        "fill, dark brown outline, short outline strokes marking the folded "
        "knuckles. Same drawing hand and palette as the reference cursors.",
        refs=(OUT_DIR / "pickup_pinch_raw.png", OUT_DIR / "arrow_raw.png",
              OUT_DIR / "dagger_raw.png")),
    Candidate("pinch_down_b",
        "The icon is a HAND REACHING DOWN to pick something up, seen from the "
        "side and slightly behind. The wrist enters from the TOP-RIGHT of the "
        "frame and the hand angles down and left, thumb and index finger almost "
        "touching in a pinch at the LOWER LEFT, the remaining fingers curled "
        "loosely under the palm. Cream fill, dark brown outline. Same drawing "
        "hand and palette as the reference cursors.",
        refs=(OUT_DIR / "pickup_pinch_raw.png", OUT_DIR / "arrow_raw.png",
              OUT_DIR / "dagger_raw.png")),
    Candidate("book_open",
        "The icon is an OPEN BOOK seen from a low three-quarter angle: two "
        "facing pages splayed from a central spine, the page block thick enough "
        "to show a few stacked page edges, the outer covers curling slightly "
        "up. Three or four short horizontal strokes on each page stand in for "
        "lines of text. Cream fill, dark brown outline. Same drawing hand and "
        "palette as the reference cursors.",
        refs=(OUT_DIR / "quill_raw.png", OUT_DIR / "dagger_raw.png",
              OUT_DIR / "arrow_raw.png")),
    Candidate("book_closed",
        "The icon is a CLOSED BOOK standing at a three-quarter angle, tilted "
        "slightly: a thick tome with a hard cover, a raised banded spine on the "
        "left, and a visible block of stacked page edges on the right. A small "
        "clasp or a simple cross-strap detail on the cover. Cream fill, dark "
        "brown outline, the page-edge stack drawn as three or four short "
        "parallel strokes. Same drawing hand and palette as the references.",
        refs=(OUT_DIR / "quill_raw.png", OUT_DIR / "dagger_raw.png",
              OUT_DIR / "arrow_raw.png")),

    # Third pass: the talk cursor, the last of the set still on the old
    # white-silhouette style.
    Candidate("talk_head",
        "The icon is a HEAD IN PROFILE SPEAKING, facing right: a simple "
        "human head-and-shoulders silhouette in side view with the mouth open "
        "mid-word, and three short curved sound-wave arcs radiating from the "
        "mouth toward the right edge of the frame. Cream fill, dark brown "
        "outline; the brow, nose, lips and chin are carved into the outline as "
        "one continuous profile line. Same drawing hand and palette as the "
        "reference cursors.",
        refs=(OUT_DIR / "book_open_raw.png", OUT_DIR / "pinch_down_b_raw.png",
              OUT_DIR / "arrow_raw.png")),
    Candidate("talk_bubble",
        "The icon is a SPEECH BUBBLE: a rounded, slightly lopsided hand-drawn "
        "speech balloon with a tail pointing down-left, and two or three short "
        "horizontal strokes inside standing in for a line of speech. Cream "
        "fill, dark brown outline, the balloon drawn with a wobbling ink line "
        "rather than a perfect ellipse. Same drawing hand and palette as the "
        "reference cursors.",
        refs=(OUT_DIR / "book_open_raw.png", OUT_DIR / "pinch_down_b_raw.png",
              OUT_DIR / "arrow_raw.png")),
]


def load_refs(paths: list[Path]) -> list[Image.Image]:
    """Load style references as opaque RGB, upscaled so details survive encoding."""
    out: list[Image.Image] = []
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f"reference missing: {path}")
        src = Image.open(path).convert("RGBA")
        # Flatten onto white so the model sees the outlines, not an alpha mess.
        flat = Image.new("RGB", src.size, (255, 255, 255))
        flat.paste(src, mask=src.split()[3])
        if max(flat.size) < 256:
            scale = 256 // max(flat.size)
            flat = flat.resize((flat.width * scale, flat.height * scale), Image.NEAREST)
        out.append(flat)
    return out


def _extract_image(resp) -> Image.Image:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        for part in (getattr(content, "parts", None) or []):
            inline = getattr(part, "inline_data", None)
            if inline is None or not getattr(inline, "data", None):
                continue
            data = inline.data
            if isinstance(data, str):
                data = b64.b64decode(data)
            return Image.open(io.BytesIO(data))
    raise RuntimeError("no inline image data in any candidate part")


def generate(client: genai.Client, cand: Candidate,
             references: list[Image.Image]) -> Image.Image:
    last_err: Exception | None = None
    full_prompt = f"{STYLE}\n\n{cand.prompt}"
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = client.models.generate_content(
                model=MODEL,
                contents=[*references, full_prompt],
                config=types.GenerateContentConfig(response_modalities=["IMAGE"]),
            )
            return _extract_image(resp)
        except Exception as e:  # noqa: BLE001
            last_err = e
            wait = 2 ** attempt
            print(f"  [{cand.name}] attempt {attempt}/{MAX_RETRIES} failed: {e!r};"
                  f" sleeping {wait}s")
            time.sleep(wait)
    raise RuntimeError(f"giving up on {cand.name}: {last_err!r}")


def to_cursor(img: Image.Image, tolerance: int = 60) -> Image.Image:
    """Key out the flat background, trim, and downscale to a 32px cursor."""
    img = img.convert("RGBA")
    w, h = img.size

    rgb = img.convert("RGB").copy()
    for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        ImageDraw.floodfill(rgb, corner, SENTINEL, thresh=tolerance)
    arr = np.array(rgb)
    is_bg = ((arr[:, :, 0] == SENTINEL[0]) & (arr[:, :, 1] == SENTINEL[1])
             & (arr[:, :, 2] == SENTINEL[2]))

    rgba = np.array(img)
    rgba[:, :, 3] = np.where(is_bg, 0, rgba[:, :, 3])

    # The floodfill only reaches fully-background pixels; the anti-aliased ring
    # where the ink outline blends into magenta survives and, once downscaled,
    # shows as a pink halo. Drop anything still visibly magenta.
    r, g, b = rgba[:, :, 0].astype(int), rgba[:, :, 1].astype(int), rgba[:, :, 2].astype(int)
    fringe = (r - g > 40) & (b - g > 40)
    rgba[:, :, 3] = np.where(fringe, 0, rgba[:, :, 3])

    out = Image.fromarray(rgba, "RGBA")

    bbox = out.getbbox()
    if bbox:
        out = out.crop(bbox)

    scale = TARGET_PX / max(out.size)
    size = (max(1, round(out.width * scale)), max(1, round(out.height * scale)))
    return out.resize(size, Image.LANCZOS)


def contact_sheet(paths: list[Path], dest: Path, zoom: int = 4) -> None:
    tiles = [Image.open(p).convert("RGBA") for p in paths]
    cell = TARGET_PX * zoom + 16
    sheet = Image.new("RGBA", (cell * len(tiles), cell + 22), (96, 104, 114, 255))
    draw = ImageDraw.Draw(sheet)
    for i, (tile, path) in enumerate(zip(tiles, paths)):
        big = tile.resize((tile.width * zoom, tile.height * zoom), Image.NEAREST)
        sheet.alpha_composite(big, (i * cell + 8, 8))
        draw.text((i * cell + 8, cell + 4), path.stem, fill=(255, 255, 255, 255))
    sheet.save(dest)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--only", default=None, help="comma-separated candidate names")
    ap.add_argument("--reprocess", action="store_true",
                    help="re-key existing *_raw.png instead of calling the API")
    args = ap.parse_args()

    if args.list:
        for c in CANDIDATES:
            print(f"  {c.name}")
        return 0

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key and not args.reprocess:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        return 2

    default_refs = [UI_DIR / n for n in REFERENCE_NAMES]

    targets = CANDIDATES
    if args.only:
        wanted = {n.strip() for n in args.only.split(",") if n.strip()}
        targets = [c for c in CANDIDATES if c.name in wanted]
        if not targets:
            print(f"ERROR: no candidates matched {sorted(wanted)}", file=sys.stderr)
            return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    client = None if args.reprocess else genai.Client(api_key=api_key)

    made: list[Path] = []
    for cand in targets:
        raw_path = OUT_DIR / f"{cand.name}_raw.png"
        if args.reprocess:
            if not raw_path.exists():
                print(f"[{cand.name}] no raw image, skipping")
                continue
            raw = Image.open(raw_path)
        else:
            print(f"[{cand.name}] generating…")
            refs = load_refs(list(cand.refs) or default_refs)
            raw = generate(client, cand, refs)
            raw.save(raw_path)
        dest = OUT_DIR / f"{cand.name}.png"
        cursor = to_cursor(raw)
        cursor.save(dest)
        made.append(dest)
        print(f"[{cand.name}] -> {dest}  ({cursor.width}x{cursor.height})")

    if made:
        contact_sheet(made, OUT_DIR / "_contact.png")
        print(f"contact sheet -> {OUT_DIR / '_contact.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
