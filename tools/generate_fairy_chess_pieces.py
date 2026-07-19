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
RAW_DIR = Path("tools") / "_fairy_chess_raw"  # kept diptychs, for re-splitting
MAX_RETRIES = 4

# Shared style, anchored on the King reference the caller passes in.
STYLE = (
    "A single image containing TWO views of the SAME fantasy CHESS PIECE "
    "figurine, side by side with a clear empty gap between them, both rendered "
    "exactly like the reference images: small cast-metal tabletop miniatures, "
    "photographed straight on at eye level, standing on round pedestal bases. "
    "LEFT copy: bright polished pewter/silver metal (the light army). RIGHT "
    "copy: dark gunmetal/blackened iron (the dark army). They must be the "
    "IDENTICAL sculpt in the IDENTICAL pose at the IDENTICAL size -- the same "
    "piece cast in two different metals, not two different models. Match the "
    "reference lighting and fine sculpted detail. "
    "Both stand on a COMPLETELY FLAT, UNIFORM PURE WHITE (#FFFFFF) background "
    "that touches all four edges -- no gradient, no vignette, no checkerboard, "
    "no ground shadow, no scenery, no text, no labels, no border. "
    "Each figure is strictly frontal and bilaterally SYMMETRICAL left-to-right, "
    "with nothing that reads as a front or a back -- no cape trailing to one "
    "side, no turned head, no weapon or prop held out to one side only -- so "
    "the piece looks correct to a player seated on either side of the board. "
    "Both figures fill the frame vertically with a small even margin above the "
    "head and below the base."
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


def generate(client: genai.Client, piece: Piece, references: list) -> Image.Image:
    full_prompt = f"{STYLE}\n\n{piece.prompt}"
    last_err: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = client.models.generate_content(
                model=MODEL,
                contents=references + [full_prompt],
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


def find_figure_clusters(img: Image.Image, min_gap_frac: float = 0.015) -> list:
    """Column ranges of the distinct figures in an image.

    Gaps narrower than `min_gap_frac` of the width are treated as part of the
    same figure (the space between an arm and a torso, say) so a single
    figurine isn't reported as two.
    """
    arr = np.array(img.convert("RGBA"))
    if arr.size == 0:
        return []
    filled = (arr[:, :, 3] > 16).sum(axis=0) > 0
    width = len(filled)
    min_gap = max(4, int(width * min_gap_frac))

    spans = []
    start = None
    for x in range(width):
        if filled[x] and start is None:
            start = x
        elif not filled[x] and start is not None:
            spans.append([start, x])
            start = None
    if start is not None:
        spans.append([start, width])
    if not spans:
        return []

    merged = [spans[0]]
    for span in spans[1:]:
        if span[0] - merged[-1][1] < min_gap:
            merged[-1][1] = span[1]
        else:
            merged.append(span)
    # Ignore specks (stray artefacts), keep real figures.
    widest = max(s[1] - s[0] for s in merged)
    return [tuple(s) for s in merged if (s[1] - s[0]) > widest * 0.25]


def split_pair(img: Image.Image) -> tuple[Image.Image, Image.Image]:
    """Extract the (light, dark) figures from a multi-up image.

    The model is asked for two figures but sometimes renders the pair twice
    (four figurines: light, light, dark, dark). Cropping the LEFTMOST cluster
    as light and the RIGHTMOST as dark is correct for both layouts, and beats
    halving the canvas -- which would hand back two figures per half.
    Expects the background to have been keyed out already.
    """
    clusters = find_figure_clusters(img)
    if len(clusters) >= 2:
        left, right = clusters[0], clusters[-1]
        pad = 6
        return (
            img.crop((max(0, left[0] - pad), 0, min(img.width, left[1] + pad), img.height)),
            img.crop((max(0, right[0] - pad), 0, min(img.width, right[1] + pad), img.height)),
        )
    mid = img.width // 2
    return img.crop((0, 0, mid, img.height)), img.crop((mid, 0, img.width, img.height))


def looks_like_one_figure(img: Image.Image) -> bool:
    """True if a cropped half holds exactly one figurine."""
    return len(find_figure_clusters(img)) == 1


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
    ap.add_argument("--resplit", action="store_true", help="re-cut saved diptychs, no API calls")
    args = ap.parse_args()

    if args.list:
        for p in PIECES:
            print(f"  {p.name}")
        return 0

    if args.resplit:
        refs = [Image.open(ICONS_DIR / f"King_{c}.png").convert("RGBA") for c in ("white", "black")]
        n = 0
        for piece in PIECES:
            if args.only and piece.name.lower() not in {x.strip().lower() for x in args.only.split(",")}:
                continue
            raw_path = RAW_DIR / f"{piece.name}_pair.png"
            if not raw_path.exists():
                print(f"  no saved diptych for {piece.name}")
                continue
            light, dark = split_pair(Image.open(raw_path))
            for color, half in (("white", light), ("black", dark)):
                if not looks_like_one_figure(half):
                    print(f"  WARNING: {piece.name}_{color} still looks like two figures", file=sys.stderr)
                fit_to_reference(half, refs[0].size).save(ICONS_DIR / f"{piece.name}_{color}.png")
            n += 1
            print(f"  re-split {piece.name}")
        print(f"re-split {n} piece(s)")
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

    failures = 0
    refs = []
    for color in ("white", "black"):
        ref_path = ICONS_DIR / f"King_{color}.png"
        if not ref_path.exists():
            print(f"ERROR: reference {ref_path} missing", file=sys.stderr)
            return 2
        refs.append(Image.open(ref_path).convert("RGBA"))
    ref_size = refs[0].size

    for piece in PIECES:
        if wanted and piece.name.lower() not in wanted:
            continue
        outputs = {c: ICONS_DIR / f"{piece.name}_{c}.png" for c in colors}
        if all(p.exists() for p in outputs.values()) and not args.force:
            print(f"  skip {piece.name} (exists)")
            continue
        print(f"generating {piece.name} (light + dark in one pass) ...")
        try:
            raw = generate(client, piece, refs)
            keyed = strip_background(raw)
            # Keep the diptych so a bad split can be re-cut without paying for
            # another generation (see --resplit).
            raw_path = RAW_DIR / f"{piece.name}_pair.png"
            RAW_DIR.mkdir(parents=True, exist_ok=True)
            keyed.save(raw_path)
            light, dark = split_pair(keyed)
            halves = {"white": light, "black": dark}
            for color, path in outputs.items():
                if not looks_like_one_figure(halves[color]):
                    print(f"  WARNING: {piece.name}_{color} split looks like it caught "
                          f"two figures; re-cut with --resplit or regenerate", file=sys.stderr)
                img = fit_to_reference(halves[color], ref_size)
                img.save(path)
                print(f"  wrote {path} {img.size}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"  FAILED {piece.name}: {e!r}", file=sys.stderr)

    if failures:
        print(f"\n{failures} generation(s) failed", file=sys.stderr)
        return 1
    print("\nDone. Re-open the Godot editor once to import the new textures.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
