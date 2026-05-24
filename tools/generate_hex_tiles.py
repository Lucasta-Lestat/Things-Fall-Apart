"""Generate worldmap hex tiles via Gemini 2.5 Flash Image (Nano Banana).

Tile set: flat-top hex tiles, painted fantasy illustration style, 512x512 RGBA.
Outputs to tfa-simultaneous-gemini-1/Assets/HexTiles/{base,river,beach}/.

The script is idempotent: re-running skips tiles already on disk.
Set HEX_TILES_FORCE=1 to overwrite. Use --only <pattern> to filter.

Run from repo root:
    python tools/generate_hex_tiles.py            # generate everything
    python tools/generate_hex_tiles.py --only plains     # only matching names
    python tools/generate_hex_tiles.py --only base/      # only the base folder
    python tools/generate_hex_tiles.py --test            # one test tile then stop
"""
from __future__ import annotations

import argparse
import io
import math
import os
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image

MODEL = os.environ.get("HEX_TILES_MODEL", "gemini-2.5-flash-image")
OUTPUT_SIZE = 512
OUT_ROOT = Path("tfa-simultaneous-gemini-1") / "Assets" / "HexTiles"
MAX_WORKERS = 4
MAX_RETRIES = 4

STYLE = (
    "A square map tile rendered in a painted fantasy illustration style, viewed top-down "
    "from a fantasy adventure-map perspective. Painted terrain fills the entire square "
    "frame edge to edge, with no border, no vignette, and no frame. Warm painted colors, "
    "soft shading. No text, no labels, no borders, no compass, no UI, no grid lines, no "
    "characters or figures, no decorative frames.\n\n"
    "*** CRITICAL TILEABLE-EDGE RULE — this is the most important rule, do not violate it ***\n"
    "This tile will be placed in a hexagonal grid next to other tiles. To prevent visible "
    "seams, the OUTER 20% of the frame (a margin strip around all four edges, including "
    "the corners) MUST contain ONLY flat continuous ground appropriate to the terrain — "
    "for example plain grass, plain snow, plain rocky ground, plain water, plain sand. "
    "NO discrete objects of any kind may be placed in that outer margin: no whole trees, "
    "no bushes, no rocks/boulders, no buildings, no roads, no fences, no rivers, no "
    "creatures. Nothing may be cut off by any edge of the frame. All distinct features "
    "(trees, buildings, etc.) must be fully contained within the CENTRAL 60% of the frame "
    "with empty ground around them, like islands in a sea of plain ground. Small ground-"
    "level texture (grass blades, tiny pebbles, leaf litter, dirt patches, ripples) is OK "
    "near the edges as long as no single feature is cut. Even partial features near the "
    "edges are forbidden."
)

