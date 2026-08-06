#!/usr/bin/env python3
"""Generate identity-card photographs for the character creation pool.

The creation screen (UI/CartaIdentita.gd) shows the holder's FOTOGRAFIA in a
printer's frame on a Scarlatti carta d'identita. Its pool is seeded from the
existing circular Icons/ tokens, which read as portrait tokens rather than as
photographs pasted to a document. This tool produces the real thing: a
front-facing, plainly-lit studio bust on a blank backdrop, toned and grained
like a period identity photo, cropped to the frame's aspect.

Output goes to Icons/carta/<id>.png and, with --wire, is appended to the
`portraits` block of data/character_creation.json so the new faces are pickable
without hand-editing the manifest. Entries are written with "crop": "full" —
the card crops into circular Icons/ tokens, but these are already the right
shape and must be used as they stand.

Usage:
    python tools/generate_creation_portraits.py --list
    python tools/generate_creation_portraits.py --dry-run
    python tools/generate_creation_portraits.py --gender female --wire
    python tools/generate_creation_portraits.py --only cc_f_scrivener --overwrite

Requires GEMINI_API_KEY (or GOOGLE_API_KEY), google-genai, Pillow.
Mirrors tools/generate_character_icons.py — same client, same model flags.
"""

import argparse
import io
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
OUT_DIR = ROOT / "Icons" / "carta"
CREATION_JSON = DATA_DIR / "character_creation.json"

DEFAULT_MODEL = "imagen-4.0-ultra-generate-001"

# UI/CartaIdentita.PHOTO_SIZE is 196x236; generate a little over 2x that and
# let Godot's importer downscale. Anything squarer gets cropped by the frame.
OUT_W, OUT_H = 400, 482

# The document's own palette, from UI/CartaIdentita.gd — the photo is toned
# toward it so a pasted print sits in the card instead of on top of it.
SEPIA_SHADOW = (48, 34, 30)
SEPIA_HIGHLIGHT = (238, 226, 206)

# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------

# What makes it read as a document photograph rather than a character portrait:
# flat frontal light, dead-centre framing, an empty backdrop, and the sitter
# doing what everyone does for an official photograph — nothing.
#
# Phrased entirely in the positive. Image models attend to the concepts a
# prompt names whether or not they are negated, so "no pointed ears" is a
# reliable way to get pointed ears; state the wanted feature instead.
PHOTO_STYLE = (
    "A real black-and-white silver-gelatin photograph from the 1930s, taken "
    "in a municipal photographer's studio and pasted into a national identity "
    "card, struck with an office stamp. Strictly front-facing "
    "head-and-shoulders bust, the head centred and filling roughly the upper "
    "two thirds of the frame, shoulders squared to the camera. The backdrop "
    "behind the sitter is an empty seamless sheet of flat mid-grey paper, "
    "smooth and evenly lit from edge to edge. Flat even frontal studio "
    "lighting with a soft shadow under the chin. A neutral, unsmiling, "
    "slightly resigned civil expression, eyes to the lens. Sharp central "
    "focus, fine silver-gelatin grain, gentle corner vignetting, faint age "
    "spotting and a scuff or two from handling. Every detail is "
    "photographic: real skin texture, real fabric weave, real lens optics."
)

