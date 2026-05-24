"""Generate hex worldmap tiles by carving large continuous landscape paintings.

Approach:
  1) Generate a single 2048x2048 painted landscape (e.g. a forest, plains, coast).
  2) Carve a staggered flat-top hex grid out of it. Adjacent carved hexes tile
     perfectly because they were painted as one image.
  3) Save each hex as a separate PNG with a transparent hexagonal alpha mask.

Outputs:
  tfa-simultaneous-gemini-1/Assets/HexTiles/
    sources/<scene>.png            -- the raw landscape image
    sources/<scene>_grid.png       -- the landscape with hex grid overlay (debug)
    <scene>/<scene>_c<col>_r<row>.png  -- carved hex tiles

Usage:
    python tools/generate_hex_landscape.py --scene forest_summer --test
    python tools/generate_hex_landscape.py --scene forest_summer
    python tools/generate_hex_landscape.py --list           # list known scenes
    python tools/generate_hex_landscape.py --all            # all scenes
"""
from __future__ import annotations

import argparse
import io
import math
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

IMAGEN_MODEL = os.environ.get("HEX_TILES_IMAGEN_MODEL", "imagen-4.0-generate-001")
GEMINI_IMAGE_MODEL = os.environ.get("HEX_TILES_GEMINI_MODEL", "gemini-3-pro-image-preview")
SOURCE_SIZE = 2048             # 2048x2048 source landscapes
HEX_WIDTH = 384                # final hex width (left-point to right-point)
CROP_FRACTION = 0.10           # crop this fraction off each side before carving
                               # (removes torn-page / vignette borders the model loves to add)
OUT_ROOT = Path("tfa-simultaneous-gemini-1") / "Assets" / "HexTiles"
REFERENCE_PATH = OUT_ROOT / "sources" / "forest_summer.png"   # style/perspective anchor
MAX_RETRIES = 4

# Extra instructions appended when a reference image is supplied (style-match mode)
REFERENCE_DIRECTIVE = (
    "Match the painted style AND the perspective of the reference image exactly: "
    "a strictly top-down map view, as if looking straight down at the terrain from "
    "directly overhead. No horizon. No sky. No background. The entire frame is "
    "ground/terrain. Same color palette, same illustrative shading, same scale. "
    "Render hills and mountains as seen from directly above: show their rocky tops "
    "and ridgelines from overhead, with soft cast shadows on the surrounding ground "
    "to convey height, the same way the reference shows tree canopies from straight "
    "above."
)

# Directive for image-edit mode (when --edit is passed)
EDIT_DIRECTIVE = (
    "Take the reference image and produce a new image that is IDENTICAL to it in "
    "composition, coastlines, shapes, palette, drawing style, paper texture, and "
    "framing, EXCEPT for the specific change requested in the scene prompt. Treat "
    "the reference as the canonical base; only the change explicitly requested "
    "should differ in the output."
)

# ---------------------------------------------------------------------------
# Style preamble shared by every scene prompt
# ---------------------------------------------------------------------------

STYLE = (
    "An aged hand-drawn fantasy worldmap in the style of an antique paper "
    "cartograph (Tolkien-style maps, or the Semillan Protectorates by Tim Paul). "
    "The background is warm cream/tan parchment with subtle aging stains and "
    "faint paper texture. All terrain is rendered with delicate sepia/brown ink "
    "linework over soft muted watercolor washes. Faded antique palette: dusty "
    "sage greens, sand and ochre, faded earth-brown, muted blue-grey water, "
    "soft cream.\n\n"
    "Terrain features are drawn as small stylized icons in the overhead map "
    "convention. The image is a tight zoomed-in viewport showing only a small "
    "interior section of a much larger antique map (about 30 miles of terrain "
    "across), cropped from the middle of the map far from any coastline or "
    "border. The depicted terrain extends to all four edges of the frame — the "
    "frame is a window onto the interior of the map. The parchment surface is "
    "plain and unruled, showing only natural age-stains and the terrain art "
    "itself. No border decorations, no title cartouche, no compass rose, no "
    "heraldry, no legend scroll, no text, no marginal illustrations, no map "
    "grid lines, no lattice, no ruled lines."
)


