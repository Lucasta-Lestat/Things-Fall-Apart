#!/usr/bin/env python3
"""Generate speaking-mouth animation frames for character portraits.

For each target character, this uses gemini-2.5-flash-image (with the existing
Icons/{id}_icon.png as the reference image) to produce variants where ONLY the
mouth shape changes -- everything else (pose, eyes, lighting, frame ring) stays
identical. Output is written to Icons/anim/{id}/frame_N.png.

Frame 0 is always the rest pose (closed mouth) and is NOT regenerated -- the
existing portrait is referenced directly via the speak_frames JSON entry. Only
the open-mouth frames are generated, so cost scales with N-1 per character.

After successful generation for a character, this tool writes the resulting
frame paths to data/portrait_animations.json (a small manifest keyed by
character_id) so the Godot side can pick them up without manual editing.
TopDownCharacters.json is intentionally NOT modified -- its tab-indented
hand-formatted layout would be clobbered by a json.dump round-trip.

Usage:
    python tools/generate_portrait_animations.py [--only id1,id2,...]
                                                  [--frames N]
                                                  [--model name]
                                                  [--overwrite] [--dry-run]

Requires GEMINI_API_KEY (or GOOGLE_API_KEY) env var, google-genai, Pillow.
"""

import argparse
import io
import json
import sys
import time
from pathlib import Path

# Reuse the existing tool's helpers so we keep one source of truth for client
# init, the gemini-2.5-flash-image call, and image post-processing.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_character_icons import (  # noqa: E402
    ICONS_DIR,
    ROOT,
    CHARACTERS_JSON,
    OUTPUT_SIZE,
    init_client,
    call_gemini_image,
    load_json,
)

ANIM_DIR = ICONS_DIR / "anim"
MANIFEST_PATH = ROOT / "data" / "portrait_animations.json"
DEFAULT_MODEL = "gemini-2.5-flash-image"

# Mouth states for frames 1..N. Frame 0 is the original (closed/rest) and is
# referenced directly without regenerating. Order matters: subtle -> open.
MOUTH_STATES = [
    "slightly parted, showing a small gap between the lips as if mid-syllable",
    "open in mid-speech in a clear O shape, showing the inside of the mouth",
    "open wider in an emphatic shout, mouth fully open",
]


def build_frame_prompt(char_name: str, mouth_state: str) -> str:
    return (
        f"Edit this 256x256 character portrait of {char_name}. "
        "Keep EVERYTHING identical to the source image: same pose, same head "
        "angle, same eyes, same hair, same skin tone, same colors, same "
        "lighting, same background, same border ring, same outline thickness, "
        "same crop, same canvas size. The ONLY change you may make is to "
        f"redraw the mouth so it is {mouth_state}. Do not redraw any other "
        "facial feature. The output must be pixel-aligned with the source so "
        "that crossfading between source and output looks like only the mouth "
        "moves."
    )


def select_targets(characters, only_ids):
    if not only_ids:
        return []  # require explicit --only -- generating for all 60+ is expensive
    selected = []
    for c in characters:
        if c["id"] in only_ids:
            selected.append(c)
    found = {c["id"] for c in selected}
    missing = set(only_ids) - found
    if missing:
        print(f"WARNING: ids not found in TopDownCharacters.json: {sorted(missing)}", file=sys.stderr)
    return selected


