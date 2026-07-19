#!/usr/bin/env python3
"""Generate fairy-chess piece art with Gemini, keyed off the existing King art.

The King_white / King_black icons define the look: a pewter tabletop figurine
against transparency, ~512x1024. Every new piece is generated from that
reference so the set stays visually consistent, then matched to the King's
canvas size and alpha-trimmed the same way.

IMPORTANT -- how the two armies are told apart: NOT by colour. Every piece in
the set is the same pewter. The sides differ by FACING. Looking at the board
from white's seat you see your own pieces from BEHIND and the enemy's facing
you, so:
    <piece>_white  = the figurine viewed from BEHIND (no face)
    <piece>_black  = the same figurine viewed from the FRONT
Each generation therefore produces one two-up image -- rear view on the left,
front view on the right -- which is split into those two files.

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
VARIANT_DIR = RAW_DIR / "variants"           # candidate art awaiting a human pick
MAX_RETRIES = 4

# Shared style, anchored on the two King references passed in.
#
# The set does NOT distinguish the two armies by colour -- every piece is the
# same pewter. The sides are told apart by WHICH WAY THE PIECE FACES: your own
# army is seen from behind, the enemy army faces you. So each generation is one
# figurine photographed twice, rear view and front view, and the halves map to
# <piece>_white (rear) and <piece>_black (front).
STYLE = (
    "A single image containing TWO photographs of the SAME fantasy CHESS PIECE "
    "figurine, side by side with a clear empty gap between them, rendered "
    "exactly like the reference images: a small cast-metal tabletop miniature "
    "photographed straight on at eye level, standing on a round pedestal base. "
    "LEFT photograph: the figurine seen from BEHIND -- its back to the camera, "
    "showing the back of the head/helmet and the back of the cloak or body, "
    "with NO face visible at all. "
    "RIGHT photograph: the SAME figurine seen from the FRONT -- facing the "
    "camera, face and frontal detail visible. "
    "Both photographs show the IDENTICAL sculpt at the IDENTICAL size in the "
    "IDENTICAL metal: the SAME aged pewter / antique silver tone as the "
    "reference, with the same lighting and fine sculpted detail. Do NOT make "
    "one copy darker or a different colour than the other -- they are one "
    "miniature shot from two angles, not a light and a dark army. "
    "Both stand on a COMPLETELY FLAT, UNIFORM PURE WHITE (#FFFFFF) background "
    "that touches all four edges -- no gradient, no vignette, no checkerboard, "
    "no ground shadow, no scenery, no text, no labels, no border. Keep the "
    "background visible THROUGH any gaps in the figure, such as between the "
    "legs or under a raised arm. "
    "Each figure is bilaterally SYMMETRICAL left-to-right -- no turned head, no "
    "prop held out to one side only -- so it reads cleanly on the board. "
    "CRITICAL: whatever the figure HOLDS (sword, staff, axe, sceptre) is held "
    "in FRONT of its body, so it belongs ONLY in the front view. In the REAR "
    "view the body hides it -- do NOT draw a second copy of the weapon or "
    "staff strapped to, sheathed on, or floating over the figure's back. The "
    "rear view shows only the back of the body, cloak and head; at most the "
    "very tip or pommel may peek past the silhouette if the object is long. "
    "One weapon exists, not two. "
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
        "Strictly symmetrical about the vertical axis."),
    Piece("Doppelganger",
        "The figurine is a DOPPELGANGER: a smooth faceless humanoid with a "
        "blank featureless oval head, standing upright with both arms held "
        "symmetrically at its sides. Its surface looks half-formed and "
        "liquid, as though the metal is still deciding on a shape, with soft "
        "rippling seams flowing down the body. Eerie and anonymous. No face, "
        "no hair, no clothing detail. Strictly symmetrical about the vertical axis."),
    Piece("Berserker",
        "The figurine is a BERSERKER: a bare-chested viking warrior in a "
        "snarling wolf-pelt hood, roaring, holding a broad axe raised in BOTH "
        "hands directly above and in front of the head, arms mirrored evenly "
        "on both sides. Braided beard, fur across both shoulders equally, "
        "heavy boots planted wide on the base. Ferocious and wild. "
        "Strictly symmetrical about the vertical axis."),
    Piece("Chieftain",
        "The figurine is a viking CHIEFTAIN: a broad commanding warrior-king "
        "in a horned-and-winged crowned helm, wearing a heavy fur mantle "
        "draped evenly over both shoulders, both hands resting on the pommel "
        "of a large sword planted point-down and exactly centered in front of "
        "him. Ring-mail and knotwork detailing. Clearly a royal piece, "
        "weathered and imposing. Strictly symmetrical about the vertical axis."),
    Piece("Spymaster",
        "The figurine is a SPYMASTER: a slender hooded figure in a deep cowl "
        "that hides the face entirely in shadow, wrapped in a close cloak that "
        "falls evenly on both sides, both hands drawing the cloak closed at "
        "the center of the chest. A small symmetrical mask motif at the "
        "throat clasp. Secretive and still. No weapon shown. Strictly "
        "symmetrical about the vertical axis."),
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
    return _clear_enclosed_background(Image.fromarray(out, "RGBA"))


def _clear_enclosed_background(img: Image.Image, min_area: int = 120) -> Image.Image:
    """Punch out background trapped INSIDE the figure.

    Corner flood-fill can only reach background connected to the frame edge,
    so enclosed pockets -- the gap between a figure's legs, the hole under a
    raised arm -- survive as opaque white. Those pockets are flat, neutral and
    near-pure-white, which sculpted metal highlights are not, so they can be
    removed by colour without eating the artwork.
    """
    arr = np.array(img.convert("RGBA"))
    height, width = arr.shape[:2]
    rgb = arr[:, :, :3].astype(np.int16)
    # Flat, neutral, very bright, and still opaque = leftover backdrop.
    candidate = (
        (rgb.min(axis=2) >= 232)
        & ((rgb.max(axis=2) - rgb.min(axis=2)) <= 12)
        & (arr[:, :, 3] > 0)
    )
    if not candidate.any():
        return img

    visited = np.zeros((height, width), dtype=bool)
    ys, xs = np.nonzero(candidate)
    for sy, sx in zip(ys, xs):
        if visited[sy, sx]:
            continue
        stack = [(sy, sx)]
        visited[sy, sx] = True
        pocket = []
        while stack:
            y, x = stack.pop()
            pocket.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < height and 0 <= nx < width and candidate[ny, nx] and not visited[ny, nx]:
                    visited[ny, nx] = True
                    stack.append((ny, nx))
        if len(pocket) >= min_area:
            for y, x in pocket:
                arr[y, x, 3] = 0
    return Image.fromarray(arr, "RGBA")


def find_figure_clusters(img: Image.Image, axis: int = 0, min_gap_frac: float = 0.015) -> list:
    """Ranges occupied by distinct figures along one axis.

    axis=0 scans columns (figures side by side), axis=1 scans rows (figures
    stacked). Gaps narrower than `min_gap_frac` are treated as part of the same
    figure -- the space between an arm and a torso, say -- so one figurine
    isn't reported as two.
    """
    arr = np.array(img.convert("RGBA"))
    if arr.size == 0:
        return []
    alpha = arr[:, :, 3] > 16
    filled = alpha.sum(axis=0) > 0 if axis == 0 else alpha.sum(axis=1) > 0
    extent = len(filled)
    min_gap = max(4, int(extent * min_gap_frac))

    spans = []
    start = None
    for i in range(extent):
        if filled[i] and start is None:
            start = i
        elif not filled[i] and start is not None:
            spans.append([start, i])
            start = None
    if start is not None:
        spans.append([start, extent])
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


PAD = 6


def _crop_span(img: Image.Image, span: tuple, axis: int) -> Image.Image:
    lo, hi = span
    if axis == 0:
        return img.crop((max(0, lo - PAD), 0, min(img.width, hi + PAD), img.height))
    return img.crop((0, max(0, lo - PAD), img.width, min(img.height, hi + PAD)))


def split_pair(img: Image.Image) -> tuple[Image.Image, Image.Image]:
    """Extract the (rear-view, front-view) figures from a multi-up image.

    The prompt asks for the pair side by side, but the model freely rearranges:
    sometimes stacked vertically, sometimes the pair rendered twice as a 2x2
    grid. So detect the layout instead of assuming one -- take the first figure
    in reading order as the rear view and the last as the front view.
    Expects the background to have been keyed out already.
    """
    cols = find_figure_clusters(img, axis=0)
    rows = find_figure_clusters(img, axis=1)

    # Side by side.
    if len(cols) >= 2 and len(rows) <= 1:
        return _crop_span(img, cols[0], 0), _crop_span(img, cols[-1], 0)
    # Stacked.
    if len(rows) >= 2 and len(cols) <= 1:
        return _crop_span(img, rows[0], 1), _crop_span(img, rows[-1], 1)
    # A grid: first cell (top-left) is the rear view, last cell the front.
    if len(cols) >= 2 and len(rows) >= 2:
        first = _crop_span(img, cols[0], 0)
        last = _crop_span(img, cols[-1], 0)
        first_rows = find_figure_clusters(first, axis=1)
        last_rows = find_figure_clusters(last, axis=1)
        if first_rows:
            first = _crop_span(first, first_rows[0], 1)
        if last_rows:
            last = _crop_span(last, last_rows[-1], 1)
        return first, last
    # Nothing separable: fall back to halving the longer side.
    if img.width >= img.height:
        mid = img.width // 2
        return img.crop((0, 0, mid, img.height)), img.crop((mid, 0, img.width, img.height))
    mid = img.height // 2
    return img.crop((0, 0, img.width, mid)), img.crop((0, mid, img.width, img.height))


def looks_like_one_figure(img: Image.Image) -> bool:
    """True if a cropped half holds exactly one figurine, on both axes."""
    return len(find_figure_clusters(img, axis=0)) == 1 and len(find_figure_clusters(img, axis=1)) == 1


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
    ap.add_argument("--variants", type=int, default=0,
                    help="generate N candidates per piece into staging; live art untouched")
    ap.add_argument("--promote", default=None,
                    help="adopt staged candidates, e.g. 'Chieftain=2,Praetor=1'")
    args = ap.parse_args()

    if args.list:
        for p in PIECES:
            print(f"  {p.name}")
        return 0

    if args.promote:
        refs = Image.open(ICONS_DIR / "King_white.png").convert("RGBA")
        for token in args.promote.split(","):
            if "=" not in token:
                print(f"  skipping {token!r}: expected Piece=N", file=sys.stderr)
                continue
            name, number = (t.strip() for t in token.split("=", 1))
            moved = 0
            for color in ("white", "black"):
                src = VARIANT_DIR / f"{name}_v{number}_{color}.png"
                if not src.exists():
                    print(f"  missing {src}", file=sys.stderr)
                    continue
                fit_to_reference(Image.open(src), refs.size).save(ICONS_DIR / f"{name}_{color}.png")
                moved += 1
            # Keep the winning diptych as the piece's canonical raw.
            raw_src = VARIANT_DIR / f"{name}_v{number}_pair.png"
            if raw_src.exists():
                Image.open(raw_src).save(RAW_DIR / f"{name}_pair.png")
            if moved:
                print(f"  promoted {name} variant {number}")
        print("Done. Re-open the Godot editor once to import the new textures.")
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
            rear, front = split_pair(Image.open(raw_path))
            for color, half in (("white", rear), ("black", front)):
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

    if args.variants > 0:
        VARIANT_DIR.mkdir(parents=True, exist_ok=True)
        for piece in PIECES:
            if wanted and piece.name.lower() not in wanted:
                continue
            for n in range(1, args.variants + 1):
                print(f"staging {piece.name} variant {n} ...")
                try:
                    raw = generate(client, piece, refs)
                    keyed = strip_background(raw)
                    keyed.save(VARIANT_DIR / f"{piece.name}_v{n}_pair.png")
                    rear, front = split_pair(keyed)
                    for color, half in (("white", rear), ("black", front)):
                        if not looks_like_one_figure(half):
                            print(f"  WARNING: {piece.name} v{n} {color} caught more than one figure",
                                  file=sys.stderr)
                        fit_to_reference(half, ref_size).save(
                            VARIANT_DIR / f"{piece.name}_v{n}_{color}.png")
                    print(f"  staged {piece.name} v{n}")
                except Exception as e:  # noqa: BLE001
                    failures += 1
                    print(f"  FAILED {piece.name} v{n}: {e!r}", file=sys.stderr)
        print(f"\nStaged candidates in {VARIANT_DIR}. Adopt one with --promote 'Piece=N'.")
        if failures:
            return 1
        return 0


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
            rear, front = split_pair(keyed)
            halves = {"white": rear, "black": front}  # own army seen from behind
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
