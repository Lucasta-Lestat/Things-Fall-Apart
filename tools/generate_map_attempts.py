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
    "saturated colors, soft drop shadows under walls. Architectural floor plan "
    "view: the camera is positioned directly above the scene at exactly 90 "
    "degrees looking straight down, like a satellite photo, so every wall is "
    "drawn as a thin outlined rectangle and every roof opening reveals the "
    "floor below. A grassy meadow extends to every corner and the very "
    "edges of the picture, with a small fortified medieval compound sitting "
    "in the middle of that meadow. Thick stone perimeter walls drawn as light "
    "grey blocks with dark ink outlines enclose the compound; the wall hugs "
    "the outer edge of the meadow with a single wooden gatehouse on one side. "
    "Inside the walls there are only two freestanding buildings, each "
    "separated from the perimeter walls and from each other by open grass: "
    "(1) a large prominent central main hall that dominates the middle of "
    "the compound and takes up roughly a quarter of the entire picture, drawn "
    "cutaway with no roof so the interior is fully visible from above, a long "
    "red-tile floor running its length, two rows of long wooden dining tables "
    "and benches, a tall stone hearth at one end, a raised dais with a wooden "
    "chair at the other end, banners hanging on the inner walls; "
    "(2) a small wooden stable off to one side, also cutaway with no roof, "
    "showing straw piles, stalls, a water trough. "
    "A cobbled courtyard with a single stone well sits in front of the "
    "central hall. A clear medium-blue river flows along the right edge of "
    "the picture outside the walls with a sandy beige bank. Warm earthy "
    "palette: terracotta, ochre, moss, soft blue."
)

ULTRA = "imagen-4.0-ultra-generate-001"
DETAIL_SUFFIX = (
    " Highly detailed ink linework with painterly watercolor washes inside "
    "the shapes."
)

VARIANTS: list[tuple[str, str, str]] = [
    (
        ULTRA,
        "base_v6a",
        BASE_DESCRIPTION + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "base_v6b",
        BASE_DESCRIPTION + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "floorplan_emphasis",
        BASE_DESCRIPTION
        + " Composition reads as an architectural floor plan or game map, "
          "completely flat, no three-dimensional rendering of building sides."
        + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "satellite_emphasis",
        BASE_DESCRIPTION
        + " The image looks like a top-down hand-painted version of a "
          "satellite photograph, every element seen from directly above."
        + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "larger_hall",
        BASE_DESCRIPTION.replace(
            "takes up roughly a quarter of the entire picture",
            "takes up roughly a third of the entire picture and is clearly "
            "the largest single feature in the scene",
        )
        + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "no_river",
        BASE_DESCRIPTION.replace(
            "A clear medium-blue river flows along the right edge of "
            "the picture outside the walls with a sandy beige bank. ",
            "",
        )
        + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "monastery",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "small walled monastery",
        )
        + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "manor_estate",
        BASE_DESCRIPTION.replace(
            "small fortified medieval compound",
            "noble manor estate inside a low stone wall",
        )
        + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "warm_palette_push",
        BASE_DESCRIPTION
        + " Warm sunlit afternoon palette, soft cream stone, deep red roof "
          "accents, lush emerald grass, gentle painterly shading."
        + DETAIL_SUFFIX,
    ),
    (
        ULTRA,
        "tighter_composition",
        BASE_DESCRIPTION.replace(
            "Inside the walls there are only two freestanding buildings, "
            "each separated from the perimeter walls and from each other by "
            "open grass: ",
            "Inside the walls there are only two freestanding buildings, "
            "each surrounded on every side by at least one building's width "
            "of open grass so nothing touches anything else: ",
        )
        + DETAIL_SUFFIX,
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