BASE_TILES: dict[str, str] = {
    "plains": "Rolling green grassland. The outer 20% margin is plain even grass with only ground-level texture (grass blades, tiny pebbles, small dirt patches). The central 60% contains scattered wildflower clusters, taller grass tufts, and at most three or four small distinct bushes — fully enclosed within the central area, not touching any edge.",
    "forest_summer": "A deciduous forest in summer. The outer 20% margin is plain grassy forest-floor with leaf litter (NO whole tree trunks or canopies in that margin). The central 60% contains a dense cluster of six to ten fully-visible deciduous trees with bright green canopies, dappled shadow, and small clearings between trunks. Every tree is fully inside the central area; no tree is cut by any edge.",
    "forest_autumn": "A deciduous forest in autumn. The outer 20% margin is plain grass and earth with fallen orange/red/yellow leaves scattered as flat texture (NO whole tree trunks in that margin). The central 60% contains a dense cluster of six to ten fully-visible deciduous trees with vibrant orange, red, and yellow canopies. Every tree is fully inside the central area; no tree is cut by any edge.",
    "forest_winter": "A deciduous forest in winter. The outer 20% margin is plain snow-covered ground with only faint texture (NO whole tree trunks in that margin). The central 60% contains six to ten fully-visible bare deciduous trees and a few dark evergreens, all fully enclosed. No tree is cut by any edge.",
    "forest_spring": "A deciduous forest in spring. The outer 20% margin is plain fresh grass with small scattered wildflowers as flat texture (NO whole tree trunks in that margin). The central 60% contains six to ten fully-visible deciduous trees with young green leaves and pink/white blossoms. No tree is cut by any edge.",
    "swamp": "Murky marshland. The outer 20% margin is flat muddy/grassy ground or shallow stagnant water with lily pad texture (NO whole gnarled trees in that margin). The central 60% contains three to five fully-visible twisted gnarled trees with hanging moss, fog patches, and a fallen log or two, all fully enclosed. No tree or log is cut by any edge.",
    "mountain": "A single rocky mountain peak centered in the frame, occupying the central 60% only. The mountain has grey stone, a snow-capped summit, and jagged ridges, and is fully contained within the central area. The outer 20% margin is plain rocky/grassy foothill ground with only ground-level texture — no part of the mountain or any boulder reaches the edges.",
    "lake": "A freshwater lake. Deep blue water with gentle ripples fills the central 60%, with reed-lined banks just inside it. The outer 20% margin is plain grass with only ground-level texture. The lake does not touch any edge.",
    "shallow_ocean": "Shallow tropical ocean water filling the ENTIRE frame uniformly, turquoise and aquamarine, sandy seabed visible through the water, gentle waves and sparkles. This is an all-water tile — the safe-zone rule is satisfied because the entire image is continuous water texture with no discrete objects.",
    "deep_ocean": "Deep ocean water filling the ENTIRE frame uniformly, dark navy and indigo with whitecaps and choppy waves. This is an all-water tile — the safe-zone rule is satisfied because the entire image is continuous water texture with no discrete objects.",
    "small_village": "A tiny rural village seen from above. The outer 20% margin is plain grass with only ground-level texture (NO buildings, NO fences, NO roads in that margin). The central 60% contains four to six fully-visible thatched-roof cottages clustered around a small central well, with short dirt paths between them and small fenced garden patches — all fully enclosed within the central area. No cottage, fence, or path is cut by any edge.",
    "large_village": "A larger village seen from above. The outer 20% margin is plain grass and farmland texture (NO buildings, NO road segments in that margin). The central 60% contains twelve to fifteen fully-visible mixed thatch- and tile-roofed buildings clustered around a central market square, with a small chapel and intersecting dirt roads that stay inside the central area. No building or road is cut by any edge.",
    "city": "A walled fantasy city seen from above. The outer 20% margin is plain grass or paved approach with only ground-level texture (NO buildings, NO wall segments in that margin). The central 60% contains a fully-visible walled city: stone walls forming a ring, packed stone and timber buildings inside, several tall towers, a central plaza, fortified gates, paved roads radiating only within the wall. The wall and all buildings are fully enclosed within the central area; nothing is cut by any edge.",
}

# Land tiles eligible for beach edge variants
BEACH_BASES = [
    "plains", "forest_summer", "forest_autumn", "forest_winter", "forest_spring",
    "swamp", "mountain", "small_village", "large_village", "city",
]

# Land tiles eligible for river through-flow variants
RIVER_BASES = ["plains", "forest_summer", "forest_autumn", "forest_winter", "forest_spring"]

# River through-axes (three unique orientations on a flat-top hex)
# RIVER EXCEPTION: the river is the only feature allowed to touch edges, and only
# at the two specified edge midpoints. Banks of the river within the outer margin
# must be plain grass (no trees, no rocks).
RIVER_DIRECTIONS: dict[str, str] = {
    "NS": (
        "A wide winding river runs vertically through the image, ENTERING exactly at the "
        "midpoint of the top edge and EXITING exactly at the midpoint of the bottom edge. "
        "Blue water with gentle reflections; plain grassy banks on either side. The river "
        "is the ONLY feature permitted to touch the frame edges, and it must touch only "
        "those two midpoints. Where the river meets the top and bottom edges, the banks "
        "are plain grass with no trees, bushes, or rocks; all other features stay inside "
        "the central 60% as in the base rule."
    ),
    "NE_SW": (
        "A wide winding river runs diagonally across the image, ENTERING near the top "
        "edge close to the upper-right corner (about 80% of the way along the top edge) "
        "and EXITING near the bottom edge close to the lower-left corner (about 20% of "
        "the way along the bottom edge), curving naturally between. Blue water with "
        "gentle reflections; plain grassy banks. The river is the ONLY feature permitted "
        "to touch the frame edges, and only at those two points. All other features stay "
        "inside the central 60%."
    ),
    "NW_SE": (
        "A wide winding river runs diagonally across the image, ENTERING near the top "
        "edge close to the upper-left corner (about 20% of the way along the top edge) "
        "and EXITING near the bottom edge close to the lower-right corner (about 80% of "
        "the way along the bottom edge), curving naturally between. Blue water with "
        "gentle reflections; plain grassy banks. The river is the ONLY feature permitted "
        "to touch the frame edges, and only at those two points. All other features stay "
        "inside the central 60%."
    ),
}