@dataclass
class Scene:
    name: str
    prompt: str  # appended to STYLE


SCENES: list[Scene] = [
    # ---- Pure biomes (carve any hex to get a tile of that biome) -----------
    Scene("forest_summer",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "covered in summer forest. Drawn as a dense cluster of small stylized "
        "tree icons — round olive-green canopies with tiny brown trunk marks — "
        "in delicate sepia ink with soft muted watercolor wash over warm "
        "parchment. Trees arranged ORGANICALLY at IRREGULAR spacing so the "
        "whole region reads as one continuous forest biome. The forest fills "
        "the entire image edge-to-edge with tree icons reaching all four "
        "edges of the frame."),
    Scene("forest_autumn",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "covered in autumn forest. Drawn as a dense cluster of small stylized "
        "tree icons — round canopies in muted antique russet, ochre, and burnt-"
        "orange watercolor wash with tiny brown trunk marks — in delicate sepia "
        "ink over warm parchment. Trees arranged ORGANICALLY at IRREGULAR "
        "spacing across the whole region. The forest fills the entire image "
        "edge-to-edge with tree icons reaching all four edges of the frame."),
    Scene("forest_winter",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "covered in winter forest. Drawn as a dense cluster of bare leafless "
        "tree icons — small spindly sepia ink branch silhouettes over pale "
        "cream and soft blue-grey watercolor wash — with a few scattered dark "
        "evergreen icons mixed in. Trees arranged ORGANICALLY at IRREGULAR "
        "spacing across the whole region. The forest fills the entire image "
        "edge-to-edge with tree icons reaching all four edges of the frame."),
    Scene("forest_spring",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "covered in spring forest. Drawn as a dense cluster of small stylized "
        "tree icons — round canopies in fresh dusty-green watercolor wash with "
        "tiny pink and white blossom dots scattered through — in delicate sepia "
        "ink over warm parchment. Trees arranged ORGANICALLY at IRREGULAR "
        "spacing across the whole region. The forest fills the entire image "
        "edge-to-edge with tree icons reaching all four edges of the frame."),
    Scene("plains",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "open plains. Light dusty-sage and ochre watercolor wash over warm "
        "parchment with delicate sepia ink texture, a few wisps of grass and "
        "scattered tiny flower marks suggesting open grassland. Uniform plains "
        "throughout. The plains terrain fills the entire image edge-to-edge "
        "with grass and flower marks reaching all four edges of the frame."),
    Scene("swamp",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "murky swampland. Dark mossy-green and brown watercolor wash over warm "
        "parchment with thin curly blue-ink water-channel lines threading "
        "through, small stylized reed and lily-pad marks scattered ORGANICALLY "
        "at IRREGULAR spacing, and a few small twisted gnarled-tree icons in "
        "dark sepia ink. Uniform swamp throughout. The swamp fills the entire "
        "image edge-to-edge with mossy wash, reeds, and water channels reaching "
        "all four edges of the frame."),
    Scene("mountain_range",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "mountainous. Many small stylized mountain icons — pointed grey-brown "
        "peaks with simple snow caps, drawn in sepia ink with soft grey-blue "
        "watercolor wash — clustered ORGANICALLY across the entire frame at "
        "IRREGULAR spacing. Each icon is small relative to the frame (dozens "
        "of mountain icons across the image, not a few large peaks). The whole "
        "region reads as continuous mountain terrain. The mountain icons fill "
        "the entire image edge-to-edge, reaching all four edges of the frame."),
    Scene("shallow_ocean",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "open sea. Soft turquoise and aquamarine watercolor wash over cream "
        "parchment, with delicate thin sepia ink wave lines and tiny stippled "
        "marks evenly across the whole frame. A uniform shallow-sea texture. "
        "The water fills the entire image edge-to-edge with the wash and wave "
        "marks reaching all four edges of the frame."),
    Scene("deep_ocean",
        "A continuous section of antique hand-drawn fantasy worldmap, all of it "
        "deep open ocean. Muted dusty navy-blue watercolor wash over cream "
        "parchment with delicate thin sepia ink curls indicating choppy waves "
        "and the occasional tiny stylized wave-foam mark. A uniform deep-sea "
        "texture. The water fills the entire image edge-to-edge with the wash "
        "and wave marks reaching all four edges of the frame."),
    Scene("lake_district",
        "A continuous section of antique hand-drawn fantasy worldmap showing "
        "several small lakes scattered across open plains. The plains are "
        "dusty-sage watercolor wash with delicate sepia ink texture; the lakes "
        "are small irregular blue-ink-outlined patches of muted blue watercolor "
        "wash with thin reed marks around the edges. Lakes vary in size and "
        "shape, placed ORGANICALLY with IRREGULAR spacing across the whole "
        "frame. The plains terrain fills the entire image edge-to-edge with "
        "the grass and lake marks reaching all four edges of the frame."),

    # ---- Biome transitions (harvest hexes along the boundary) --------------
    Scene("forest_to_plains_vertical",
        "A continuous section of antique hand-drawn fantasy worldmap. The LEFT "
        "40 percent is dense forest drawn as a cluster of small olive-green "
        "tree icons with sepia ink trunk marks. The RIGHT 40 percent is open "
        "plains in dusty-sage and ochre watercolor wash with scattered grass "
        "and flower marks. The middle 20 percent is a natural irregular "
        "meandering tree line where outlying tree icons stand alone on the "
        "plains side and small grass patches appear inside the forest side. "
        "The boundary runs vertically (north-south) across the frame."),
    Scene("forest_to_plains_diagonal",
        "A continuous section of antique hand-drawn fantasy worldmap. The "
        "UPPER-LEFT region is dense forest drawn as small olive-green tree "
        "icons. The LOWER-RIGHT region is open plains in dusty-sage watercolor "
        "wash with grass and flower marks. Between them an irregular tree line "
        "runs at roughly a 45-degree diagonal, with outlying trees on the "
        "plains side and grass patches on the forest side."),
    Scene("plains_to_mountains",
        "A continuous section of antique hand-drawn fantasy worldmap. The "
        "LOWER 55 percent is open plains in dusty-sage watercolor wash with "
        "scattered grass and flower marks. The UPPER 45 percent is mountain "
        "terrain drawn as small clustered pointed peak icons in sepia ink with "
        "grey-blue watercolor wash and snow caps. The two terrains meet in a "
        "meandering line of small foothill icons and stylized boulder marks. "
        "The mountain line runs roughly horizontally across the frame, curving "
        "gently."),
    Scene("forest_to_swamp",
        "A continuous section of antique hand-drawn fantasy worldmap. The LEFT "
        "40 percent is dense forest drawn as small olive-green tree icons. The "
        "RIGHT 40 percent is murky swampland in mossy-green wash with thin "
        "curly blue water-channel lines and twisted gnarled-tree icons. The "
        "middle 20 percent is a natural transition where the bright forest "
        "gradually grows mossier, with small patches of standing water "
        "appearing among the trees."),

    # ---- Coastline (harvest beach hexes; boundary at varied angles) --------
    Scene("coast_plains_horizontal",
        "A continuous section of antique hand-drawn fantasy worldmap. The UPPER "
        "55 percent is open plains in dusty-sage and ochre watercolor wash with "
        "grass marks. The LOWER 45 percent is shallow sea in soft turquoise "
        "watercolor wash with delicate sepia wave lines. Between them a natural "
        "curving sandy-cream coastline drawn as a soft brown ink line with a "
        "thin pale sand band runs roughly horizontally across the image, "
        "curving gently — coming further inland on the left, receding on the "
        "right."),
    Scene("coast_plains_diagonal",
        "A continuous section of antique hand-drawn fantasy worldmap. The "
        "UPPER-LEFT region is open plains in dusty-sage watercolor wash. The "
        "LOWER-RIGHT region is shallow sea in soft turquoise watercolor wash "
        "with sepia wave lines. Between them a natural sandy-cream coastline "
        "drawn as a soft brown ink line runs at roughly a 45-degree diagonal "
        "across the frame, curving gently."),
    Scene("coast_forest_horizontal",
        "A continuous section of antique hand-drawn fantasy worldmap. The UPPER "
        "55 percent is dense forest drawn as small olive-green tree icons over "
        "warm parchment. The LOWER 45 percent is shallow sea in soft turquoise "
        "watercolor wash with sepia wave lines. Between them a natural sandy-"
        "cream coastline drawn as a soft brown ink line with a thin pale sand "
        "band runs horizontally across the frame, curving gently. The tree "
        "icons sit just inland of the coast."),
    Scene("coast_mountain",
        "A continuous section of antique hand-drawn fantasy worldmap. The UPPER "
        "55 percent is mountain terrain drawn as small clustered pointed peak "
        "icons in sepia ink and grey-blue wash with snow caps. The LOWER 45 "
        "percent is shallow sea in soft turquoise watercolor wash with sepia "
        "wave lines. Between them a natural rocky-and-sandy coastline drawn as "
        "a brown ink line with a few scattered boulder marks runs horizontally "
        "across the frame."),
    Scene("coast_swamp",
        "A continuous section of antique hand-drawn fantasy worldmap. The UPPER "
        "55 percent is murky swampland in mossy-green wash with thin curly blue "
        "water-channel lines and twisted gnarled-tree icons. The LOWER 45 "
        "percent is shallow sea in soft turquoise watercolor wash with sepia "
        "wave lines. Between them a natural muddy coastline drawn as a brown "
        "ink line gradually transitions from brackish swamp to open sea."),

    # ---- Rivers (harvest hexes the river passes through) -------------------
    Scene("river_through_plains_NS",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "open plains, with a wide meandering RIVER (drawn as a blue watercolor-filled water channel with thin sepia ink banks on either side, clearly water not land) flowing VERTICALLY "
        "through the entire image, entering at the top edge and exiting at the "
        "bottom edge. The river is a thin blue ink line with soft watercolor "
        "wash. The surrounding plains are dusty-sage and ochre watercolor wash "
        "over warm parchment with scattered tiny grass and flower marks."),
    Scene("river_through_plains_diagonal",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "open plains, with a wide meandering RIVER (drawn as a blue watercolor-filled water channel with thin sepia ink banks on either side, clearly water not land) flowing diagonally "
        "through the entire image, entering near the UPPER-LEFT corner area "
        "and exiting near the LOWER-RIGHT corner area at roughly a 30-degree "
        "slope. The river is a thin blue ink line with soft watercolor wash. "
        "The surrounding plains are dusty-sage and ochre watercolor wash with "
        "grass and flower marks."),
    Scene("river_through_forest_NS",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "summer forest drawn as small olive-green tree icons, with a thin "
        "meandering blue-ink RIVER flowing VERTICALLY through the entire "
        "image, entering at the top edge and exiting at the bottom edge. Tree "
        "icons cluster on both sides of the river with a thin sand-colored "
        "bank between water and trees."),
    Scene("river_through_forest_autumn_NS",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "autumn forest drawn as small russet and ochre tree icons, with a thin "
        "meandering blue-ink RIVER flowing VERTICALLY through the entire image, "
        "entering at the top edge and exiting at the bottom edge. Scattered "
        "tiny fallen-leaf dot marks line the riverbanks."),
    Scene("river_through_forest_winter_NS",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "winter forest drawn as small bare leafless sepia tree icons and a few "
        "dark evergreen icons over cream and pale blue-grey wash, with a thin "
        "meandering blue-ink RIVER flowing VERTICALLY through the entire image, "
        "entering at the top edge and exiting at the bottom edge. Snow-toned "
        "cream banks separate water from tree icons."),
    Scene("river_through_forest_spring_NS",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "spring forest drawn as small fresh-green tree icons with tiny pink "
        "and white blossom dots, with a wide meandering RIVER (drawn as a blue watercolor-filled water channel with thin sepia ink banks on either side, clearly water not land) flowing "
        "VERTICALLY through the entire image, entering at the top edge and "
        "exiting at the bottom edge. Fresh dusty-green banks with small flower "
        "marks line the river."),

    # ---- Settlements in context (harvest the central hex as the settlement) -
    Scene("small_village_in_plains",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "open plains, with a small village icon CENTERED in the image. The "
        "village is a small cluster of tiny drawn cottage icons (pointed "
        "thatched roofs in muted brown) around a central well, with a few "
        "faint road lines connecting it to the edges of the frame. The "
        "surrounding plains are dusty-sage watercolor wash with scattered "
        "grass and flower marks. The village occupies roughly the central 20 "
        "percent of the image."),
    Scene("large_village_in_plains",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "open plains, with a larger village icon CENTERED in the image. The "
        "village is a cluster of about fifteen mixed cottage and workshop "
        "icons in muted brown and brick-red around a small central market "
        "square and a tiny chapel icon, with faint dirt-road lines and "
        "stylized quilted farmland patches in muted pink, cream, and ochre "
        "surrounding it. The village occupies roughly the central 25 percent "
        "of the image."),
    Scene("city_in_plains",
        "A continuous section of antique hand-drawn fantasy worldmap, mostly "
        "open plains, with a SMALL walled-city icon CENTERED in the image. "
        "The city is a small stylized icon (occupying only the central 12-15 "
        "percent of the image — about the size of a small coin in the middle "
        "of the frame) of a ring of stone walls around clustered tower and "
        "building icons, drawn in sepia ink with muted watercolor wash. Faint "
        "cream-colored road lines radiate outward to the edges. The "
        "surrounding plains are dusty-sage watercolor wash with scattered "
        "grass and flower marks; the plains fill the rest of the image edge-"
        "to-edge."),
]


