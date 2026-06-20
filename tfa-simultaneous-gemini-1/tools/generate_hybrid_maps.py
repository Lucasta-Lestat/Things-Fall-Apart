#!/usr/bin/env python3
"""Generate new in-game battlemaps by hybridizing existing Czepeku reference
maps via the Gemini image API (gemini-3-pro-image / "Nano Banana Pro").

For each map spec we produce TWO images at the largest resolution the model
supports:

  Maps/<id>.png         the REGULAR version  (terrain + buildings/structures)
  Maps/<id>_clean.png   the CLEAN version    (same scene, structures removed —
                                              the structureless base layer)

The clean version is derived FROM the freshly generated regular version (fed
back to the model as a reference) so the two stay pixel-aligned for in-game
layering.

References are pulled either from the repo's curated set
(Maps/Example Maps/...) or extracted on demand from the full Czepeku library
at  ~/Downloads/czepeku-maps/<folder>/all-variants.zip .

Prompts are phrased positively (the model latches onto negated concepts), and
ask for a general absence of clutter, per project conventions.

Requires GEMINI_API_KEY (or GOOGLE_API_KEY), google-genai, Pillow.

Usage:
    python tools/generate_hybrid_maps.py --list
    python tools/generate_hybrid_maps.py --only lighthouse,perrow_river_stronghold
    python tools/generate_hybrid_maps.py            # all maps
    python tools/generate_hybrid_maps.py --overwrite --size 4K
"""

import argparse
import io
import os
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAPS_DIR = ROOT / "Maps"
EXAMPLES = MAPS_DIR / "Example Maps"
REFS_CACHE = MAPS_DIR / "_refs"            # extracted czepeku references
CZEPEKU = Path(os.path.expanduser("~")) / "Downloads" / "czepeku-maps"

DEFAULT_MODEL = "gemini-3-pro-image-preview"
DEFAULT_SIZE = "4K"

# Supported aspect ratios (label -> width/height) for gemini-3-pro-image.
ASPECTS = {
    "1:1": 1.0, "2:3": 2 / 3, "3:2": 3 / 2, "3:4": 3 / 4, "4:3": 4 / 3,
    "4:5": 4 / 5, "5:4": 5 / 4, "9:16": 9 / 16, "16:9": 16 / 9, "21:9": 21 / 9,
}


# ----------------------------------------------------------------------------
# Reference resolution
# ----------------------------------------------------------------------------
# A reference is either:
#   ("repo", "<path under Maps/>")                 an already-present image
#   ("czepeku", "<folder>", "<variant substring>") extract from all-variants.zip
# The variant substring is matched case-insensitively against zip entry names;
# defaults to "Original_Day" when omitted.

REFS = {
    # --- repo Example Maps (present as files) ---
    "river_stronghold":  ("repo", "Example Maps/GL_RiverStronghold_Original_Day.jpeg"),
    "bullywug_swamp":    ("repo", "Example Maps/GL_BullywugSwamp_Original_Day.jpeg"),
    "swamp_graveyard":   ("repo", "Example Maps/GL_SwampGraveyard_Natural_Day.jpeg"),
    "ages_vale_tavern":  ("repo", "Example Maps/GL_AgesOfTheValeTavern_Indoors_Stage_Day.jpeg"),
    "village_market":    ("repo", "Example Maps/GL_MarketCityWalls_Village_Market_Day.jpeg"),
    "city_market":       ("repo", "Example Maps/GL_MarketCityWalls_Original_Day.jpeg"),
    "goblin_fortress":   ("repo", "Example Maps/GL_GoblinForestFortress_Original_Day.jpeg"),
    "forest_pass":       ("repo", "Example Maps/GL_ForestPass_Original_Day.jpeg"),
    "mangrove_forest":   ("repo", "Example Maps/GL_MangroveForest_No_Animals.jpeg"),
    "amphitheatre":      ("repo", "Example Maps/Affluent Amphitheatre/GL_AffluentAmphitheatre_Original_Day.jpeg"),
    "hippodrome":        ("repo", "Example Maps/GL_Hippodrome_Original_Day.jpeg"),
    "training_grounds":  ("repo", "Example Maps/GL_TrainingGrounds_Original_Day.jpeg"),
    "tidal_river":       ("repo", "Example Maps/GL_TidalRiver_Empty.jpeg"),
    "floating_market":   ("repo", "Example Maps/GL_FloatingMarket_Original_Day.jpeg"),
    "black_market":      ("repo", "Example Maps/GL_BlackMarketStreets_Fog.jpeg"),
    "druid_islands":     ("repo", "Example Maps/GL_DruidIslands_Original_Day.jpeg"),
    "dragon_memorial":   ("repo", "Example Maps/GL_Dragon'sMemorial_Rocklands.jpeg"),
    "lighthouse_isle":   ("repo", "Example Maps/GL_LighthouseIsle_Original_Day.jpeg"),
    "archons_villa":     ("repo", "Example Maps/GL_Archon'sVilla_Original_Day.jpeg"),
    "beachside_cliff":   ("repo", "Example Maps/GL_BeachsideCliff_Natural_Day.jpeg"),

    # --- czepeku library (extracted on demand) ---
    "adventurers_guild": ("czepeku", "adventurers-guildhall", "Original_Day"),
    "eeler_base":        ("czepeku", "pirate-port-tavern", "PiratePortTavern_Tavern_Level_Day"),
    "royal_stables":     ("czepeku", "with foundry/royal-stables", "Original_Day"),
    "royal_mine_town":   ("czepeku", "with foundry/royal-mine-town", "Original_Day"),
    "wild_west_town":    ("czepeku", "with foundry/wild-west-town", "Original_Exterior_Day"),
    "harpy_cove":        ("czepeku", "harpy-cove", "Original_Day"),
    "heart_of_village":  ("repo", "Example Maps/Heart of the Village.zip"),  # zip in repo
}


