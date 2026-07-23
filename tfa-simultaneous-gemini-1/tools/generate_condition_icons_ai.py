#!/usr/bin/env python3
"""Generate condition/status icons via Gemini, matching the ability-icon style.

Reuses the flat risograph style + Gemini plumbing from generate_ability_icons_ai.py.
Condition icons render very small (16x16 in the party panel's status row), so the
symbols here are deliberately bolder and simpler than the ability set.

The disc colour encodes the condition's *category* rather than a school, so a
glance separates buffs from afflictions:
    buff       -> sage green
    physical   -> clay orange   (movement/body debuffs)
    mental     -> muted violet  (afflictions of the mind)
    disease    -> sickly chartreuse
    special    -> slate blue    (unique mechanics)

Three conditions (bide, deny_ending, panic) share an identity with an ability and
simply reuse that ability's icon; they are not regenerated here.

Usage:
    python tools/generate_condition_icons_ai.py            # all 30
    python tools/generate_condition_icons_ai.py pox mania  # just these
    python tools/generate_condition_icons_ai.py --list
"""

import io
import os
import sys

# Run-as-script puts tools/ on sys.path[0], so a plain import resolves.
from generate_ability_icons_ai import (
    ICONS,
    REFS,
    STYLE,
    b64_image,
    gen,
    square_and_resize,
)
from PIL import Image

CATEGORY_CIRCLE = {
    "buff": "soft sage green (#A7C9A0)",
    "physical": "soft clay orange (#E0A878)",
    "mental": "soft muted violet (#B296CC)",
    "disease": "sickly chartreuse green (#BFC96E)",
    "special": "soft slate blue (#93A9C4)",
}


def spec(category, symbol, color):
    return {"category": category, "symbol": symbol, "color": color}


# id -> (category, symbol description, symbol colour)
SPECS = {
    # ── Buffs (sage green) ──
    "powerful": spec("buff", "one bold upward-pointing arrow, thick with a wide chevron head", "bright white"),
    "focused": spec("buff", "a bullseye target of two concentric rings around a solid center dot", "bright white"),
    "stalwart": spec("buff", "a solid heater shield seen face-on", "bright white"),
    "physically_resistant": spec("buff", "a short wall of three stacked bricks in a staggered bond", "bright white"),
    "acute": spec("buff", "a glowing lightbulb with a small screw base and three short rays above it", "bright white"),
    "perceptive": spec("buff", "one wide open eye with a round pupil at its center", "bright white"),
    "courageous": spec("buff", "one bold five-pointed star", "bright white"),
    "blessed": spec("buff", "a small sun: a solid center disc ringed by short straight rays", "bright white"),
    "verdant_blessing": spec("buff", "a young sprout of two rounded leaves rising from a short stem", "bright white"),
    "undead_resilience": spec("buff", "a simple skull silhouette seen from the front", "pale bone white"),

    # ── Physical debuffs (clay orange) ──
    "grappled": spec("physical", "a chain of three thick interlocking oval links running diagonally", "dark walnut brown"),
    "lethargic": spec("physical", "one thick downward-drooping arrow", "dark walnut brown"),
    "fatigued": spec("physical", "three letter Z shapes rising in a diagonal stair from small to large", "dark walnut brown"),
    "hungover": spec("physical", "a bottle tipped on its side with a small loose spiral drifting up from its mouth", "dark walnut brown"),

    # ── Mental afflictions (muted violet) ──
    "irrational": spec("mental", "a side profile of a head with a tangled scribble knot where the brain would be", "bright white"),
    "paranoid": spec("mental", "one wide staring eye with its round pupil shoved hard to one side", "bright white"),
    "selfish": spec("mental", "three short stubby arrows all pointing inward toward one small solid dot at the center", "bright white"),
    "hopelessness": spec("mental", "a small rain cloud with a single downturned frown curve beneath it", "bright white"),
    "mania": spec("mental", "a tight wound-up scribble spiral", "bright white"),
    "anxiety": spec("mental", "one sharp jagged trembling zigzag line running across", "bright white"),
    "narcissistic": spec("mental", "a hand mirror: an upright oval on a short handle", "bright white"),
    "masochistic": spec("mental", "a coiled whip curling into a loop", "bright white"),
    "hypochondria": spec("mental", "an upright medical thermometer with a rounded bulb at the bottom", "bright white"),
    "fearful": spec("mental", "a small rounded ghost with a wavy bottom edge and two dark eyes", "bright white"),
    "haunted": spec("mental", "a pale hollow mask face with two dark empty round eye sockets and a small dark open mouth", "bright white"),

    # ── Disease (chartreuse) ──
    "pox": spec("disease", "a cluster of three round pockmark blotches, one large and two small", "dark olive brown"),
    "scarred": spec("disease", "one long jagged scar line crossed by four short stitch marks", "dark olive brown"),

    # ── Special mechanics (slate blue) ──
    "thrill_of_sin": spec("special", "a single tumbling die showing five pips on its face", "bright white"),
    "the_jaws_that_bite": spec("special", "a pair of open jaws: an upper and lower arc of thick pointed fangs with a gap between", "pale bone white"),
    "the_claws_that_catch": spec("special", "three parallel curved claw slashes tearing diagonally, each tapered at both ends", "pale bone white"),
    "wanted": spec("special", "a hangman's noose: a loop of rope with a coiled knot at the top", "dark rope brown"),
}

REUSED = {
    "bide": "res://UI/UI Icons/ability_bide.png",
    "deny_ending": "res://UI/UI Icons/ability_deny_ending.png",
    "panic": "res://UI/UI Icons/ability_test_panicked.png",
}


def build_prompt(s):
    circle = CATEGORY_CIRCLE[s["category"]]
    return (
        STYLE
        + f"The large circle is {circle}. "
        + f"The symbol inside it is {s['symbol']}, drawn as a flat solid shape in {s['color']}. "
        + "Because this icon is viewed very small, make the symbol especially bold, thick and simple "
        + "with no fine detail, filling most of the circle."
    )


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--list" in sys.argv:
        for k, v in SPECS.items():
            print(f"{v['category']:9s}  cond_{k}")
        for k, v in REUSED.items():
            print(f"{'(reused)':9s}  {k} -> {v}")
        return

    targets = args or list(SPECS.keys())
    unknown = [t for t in targets if t not in SPECS]
    if unknown:
        sys.exit(f"unknown / non-generated condition ids: {', '.join(unknown)}")

    ref_paths = [os.path.join(ICONS, r) for r in REFS]
    failures = []
    for i, name in enumerate(targets, 1):
        s = SPECS[name]
        print(f"[{i}/{len(targets)}] cond_{name} ({s['category']}) ...", flush=True)
        try:
            raw, model = gen(build_prompt(s), ref_paths)
        except Exception as e:
            print(f"[FAIL] {name}: {e}", flush=True)
            failures.append(name)
            continue
        img = square_and_resize(Image.open(io.BytesIO(raw)))
        out_path = os.path.join(ICONS, f"cond_{name}.png")
        img.save(out_path)
        print(f"[ ok ] cond_{name}.png  {img.size}  via {model}", flush=True)

    if failures:
        print(f"\n{len(failures)} failed: {', '.join(failures)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
