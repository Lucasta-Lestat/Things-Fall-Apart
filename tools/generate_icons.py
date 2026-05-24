"""Generate building icons in the antique-map style.

Each icon is generated using gemini-3-pro-image-preview with the
`large_village_in_plains_cropped.png` source as a style/aesthetic reference, then
saved to `tfa-simultaneous-gemini-1/Assets/HexTiles/icons/`. Icons are intended
as stamps that can be overlaid on top of biome hex tiles in the world map.

Usage:
    python tools/generate_icons.py            # generate every icon (skips existing)
    python tools/generate_icons.py --force    # regenerate everything
    python tools/generate_icons.py --only castle,fort
    python tools/generate_icons.py --list
"""
from __future__ import annotations

import argparse
import io
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image

MODEL = os.environ.get("HEX_ICONS_MODEL", "gemini-3-pro-image-preview")
OUT_ROOT = Path("tfa-simultaneous-gemini-1") / "Assets" / "HexTiles"
REFERENCE_PATH = OUT_ROOT / "sources" / "large_village_in_plains_cropped.png"
ICONS_DIR = OUT_ROOT / "icons"
MAX_RETRIES = 4

STYLE = (
    "An antique hand-drawn fantasy worldmap building icon, in the same style as "
    "the reference image: delicate sepia/brown ink linework over soft muted "
    "watercolor wash, warm cream/tan parchment background, faded antique palette "
    "(dusty earth-browns, muted brick-red, soft sage). The icon is a SINGLE small "
    "stylized structure drawn in the overhead-with-slight-isometric map convention "
    "used in classic fantasy cartography — like the village icons in the reference. "
    "The structure is the only feature in the frame; it sits centered on plain "
    "parchment with a thin patch of dusty-green grass and a few tiny grass tufts "
    "around its base. No surrounding terrain features, no roads leading anywhere, "
    "no text, no labels, no decorations, no border, no title."
)


@dataclass
class Icon:
    name: str
    prompt: str  # appended to STYLE


ICONS: list[Icon] = [
    Icon("castle",
        "The structure is a small CASTLE icon: a stone keep with two or three "
        "tall crenellated towers, a curtain wall enclosing it, a small fortified "
        "gatehouse. Grey/dusty-sepia stone walls, dark slate-grey conical tower "
        "roofs. The whole castle icon is small in the frame — about a third of "
        "the image width — like a single building icon on an antique map."),
    Icon("fort",
        "The structure is a small FORT icon: a square palisade or low stone wall "
        "enclosing a single watchtower and a couple of plain rectangular "
        "barracks buildings, drawn smaller and more utilitarian than a castle. "
        "Muted brown timber and grey stone. The whole fort icon is small in the "
        "frame — about a third of the image width."),
    Icon("farm",
        "The structure is a small FARM icon: a single thatched-roof farmhouse "
        "with a long barn and a small grain silo, surrounded by a few quilted "
        "field patches in muted pink, cream, and ochre (like the farmland "
        "patches in the reference village). Brown thatch and timber walls, "
        "small fenced garden. The whole farm icon is small in the frame — about "
        "a third of the image width."),
    Icon("factory",
        "The structure is a small FACTORY icon: a single industrial building "
        "drawn as a long brick-and-timber workshop with two tall smokestacks "
        "puffing thin curls of grey smoke, a few small high windows, and a "
        "tile roof. Muted brick-red walls, grey slate roof, dark grey "
        "smokestacks. The whole factory icon is small in the frame — about a "
        "third of the image width."),
    Icon("university",
        "The structure is a small UNIVERSITY icon: a stately stone building "
        "with a central domed rotunda flanked by two symmetrical wings, an "
        "ornate central entrance with steps, and a small clocktower. Pale "
        "stone walls, slate-grey roof, copper-green dome. The whole university "
        "icon is small in the frame — about a third of the image width."),
    Icon("church",
        "The structure is a small CHURCH icon: a single stone chapel with a "
        "tall pointed steeple topped by a small cross, a peaked tile roof, an "
        "arched front door, and a small attached vestry. Pale stone walls, "
        "dark slate-grey roof. The whole church icon is small in the frame — "
        "about a third of the image width."),
]


def _extract_image(resp) -> Image.Image:
    cands = resp.candidates or []
    if not cands:
        raise RuntimeError(f"no candidates (prompt_feedback={getattr(resp, 'prompt_feedback', None)!r})")
    for cand in cands:
        content = getattr(cand, "content", None)
        if content is None or not getattr(content, "parts", None):
            raise RuntimeError(f"empty content (finish_reason={getattr(cand, 'finish_reason', None)!r})")
        for part in content.parts:
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                data = inline.data
                if isinstance(data, str):
                    import base64 as b64
                    data = b64.b64decode(data)
                return Image.open(io.BytesIO(data))
    raise RuntimeError("no inline image data in any candidate part")


def generate_icon(client: genai.Client, icon: Icon, reference: Image.Image) -> Image.Image:
    last_err: Exception | None = None
    full_prompt = f"{STYLE}\n\n{icon.prompt}"
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = client.models.generate_content(
                model=MODEL,
                contents=[reference, full_prompt],
                config=types.GenerateContentConfig(response_modalities=["IMAGE"]),
            )
            return _extract_image(resp)
        except Exception as e:  # noqa: BLE001
            last_err = e
            wait = 2 ** attempt
            print(f"  [{icon.name}] attempt {attempt}/{MAX_RETRIES} failed: {e!r}; sleeping {wait}s")
            time.sleep(wait)
    raise RuntimeError(f"giving up on {icon.name}: {last_err!r}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="list known icon names")
    ap.add_argument("--only", default=None, help="comma-separated icon names to generate")
    ap.add_argument("--force", action="store_true", help="regenerate even if file exists")
    args = ap.parse_args()

    if args.list:
        for ic in ICONS:
            print(f"  {ic.name}")
        return 0

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        return 2
    if not REFERENCE_PATH.exists():
        print(f"ERROR: reference image missing: {REFERENCE_PATH}", file=sys.stderr)
        return 2

    client = genai.Client(api_key=api_key)
    reference = Image.open(REFERENCE_PATH).convert("RGB")
    reference.load()

    if args.only:
        wanted = {n.strip() for n in args.only.split(",") if n.strip()}
        targets = [ic for ic in ICONS if ic.name in wanted]
        missing = wanted - {ic.name for ic in targets}
        if missing:
            print(f"ERROR: unknown icon name(s): {missing}", file=sys.stderr)
            return 2
    else:
        targets = list(ICONS)

    ICONS_DIR.mkdir(parents=True, exist_ok=True)
    fail = 0
    for ic in targets:
        out_path = ICONS_DIR / f"{ic.name}.png"
        if out_path.exists() and not args.force:
            print(f"  [{ic.name}] exists, skipping -> {out_path}")
            continue
        try:
            print(f"  [{ic.name}] generating...")
            img = generate_icon(client, ic, reference)
            img.save(out_path, "PNG")
            print(f"    saved -> {out_path}")
        except Exception as e:  # noqa: BLE001
            fail += 1
            print(f"FAIL [{ic.name}]: {e}")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
