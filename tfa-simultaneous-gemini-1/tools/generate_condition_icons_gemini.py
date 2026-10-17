#!/usr/bin/env python3
"""Generate candidate condition icons via Gemini and finish them to match the cond_* set.

The cond_* set was made in two passes:
  1. tools/generate_condition_icons_ai.py asks Gemini for a risograph icon: a
     cream paper square, one flat category-coloured disc, one bold glyph
     (style references: the four resource icons, Adrenaline/Focus/Harmony/soul).
  2. the repo-level tools/rework_ui_icons.py drops the paper square, grows the disc to fill
     the 256px frame (transparent corners) and scales the glyph to 72% of it.

This script runs both passes for conditions that do not have art yet, but makes
several candidates per condition (a few symbol ideas, a few samples of each) so
one can be picked by eye, and snaps the disc to the exact colour the existing
icons of that category use, measured from the set itself. Nothing is written
into "UI/UI Icons" until a candidate is picked with --pick. Gemini does not
take a seed, so a rerun gives new candidates, not the same pixels; the raw
images in <out>/raw are the record.

Shipped picks: cond_shrouded = shrouded_hood_shadow_1, cond_inspired =
inspired_crown_rays_1 (gemini-3-pro-image, 14 requests for 14 candidates).

Only the image prompt (text + the four style-reference icons, exactly what
generate_condition_icons_ai.py sends) goes to the API. Every request is logged
to <out>/calls.json with the model that answered it.

Usage:
    python tools/generate_condition_icons_gemini.py --out DIR                  # all, 2 samples per idea
    python tools/generate_condition_icons_gemini.py --out DIR --n 3 inspired   # just this one
    python tools/generate_condition_icons_gemini.py --out DIR --rework-only    # redo pass 2 from DIR/raw
    python tools/generate_condition_icons_gemini.py --pick shrouded=DIR/shrouded_hood_shadow_1.png
    python tools/generate_condition_icons_gemini.py --out DIR --contact shrouded=...,inspired=...
    python tools/generate_condition_icons_gemini.py --list

--icons-dir points at the folder holding the style references and the existing
cond_* icons (default: this project's "UI/UI Icons"); use it when running from a
checkout whose binary art is not on disk.
"""

import argparse
import base64
import glob
import io
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request

import numpy as np
from PIL import Image, ImageDraw

# Run-as-script puts tools/ on sys.path[0]; the rework pass lives in the repo-level tools/.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(os.path.dirname(os.path.dirname(HERE)), "tools"))

from generate_ability_icons_ai import ICONS, MODELS, REFS  # noqa: E402
from generate_condition_icons_ai import SPECS, build_prompt  # noqa: E402
import rework_ui_icons  # noqa: E402

KEY = os.environ["GEMINI_API_KEY"]


def idea(category, symbol, color):
    return {"category": category, "symbol": symbol, "color": color}


# condition id -> {idea name -> spec}. Same shape as generate_condition_icons_ai.SPECS,
# so the prompt is built by that script's own build_prompt.
CANDIDATES = {
    # Worn Dark Hood: others see you at half range. Hard to see, NOT invisible
    # (invisible.png is the slashed eye), so the glyph is a hood whose face is lost
    # in shadow rather than anything crossed out or missing.
    "shrouded": {
        "hood": idea("buff", "a deep hooded cloak seen from the front, head and shoulders only: a tall rounded "
                     "hood draped over broad sloping shoulders, the face opening inside the hood one solid "
                     "empty shadow with no face showing", "bright white"),
        "hood_dark": idea("buff", "a deep hooded cloak seen from the front, head and shoulders only: a tall "
                          "rounded hood draped over broad sloping shoulders, with no face showing inside the "
                          "hood opening", "dark charcoal grey"),
        "hood_mist": idea("buff", "a hooded head and shoulders seen from the front with no face showing in the "
                          "dark hood opening, the lower half of the figure trailing away into three wavy "
                          "horizontal wisps of drifting smoke", "bright white"),
        "hood_shadow": idea("buff", "a deep hooded cloak seen from the front, head and shoulders only: a tall "
                            "rounded hood draped over broad sloping shoulders, the face opening inside the hood "
                            "filled completely with flat dark charcoal shadow so no face can be seen",
                            "bright white with the shadowed face opening in dark charcoal"),
    },
    # Worn Golden Crown: +10 Will and Charisma, a morale lift. A crown, lifted.
    "inspired": {
        "crown_rays": idea("buff", "a royal crown with three tall points, each point tipped with a small round "
                           "ball, sitting on a thick plain band, with three short straight rays fanning upward "
                           "above its middle point", "bright white"),
        "crown_star": idea("buff", "a royal crown with three points sitting on a thick plain band, with one bold "
                           "five-pointed star floating just above the middle point", "bright white"),
        "crown_gold": idea("buff", "a royal crown with three tall points, each point tipped with a small round "
                           "ball, sitting on a thick plain band", "rich golden yellow"),
    },
}