# ---------------------------------------------------------------------------
# Hex math (flat-top hex grid)
# ---------------------------------------------------------------------------

def hex_centers(image_size: int, hex_width: int) -> list[tuple[int, int, int, int]]:
    """Return (col, row, cx, cy) for every hex fully inside the image.

    Flat-top hex: width W = hex_width (left-point to right-point), height H = W * sqrt(3)/2.
    Columns are spaced (3W/4) apart horizontally. Odd columns are shifted down by H/2.
    """
    W = hex_width
    H = W * math.sqrt(3) / 2
    col_pitch = 3 * W / 4
    row_pitch = H

    centers: list[tuple[int, int, int, int]] = []
    col = 0
    while True:
        cx = (W / 2) + col * col_pitch
        if cx + W / 2 > image_size + 0.5:
            break
        y_offset = (row_pitch / 2) if (col % 2 == 1) else 0
        row = 0
        while True:
            cy = (H / 2) + y_offset + row * row_pitch
            if cy + H / 2 > image_size + 0.5:
                break
            centers.append((col, row, int(round(cx)), int(round(cy))))
            row += 1
        col += 1
    return centers


def flat_top_hex_mask(size_w: int, size_h: int) -> Image.Image:
    """L-mode mask: 255 inside a centered flat-top hex (width=size_w, height=size_h), 0 outside."""
    mask = Image.new("L", (size_w, size_h), 0)
    d = ImageDraw.Draw(mask)
    cx, cy = size_w / 2, size_h / 2
    r = size_w / 2  # circumradius for flat-top hex = half-width
    pts = [
        (cx + r * math.cos(math.radians(60 * k)), cy + r * math.sin(math.radians(60 * k)))
        for k in range(6)
    ]
    d.polygon(pts, fill=255)
    return mask


