#!/usr/bin/env python3
"""Generate ability icons via Gemini, styled to match the resource icons.

The resource icons (Adrenaline / Focus / Harmony / soul) are flat risograph-style
prints: a warm off-white paper square, one large flat-coloured circle, and a bold
two-tone symbol inside it. This regenerates the hand-made temp ability icons in
that same style.

The circle colour encodes the ability's school (matching PartySidePanel's colours),
so a glance tells you which resource it draws on; the symbol colour is chosen per
ability for contrast and theme.

Usage:
    python tools/generate_ability_icons_ai.py                # all abilities
    python tools/generate_ability_icons_ai.py fireball rage  # just these
    python tools/generate_ability_icons_ai.py --list         # names only
"""

import base64
import io
import json
import os
import sys
import urllib.error
import urllib.request

from PIL import Image

KEY = os.environ["GEMINI_API_KEY"]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "UI", "UI Icons")
MODELS = ["gemini-3-pro-image", "gemini-3.1-flash-image", "gemini-2.5-flash-image"]

# The four resource icons that define the target style.
REFS = [
    "Adrenaline Icon.png",
    "Focus Icon.png",
    "Harmony Icon.png",
    "soul icon.png",
]

OUT_SIZE = 256

# Circle colour per school, in the soft riso register of the reference icons.
SCHOOL_CIRCLE = {
    "Arcane": "soft cornflower blue (#8FB8DE)",
    "Occult": "soft muted violet (#B296CC)",
    "Primal": "soft mint green (#A5D3AE)",
    "Martial": "soft salmon red (#E8A09A)",
    "Utility": "warm sand gold (#E3C98A)",
}

STYLE = (
    "A single flat vector game UI icon drawn in a retro screen-print / risograph style, "
    "matching the palette, flat shapes and paper texture of the four reference icons provided. "
    "Composition: the square canvas is plain warm off-white printing paper (#EDEAE0) filling the "
    "frame edge to edge; one large flat-coloured circle sits centered on it, its diameter measuring "
    "about 88% of the canvas width so that a clean even border of bare paper stays visible around "
    "the whole circle and its curved edge reads clearly the whole way round; one bold simple symbol "
    "sits centered inside the circle and spans about two thirds of the circle's diameter. The circle "
    "and the symbol are the only two shapes in the image, and the paper border around the circle is "
    "plain and unbroken. "
    "The symbol is a clean flat silhouette built from thick strokes and rounded ends, solid and "
    "chunky enough to stay readable when the icon is shrunk to 32 pixels wide. The whole print uses "
    "exactly three flat colours: the off-white paper, one colour for the circle, one contrasting "
    "colour for the symbol. A subtle even paper grain lies over everything, and a soft pale halo of "
    "the paper colour hugs the symbol's outline, exactly as in the reference icons. "
)


def spec(school, symbol, color):
    return {"school": school, "symbol": symbol, "color": color}


# ─── Ability icon specs ───
# key = ability id -> (school for circle colour, symbol description, symbol colour)