# Existing icons shown beside the new ones on the contact sheet.
CONTACT_NEIGHBOURS = [
    "courageous", "perceptive", "stalwart", "blessed",
    "focused", "powerful", "fearful", "haunted",
]

SHEET_BG = (58, 58, 64, 255)  # rework_ui_icons' preview background
TEXT = (255, 255, 255, 255)


# ─── Gemini ───

def gen_counted(prompt, ref_paths, log):
    """generate_ability_icons_ai.gen with every HTTP request logged: same models,
    same fallback order, same body, plus a 1:1 aspect ratio."""
    parts = [{"text": prompt}]
    for rp in ref_paths:
        with open(rp, "rb") as f:
            parts.append({"inline_data": {"mime_type": "image/png", "data": base64.b64encode(f.read()).decode()}})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {
            "responseModalities": ["TEXT", "IMAGE"],
            "imageConfig": {"aspectRatio": "1:1"},
        },
    }
    data = json.dumps(body).encode()
    last_err = None
    for model in MODELS:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        req = urllib.request.Request(url, data=data, headers={
            "Content-Type": "application/json", "x-goog-api-key": KEY})
        entry = {"model": model, "status": None, "image": False}
        log.append(entry)
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=240) as resp:
                entry["status"] = resp.status
                out = json.loads(resp.read())
            entry["seconds"] = round(time.time() - t0, 1)
            entry["usage"] = out.get("usageMetadata", {})
            for cand in out.get("candidates", []):
                for p in cand.get("content", {}).get("parts", []):
                    idata = p.get("inlineData") or p.get("inline_data")
                    if idata and idata.get("data"):
                        entry["image"] = True
                        return base64.b64decode(idata["data"]), model
            last_err = f"{model}: no image part in response: " + json.dumps(out)[:300]
        except urllib.error.HTTPError as e:
            entry["status"] = e.code
            last_err = f"{model} HTTP {e.code}: {e.read().decode()[:300]}"
        except Exception as e:
            last_err = f"{model} {e}"
        entry["error"] = last_err
    raise RuntimeError(last_err)


# ─── Finishing pass ───

def set_disc_color(icons_dir, category):
    """Median rim colour of the existing cond_* icons of this category, i.e. the
    exact disc the new icon has to sit beside. None if none are on disk."""
    ids = [k for k, v in SPECS.items() if v["category"] == category]
    samples = []
    for cid in ids:
        p = os.path.join(icons_dir, f"cond_{cid}.png")
        if not os.path.exists(p):
            continue
        a = np.array(Image.open(p).convert("RGBA"))
        h, w = a.shape[:2]
        yy, xx = np.mgrid[0:h, 0:w]
        rr = np.sqrt((yy - (h - 1) / 2.0) ** 2 + (xx - (w - 1) / 2.0) ** 2) / (min(h, w) / 2.0)
        ring = (rr > 0.86) & (rr < 0.96) & (a[..., 3] > 250)
        if ring.sum():
            samples.append(np.median(a[..., :3][ring], axis=0))
    if not samples:
        return None
    return tuple(int(round(v)) for v in np.median(np.array(samples), axis=0))