def crop_borders(img: Image.Image, fraction: float) -> Image.Image:
    """Crop `fraction` off each side and resize back to the original dimensions.
    Used to remove torn-page / vignette artifacts the model adds around the frame."""
    if fraction <= 0:
        return img
    w, h = img.size
    dx = int(round(w * fraction))
    dy = int(round(h * fraction))
    cropped = img.crop((dx, dy, w - dx, h - dy))
    return cropped.resize((w, h), Image.LANCZOS)


def carve_hexes(source: Image.Image, hex_width: int, scene_name: str, out_dir: Path) -> int:
    """Carve all hexes from `source`, save each as a transparent PNG. Returns count."""
    W = hex_width
    H = int(round(W * math.sqrt(3) / 2))
    mask = flat_top_hex_mask(W, H)
    centers = hex_centers(source.size[0], hex_width)
    out_dir.mkdir(parents=True, exist_ok=True)

    for col, row, cx, cy in centers:
        left = cx - W // 2
        top = cy - H // 2
        crop = source.crop((left, top, left + W, top + H)).convert("RGBA")
        crop.putalpha(mask)
        crop.save(out_dir / f"{scene_name}_c{col}_r{row}.png", "PNG")
    return len(centers)


def draw_grid_overlay(source: Image.Image, hex_width: int) -> Image.Image:
    """Return a copy of source with hex grid lines drawn on top (debug helper)."""
    img = source.copy().convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    W = hex_width
    H = W * math.sqrt(3) / 2
    for col, row, cx, cy in hex_centers(img.size[0], hex_width):
        pts = [
            (cx + (W / 2) * math.cos(math.radians(60 * k)),
             cy + (W / 2) * math.sin(math.radians(60 * k)))
            for k in range(6)
        ]
        d.polygon(pts, outline=(255, 0, 255, 200))
        d.text((cx - 16, cy - 6), f"{col},{row}", fill=(255, 255, 255, 220))
    return Image.alpha_composite(img, overlay)