def _extract_from_zip(zip_path: Path, variant: str, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        names = [n for n in zf.namelist() if n.lower().endswith((".jpeg", ".jpg", ".png"))]
        if not names:
            raise RuntimeError(f"No images inside {zip_path}")
        match = next((n for n in names if variant.lower() in n.lower()), None)
        if match is None:
            # fall back to the first image
            match = sorted(names)[0]
            print(f"    (variant '{variant}' not found in {zip_path.name}; using {match})")
        target = out_dir / Path(match).name
        if not target.exists():
            with zf.open(match) as src, open(target, "wb") as dst:
                dst.write(src.read())
        return target


def resolve_ref(key: str) -> Path:
    spec = REFS[key]
    kind = spec[0]
    if kind == "repo":
        p = MAPS_DIR / spec[1]
        if p.suffix.lower() == ".zip":
            return _extract_from_zip(p, "Original_Day", REFS_CACHE / key)
        if not p.exists():
            raise FileNotFoundError(f"Missing repo reference for '{key}': {p}")
        return p
    elif kind == "czepeku":
        folder = spec[1]
        variant = spec[2] if len(spec) > 2 else "Original_Day"
        base = CZEPEKU / folder
        # prefer an already-extracted all-variants/ dir
        extracted = base / "all-variants"
        if extracted.is_dir():
            cands = [f for f in extracted.iterdir()
                     if f.suffix.lower() in (".jpeg", ".jpg", ".png")]
            match = next((f for f in cands if variant.lower() in f.name.lower()), None)
            if match:
                return match
        zip_path = base / "all-variants.zip"
        if zip_path.exists():
            return _extract_from_zip(zip_path, variant, REFS_CACHE / key)
        raise FileNotFoundError(f"No czepeku source for '{key}' at {base}")
    raise ValueError(f"Unknown ref kind {kind!r} for '{key}'")


# ----------------------------------------------------------------------------
# Map specifications
# ----------------------------------------------------------------------------
# Each spec: id, name, region, base (primary structures source), hybrid (the
# environment/biome to blend in), and `theme` text describing the fused result.

MAP_SPECS = [
    # ---- Perrow village, blended with the swamp around the town ----
    dict(id="perrow_river_stronghold", name="River Stronghold", region="perrow",
         base="river_stronghold", hybrid="bullywug_swamp",
         theme="a riverside stone stronghold half-claimed by a murky bullywug swamp, "
               "its walls rising from reed-choked black water and mossy mudflats"),
    dict(id="perrow_heart_village", name="Heart of the Village", region="perrow",
         base="heart_of_village", hybrid="swamp_graveyard",
         theme="the heart of a sunken village square sinking into a misty swamp graveyard, "
               "crooked headstones and gnarled willows among the cottages"),
    dict(id="perrow_vale_tavern", name="Ages of the Vale Tavern", region="perrow",
         base="ages_vale_tavern", hybrid="bullywug_swamp",
         theme="a timber tavern on stilts over swampy bullywug shallows, "
               "boardwalks crossing dark reed-fringed water"),
    dict(id="perrow_village_market", name="Perrow Village Market", region="perrow",
         base="village_market", hybrid="bullywug_swamp",
         theme="a walled village market square edged by encroaching swamp, "
               "market stalls on raised planking above muddy bog channels"),
    dict(id="perrow_adventurers_guild", name="Perrow Adventurers' Guild", region="perrow",
         base="adventurers_guild", hybrid="swamp_graveyard",
         theme="an adventurers' guildhall on the edge of a fog-laden swamp graveyard, "
               "the courtyard giving way to mossy tombs and still black water"),
    dict(id="perrow_eeler_tavern", name="The Eeler's Tavern", region="perrow",
         base="eeler_base", hybrid="bullywug_swamp",
         theme="a dockside eel-fishers' tavern over brackish swamp water, "
               "eel-traps and nets along weathered jetties amid the reeds"),

    # ---- Perrow wilderness, blended with mangrove forest ----
    dict(id="perrow_goblin_fortress", name="Goblin Forest Fortress", region="perrow",
         base="goblin_fortress", hybrid="mangrove_forest",
         theme="a ramshackle goblin fortress built among the tangled roots and "
               "channels of a flooded mangrove forest"),
    dict(id="perrow_forest_pass", name="Mangrove Forest Pass", region="perrow",
         base="forest_pass", hybrid="mangrove_forest",
         theme="a winding forest pass threading through dense mangrove woodland, "
               "raised trail and footbridges over tidal mangrove water"),

    # ---- Bortellini, blended with a tidal river ----
    dict(id="bortellini_amphitheatre", name="Bortellini Amphitheatre", region="bortellini",
         base="amphitheatre", hybrid="tidal_river",
         theme="a grand stone amphitheatre on the banks of a wide tidal river, "
               "tiered seating descending toward the glittering water"),
    dict(id="bortellini_royal_stables", name="Royal Stables", region="bortellini",
         base="royal_stables", hybrid="tidal_river",
         theme="royal riverside stables beside a broad tidal river, "
               "paddocks and stable yards opening onto the riverbank"),
    dict(id="bortellini_adventurers_guild", name="Bortellini Adventurers' Guild", region="bortellini",
         base="adventurers_guild", hybrid="tidal_river",
         theme="an adventurers' guildhall on a tidal riverfront, "
               "its courtyard meeting stone quays along the flowing water"),
    dict(id="bortellini_hippodrome", name="Bortellini Hippodrome", region="bortellini",
         base="hippodrome", hybrid="tidal_river",
         theme="a grand chariot hippodrome alongside a tidal river, "
               "the long racing track running parallel to the riverbank"),
    dict(id="bortellini_training_camp", name="Bortellini Training Camp", region="bortellini",
         base="training_grounds", hybrid="tidal_river",
         theme="a military training camp on a tidal riverbank, "
               "sparring yards and drill grounds beside the water"),
    dict(id="bortellini_city_market", name="Bortellini City Market", region="bortellini",
         base="city_market", hybrid="tidal_river",
         theme="a bustling walled city market beside a tidal river, "
               "market quays and stalls lining the waterfront"),

    # ---- Alamone, blended with druid islands ----
    dict(id="alamone_floating_market", name="Alamone Floating Market", region="alamone",
         base="floating_market", hybrid="druid_islands",
         theme="a floating market of boats and pontoons drifting among lush "
               "druidic islands, walkways linking verdant islets"),
    dict(id="alamone_black_market", name="Alamone Black Market", region="alamone",
         base="black_market", hybrid="druid_islands",
         theme="a shadowy black-market quarter built across small druid islands, "
               "narrow alleys and bridges spanning overgrown island channels"),
    dict(id="alamone_adventurers_guild", name="Alamone Adventurers' Guild", region="alamone",
         base="adventurers_guild", hybrid="druid_islands",
         theme="an adventurers' guildhall set on a lush druid island, "
               "the courtyard ringed by water, standing stones and ancient trees"),

    # ---- Argentiara, blended with the dragon memorial rocklands ----
    dict(id="argentiara_mine_town", name="Royal Mine Town", region="argentiara",
         base="royal_mine_town", hybrid="dragon_memorial",
         theme="a royal silver-mining town carved into rocky dragon-memorial "
               "highlands, ore-works and rooftops among weathered stone monuments"),
    dict(id="argentiara_wild_west_town", name="Frontier Town", region="argentiara",
         base="wild_west_town", hybrid="dragon_memorial",
         theme="a dusty frontier mining town in rocky dragon-memorial badlands, "
               "a wide main street flanked by timber buildings beneath stone outcrops"),

    # ---- Don Manor (Perrow), villa architecture amid the bullywug swamp ----
    dict(id="don_manor", name="Don Manor", region="perrow",
         base="archons_villa", hybrid="beachside_cliff",
         theme="the opulent clifftop villa manor of the local crime Don, its "
               "colonnaded courtyards, tiled terraces, and ornamental gardens "
               "perched on a rocky seaside bluff, with stone steps and a private "
               "landing descending the cliff to the sea below, waves breaking on "
               "the rocks at the water's edge"),

    # ---- Lighthouse (explicit single deliverable) ----
    dict(id="lighthouse", name="Lighthouse", region="perrow",
         base="lighthouse_isle", hybrid="harpy_cove",
         theme="a rugged coastal lighthouse on a rocky isle within a sheltered "
               "harpy cove, the tower rising over tide-washed rocks and a curving shore"),
]


# ----------------------------------------------------------------------------
# Gemini
# ----------------------------------------------------------------------------

def init_client():
    api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        sys.exit("ERROR: GEMINI_API_KEY (or GOOGLE_API_KEY) not set.")
    try:
        from google import genai  # type: ignore
    except ImportError:
        sys.exit("ERROR: google-genai not installed. pip install google-genai pillow")
    return genai.Client(api_key=api_key)


def nearest_aspect(path: Path) -> str:
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None  # source battlemaps are legitimately huge
    w, h = Image.open(path).size
    r = w / h
    return min(ASPECTS, key=lambda k: abs(ASPECTS[k] - r))


def _gen(client, model, contents, aspect, size):
    from google.genai import types  # type: ignore
    cfg = types.GenerateContentConfig(
        response_modalities=["IMAGE"],
        # NOTE: the model returns JPEG bytes by default (which is why we save
        # .jpg). output_mime_type is NOT supported by this API — do not add it.
        image_config=types.ImageConfig(aspect_ratio=aspect, image_size=size),
    )
    resp = client.models.generate_content(model=model, contents=contents, config=cfg)
    for cand in resp.candidates or []:
        for part in (cand.content.parts if cand.content else []):
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                return inline.data
    raise RuntimeError("No image returned by Gemini.")


MAX_REF_EDGE = 4096       # downscale references longer than this on the long edge
MAX_REF_BYTES = 12 << 20  # ...or larger than this many bytes (API inline limit)


def part_from(path: Path):
    """Return an image Part, downscaling oversized references.

    Some Czepeku source maps are enormous (e.g. the hippodrome is 8400x22400,
    61MB) and the Gemini API rejects them with 400 INVALID_ARGUMENT. Re-encode
    anything too large to a JPEG that fits comfortably under the inline limit;
    the model only needs the composition, not full print resolution.
    """
    from google.genai import types  # type: ignore
    data = path.read_bytes()
    mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    w, h = Image.open(path).size
    if max(w, h) > MAX_REF_EDGE or len(data) > MAX_REF_BYTES:
        scale = MAX_REF_EDGE / max(w, h)
        img = Image.open(path).convert("RGB")
        if scale < 1:
            img = img.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=90)
        data, mime = buf.getvalue(), "image/jpeg"
        print(f"      (downscaled ref {path.name} {w}x{h} -> {img.size}, {len(data)/1e6:.1f}MB)")
    return types.Part.from_bytes(data=data, mime_type=mime)