def finish(raw_img, disc_rgb):
    """rework_ui_icons.rework, with the disc painted the set's colour instead of
    whatever shade the model happened to print."""
    orig = rework_ui_icons.analyse

    def analyse_snapped(img):
        info = orig(img)
        if info is not None and disc_rgb is not None:
            info["disc_color"] = np.array(disc_rgb, dtype=np.uint8)
        return info

    rework_ui_icons.analyse = analyse_snapped
    try:
        return rework_ui_icons.rework(raw_img)
    finally:
        rework_ui_icons.analyse = orig


# ─── Sheets ───

def _label(d, xy, text, fill=TEXT):
    d.text(xy, text, fill=fill)


def candidates_sheet(out_dir, path, picked=()):
    """One row per condition: every finished candidate at 128px, 64px and 32px,
    the picked ones framed."""
    rows = []
    for cid in CANDIDATES:
        files = sorted(glob.glob(os.path.join(out_dir, f"{cid}_*.png")))
        if files:
            rows.append((cid, files))
    if not rows:
        return None
    CELL_W, CELL_H = 150, 128 + 4 + 64 + 30
    ncol = max(len(f) for _, f in rows)
    sheet = Image.new("RGBA", (CELL_W * ncol + 10, CELL_H * len(rows) + 10), SHEET_BG)
    d = ImageDraw.Draw(sheet)
    for r, (cid, files) in enumerate(rows):
        for c, f in enumerate(files):
            im = Image.open(f).convert("RGBA")
            x, y = 10 + c * CELL_W, 10 + r * CELL_H
            sheet.alpha_composite(im.resize((128, 128), Image.LANCZOS), (x, y))
            sheet.alpha_composite(im.resize((64, 64), Image.LANCZOS), (x, y + 132))
            sheet.alpha_composite(im.resize((32, 32), Image.LANCZOS), (x + 72, y + 132 + 16))
            stem = os.path.basename(f)[:-4]
            if stem in picked:
                d.rectangle([x - 5, y - 5, x + 133, y + 214], outline=(255, 210, 90, 255), width=2)
                _label(d, (x + 104, y + 150), "PICK", (255, 210, 90, 255))
            _label(d, (x, y + 200), stem[:24])
    sheet.save(path)
    return path


def contact_sheet(picks, icons_dir, path):
    """The picked icons first, then existing cond_* icons, at 64px and 32px,
    on the dark panel colour and on a light strip."""
    items = [(f"NEW {cid}", Image.open(p).convert("RGBA")) for cid, p in picks]
    for cid in CONTACT_NEIGHBOURS:
        p = os.path.join(icons_dir, f"cond_{cid}.png")
        if os.path.exists(p):
            items.append((cid, Image.open(p).convert("RGBA")))
    CELL = 96
    W = 20 + CELL * len(items)
    H = 34 + (64 + 12) * 2 + (32 + 12) * 2 + 40
    sheet = Image.new("RGBA", (W, H), SHEET_BG)
    d = ImageDraw.Draw(sheet)
    _label(d, (10, 8), "cond_* set at 64px and 32px, dark panel and light strip; NEW = generated this pass")
    y = 34
    for size, light in ((64, False), (64, True), (32, False), (32, True)):
        if light:
            d.rectangle([0, y - 6, W, y + size + 6], fill=(214, 208, 192, 255))
        for i, (_name, im) in enumerate(items):
            x = 20 + i * CELL + (CELL - 20 - size) // 2
            sheet.alpha_composite(im.resize((size, size), Image.LANCZOS), (x, y))
        y += size + 12
    for i, (name, _im) in enumerate(items):
        _label(d, (20 + i * CELL, y + 4), name[:14], (255, 230, 150, 255) if name.startswith("NEW") else TEXT)
    sheet.save(path)
    return path


# ─── Main ───