# ---------------------------------------------------------------------------
# Gemini / Imagen call
# ---------------------------------------------------------------------------

def _imagen_call(client: genai.Client, scene: Scene, image_size: str) -> Image.Image:
    """Call Imagen 4 (text-only) and return the first generated PIL image."""
    full_prompt = f"{STYLE}\n\n{scene.prompt}"
    cfg = types.GenerateImagesConfig(
        number_of_images=1,
        aspect_ratio="1:1",
        image_size=image_size,
        person_generation="dont_allow",
        safety_filter_level="block_low_and_above",
    )
    resp = client.models.generate_images(model=IMAGEN_MODEL, prompt=full_prompt, config=cfg)
    if not resp.generated_images:
        raise RuntimeError(f"no images returned (rai={getattr(resp, 'rai_filtered_reason', None)})")
    img_obj = resp.generated_images[0].image
    if hasattr(img_obj, "image_bytes") and img_obj.image_bytes:
        return Image.open(io.BytesIO(img_obj.image_bytes))
    if hasattr(img_obj, "_pil_image") and img_obj._pil_image is not None:
        return img_obj._pil_image
    raise RuntimeError(f"unexpected image object type: {type(img_obj)}")


def _gemini_image_call(
    client: genai.Client,
    scene: Scene,
    reference: Image.Image | None,
    edit_mode: bool = False,
    prompt_override: str | None = None,
) -> Image.Image:
    """Call Gemini Image model with optional reference image. Returns PIL image."""
    parts: list = []
    if reference is not None:
        parts.append(reference)
    scene_text = prompt_override if prompt_override is not None else scene.prompt
    directive = EDIT_DIRECTIVE if edit_mode else REFERENCE_DIRECTIVE
    parts.append(f"{STYLE}\n\n{scene_text}\n\n{directive if reference else ''}".strip())
    resp = client.models.generate_content(
        model=GEMINI_IMAGE_MODEL,
        contents=parts,
        config=types.GenerateContentConfig(response_modalities=["IMAGE"]),
    )
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