# Beach edges around a flat-top hex (top/bottom flat, four angled)
# BEACH EXCEPTION: the water and sand may extend to the SPECIFIED edge across its
# entire width; all OTHER edges still obey the safe-zone rule (only continuous ground,
# no discrete features within the outer 20%).
_BEACH_TAIL = (
    " The water and sand are the ONLY things allowed to touch that one specified edge; "
    "all other edges of the frame still follow the base rule (only continuous ground, "
    "no whole or partial trees/bushes/rocks/buildings within the outer 20%). All "
    "discrete land features remain inside the central 60% on the inland side."
)
BEACH_EDGES: dict[str, str] = {
    "N":  "Along the TOP edge of the frame the land transitions into a curving sandy beach and then into shallow turquoise ocean water that occupies roughly the top third of the image. Soft surf line and gentle wavefront parallel to the top edge. Scattered tiny seashells in the sand." + _BEACH_TAIL,
    "S":  "Along the BOTTOM edge of the frame the land transitions into a curving sandy beach and then into shallow turquoise ocean water that occupies roughly the bottom third of the image. Soft surf line and gentle wavefront parallel to the bottom edge." + _BEACH_TAIL,
    "NE": "In the UPPER-RIGHT corner area of the frame, a sandy beach gives way to shallow turquoise ocean water. The coastline runs from a point on the top edge (about 70% of the way across) down to a point on the right edge (about 30% from the top), at roughly a 60-degree angle. Water occupies the upper-right wedge of the image; the surf line is parallel to the coastline." + _BEACH_TAIL,
    "SE": "In the LOWER-RIGHT corner area of the frame, a sandy beach gives way to shallow turquoise ocean water. The coastline runs from a point on the right edge (about 70% from the top) down to a point on the bottom edge (about 70% of the way across). Water occupies the lower-right wedge of the image; the surf line is parallel to the coastline." + _BEACH_TAIL,
    "SW": "In the LOWER-LEFT corner area of the frame, a sandy beach gives way to shallow turquoise ocean water. The coastline runs from a point on the left edge (about 70% from the top) down to a point on the bottom edge (about 30% of the way across). Water occupies the lower-left wedge of the image; the surf line is parallel to the coastline." + _BEACH_TAIL,
    "NW": "In the UPPER-LEFT corner area of the frame, a sandy beach gives way to shallow turquoise ocean water. The coastline runs from a point on the top edge (about 30% of the way across) down to a point on the left edge (about 30% from the top). Water occupies the upper-left wedge of the image; the surf line is parallel to the coastline." + _BEACH_TAIL,
}


@dataclass
class TileJob:
    name: str       # e.g. "plains" or "forest_autumn_river_NS"
    folder: str     # "base" | "river" | "beach"
    prompt: str     # full text prompt sent to the model


def build_prompt(terrain_desc: str, extra: str = "") -> str:
    parts = [STYLE, f"Terrain: {terrain_desc}."]
    if extra:
        parts.append(extra)
    return "\n\n".join(parts)


def all_jobs() -> list[TileJob]:
    jobs: list[TileJob] = []

    # Base tiles
    for name, desc in BASE_TILES.items():
        jobs.append(TileJob(name=name, folder="base", prompt=build_prompt(desc)))

    # River variants
    for base in RIVER_BASES:
        base_desc = BASE_TILES[base]
        for dir_key, dir_desc in RIVER_DIRECTIONS.items():
            jobs.append(TileJob(
                name=f"{base}_river_{dir_key}",
                folder="river",
                prompt=build_prompt(base_desc, dir_desc),
            ))

    # Beach variants
    for base in BEACH_BASES:
        base_desc = BASE_TILES[base]
        for edge_key, edge_desc in BEACH_EDGES.items():
            jobs.append(TileJob(
                name=f"{base}_beach_{edge_key}",
                folder="beach",
                prompt=build_prompt(base_desc, edge_desc),
            ))

    return jobs


# ----- Hex mask & post-processing ---------------------------------------------

def flat_top_hex_mask(size: int) -> Image.Image:
    """Return an L-mode mask: 255 inside a centered flat-top regular hexagon, 0 outside.

    Hex is sized to fit the square: width = size (left point to right point),
    height = size * sqrt(3)/2. Centered. Slight margin avoids seams from JPEG-ish
    blur the model sometimes adds at the very edge.
    """
    from PIL import ImageDraw
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    cx, cy = size / 2, size / 2
    r = size / 2  # circumradius = half width
    # Flat-top hex vertices at angles 0, 60, 120, 180, 240, 300 (deg) from center
    pts = []
    for k in range(6):
        ang = math.radians(60 * k)
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    draw.polygon(pts, fill=255)
    return mask


