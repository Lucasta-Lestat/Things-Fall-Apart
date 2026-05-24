"""Generate 10 fantasy-battlemap attempts across multiple Gemini image models.

The reference is a top-down hand-drawn fantasy compound: stone walls enclosing
a courtyard, multiple wooden-roofed buildings, fenced gardens with crops, a
river along one edge, all painted in warm watercolor over parchment.

Outputs go to tools/map_outputs/ as 01_<model>_<variant>.png with a sidecar
JSON of the prompt used. Errors are logged but never abort the batch.

Run from repo root:
    python tools/generate_map_attempts.py
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv
from google import genai
from google.genai import types

load_dotenv()

API_KEY = os.environ.get("GEMINI_API_KEY")
if not API_KEY:
    sys.exit("GEMINI_API_KEY not set (check .env)")

OUT_DIR = Path(__file__).resolve().parent / "map_outputs"
OUT_DIR.mkdir(exist_ok=True)

BASE_DESCRIPTION = (
    "Top-down digital battlemap illustration in the 2-Minute Tabletop / Czepeku "
    "style. Clean crisp ink linework with flat watercolor fills, bright "
    "saturated colors, soft drop shadows under walls. Bird's-eye orthographic "
    "view of a small fortified medieval compound that fills the entire frame "
    "edge to edge. Thick stone perimeter walls drawn as light grey blocks with "
    "dark ink outlines form an irregular rectangular enclosure with corner "
    "towers and a wooden gatehouse, hugging the outer edge of the image. "
    "A large prominent central main hall dominates the middle of the compound, "
    "roughly a quarter of the entire map area, drawn cutaway with no roof so "
    "the interior is fully visible: a long red-tile floor down a great hall "
    "with rows of long wooden dining tables and benches, a tall hearth at one "
    "end, banners on the inner walls, a raised dais with a chair. Surrounding "
    "this central hall, organically spaced and at varied angles, are smaller "
    "stone-and-timber outbuildings (chapel, stable, barracks, kitchen, "
    "smithy), every single building shown cutaway with no roof so all "
    "furniture inside is visible from above: beds with quilts, chairs, "
    "tables, fireplaces, looms, anvils, barrels, sacks, crates. Between and "
    "around buildings, organically scattered: fenced garden plots as green "
    "rectangles with rows of vegetables (cabbages, onions, herbs), an orchard "
    "with fruit trees, a cobbled courtyard with a stone well, wooden carts. "
    "A clear medium-blue river flows along the right edge with sandy beige "
    "banks, crossed by small wooden footbridges. Lush green grass fills every "
    "gap between buildings, grass extends all the way to the image edges. "
    "Warm earthy palette: terracotta, ochre, moss, soft blue."
)

VARIANTS: list[tuple[str, str]] = [
    (
        "imagen-4.0-generate-001",
        "fortified_compound_v1",
        BASE_DESCRIPTION,
    ),
    (
        "imagen-4.0-generate-001",
        "monastery_v1",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "small walled monastery with cloister courtyard",
        ),
    ),
    (
        "imagen-4.0-generate-001",
        "frontier_keep_v1",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "frontier border keep with a great hall and watchtowers",
        ),
    ),
    (
        "imagen-4.0-ultra-generate-001",
        "fortified_compound_ultra",
        BASE_DESCRIPTION
        + " Highly detailed ink linework with painterly watercolor washes inside the shapes.",
    ),
    (
        "imagen-4.0-ultra-generate-001",
        "manor_estate_ultra",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "noble manor estate enclosed by a low stone wall",
        )
        + " Highly detailed ink linework with painterly watercolor washes inside the shapes.",
    ),
    (
        "imagen-4.0-fast-generate-001",
        "village_hamlet_fast",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "small walled village hamlet",
        ),
    ),
    (
        "imagen-4.0-fast-generate-001",
        "trading_post_fast",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "remote trading post with merchant stalls and warehouses",
        ),
    ),
    (
        "gemini-2.5-flash-image",
        "fortified_compound_flash",
        BASE_DESCRIPTION,
    ),
    (
        "gemini-2.5-flash-image",
        "abbey_garden_flash",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "small walled abbey with extensive herb and vegetable gardens",
        ),
    ),
    (
        "gemini-2.5-flash-image",
        "river_outpost_flash",
        BASE_DESCRIPTION.replace(
            "A clear blue river flows along the right edge",
            "A wide clear river dominates the right third of the map",
        ).replace(
            "small fortified medieval compound",
            "riverside outpost built around a stone bridge",
        ),
    ),
]


@dataclass
class Result:
    index: int
    model: str
    variant: str
    status: str
    path: str | None = None
    error: str | None = None


def save_imagen(client: genai.Client, model: str, prompt: str, out_path: Path) -> None:
    resp = client.models.generate_images(
        model=model,
        prompt=prompt,
        config=types.GenerateImagesConfig(
            number_of_images=1,
            aspect_ratio="4:3",
            person_generation="dont_allow",
        ),
    )
    if not resp.generated_images:
        raise RuntimeError("no images returned")
    img = resp.generated_images[0].image
    data = img.image_bytes
    out_path.write_bytes(data)


def save_gemini_image(client: genai.Client, model: str, prompt: str, out_path: Path) -> None:
    resp = client.models.generate_content(
        model=model,
        contents=prompt,
    )
    for cand in resp.candidates or []:
        for part in cand.content.parts or []:
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                data = inline.data
                if isinstance(data, str):
                    data = base64.b64decode(data)
                out_path.write_bytes(data)
                return
    raise RuntimeError("no image part in response")


def main() -> None:
    client = genai.Client(api_key=API_KEY)
    results: list[Result] = []

    for i, (model, variant, prompt) in enumerate(VARIANTS, start=1):
        stem = f"{i:02d}_{model.replace('.', '-').replace('/', '-')}_{variant}"
        out_path = OUT_DIR / f"{stem}.png"
        meta_path = OUT_DIR / f"{stem}.json"

        print(f"[{i:02d}/10] {model} :: {variant}")
        t0 = time.time()
        try:
            if model.startswith("imagen"):
                save_imagen(client, model, prompt, out_path)
            else:
                save_gemini_image(client, model, prompt, out_path)
            dt = time.time() - t0
            print(f"        OK  {out_path.name}  ({dt:.1f}s, {out_path.stat().st_size} bytes)")
            results.append(Result(i, model, variant, "ok", str(out_path)))
        except Exception as e:
            dt = time.time() - t0
            print(f"        ERR ({dt:.1f}s) {type(e).__name__}: {e}")
            results.append(Result(i, model, variant, "error", error=f"{type(e).__name__}: {e}"))

        meta_path.write_text(json.dumps({
            "index": i,
            "model": model,
            "variant": variant,
            "prompt": prompt,
        }, indent=2))

    summary_path = OUT_DIR / "_summary.json"
    summary_path.write_text(json.dumps([r.__dict__ for r in results], indent=2))
    print(f"\nSummary written to {summary_path}")
    ok = sum(1 for r in results if r.status == "ok")
    print(f"{ok}/{len(results)} succeeded")


if __name__ == "__main__":
    main()
