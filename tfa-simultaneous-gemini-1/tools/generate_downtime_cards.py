#!/usr/bin/env python3
"""Generate parchment downtime-card backgrounds for the DowntimePanel.

Mirrors tools/generate_service_cards.py — same 512x256 parchment-with-watermark
aesthetic. Each card matches a downtime activity_id from data/downtime.json.

For activities whose symbology already lives in service_cards (e.g. drinking
≈ alewife's tankard, gambling ≈ the_house's dice), we copy the existing image
instead of regenerating. The rest get a fresh prompt.

Output: tfa-simultaneous-gemini-1/UI/Assets/downtime_cards/<activity_id>.png

Requires: GEMINI_API_KEY env var (or pass --api-key), google-genai, Pillow.
"""

import argparse
import io
import os
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = ROOT / "UI" / "Assets" / "downtime_cards"
SERVICE_DIR = ROOT / "UI" / "Assets" / "service_cards"
MODEL = "gemini-2.5-flash-image"

# activity_id -> source service_card_id to copy from.
REUSED_FROM_SERVICES = {
    "drinking": "alewife",
    "gambling": "the_house",
    "johning": "whoremonger",
    "research": "librarian",
    "devotion": "reverend_mother",
    "crafting": "smith",
}

# activity_id -> (icon-description, flavor)
# Style is intentionally tight to match generate_service_cards.py.
NEW_ACTIVITIES = {
    "carousing":      ("two foaming tankards clinking together",                    "tavern revelry, wooden mugs, frothy heads"),
    "arena_fighting": ("two crossed broadswords above a laurel wreath",             "gladiatorial, blades pointed up, simple wreath"),
    "orgies":         ("a cluster of grapes entwined with a silk ribbon",           "dionysian, vine leaves, languid ribbon curl"),
    "theft":          ("a single iron lockpick crossed with a small key",           "cant of light, hooked tip, simple bow key"),
    "meditation":     ("a seated figure silhouette in a lotus posture",             "single-tone dark sepia silhouette, flat shape, no inner detail, no face — like a paper-cut"),
    "prostitution":   ("a single rose with a silver coin pinned to its stem",       "delicate stem, rose head in profile, coin behind"),
    "hunting":        ("a longbow with a single arrow nocked",                      "horizontal bow, taut string, fletched arrow"),
    "bushcraft":      ("a curved skinning knife crossed over a sprig of leaves",    "woodsman, simple blade, three-lobed leaves"),
    "camp":           ("a small campfire with three crossed logs",                  "tent flap silhouette in background, low flames"),
    "rest":           ("a rolled bedroll with a crescent moon above",               "simple roll, two strap ties, thin crescent"),
    "watch":          ("a single oil lantern hanging from a wooden post",           "lantern at rest, faint wisp of smoke"),
    "cook":           ("a cast-iron cookpot suspended over a small flame",          "three-legged pot, faint steam, ladle resting on rim"),
}


def build_prompt(icon, flavor):
    return (
        "A horizontal parchment card background, 2:1 aspect ratio. "
        "The parchment is aged cream-tan paper with subtle fiber texture, "
        "softly worn edges, faint stains, and a barely-visible warm brown gradient "
        "vignette. "
        f"In the exact center of the parchment, embossed as a low-contrast watermark, "
        f"is {icon}. The watermark is a single-tone soft dark sepia color "
        "(roughly #6B5538), with very low opacity around 25%, as if pressed into the "
        "paper or stamped with a faded seal. No outline, no glow, no shading "
        "highlights — just a subtle silhouette. "
        f"Style cues for the icon: {flavor}. "
        "The image must be flat-lit, no perspective, no shadows cast onto the paper. "
        "No text, no letters, no border frame, no characters, no people, "
        "no foreground objects other than the central watermark icon. "
        "The composition should leave plenty of negative space so UI elements "
        "(activity title and description) can render legibly on top of it."
    )


def _call_gemini_image(client, prompt):
    response = client.models.generate_content(model=MODEL, contents=[prompt])
    for cand in response.candidates or []:
        if not cand.content:
            continue
        for part in cand.content.parts or []:
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                return inline.data
    return None


def generate_one(client, prompt, out_path):
    raw = _call_gemini_image(client, prompt)
    if not raw:
        return False
    from PIL import Image
    src = Image.open(io.BytesIO(raw)).convert("RGB")
    target_w, target_h = 512, 256
    src_w, src_h = src.size
    src_aspect = src_w / src_h
    target_aspect = target_w / target_h
    if src_aspect > target_aspect:
        new_w = int(src_h * target_aspect)
        x0 = (src_w - new_w) // 2
        cropped = src.crop((x0, 0, x0 + new_w, src_h))
    else:
        new_h = int(src_w / target_aspect)
        y0 = (src_h - new_h) // 2
        cropped = src.crop((0, y0, src_w, y0 + new_h))
    cropped = cropped.resize((target_w, target_h), Image.LANCZOS)
    cropped.save(out_path, "PNG")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-key", default=None, help="Gemini API key (overrides env)")
    parser.add_argument("--only", help="comma-separated activity_ids to (re)generate")
    parser.add_argument("--overwrite", action="store_true",
                        help="regenerate even if file already exists")
    parser.add_argument("--dry-run", action="store_true",
                        help="print prompts instead of calling the API")
    args = parser.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    api_key = args.api_key or os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key and not args.dry_run:
        print("ERROR: GEMINI_API_KEY (or GOOGLE_API_KEY) is not set; pass --api-key.", file=sys.stderr)
        return 1

    only = set(args.only.split(",")) if args.only else None

    # 1. Copy reused service cards.
    print("=== Reusing service-card art ===")
    for aid, sid in REUSED_FROM_SERVICES.items():
        if only and aid not in only:
            continue
        src = SERVICE_DIR / f"{sid}.png"
        dst = OUTPUT_DIR / f"{aid}.png"
        if dst.exists() and not args.overwrite:
            print(f"[skip] {aid}: already exists")
            continue
        if not src.exists():
            print(f"  ! source {src} not found for {aid}", file=sys.stderr)
            continue
        shutil.copyfile(src, dst)
        print(f"[copy] {aid} <- service_cards/{sid}.png")

    # 2. Generate new ones.
    print("\n=== Generating new downtime cards ===")
    if args.dry_run:
        client = None
    else:
        from google import genai
        client = genai.Client(api_key=api_key)

    fails = []
    for aid, (icon, flavor) in NEW_ACTIVITIES.items():
        if only and aid not in only:
            continue
        out_path = OUTPUT_DIR / f"{aid}.png"
        if out_path.exists() and not args.overwrite:
            print(f"[skip] {aid}: already exists")
            continue

        prompt = build_prompt(icon, flavor)
        if args.dry_run:
            print(f"[dry-run] {aid}: {prompt[:120]}...")
            continue

        print(f"[gen] {aid} -> {out_path}")
        try:
            ok = generate_one(client, prompt, out_path)
            if not ok:
                fails.append(aid)
                print(f"  ! No image returned for {aid}", file=sys.stderr)
        except Exception as e:
            print(f"  ! Exception generating {aid}: {e}", file=sys.stderr)
            fails.append(aid)
        time.sleep(1.0)

    if fails:
        print(f"\nFailed: {fails}", file=sys.stderr)
        return 2
    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
