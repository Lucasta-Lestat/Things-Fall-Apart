#!/usr/bin/env python3
"""Generate fairy-chess piece art with Gemini, keyed off the existing King art.

The King_white / King_black icons define the look: a pewter/silver tabletop
figurine photographed head-on against transparency, ~512x1024. Every new piece
is generated from that reference so the set stays visually consistent, then
matched to the King's canvas size and alpha-trimmed the same way.

Front/back symmetry: the pieces are viewed straight on and the prompt asks for
a symmetrical, forward-facing figure with no distinguishing back detail, so a
piece reads the same to both players across the board.

Usage (from the repo root):
    python tools/generate_fairy_chess_pieces.py --list
    python tools/generate_fairy_chess_pieces.py                # missing only
    python tools/generate_fairy_chess_pieces.py --only Factory --force
"""

from __future__ import annotations

import argparse
import io
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from google import genai
from google.genai import types
import numpy as np
from PIL import Image, ImageDraw

MODEL = os.environ.get("FAIRY_CHESS_MODEL", "gemini-3-pro-image-preview")
ICONS_DIR = Path("fairy-chess-2") / "assets" / "icons"
MAX_RETRIES = 4

# Shared style, anchored on the King reference the caller passes in.
STYLE = (
    "A single fantasy CHESS PIECE figurine rendered exactly like the reference "
    "image: a small cast-metal tabletop miniature, photographed straight on at "
    "eye level, centered, standing on a round pedestal base. Match the "
    "reference's material and lighting precisely -- {tone} cast metal with soft "
    "studio highlights and gentle shading, fine sculpted detail. "
    "The figurine stands alone on a COMPLETELY FLAT, UNIFORM PURE WHITE "
    "(#FFFFFF) background that touches all four edges of the frame -- no "
    "gradient, no vignette, no checkerboard, no ground shadow, no scenery, no "
    "text, no border, no extra objects. The figure is strictly frontal and "
    "bilaterally SYMMETRICAL left-to-right, with nothing that reads as a front "
    "or back -- no cape trailing to one side, no turned head, no props held out "
    "to one side only -- so it looks correct to a player on either side of the "
    "board. Same overall height and framing as the reference piece: the "
    "figurine fills the frame vertically with a small margin above the head and "
    "below the base."
)


@dataclass
class Piece:
    name: str      # must match the piece type used by the game
    prompt: str    # appended to STYLE


PIECES: list[Piece] = [
    Piece("Factory",
        "The figurine is a FACTORY: a squat industrial workshop built as a "
        "chess piece -- a blocky brick-and-iron building on the pedestal, with "
        "two symmetrical smokestacks rising left and right, a central arched "
        "furnace door glowing faintly, gear-and-rivet detailing, and a small "
        "symmetrical peaked roof. Machinery, not a person. Strictly "
        "symmetrical about the vertical axis."),
    Piece("Praetor",
        "The figurine is a PRAETOR, a techno-priest magistrate: a tall upright "
        "robed figure wearing a high crested helm, holding a mechanical staff "
        "vertically centered in both hands directly in front of the body. The "
        "robes are layered and fall evenly on both sides. Ornamental cogwheel "
        "and circuitry motifs on the chestplate and hem, a small halo-like "
        "gear ring behind the head. Regal and austere, clearly a royal piece. "
        "Perfectly symmetrical, facing forward."),
    Piece("Doppelganger",
        "The figurine is a DOPPELGANGER: a smooth faceless humanoid with a "
        "blank featureless oval head, standing upright with both arms held "
        "symmetrically at its sides. Its surface looks half-formed and "
        "liquid, as though the metal is still deciding on a shape, with soft "
        "rippling seams flowing down the body. Eerie and anonymous. No face, "
        "no hair, no clothing detail. Perfectly symmetrical, facing forward."),
    Piece("Berserker",
        "The figurine is a BERSERKER: a bare-chested viking warrior in a "
        "snarling wolf-pelt hood, roaring, holding a broad axe raised in BOTH "
        "hands directly above and in front of the head, arms mirrored evenly "
        "on both sides. Braided beard, fur across both shoulders equally, "
        "heavy boots planted wide on the base. Ferocious forward charge. "
        "Strictly symmetrical about the vertical axis."),
    Piece("Chieftain",
        "The figurine is a viking CHIEFTAIN: a broad commanding warrior-king "
        "in a horned-and-winged crowned helm, wearing a heavy fur mantle "
        "draped evenly over both shoulders, both hands resting on the pommel "
        "of a large sword planted point-down and exactly centered in front of "
        "him. Ring-mail and knotwork detailing. Clearly a royal piece, "
        "weathered and imposing. Perfectly symmetrical, facing forward."),
    Piece("Spymaster",
        "The figurine is a SPYMASTER: a slender hooded figure in a deep cowl "
        "that hides the face entirely in shadow, wrapped in a close cloak that "
        "falls evenly on both sides, both hands drawing the cloak closed at "
        "the center of the chest. A small symmetrical mask motif at the "
        "throat clasp. Secretive and still. No weapon shown. Perfectly "
        "symmetrical, facing forward."),
]


