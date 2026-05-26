"""Generate footstep SFX via the ElevenLabs Sound Effects API.

Generates one short sound per (floor_type, footwear) pair. Per the design,
each footstep recipe is a tight ~0.5s sample focused on a single step so
ProceduralCharacter can trigger it on every step event.

Reads ELEVEN_LABS_API_KEY (or ELEVENLABS_API_KEY) from env. Writes mp3s to
../sfx/ named footstep_<floor>_<footwear>.mp3.

Usage:
    python tools/generate_footstep_sfx.py          # skip existing files
    python tools/generate_footstep_sfx.py --force  # regenerate all
    python tools/generate_footstep_sfx.py --only footstep_stone_boots
"""

from __future__ import annotations
import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path

API_URL = "https://api.elevenlabs.io/v1/sound-generation"
SFX_DIR = Path(__file__).resolve().parent.parent / "sfx"

PROMPT_INFLUENCE = 0.7  # tighter adherence — we want the exact surface, not interpretation
DURATION = 0.5          # shortest ElevenLabs allows; one crisp step

DRY_TAIL = "single quick footstep, close mic, dry, no music, no voice, no reverb"

FOOTSTEP_RECIPES: dict[str, dict] = {
    # ---- BOOTS variants: louder, harder transient
    "footstep_stone_boots": {
        "prompt": f"single sharp heavy leather boot stepping on flat stone, hard heel strike, "
                  f"crisp slap with brief gritty scrape, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_wood_boots": {
        "prompt": f"single heavy leather boot stepping on solid wooden plank, deep hollow thud, "
                  f"slight creak underfoot, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_dirt_boots": {
        "prompt": f"single heavy boot stepping on packed dirt, soft muted thud with faint gravel crunch, "
                  f"earthy compression, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_grass_boots": {
        "prompt": f"single heavy boot stepping on soft grass and dry leaves, gentle crunch and rustle, "
                  f"muted earth underneath, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_shallow_water_boots": {
        "prompt": f"single heavy boot stomping into shallow ankle-deep water, sharp wet splash with "
                  f"strong water spray, {DRY_TAIL}",
        "duration": DURATION,
    },

    # ---- BARE variants: softer, quieter, less transient
    "footstep_stone_bare": {
        "prompt": f"single bare human foot padding softly on cool flat stone, faint skin slap, "
                  f"very quiet, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_wood_bare": {
        "prompt": f"single bare human foot padding on wooden floorboard, soft skin pat, "
                  f"slight floorboard creak, very quiet, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_dirt_bare": {
        "prompt": f"single bare human foot stepping on soft dirt and dust, very quiet dull pat, "
                  f"barely audible earth compression, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_grass_bare": {
        "prompt": f"single bare human foot stepping on cool damp grass, soft whisper-quiet rustle, "
                  f"almost silent, {DRY_TAIL}",
        "duration": DURATION,
    },
    "footstep_shallow_water_bare": {
        "prompt": f"single bare foot stepping carefully into shallow ankle-deep water, soft small "
                  f"splash, gentle ripple, {DRY_TAIL}",
        "duration": DURATION,
    },
}


def generate(api_key: str, prompt: str, duration: float) -> bytes:
    payload = json.dumps({
        "text": prompt,
        "duration_seconds": duration,
        "prompt_influence": PROMPT_INFLUENCE,
    }).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return resp.read()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true",
                        help="overwrite files that already exist")
    parser.add_argument("--only", default="",
                        help="comma-separated subset of basenames")
    args = parser.parse_args()

    key = os.environ.get("ELEVEN_LABS_API_KEY") or os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        print("ERROR: ELEVEN_LABS_API_KEY not set in environment.", file=sys.stderr)
        return 1

    SFX_DIR.mkdir(parents=True, exist_ok=True)

    selected = FOOTSTEP_RECIPES
    if args.only:
        wanted = {s.strip() for s in args.only.split(",") if s.strip()}
        selected = {k: v for k, v in FOOTSTEP_RECIPES.items() if k in wanted}
        if not selected:
            print(f"ERROR: --only matched nothing. Known: {sorted(FOOTSTEP_RECIPES)}",
                  file=sys.stderr)
            return 1

    failures: list[str] = []
    for basename, recipe in selected.items():
        out_path = SFX_DIR / f"{basename}.mp3"
        if out_path.exists() and not args.force:
            print(f"  skip   {out_path.name} (exists; pass --force to overwrite)")
            continue
        prompt_preview = recipe["prompt"][:60].replace("\n", " ")
        print(f"  gen    {out_path.name}  ({recipe['duration']}s)  \"{prompt_preview}...\"")
        try:
            audio = generate(key, recipe["prompt"], recipe["duration"])
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")[:500]
            print(f"  FAIL   {out_path.name}  HTTP {e.code}: {body}", file=sys.stderr)
            failures.append(basename)
            continue
        except Exception as e:  # noqa: BLE001
            print(f"  FAIL   {out_path.name}  {type(e).__name__}: {e}", file=sys.stderr)
            failures.append(basename)
            continue
        out_path.write_bytes(audio)
        print(f"  ok     {out_path.name}  ({len(audio):,} bytes)")

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}", file=sys.stderr)
        return 2
    print("\nAll done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
