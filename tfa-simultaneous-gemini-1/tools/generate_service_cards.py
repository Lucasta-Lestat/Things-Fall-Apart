#!/usr/bin/env python3
"""Generate parchment service-card backgrounds for the Town Services Panel.

Each card is a wide-rectangle (512x256) image with a parchment background and
a soft, dark, embossed-seal icon centered as a low-contrast watermark. The icon
is the symbolic profession (anvil for Smith, etc.).

Output: tfa-simultaneous-gemini-1/UI/Assets/service_cards/<service_id>.png

The TownServicesPanel.gd loads these by service_id derived from the NPC's
primary title via RegionDatabase.title_to_id().

Requires: GEMINI_API_KEY env var, google-genai, Pillow.
"""

import argparse
import base64
import io
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = ROOT / "UI" / "Assets" / "service_cards"
# imagen-4.0-ultra-generate-001 hits the paid-tier-1 daily cap quickly (30/day);
# gemini-2.5-flash-image runs under a separate quota pool and is plenty for
# parchment-watermark backgrounds.
MODEL = "gemini-2.5-flash-image"

# service_id -> (prompt-fragment-icon, prompt-fragment-flavor)
# service_id matches RegionDatabase.title_to_id(title).
SERVICES = {
    "_parchment_base": ("ABSOLUTELY NOTHING in the center — the center must remain pure empty parchment with no marks, no rings, no stains, no symbols", "completely blank empty parchment paper, no central feature at all, only the natural paper texture and a few small ink splotches near the corners — never the center"),
    "smith":           ("a single blacksmith's anvil",                              "iron, sturdy, a hammer resting on it"),
    "alchemist":       ("a single glass alembic with a curling neck above a flame", "wisps of smoke, mortar and pestle nearby"),
    "peddler":         ("a wooden handcart laden with bundles of goods",            "rope, sacks, dried herbs hanging"),
    "alewife":         ("a single foaming tankard of ale",                          "wooden mug, frothy head, droplets"),
    "barkeep":         ("a single foaming tankard of ale beside a corked bottle",   "wooden mug, frothy head"),
    "whoremonger":     ("an ornate masquerade mask with feathers",                  "Venetian style, single mask"),
    "slavecatcher":    ("a pair of heavy iron manacles with a broken chain",        "rust, weight, severed link"),
    "reverend_mother": ("a single tall vine-and-cross emblem",                      "ecclesiastical, embossed seal"),
    "skipper":         ("a wooden ship's wheel",                                    "weathered, six spokes, nautical"),
    "wayfinder":       ("a brass compass rose",                                     "navigational, ornate cardinal points"),
    "librarian":       ("a single open codex book",                                 "thick pages, ribbon bookmark"),
    "professor":       ("a quill pen crossed with a rolled scroll",                 "academic, sealed scroll"),
    "the_house":       ("a pair of six-sided dice",                                 "gambling, two dice tumbling"),
    "moneylender":     ("a balance scale heaped with coins",                        "double-pan scale, gold coins"),
    "houndmaster":     ("a single flat silhouette of a hound's head in profile, simplified mastiff outline", "single-tone dark sepia silhouette, no inner detail, no fur texture, no eyes, no shading — just a flat shape like a paper-cut. Watermark opacity around 18% (more faded than other cards)"),
    "hedge_witch":     ("a small bubbling cauldron over flames",                    "three-legged iron pot, steam"),
    "hierophant":      ("a single all-seeing eye inside a triangle",                "occult, esoteric, mystical seal"),
    "venefica":        ("a single fly-agaric mushroom with spotted cap",            "amanita, alchemical"),
    "veneficus":       ("a single fly-agaric mushroom with spotted cap",            "amanita, alchemical"),
    "don":             ("a single fedora hat with a pinstripe band",                "mafia, brimmed hat, rakish tilt"),
    "default":         ("a simple decorative quatrefoil scrollwork ornament",       "neutral, vine flourish"),
}


def build_prompt(service_id, icon, flavor):
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
        "(small portrait, name, inventory grid) can render legibly on top of it."
    )


def _is_imagen(model):
    return "imagen" in model


def _call_imagen(client, prompt):
    response = client.models.generate_images(
        model=MODEL,
        prompt=prompt,
        config={
            "number_of_images": 1,
            "aspect_ratio": "16:9",
            "image_size": "2K",
        },
    )
    if not response.generated_images:
        return None
    img_obj = response.generated_images[0].image
    return img_obj.image_bytes if hasattr(img_obj, "image_bytes") else img_obj._image_bytes


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


def generate_one(client, service_id, prompt, out_path):
    """Calls the configured image model and writes the result. Returns True on success."""
    if _is_imagen(MODEL):
        raw = _call_imagen(client, prompt)
    else:
        raw = _call_gemini_image(client, prompt)
    if not raw:
        print(f"  ! No image returned for {service_id}", file=sys.stderr)
        return False
    # Resize to exact 512x256 (the Imagen 16:9 is wider; we crop from center).
    from PIL import Image
    src = Image.open(io.BytesIO(raw)).convert("RGB")
    target_w, target_h = 512, 256
    src_w, src_h = src.size
    src_aspect = src_w / src_h
    target_aspect = target_w / target_h
    if src_aspect > target_aspect:
        # Source is wider than 2:1 — crop horizontal sides.
        new_w = int(src_h * target_aspect)
        x0 = (src_w - new_w) // 2
        cropped = src.crop((x0, 0, x0 + new_w, src_h))
    else:
        # Source is taller (16:9 is wider so this branch rarely fires) — crop top/bottom.
        new_h = int(src_w / target_aspect)
        y0 = (src_h - new_h) // 2
        cropped = src.crop((0, y0, src_w, y0 + new_h))
    cropped = cropped.resize((target_w, target_h), Image.LANCZOS)
    cropped.save(out_path, "PNG")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated service_ids to (re)generate")
    parser.add_argument("--overwrite", action="store_true",
                        help="regenerate even if file already exists")
    parser.add_argument("--dry-run", action="store_true",
                        help="print prompts instead of calling the API")
    parser.add_argument("--list", action="store_true",
                        help="list service ids and exit")
    args = parser.parse_args()

    if args.list:
        for sid in SERVICES:
            print(sid)
        return 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key and not args.dry_run:
        print("ERROR: GEMINI_API_KEY (or GOOGLE_API_KEY) is not set.", file=sys.stderr)
        return 1

    only = set(args.only.split(",")) if args.only else None
    targets = [(sid, SERVICES[sid]) for sid in SERVICES if (only is None or sid in only)]
    if not targets:
        print("Nothing to generate (check --only filter).", file=sys.stderr)
        return 1

    if args.dry_run:
        client = None
    else:
        from google import genai
        client = genai.Client(api_key=api_key)

    fails = []
    for sid, (icon, flavor) in targets:
        out_path = OUTPUT_DIR / f"{sid}.png"
        if out_path.exists() and not args.overwrite:
            print(f"[skip] {sid}: already exists at {out_path}")
            continue

        prompt = build_prompt(sid, icon, flavor)
        if args.dry_run:
            print(f"[dry-run] {sid}: {prompt[:120]}...")
            continue

        print(f"[gen] {sid} -> {out_path}")
        try:
            ok = generate_one(client, sid, prompt, out_path)
            if not ok:
                fails.append(sid)
        except Exception as e:
            print(f"  ! Exception generating {sid}: {e}", file=sys.stderr)
            fails.append(sid)
        # Be polite to the API.
        time.sleep(1.0)

    if fails:
        print(f"\nFailed: {fails}", file=sys.stderr)
        return 2
    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