HEX_MASK = flat_top_hex_mask(OUTPUT_SIZE)


def postprocess(raw: Image.Image) -> Image.Image:
    """Crop to a square, resize to OUTPUT_SIZE, apply hex mask to alpha."""
    # Center-crop to square (in case model returns non-square)
    w, h = raw.size
    side = min(w, h)
    left = (w - side) // 2
    top = (h - side) // 2
    sq = raw.crop((left, top, left + side, top + side))
    sq = sq.resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.LANCZOS).convert("RGBA")
    # Use our hex mask as the alpha channel
    sq.putalpha(HEX_MASK)
    return sq


# ----- API call ---------------------------------------------------------------

def generate_one(client: genai.Client, job: TileJob, out_path: Path) -> None:
    last_err: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = client.models.generate_content(
                model=MODEL,
                contents=[job.prompt],
                config=types.GenerateContentConfig(
                    response_modalities=["IMAGE"],
                ),
            )
            img = _extract_image(resp)
            if img is None:
                raise RuntimeError("No image in response")
            postprocess(img).save(out_path, "PNG")
            return
        except Exception as e:  # noqa: BLE001
            last_err = e
            wait = 2 ** attempt
            print(f"  [{job.name}] attempt {attempt}/{MAX_RETRIES} failed: {e!r}; sleeping {wait}s")
            time.sleep(wait)
    raise RuntimeError(f"giving up on {job.name}: {last_err!r}")


def _extract_image(resp) -> Image.Image | None:
    """Pull the first inline image out of a Gemini response."""
    cands = resp.candidates or []
    if not cands:
        pf = getattr(resp, "prompt_feedback", None)
        raise RuntimeError(f"no candidates returned (prompt_feedback={pf!r})")
    for cand in cands:
        content = getattr(cand, "content", None)
        if content is None or not getattr(content, "parts", None):
            finish = getattr(cand, "finish_reason", None)
            safety = getattr(cand, "safety_ratings", None)
            raise RuntimeError(
                f"candidate has no content (finish_reason={finish!r}, safety={safety!r})"
            )
        for part in content.parts:
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                data = inline.data
                if isinstance(data, str):
                    import base64 as b64
                    data = b64.b64decode(data)
                return Image.open(io.BytesIO(data))
    return None


# ----- Driver -----------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="substring filter on folder/name (e.g. 'forest', 'beach/', 'plains')")
    ap.add_argument("--test", action="store_true", help="generate just one test tile (plains) and stop")
    ap.add_argument("--workers", type=int, default=MAX_WORKERS)
    ap.add_argument("--force", action="store_true", help="overwrite existing tiles")
    args = ap.parse_args()

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        return 2
    client = genai.Client(api_key=api_key)

    # Make sure output dirs exist
    for sub in ("base", "river", "beach"):
        (OUT_ROOT / sub).mkdir(parents=True, exist_ok=True)

    jobs = all_jobs()
    if args.test:
        jobs = [j for j in jobs if j.name == "plains"]
    elif args.only:
        jobs = [j for j in jobs if args.only in f"{j.folder}/{j.name}"]

    force = args.force or os.environ.get("HEX_TILES_FORCE") == "1"
    todo: list[tuple[TileJob, Path]] = []
    for j in jobs:
        p = OUT_ROOT / j.folder / f"{j.name}.png"
        if p.exists() and not force:
            continue
        todo.append((j, p))

    print(f"Generating {len(todo)} of {len(jobs)} tiles "
          f"({len(jobs) - len(todo)} already exist) into {OUT_ROOT}")
    if not todo:
        return 0

    ok, fail = 0, 0
    start = time.time()
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {pool.submit(generate_one, client, j, p): (j, p) for (j, p) in todo}
        for fut in as_completed(futs):
            j, p = futs[fut]
            try:
                fut.result()
                ok += 1
                print(f"  OK  [{ok + fail}/{len(todo)}] {j.folder}/{j.name}.png")
            except Exception as e:  # noqa: BLE001
                fail += 1
                print(f"  FAIL [{ok + fail}/{len(todo)}] {j.folder}/{j.name}: {e}")
                traceback.print_exc(limit=1)

    elapsed = time.time() - start
    print(f"\nDone in {elapsed:.1f}s. OK={ok} FAIL={fail}")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