def _parse_pairs(text):
    out = []
    for chunk in text:
        for part in chunk.split(","):
            if "=" in part:
                k, v = part.split("=", 1)
                out.append((k.strip(), v.strip()))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("ids", nargs="*", help="condition ids (default: all in CANDIDATES)")
    ap.add_argument("--out", help="folder for raw and finished candidates (keep it out of the project)")
    ap.add_argument("--n", type=int, default=2, help="samples per symbol idea")
    ap.add_argument("--icons-dir", default=ICONS, help="folder with the style references and the cond_* set")
    ap.add_argument("--rework-only", action="store_true", help="redo the finishing pass from <out>/raw")
    ap.add_argument("--pick", action="append", default=[], help="id=candidate.png, copied to UI Icons/cond_<id>.png")
    ap.add_argument("--contact", action="append", default=[], help="id=png,... to build <out>/contact_sheet.png")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        for cid, ideas in CANDIDATES.items():
            for name, s in ideas.items():
                print(f"{s['category']:9s}  cond_{cid}  [{name}]  {s['symbol'][:60]}...")
        return

    if args.pick:
        for cid, src in _parse_pairs(args.pick):
            dst = os.path.join(ICONS, f"cond_{cid}.png")
            shutil.copyfile(src, dst)
            print(f"picked {src} -> {dst}")
        return

    if not args.out:
        sys.exit("--out is required")
    os.makedirs(os.path.join(args.out, "raw"), exist_ok=True)

    if args.contact:
        picks = _parse_pairs(args.contact)
        print("contact ->", contact_sheet(picks, args.icons_dir, os.path.join(args.out, "contact_sheet.png")))
        # Frame whichever candidates the picked icons were copied from.
        picked_bytes = set()
        for _, p in picks:
            with open(p, "rb") as f:
                picked_bytes.add(f.read())
        picked = set()
        for f in glob.glob(os.path.join(args.out, "*_*.png")):
            with open(f, "rb") as fh:
                if fh.read() in picked_bytes:
                    picked.add(os.path.basename(f)[:-4])
        print("candidates ->", candidates_sheet(args.out, os.path.join(args.out, "candidates.png"), picked))
        return

    targets = args.ids or list(CANDIDATES)
    unknown = [t for t in targets if t not in CANDIDATES]
    if unknown:
        sys.exit(f"no candidate ideas for: {', '.join(unknown)}")

    ref_paths = [os.path.join(args.icons_dir, r) for r in REFS]
    missing = [r for r in ref_paths if not os.path.exists(r)]
    if missing and not args.rework_only:
        sys.exit(f"missing style reference(s): {missing}  (use --icons-dir)")

    log_path = os.path.join(args.out, "calls.json")
    log = []
    if os.path.exists(log_path):
        with open(log_path) as f:
            log = json.load(f)
    failures = []
    for cid in targets:
        disc = set_disc_color(args.icons_dir, next(iter(CANDIDATES[cid].values()))["category"])
        print(f"cond_{cid}: set disc colour {disc}", flush=True)
        for name, s in CANDIDATES[cid].items():
            for k in range(1, args.n + 1):
                stem = f"{cid}_{name}_{k}"
                raw_path = os.path.join(args.out, "raw", stem + ".png")
                if not args.rework_only:
                    if os.path.exists(raw_path):
                        print(f"  [skip] {stem} (raw exists)")
                    else:
                        print(f"  [gen ] {stem} ...", flush=True)
                        calls = []
                        try:
                            raw, model = gen_counted(build_prompt(s), ref_paths, calls)
                            Image.open(io.BytesIO(raw)).save(raw_path)
                            print(f"         via {model}", flush=True)
                        except Exception as e:
                            print(f"  [FAIL] {stem}: {e}", flush=True)
                            failures.append(stem)
                        for c in calls:
                            c["candidate"] = stem
                        log.extend(calls)
                        with open(log_path, "w") as f:
                            json.dump(log, f, indent=1)
                if not os.path.exists(raw_path):
                    continue
                done = finish(Image.open(raw_path).convert("RGBA"), disc)
                if done is None:
                    print(f"  [rej ] {stem}: not the paper-square + disc layout, left in raw/")
                    continue
                if done.size != (256, 256):
                    done = done.resize((256, 256), Image.LANCZOS)
                done.save(os.path.join(args.out, stem + ".png"))

    print("candidates ->", candidates_sheet(args.out, os.path.join(args.out, "candidates.png")))
    images = sum(1 for c in log if c.get("image"))
    print(f"requests logged: {len(log)}, images returned: {images}")
    if failures:
        print(f"{len(failures)} failed: {', '.join(failures)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