SPECS = {
    # ── Arcane ──
    "fireball": spec("Arcane", "a round ball of fire with three tongues of flame curling upward off the top of it", "warm orange-red"),
    "cloud_kill": spec("Arcane", "a billowing three-lobed cloud with a small simple skull silhouette showing at its center", "sickly yellow-green"),
    "ice_storm": spec("Arcane", "a six-armed snowflake, each arm carrying a pair of short angled crossbars", "bright white"),
    "lightning_bolt": spec("Arcane", "one bold zigzag lightning bolt slanting from the upper left down to the lower right", "bright lemon yellow"),
    "magnetic_pull": spec("Arcane", "a horseshoe magnet with its two poles facing upward, and a pair of short arrows on either side curving inward toward it", "deep brick red"),
    "repulsion_wave": spec("Arcane", "a small solid dot on the left with three nested arcs spreading outward to the right, each arc larger than the last", "bright white"),
    "gravity_well": spec("Arcane", "four nested rings funneling inward and downward toward one small solid dot at the bottom center, like a well seen at an angle", "deep indigo"),
    "vortex": spec("Arcane", "a tight spiral whirlpool of three sweeping curved arms winding into a solid dot at the center", "bright white"),
    "acid_splash": spec("Arcane", "one fat rounded teardrop of liquid with three small round droplets flying off to the sides", "acid yellow-green"),
    "thunderwave": spec("Arcane", "a wide cone opening upward, filled with three nested arcs that spread from a small solid dot at the bottom point", "bright white"),
    "psych_up": spec("Arcane", "two circular arrows chasing each other in a closed loop around a small solid four-pointed spark at the center", "bright lemon yellow"),
    "fire_spin": spec("Arcane", "a closed ring built from five tongues of flame, all leaning the same way around the circle like a wheel of fire", "warm orange-red"),
    "explosive_revelation": spec("Arcane", "a small solid circle at the center holding a single open eye, with four bold tapering shards blasting outward from it toward the corners", "deep plum purple"),

    # ── Occult ──
    "rat_pack": spec("Occult", "three overlapping rat silhouettes seen from the side, clustered together, their long thin tails curling behind them", "dark charcoal"),
    "creepy_beam": spec("Occult", "a single open eye on the left casting a widening triangular beam out to the right", "sickly yellow-green"),
    "beguile": spec("Occult", "one bold rounded heart", "warm rose pink"),
    "confess": spec("Occult", "two bold rounded hearts side by side, slightly overlapping in the middle", "warm rose pink"),
    "hitch": spec("Occult", "two bold rounded hearts, one on each side, joined in the middle by two interlocking chain links", "warm rose pink"),
    "fatal_attraction": spec("Occult", "one bold rounded heart split by a jagged crack down its center, with a small skull silhouette showing inside the crack", "deep blood red"),
    "test_confused": spec("Occult", "a loose spiral that unwinds upward and ends in the hook of a question mark, with a solid dot below it", "warm amber orange"),
    "test_frightened": spec("Occult", "one bold exclamation mark with a pair of short curved motion lines flaring away on either side of it", "warm amber orange"),
    "test_panicked": spec("Occult", "two bold exclamation marks side by side with a jagged many-pointed starburst spreading behind them", "warm amber orange"),
    "test_sickened": spec("Occult", "a round face with two X-shaped eyes and a wavy zigzag mouth", "sickly yellow-green"),
    "test_nauseated": spec("Occult", "a round face with two squeezed-shut curved eyes and a wide open mouth, with a wavy stream pouring down out of the mouth", "sickly yellow-green"),
    "test_animal_magnetism": spec("Occult", "an animal paw print: four rounded toe pads arranged in an arc above one large rounded heel pad", "warm tan brown"),
    "deny_ending": spec("Occult", "an upright open hand held palm-forward in a halt gesture, with one small solid heart at the center of the palm", "bright white"),
    "alms_of_the_vein": spec("Occult", "a cupped open hand below, catching one fat falling droplet of blood above it", "deep blood red"),
    "bind_soul": spec("Occult", "a small rounded ghost wisp with a wavy tail, wrapped around its middle by a loop of chain links", "pale ice white"),
    "silence": spec("Occult", "a hand bell with a rounded body and a small handle, crossed corner to corner by one bold diagonal stroke", "bright white"),
    "wave_of_dysthymia": spec("Occult", "a wide cone opening upward filled with three nested arcs, with one downturned crescent frown resting inside the widest arc", "dull slate grey"),
    "bloodmusk": spec("Occult", "a small round stoppered flask with three thick curling wisps of vapour rising and spreading from its neck", "deep oxblood red"),
    "persistent_distraction": spec("Occult", "a small squat idol figure standing on a low plinth, with a ring of short straight rays radiating around its head", "warm gold"),
    "erisian_apple": spec("Occult", "one round apple with a short stem and a single pointed leaf, with three short rays coming off its upper edge", "warm gold"),

    # ── Primal ──
    "pounce": spec("Primal", "three parallel curved claw slashes tearing diagonally across, each tapering to a point at both ends", "dark charcoal"),
    "ram": spec("Primal", "the head of a ram seen straight on, with a thick horn on each side of the head curling backward into a tight ring", "pale bone white"),
    "rain": spec("Primal", "a rounded three-lobed cloud with three straight slanted rain lines falling below it", "deep ocean blue"),
    "acid_rain": spec("Primal", "a rounded three-lobed cloud with three slanted lines falling below it, each line ending in a fat round droplet", "acid yellow-green"),
    "freezing_rain": spec("Primal", "a rounded three-lobed cloud with three slanted lines falling below it, each line ending in a small six-pointed snowflake", "pale ice blue"),
    "bumper_crop": spec("Primal", "three tall stalks of wheat with full grain heads, fanning out from a single bound base", "rich golden wheat yellow"),
    "natural_bite": spec("Primal", "a pair of open jaws biting together: an upper arc and a lower arc of thick pointed fangs, with a gap between them", "bright white"),
    "bide": spec("Primal", "a compressed coiled spring with one bold arrow pressing down onto it from above", "deep teal"),
    "oil_well": spec("Primal", "a round stone well head seen from the front, with one thick column of liquid gushing straight up out of its mouth and breaking into three fat falling droplets", "glossy blue-black"),

    # ── Martial ──
    "shield_bash": spec("Martial", "a heater shield seen face-on, with a bold four-pointed impact spark bursting off its upper right edge", "pale steel cream"),
    "rage": spec("Martial", "a clenched fist raised and seen from the front, knuckles toward the viewer", "deep red-brown"),

    # ── Utility ──
    "heal": spec("Utility", "a bold equal-armed cross with thick rounded ends on all four arms", "bright white"),
    "chasten": spec("Utility", "an upright hand with the index finger pointing straight up in a scolding gesture, the other fingers curled", "deep plum purple"),
    "force_march": spec("Utility", "a marching boot striding to the right with three forward-pointing chevrons stacked behind its heel", "dark walnut brown"),
}