def generate_landscape(
    client: genai.Client,
    scene: Scene,
    image_size: str = "2K",
    reference_path: Path | None = None,
    edit_mode: bool = False,
    prompt_override: str | None = None,
) -> Image.Image:
    """Produce a 2K landscape for `scene`. If `reference_path` is given, anchors
    style/perspective on that image via gemini-3-pro-image (or in edit-mode, uses
    the EDIT_DIRECTIVE to preserve the reference's composition)."""
    reference: Image.Image | None = None
    if reference_path:
        if not reference_path.exists():
            raise RuntimeError(f"reference image missing: {reference_path}")
        # Force-load so the file can be safely overwritten before save.
        reference = Image.open(reference_path).convert("RGB")
        reference.load()

    last_err: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            if reference is not None:
                return _gemini_image_call(client, scene, reference, edit_mode, prompt_override)
            return _imagen_call(client, scene, image_size)
        except Exception as e:  # noqa: BLE001
            last_err = e
            wait = 2 ** attempt
            print(f"  [{scene.name}] attempt {attempt}/{MAX_RETRIES} failed: {e!r}; sleeping {wait}s")
            time.sleep(wait)
    raise RuntimeError(f"giving up on {scene.name}: {last_err!r}")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def run_scene(
    client: genai.Client,
    scene: Scene,
    force: bool,
    image_size: str,
    reference_path: Path | None = None,
    edit_mode: bool = False,
    prompt_override: str | None = None,
) -> None:
    sources_dir = OUT_ROOT / "sources"
    sources_dir.mkdir(parents=True, exist_ok=True)
    src_path = sources_dir / f"{scene.name}.png"
    grid_path = sources_dir / f"{scene.name}_grid.png"
    carve_dir = OUT_ROOT / scene.name

    if src_path.exists() and not force:
        print(f"  [{scene.name}] source exists, reusing -> {src_path}")
        source = Image.open(src_path)
    else:
        if reference_path:
            mode = f"gemini-image+edit (ref={reference_path.name})" if edit_mode else f"gemini-image (ref={reference_path.name})"
        else:
            mode = "imagen"
        print(f"  [{scene.name}] generating landscape ({mode})...")
        source = generate_landscape(
            client, scene,
            image_size=image_size,
            reference_path=reference_path,
            edit_mode=edit_mode,
            prompt_override=prompt_override,
        )
        if source.size != (SOURCE_SIZE, SOURCE_SIZE):
            print(f"    upscaling {source.size} -> {SOURCE_SIZE}x{SOURCE_SIZE}")
            source = source.resize((SOURCE_SIZE, SOURCE_SIZE), Image.LANCZOS)
        source.save(src_path, "PNG")
        print(f"    saved source -> {src_path}")

    working = crop_borders(source, CROP_FRACTION)
    if CROP_FRACTION > 0:
        cropped_path = sources_dir / f"{scene.name}_cropped.png"
        working.save(cropped_path, "PNG")
        print(f"    cropped {CROP_FRACTION*100:.0f}% off each side -> {cropped_path}")
    n = carve_hexes(working, HEX_WIDTH, scene.name, carve_dir)
    draw_grid_overlay(working, HEX_WIDTH).save(grid_path, "PNG")
    print(f"    carved {n} hexes -> {carve_dir}/  (grid overlay -> {grid_path})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", help="single scene name to run (see --list)")
    ap.add_argument("--list", action="store_true", help="list known scene names")
    ap.add_argument("--all", action="store_true", help="run every scene")
    ap.add_argument("--force", action="store_true", help="regenerate source even if it exists")
    ap.add_argument("--image-size", default="2K", help="Imagen image_size: '1K' or '2K'")
    ap.add_argument("--test", action="store_true", help="generate just forest_summer")
    ap.add_argument("--reference", action="store_true",
                    help="use the default reference image (forest_summer.png) as a style/perspective anchor")
    ap.add_argument("--ref", default=None,
                    help="path to a specific reference image (overrides --reference's default)")
    ap.add_argument("--edit", action="store_true",
                    help="treat the reference as a base image to edit, preserving its composition")
    ap.add_argument("--prompt", default=None,
                    help="override the scene's prompt text (useful for ad-hoc edit instructions)")
    args = ap.parse_args()

    if args.list:
        for s in SCENES:
            print(f"  {s.name}")
        return 0

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        return 2
    client = genai.Client(api_key=api_key)

    if args.test:
        targets = [next(s for s in SCENES if s.name == "forest_summer")]
    elif args.all:
        targets = list(SCENES)
    elif args.scene:
        try:
            targets = [next(s for s in SCENES if s.name == args.scene)]
        except StopIteration:
            print(f"ERROR: unknown scene '{args.scene}'. Use --list to see options.", file=sys.stderr)
            return 2
    else:
        ap.print_help()
        return 0

    # Resolve reference path: --ref takes precedence; else --reference uses the default.
    reference_path: Path | None = None
    if args.ref:
        reference_path = Path(args.ref)
    elif args.reference:
        reference_path = REFERENCE_PATH

    fail = 0
    for s in targets:
        try:
            run_scene(
                client, s,
                force=args.force,
                image_size=args.image_size,
                reference_path=reference_path,
                edit_mode=args.edit,
                prompt_override=args.prompt,
            )
        except Exception as e:  # noqa: BLE001
            fail += 1
            print(f"FAIL [{s.name}]: {e}")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