def regular_prompt(spec):
    return (
        "You are creating a single top-down tabletop RPG battlemap, viewed "
        "straight from directly overhead (orthographic bird's-eye view), in the "
        "lush painterly Czepeku style of the two attached reference maps. "
        f"Hybridize the two references into one cohesive new scene: {spec['theme']}. "
        "Take the architecture and key structures from the first reference and "
        "reimagine them sitting naturally within the environment, terrain, water, "
        "and vegetation of the second reference, so the result reads as one "
        "believable location. "
        "Keep the composition clean and open with a general absence of clutter: "
        "clear ground for movement, only the essential buildings and a few "
        "natural features, plenty of negotiable open space. "
        "Fill the whole frame with the map itself, edge to edge, with consistent "
        "overhead lighting, rich color, and crisp readable detail. Output a single "
        "finished battlemap image."
    )


def clean_prompt(spec):
    return (
        "Here is a finished top-down RPG battlemap. Produce the matching CLEAN "
        "BASE-LAYER version of the very same scene: keep the exact same framing, "
        "camera angle, dimensions, ground layout, terrain, paths, water, and "
        "natural vegetation perfectly aligned with this image, but render it as "
        "empty ground only. Replace every building, wall, roof, tent, stall, "
        "furniture, crate, vehicle, and movable prop with the natural ground or "
        "terrain that would lie beneath it, so the surface is continuous and "
        "unobstructed. The result is the same place shown as bare, open terrain "
        "ready to have structures layered on top. Keep it clean and free of "
        "clutter, same painterly overhead style. Output a single image."
    )


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--only", help="Comma-separated map ids to generate")
    p.add_argument("--list", action="store_true", help="List specs and exit")
    p.add_argument("--overwrite", action="store_true", help="Regenerate even if PNG exists")
    p.add_argument("--clean-only", action="store_true", help="(Re)generate only the clean layer from an existing regular PNG")
    p.add_argument("--size", default=DEFAULT_SIZE, help="Image size: 1K, 2K, or 4K")
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--sleep", type=float, default=3.0)
    p.add_argument("--dry-run", action="store_true", help="Resolve refs + print prompts, no API calls")
    return p.parse_args()