# One entry per pickable face. `id` is what a saved character stores, so these
# strings are permanent once shipped — add new ones, never rename.
SUBJECTS = {
    "male": [
        ("cc_m_labourer", "a broad-shouldered man in his late twenties, dark cropped hair, "
                          "heavy brow, a collarless work shirt buttoned to the throat"),
        ("cc_m_clerk", "a thin man in his thirties with a receding hairline, wire spectacles, "
                       "a stiff detachable collar and a narrow dark tie"),
        ("cc_m_youth", "a boy of about eighteen with an unruly fringe and a soft jaw, "
                       "wearing a jacket plainly a size too large for him"),
        ("cc_m_veteran", "a weathered man in his forties, close-cropped greying hair, a scar "
                         "across one eyebrow, a plain military tunic with the insignia removed"),
        ("cc_m_priest", "a solemn man in his fifties with hollow cheeks and swept-back grey "
                        "hair, wearing a dark clerical collar"),
        ("cc_m_dandy", "a handsome man in his late twenties with pomaded hair and a thin "
                       "moustache, a well-cut striped suit and a silk cravat"),
        ("cc_m_fisher", "a sun-darkened man in his thirties with a heavy beard and "
                        "deep-set eyes, wearing an oilskin jacket"),
        ("cc_m_professor", "a gaunt elderly man with white hair worn long over the ears and a "
                           "close-trimmed beard, a dark academic gown over a waistcoat"),
        ("cc_m_bruiser", "a heavyset man in his forties with a flattened nose, a shaved head "
                         "and a thick neck, wearing a tight-buttoned waistcoat"),
        ("cc_m_invalid", "a pale, very thin man in his thirties with sunken eyes and damp "
                         "hair, a plain infirmary shirt buttoned crookedly"),
    ],
    "female": [
        ("cc_f_labourer", "a strong-featured woman in her late twenties with dark hair pulled "
                          "back severely, wearing a plain buttoned work smock"),
        ("cc_f_scrivener", "a woman in her thirties with hair in a tight low bun and small "
                           "round spectacles, a high-necked dark blouse"),
        ("cc_f_youth", "a girl of about nineteen with loose wavy hair and wide eyes, "
                       "wearing a simple pale blouse with a rounded collar"),
        ("cc_f_matron", "a heavyset woman in her fifties with grey hair pinned up and a firm "
                        "set to her mouth, a dark dress with a lace collar"),
        ("cc_f_nun", "a severe woman in her forties in a plain dark religious veil framing "
                     "the face, no ornament"),
        ("cc_f_signora", "an elegant woman in her thirties with marcelled hair and darkened "
                         "lips, a fur stole over a dark dress"),
        ("cc_f_widow", "a hollow-eyed woman in her forties in unrelieved black, hair covered "
                       "by a plain dark headscarf"),
        ("cc_f_farmhand", "a broad, sunburnt woman in her twenties with a heavy braid over one "
                          "shoulder, wearing a coarse linen shirt"),
        ("cc_f_urchin", "a wiry young woman of about twenty with hair chopped short and "
                        "unevenly, a threadbare jacket several sizes too big"),
        ("cc_f_elder", "a very old woman with deeply lined skin, thin white hair scraped back, "
                       "and small sharp eyes, wearing a plain dark shawl"),
    ],
}

# Every sitter is a Scarlattin citizen; keep the population consistent with the
# rest of the art without asking the model for a specific ethnicity.
POPULATION = (
    "An ordinary human citizen of a shabby, corrupt Mediterranean republic "
    "between the wars — plain, unglamorous, believably worn. Entirely and "
    "unmistakably human: rounded human ears, ordinary human skin in a natural "
    "complexion, ordinary human teeth, a face you would pass in the street."
)


def build_prompt(description):
    return f"{PHOTO_STYLE}\n\nThe sitter: {description}. {POPULATION}"


# ---------------------------------------------------------------------------
# API (same shape as tools/generate_character_icons.py)
# ---------------------------------------------------------------------------

def init_client():
    api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        sys.exit("ERROR: GEMINI_API_KEY (or GOOGLE_API_KEY) is not set in the environment.")
    try:
        from google import genai  # type: ignore
    except ImportError:
        sys.exit("ERROR: google-genai not installed. Run: pip install google-genai pillow")
    return genai.Client(api_key=api_key)


def is_imagen(model_name):
    return model_name.startswith("imagen-")


def call_imagen(client, model, prompt):
    from google.genai import types  # type: ignore

    response = client.models.generate_images(
        model=model,
        prompt=prompt,
        config=types.GenerateImagesConfig(number_of_images=1, aspect_ratio="3:4"),
    )
    for gen in response.generated_images or []:
        img = gen.image
        if img and img.image_bytes:
            return img.image_bytes
    raise RuntimeError("No image returned by Imagen.")


def call_gemini_image(client, model, prompt):
    from google.genai import types  # type: ignore

    response = client.models.generate_content(model=model, contents=[prompt])
    for cand in response.candidates or []:
        for part in (cand.content.parts if cand.content else []):
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                return inline.data
    raise RuntimeError("No image returned by Gemini.")


def generate_image(client, model, prompt):
    if is_imagen(model):
        return call_imagen(client, model, prompt)
    return call_gemini_image(client, model, prompt)


# ---------------------------------------------------------------------------
# Darkroom
# ---------------------------------------------------------------------------

def apply_treatment(image_bytes, treat=True):
    """Crop to the card's photo aspect and tone the print.

    Done here rather than in-engine so the pool looks consistent even when the
    model returns a slightly different crop or colour cast each run.
    """
    from PIL import Image, ImageOps

    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    # Centre-crop to OUT_W:OUT_H, biased upward — a document photo is chin-to-
    # crown, and a centred crop of a bust cuts the top of the head off.
    target = OUT_W / OUT_H
    w, h = img.size
    if w / h > target:
        new_w = int(h * target)
        left = (w - new_w) // 2
        img = img.crop((left, 0, left + new_w, h))
    else:
        new_h = int(w / target)
        top = int((h - new_h) * 0.35)
        img = img.crop((0, top, w, top + new_h))
    img = img.resize((OUT_W, OUT_H), Image.LANCZOS)

    if treat:
        img = ImageOps.colorize(ImageOps.grayscale(img), SEPIA_SHADOW, SEPIA_HIGHLIGHT)
        img = ImageOps.autocontrast(img, cutoff=1)

    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