def resize_png_bytes(image_bytes: bytes, size: int = OUTPUT_SIZE) -> bytes:
    """Resize/normalize PNG to size x size RGBA. Does NOT re-apply the Jacana
    frame -- the reference image already has it and the model is instructed to
    preserve it pixel-for-pixel."""
    from PIL import Image
    img = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    if img.size != (size, size):
        img = img.resize((size, size), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def update_manifest(char_id: str, frame_paths: list[str]) -> None:
    """Write/update data/portrait_animations.json with this character's frames.

    Manifest schema:
        {"<char_id>": {"frames": ["res://...", "res://...", ...]}, ...}

    The manifest is the single source of truth Godot reads at runtime.
    """
    manifest: dict = {}
    if MANIFEST_PATH.exists():
        try:
            manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        except Exception:
            manifest = {}
    manifest[char_id] = {"frames": frame_paths}
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--only", required=False, help="Comma-separated character ids (required)")
    p.add_argument("--frames", type=int, default=3,
                   help="Total frame count including frame 0 (rest). Default 3 -> 2 generated frames.")
    p.add_argument("--model", default=DEFAULT_MODEL,
                   help=f"Reference-image-capable model. Default {DEFAULT_MODEL}.")
    p.add_argument("--overwrite", action="store_true",
                   help="Regenerate frames even if they already exist.")
    p.add_argument("--dry-run", action="store_true",
                   help="Print prompts and target paths only; no API calls or JSON edits.")
    p.add_argument("--sleep", type=float, default=2.0,
                   help="Seconds between API calls.")
    return p.parse_args()


def main():
    args = parse_args()
    if not args.only:
        sys.exit("ERROR: --only is required (e.g. --only jacana,iguana_don,andrew_tuatara)")

    only_ids = [s.strip() for s in args.only.split(",") if s.strip()]
    n_total = max(2, args.frames)
    n_generate = n_total - 1  # frame 0 is the rest pose, not generated
    if n_generate > len(MOUTH_STATES):
        sys.exit(f"ERROR: --frames {args.frames} too high; max supported = {len(MOUTH_STATES) + 1}")

    chars = load_json(CHARACTERS_JSON)["characters"]
    targets = select_targets(chars, only_ids)
    if not targets:
        sys.exit("ERROR: no valid character ids selected.")

    ANIM_DIR.mkdir(parents=True, exist_ok=True)

    print(f"Model: {args.model}")
    print(f"Frames per character: {n_total} ({n_generate} generated, frame 0 = original portrait)")
    print(f"Targets: {[c['id'] for c in targets]}")

    client = None if args.dry_run else init_client()
    failures: list[tuple[str, str]] = []

    for ci, char in enumerate(targets, 1):
        cid = char["id"]
        name = char.get("name", cid)
        ref_path = ICONS_DIR / f"{cid}_icon.png"
        if not ref_path.exists():
            msg = f"reference portrait missing at {ref_path}"
            print(f"[{ci}/{len(targets)}] {cid}: SKIP -- {msg}")
            failures.append((cid, msg))
            continue

        out_dir = ANIM_DIR / cid
        out_dir.mkdir(parents=True, exist_ok=True)

        ref_bytes = ref_path.read_bytes()
        frame_paths = [f"res://Icons/{cid}_icon.png"]  # frame 0 = original

        print(f"\n[{ci}/{len(targets)}] {cid}")
        char_failed = False
        for fi in range(1, n_generate + 1):
            mouth_state = MOUTH_STATES[fi - 1]
            out_path = out_dir / f"frame_{fi}.png"
            frame_paths.append(f"res://Icons/anim/{cid}/frame_{fi}.png")

            if out_path.exists() and not args.overwrite:
                print(f"  frame_{fi}: exists, skip")
                continue

            prompt = build_frame_prompt(name, mouth_state)
            print(f"  frame_{fi} prompt: {prompt}")
            if args.dry_run:
                continue

            try:
                raw = call_gemini_image(client, args.model, prompt, ref_bytes)
                png = resize_png_bytes(raw, OUTPUT_SIZE)
                out_path.write_bytes(png)
                print(f"    saved: {out_path.relative_to(ROOT)}")
            except Exception as e:
                print(f"    FAILED: {e}")
                failures.append((f"{cid}/frame_{fi}", str(e)))
                char_failed = True

            if args.sleep > 0 and (fi < n_generate or ci < len(targets)):
                time.sleep(args.sleep)

        if not args.dry_run and not char_failed:
            update_manifest(cid, frame_paths)
            print(f"  updated manifest: {MANIFEST_PATH.relative_to(ROOT)}")

    print(f"\nDone. {len(failures)} failures.")
    if failures:
        for k, err in failures:
            print(f"  - {k}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
