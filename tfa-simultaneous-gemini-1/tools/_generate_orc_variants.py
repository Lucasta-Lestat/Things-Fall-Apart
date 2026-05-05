"""One-off: generate two orc attempts on Ultra. Pick the best, copy to
orc_warrior_icon.png, delete the rest."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from generate_character_icons import (
    call_imagen, init_client, apply_jacana_frame, downscale_to_token,
    PATRICIAN_STYLE, OUTPUT_SIZE, ICONS_DIR
)

MODEL = "imagen-4.0-ultra-generate-001"

common = (
    "a brutish hulking orc trench soldier with a sickly mottled grey-green "
    "diseased complexion (jaundiced, unhealthy hue, NOT bright green), "
    "wearing a pale beige loose canvas hood-style WWI Macpherson PH gas "
    "mask: a soft unfitted canvas sack pulled down covering his entire "
    "head, two simple solid matte-black flat circular goggle lenses set "
    "into the front of the hood (plain black discs), a small dark "
    "breathing tube valve protruding at the mouth area of the hood. Two "
    "large yellowed lower-jaw tusks curve UPWARD past the bottom edge of "
    "the canvas hood. Hand-stitched grey wool WWI tunic and webbing"
)

variants = {
    "v1": (
        f"Subject of the painting: Orc Warrior — {common}, gloved hands "
        "gripping a battered bolt-action rifle with bayonet, distant "
        "artillery smoke and a blood-red dawn horizon behind."
    ),
    "v2": (
        f"Subject of the painting: Orc Warrior — {common}, holding a "
        "homemade trench shovel with sharpened edge, foggy no-man's-land "
        "with broken telegraph poles silhouetted behind."
    ),
}

framing = (
    "head-and-shoulders bust portrait, three-quarter view, looking toward the viewer."
)

client = init_client()
ICONS_DIR.mkdir(parents=True, exist_ok=True)
for name, subject in variants.items():
    full = f"{subject} {framing} {PATRICIAN_STYLE}"
    print(f"\n[{name}]")
    raw = call_imagen(client, MODEL, full)
    png = downscale_to_token(raw, OUTPUT_SIZE)
    png = apply_jacana_frame(png, OUTPUT_SIZE)
    out = ICONS_DIR / f"orc_warrior_ultra_{name}_icon.png"
    out.write_bytes(png)
    print(f"  saved: {out.relative_to(ICONS_DIR.parent)}")
    time.sleep(2)