def _extract_image(resp) -> Image.Image:
    cands = resp.candidates or []
    if not cands:
        raise RuntimeError(f"no candidates (prompt_feedback={getattr(resp, 'prompt_feedback', None)!r})")
    for cand in cands:
        content = getattr(cand, "content", None)
        if content is None or not getattr(content, "parts", None):
            raise RuntimeError(f"empty content (finish_reason={getattr(cand, 'finish_reason', None)!r})")
        for part in content.parts:
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                data = inline.data
                if isinstance(data, str):
                    import base64 as b64
                    data = b64.b64decode(data)
                return Image.open(io.BytesIO(data))
    raise RuntimeError("no inline image data in any candidate part")


def generate(client: genai.Client, piece: Piece, reference: Image.Image, tone: str) -> Image.Image:
    full_prompt = f"{STYLE.format(tone=tone)}\n\n{piece.prompt}"
    last_err: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = client.models.generate_content(
                model=MODEL,
                contents=[reference, full_prompt],
                config=types.GenerateContentConfig(response_modalities=["IMAGE"]),
            )
            return _extract_image(resp)
        except Exception as e:  # noqa: BLE001
            last_err = e
            wait = 2 ** attempt
            print(f"  [{piece.name}] attempt {attempt}/{MAX_RETRIES} failed: {e!r}; sleeping {wait}s")
            time.sleep(wait)
    raise RuntimeError(f"giving up on {piece.name}: {last_err!r}")


def strip_background(img: Image.Image, tolerance: int = 36) -> Image.Image:
    """Key out the flat background by flood-filling inward from the corners.

    Image models almost never emit real alpha, so we ask for a flat white
    backdrop and remove it here. Flood-filling (rather than thresholding on
    brightness) preserves white HIGHLIGHTS inside the figurine, since those
    aren't connected to the frame edge.
    """
    img = img.convert("RGBA")
    rgb = img.convert("RGB")
    width, height = img.size
    sentinel = (255, 0, 255)
    for corner in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]:
        if sum(rgb.getpixel(corner)) < 600:
            continue  # corner isn't background-bright; don't eat the artwork
        ImageDraw.floodfill(rgb, corner, sentinel, thresh=tolerance)
    flat = np.array(rgb)
    mask = np.all(flat == np.array(sentinel, dtype=flat.dtype), axis=-1)
    out = np.array(img)
    out[mask, 3] = 0
    return Image.fromarray(out, "RGBA")


def fit_to_reference(img: Image.Image, ref_size: tuple[int, int]) -> Image.Image:
    """Trim transparent padding, then letterbox onto the King's canvas size so
    the new piece scales identically on the board."""
    img = img.convert("RGBA")
    bbox = img.getbbox()
    if bbox:
        img = img.crop(bbox)
    target_w, target_h = ref_size
    scale = min(target_w / img.width, target_h / img.height)
    new_size = (max(1, int(img.width * scale)), max(1, int(img.height * scale)))
    img = img.resize(new_size, Image.LANCZOS)
    canvas = Image.new("RGBA", ref_size, (0, 0, 0, 0))
    canvas.paste(img, ((target_w - img.width) // 2, (target_h - img.height) // 2), img)
    return canvas


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="list piece names")
    ap.add_argument("--only", default=None, help="comma-separated piece names")
    ap.add_argument("--force", action="store_true", help="regenerate existing art")
    ap.add_argument("--colors", default="white,black", help="which sides to generate")
    ap.add_argument("--isolate", action="store_true", help="re-key existing art, no API calls")
    args = ap.parse_args()

    if args.list:
        for p in PIECES:
            print(f"  {p.name}")
        return 0

    if args.isolate:
        n = 0
        for color in [c.strip() for c in args.colors.split(",") if c.strip()]:
            ref = Image.open(ICONS_DIR / f"King_{color}.png").convert("RGBA")
            for piece in PIECES:
                if args.only and piece.name.lower() not in {x.strip().lower() for x in args.only.split(",")}:
                    continue
                path = ICONS_DIR / f"{piece.name}_{color}.png"
                if not path.exists():
                    continue
                img = fit_to_reference(strip_background(Image.open(path)), ref.size)
                img.save(path)
                n += 1
                print(f"  isolated {path.name}")
        print(f"re-keyed {n} image(s)")
        return 0

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        return 2

    wanted = None
    if args.only:
        wanted = {n.strip().lower() for n in args.only.split(",")}
    colors = [c.strip() for c in args.colors.split(",") if c.strip()]

    client = genai.Client(api_key=api_key)
    tones = {"white": "bright polished pewter/silver", "black": "dark gunmetal/blackened iron"}

    failures = 0
    for color in colors:
        ref_path = ICONS_DIR / f"King_{color}.png"
        if not ref_path.exists():
            print(f"ERROR: reference {ref_path} missing", file=sys.stderr)
            return 2
        reference = Image.open(ref_path).convert("RGBA")
        for piece in PIECES:
            if wanted and piece.name.lower() not in wanted:
                continue
            out = ICONS_DIR / f"{piece.name}_{color}.png"
            if out.exists() and not args.force:
                print(f"  skip {out.name} (exists)")
                continue
            print(f"generating {out.name} ...")
            try:
                img = generate(client, piece, reference, tones.get(color, "cast metal"))
                img = fit_to_reference(strip_background(img), reference.size)
                img.save(out)
                print(f"  wrote {out} {img.size}")
            except Exception as e:  # noqa: BLE001
                failures += 1
                print(f"  FAILED {piece.name}_{color}: {e!r}", file=sys.stderr)

    if failures:
        print(f"\n{failures} generation(s) failed", file=sys.stderr)
        return 1
    print("\nDone. Re-open the Godot editor once to import the new textures.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