def b64_image(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def build_prompt(s):
    circle = SCHOOL_CIRCLE[s["school"]]
    return (
        STYLE
        + f"The large circle is {circle}. "
        + f"The symbol inside it is {s['symbol']}, drawn as a flat solid shape in {s['color']}."
    )


def gen(prompt, ref_paths):
    parts = [{"text": prompt}]
    for rp in ref_paths:
        parts.append({"inline_data": {"mime_type": "image/png", "data": b64_image(rp)}})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
    }
    data = json.dumps(body).encode()
    last_err = None
    for model in MODELS:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={KEY}"
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=240) as resp:
                out = json.loads(resp.read())
            for cand in out.get("candidates", []):
                for p in cand.get("content", {}).get("parts", []):
                    idata = p.get("inlineData") or p.get("inline_data")
                    if idata and idata.get("data"):
                        return base64.b64decode(idata["data"]), model
            last_err = f"{model}: no image part in response: " + json.dumps(out)[:300]
        except urllib.error.HTTPError as e:
            last_err = f"{model} HTTP {e.code}: {e.read().decode()[:300]}"
        except Exception as e:
            last_err = f"{model} {e}"
    raise RuntimeError(last_err)


def square_and_resize(img, size=OUT_SIZE):
    """Center-crop to a square, then downscale."""
    img = img.convert("RGBA")
    w, h = img.size
    if w != h:
        side = min(w, h)
        left = (w - side) // 2
        top = (h - side) // 2
        img = img.crop((left, top, left + side, top + side))
    if img.size[0] != size:
        img = img.resize((size, size), Image.LANCZOS)
    return img


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--list" in sys.argv:
        for k, v in SPECS.items():
            print(f"{v['school']:8s}  {k}")
        return

    targets = args or list(SPECS.keys())
    unknown = [t for t in targets if t not in SPECS]
    if unknown:
        sys.exit(f"unknown ability ids: {', '.join(unknown)}")

    ref_paths = [os.path.join(ICONS, r) for r in REFS]
    for r in ref_paths:
        if not os.path.exists(r):
            sys.exit(f"missing style reference: {r}")

    failures = []
    for i, name in enumerate(targets, 1):
        s = SPECS[name]
        print(f"[{i}/{len(targets)}] {name} ({s['school']}) ...", flush=True)
        try:
            raw, model = gen(build_prompt(s), ref_paths)
        except Exception as e:
            print(f"[FAIL] {name}: {e}", flush=True)
            failures.append(name)
            continue
        img = square_and_resize(Image.open(io.BytesIO(raw)))
        out_path = os.path.join(ICONS, f"ability_{name}.png")
        img.save(out_path)
        print(f"[ ok ] ability_{name}.png  {img.size}  via {model}", flush=True)

    if failures:
        print(f"\n{len(failures)} failed: {', '.join(failures)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