# ---------------------------------------------------------------------------
# Manifest wiring
# ---------------------------------------------------------------------------

def wire_manifest(entries_by_gender):
    """Append generated faces to data/character_creation.json, in place.

    Idempotent: an id already present is left alone, so re-running after
    regenerating a single portrait does not duplicate it.
    """
    data = json.loads(CREATION_JSON.read_text(encoding="utf-8"))
    portraits = data.setdefault("portraits", {})
    added = 0
    for gender, entries in entries_by_gender.items():
        pool = portraits.setdefault(gender, [])
        have = {e.get("id") for e in pool}
        for pid, res_path in entries:
            if pid in have:
                continue
            pool.append({"id": pid, "path": res_path, "crop": "full"})
            added += 1
    CREATION_JSON.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return added


# ---------------------------------------------------------------------------

def select_targets(genders, only_ids):
    targets = []
    for gender in genders:
        for pid, desc in SUBJECTS.get(gender, []):
            if only_ids and pid not in only_ids:
                continue
            targets.append((gender, pid, desc))
    return targets


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--gender", choices=["male", "female", "both"], default="both")
    p.add_argument("--only", help="Comma-separated portrait ids to (re)generate")
    p.add_argument("--overwrite", action="store_true", help="Re-generate even if the file exists")
    p.add_argument("--dry-run", action="store_true", help="Print prompts; do not call the API")
    p.add_argument("--list", action="store_true", help="List target ids and exit")
    p.add_argument("--sleep", type=float, default=2.0, help="Seconds between API calls")
    p.add_argument("--model", default=DEFAULT_MODEL,
                   help=f"Image model id. Default {DEFAULT_MODEL}.")
    p.add_argument("--no-treatment", action="store_true",
                   help="Skip the sepia/contrast pass; keep the model's own colour")
    p.add_argument("--wire", action="store_true",
                   help="Append the generated faces to data/character_creation.json")
    p.add_argument("--retreat-existing", action="store_true",
                   help="No API calls; re-run the crop/tone pass over Icons/carta/*.png")
    return p.parse_args()


def main():
    args = parse_args()
    genders = ["male", "female"] if args.gender == "both" else [args.gender]
    only_ids = set(args.only.split(",")) if args.only else None
    targets = select_targets(genders, only_ids)

    if args.list:
        for gender, pid, desc in targets:
            print(f"{gender:6} {pid:20} {desc[:70]}")
        return

    if args.retreat_existing:
        count = 0
        for path in sorted(OUT_DIR.glob("*.png")):
            path.write_bytes(apply_treatment(path.read_bytes(), not args.no_treatment))
            print(f"  retreated: {path.relative_to(ROOT)}")
            count += 1
        print(f"Done. Retreated {count} photographs.")
        return

    print(f"Model: {args.model}")
    print(f"Targeting {len(targets)} photographs -> {OUT_DIR.relative_to(ROOT)}")
    client = None if args.dry_run else init_client()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    generated = {"male": [], "female": []}
    failures = []
    for i, (gender, pid, desc) in enumerate(targets, 1):
        out_path = OUT_DIR / f"{pid}.png"
        res_path = f"res://Icons/carta/{pid}.png"
        if out_path.exists() and not args.overwrite:
            print(f"[{i}/{len(targets)}] {pid}: exists, skip")
            generated[gender].append((pid, res_path))
            continue

        prompt = build_prompt(desc)
        print(f"\n[{i}/{len(targets)}] {pid} ({gender})")
        if args.dry_run:
            print(f"  prompt: {prompt}")
            continue

        try:
            raw = generate_image(client, args.model, prompt)
            out_path.write_bytes(apply_treatment(raw, not args.no_treatment))
            print(f"  saved: {out_path.relative_to(ROOT)}")
            generated[gender].append((pid, res_path))
        except Exception as exc:  # noqa: BLE001 — report and keep going
            print(f"  FAILED: {exc}")
            failures.append(pid)
        time.sleep(args.sleep)

    if args.wire and not args.dry_run:
        added = wire_manifest(generated)
        print(f"\nWired {added} new portrait(s) into "
              f"{CREATION_JSON.relative_to(ROOT)}")
        print("Run a Godot import pass so the new PNGs get .import files, then "
              "check tests/character_creation_test.tscn still passes.")

    if failures:
        print(f"\n{len(failures)} failed: {', '.join(failures)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