def select(only):
    if not only:
        return MAP_SPECS
    want = set(only.split(","))
    return [s for s in MAP_SPECS if s["id"] in want]


def main():
    args = parse_args()
    specs = select(args.only)

    if args.list:
        for s in MAP_SPECS:
            print(f"{s['id']:30s} [{s['region']:11s}] base={s['base']:18s} + {s['hybrid']}")
        print(f"\nTotal: {len(MAP_SPECS)} maps ({len(MAP_SPECS) * 2} images)")
        return
    if not specs:
        sys.exit("No matching map ids.")

    print(f"Model: {args.model}   size: {args.size}")
    print(f"Generating {len(specs)} maps -> {len(specs) * 2} images\n")

    client = None if args.dry_run else init_client()
    failures = []

    for i, spec in enumerate(specs, 1):
        mid = spec["id"]
        # Gemini returns JPEG bytes; save with a .jpg extension so Godot's
        # importer decodes them correctly (a .png extension on JPEG data fails
        # to import with ERR_CANT_OPEN / res.is_null()).
        reg_path = MAPS_DIR / f"{mid}.jpg"
        clean_path = MAPS_DIR / f"{mid}_clean.jpg"
        print(f"[{i}/{len(specs)}] {mid}  ({spec['region']})")
        try:
            base = resolve_ref(spec["base"])
            hybrid = resolve_ref(spec["hybrid"])
        except Exception as e:
            print(f"   REF ERROR: {e}")
            failures.append((mid, f"ref: {e}"))
            continue
        aspect = nearest_aspect(base)
        print(f"   base={base.name}  hybrid={hybrid.name}  aspect={aspect}")

        if args.dry_run:
            print(f"   [regular prompt] {regular_prompt(spec)[:120]}...")
            continue

        # --- regular ---
        try:
            if reg_path.exists() and not args.overwrite and not args.clean_only:
                print(f"   regular exists, skip: {reg_path.name}")
            elif not args.clean_only:
                data = _gen(client, args.model,
                            [part_from(base), part_from(hybrid), regular_prompt(spec)],
                            aspect, args.size)
                reg_path.write_bytes(data)
                from PIL import Image
                print(f"   saved {reg_path.name}  {Image.open(io.BytesIO(data)).size}")
        except Exception as e:
            print(f"   REGULAR FAILED: {e}")
            failures.append((mid, f"regular: {e}"))
            continue

        # --- clean (derived from regular) ---
        try:
            if clean_path.exists() and not args.overwrite and not args.clean_only:
                print(f"   clean exists, skip: {clean_path.name}")
            else:
                if not reg_path.exists():
                    raise RuntimeError("regular PNG missing; cannot derive clean")
                data = _gen(client, args.model,
                            [part_from(reg_path), clean_prompt(spec)],
                            aspect, args.size)
                clean_path.write_bytes(data)
                from PIL import Image
                print(f"   saved {clean_path.name}  {Image.open(io.BytesIO(data)).size}")
        except Exception as e:
            print(f"   CLEAN FAILED: {e}")
            failures.append((mid, f"clean: {e}"))

        if args.sleep and i < len(specs):
            time.sleep(args.sleep)

    print(f"\nDone. {len(specs) - len({f[0] for f in failures})}/{len(specs)} maps OK.")
    if failures:
        for mid, err in failures:
            print(f"  - {mid}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
