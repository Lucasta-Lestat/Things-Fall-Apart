#!/usr/bin/env python3
"""Generate unique top-down head sprites for named NPCs via Gemini.

For each named NPC in data/TopDownCharacters.json, generates a 68x60 RGBA PNG
head sprite that matches the perspective and style of the existing
Characters/Assets/Body Parts/Male Human/head.png reference, but is
differentiated by the NPC's race, background, faction, and personality.

Outputs:
  Characters/Assets/Body Parts/Named/<npc_id>/head.png             (68x60 final)
  Characters/Assets/Body Parts/Named/<npc_id>/raw_generated/head_raw.png
                                                            (full-res raw output)

Side effect (unless --no-json-update):
  Updates each target NPC's body_sprites in data/TopDownCharacters.json to
  { head: <new>, torso/upper_arm/forearm/leg: race-default-resolved-by-gender }
  and patches earl_grey's race from "human" to "elf".

Requires GEMINI_API_KEY (or GOOGLE_API_KEY) env var, google-genai, Pillow.

Usage:
    python tools/generate_named_npc_heads.py [--only id1,id2,...]
                                              [--overwrite] [--dry-run]
                                              [--list] [--sleep 2.0]
                                              [--gender id=female,...]
                                              [--no-json-update]
                                              [--model gemini-2.5-flash-image]
"""

import argparse
import io
import json
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
CHARACTERS_JSON = DATA_DIR / "TopDownCharacters.json"
RACES_JSON = DATA_DIR / "races.json"

REFERENCE_HEAD = ROOT / "Characters" / "Assets" / "Body Parts" / "Male Human" / "head.png"
NAMED_HEADS_DIR = ROOT / "Characters" / "Assets" / "Body Parts" / "Named"

OUTPUT_SIZE = (68, 60)
DEFAULT_MODEL = "gemini-2.5-flash-image"

# The 46 named NPCs that get unique heads. (Excludes generic archetypes,
# the protagonist, and characters with already-iconic dedicated art like
# jacana/dryad/siren.)
TARGET_IDS = {
    # human (24)
    "hadrian_rosemerrow", "sunder_havelton", "captain_morgan", "captain_jameson",
    "lighthouse_keeper_brother", "prosecco", "joey_feritas", "reverend_mother_liana",
    "mother_inferior_macaria", "hunter_john", "centurion_marcus", "deputy_gleg",
    "hedge_witch_magda", "cletus_samson", "obediah", "jezebel",
    "austache_jongle", "mostlemyre_drouge", "smith_darcy", "professor_circino",
    "professor_easton", "zakariah", "saul_laelia", "big_al_samson",
    # saurian (12)
    "liziti_don", "iguana_don", "roy_demonitor", "andrew_tuatara",
    "gordon_gecko", "dusk", "chameleon_paglia", "boa",
    "mary_guana", "lot_lizard_zillah", "alligator_capone",
    # elf (2): earl_grey is currently mis-classified as human in JSON; we patch it.
    "earl_grey", "nude_elf",
    # other (8)
    "brutus_half_off",     # dwarf
    "quillath",            # halfling
    "stokes_carfire",      # kobold
    "djargo",              # grimalkin
    "pesto", "tommy",      # carapacian
    "alewife_juturna",     # half_elf
    "rodney_the_rat",      # rodentkin
}

# TopDownCharacters.json uses some race ids that don't exist in races.json
# under that exact spelling. Map to the actual race entry.
RACE_ID_ALIASES = {
    "elf":         "high_elf",
    "carapacian":  "carapacians",
    "rodentkin":   "rat",
}

# Gender per NPC. Used to (1) drop the right word into the prompt and
# (2) pick races[race_id].body_sprites.male|female for torso/arm/leg paths.
# Defaults to "male" for any id not listed. Override at runtime with
# --gender id=female,other_id=male.
GENDER_MAP = {
    "jezebel":                 "female",
    "hedge_witch_magda":       "female",
    "alewife_juturna":         "female",
    "mary_guana":              "female",
    "lot_lizard_zillah":       "female",
    "reverend_mother_liana":   "female",
    "mother_inferior_macaria": "female",
    "prosecco":                "female",
    "boa":                     "female",
}

# Strong race-anatomy hint passed to the model in TEXT (since the only
# image reference we send is the male human head). Each description is
# crafted to make the model render distinctively non-human anatomy when
# appropriate — overcoming the human bias of the reference image.
RACE_ANATOMY_HINTS = {
    "human":      "ordinary human head with skin, hair, ears on the sides",
    "elf":        "elven head with sharply pointed ears extending up and outward, fine angular features, smooth fair skin",
    "high_elf":   "high-elf head with sharply pointed ears extending up and outward, fine angular features, smooth pale skin",
    "half_elf":   "half-elf head with subtly pointed ears, refined human-like features",
    "halfling":   "halfling head, smaller and rounder than a human head, ruddy cheeks, curly hair, bare round ears",
    "dwarf":      "dwarven head with thick voluminous beard covering the lower face, broad nose, bushy eyebrows",
    "kobold":     "small kobold dragon-kin head, short scaly snout protruding forward, small curved horns or horn-nubs at the brow, slit reptilian eyes, no hair",
    "saurian":    "anthropomorphic lizard-folk head, prominent reptilian snout protruding forward (NOT a flat human face), green or brown scaled hide, slit yellow reptile eyes, NO hair, optional small ridge of spines or dewlap, fanged mouth — viewed from straight above so the snout is clearly visible projecting forward from the body",
    "draconian":  "dragon-blooded head with full reptilian scaled face, prominent snout, slit eyes, small horns",
    "carapacian": "anthropomorphic turtle-folk head, smooth scaly green-brown turtle head with hooked beak instead of a mouth, small beady black eyes, NO hair, hard shell ridge visible at the back of the head/neck",
    "carapacians":"anthropomorphic turtle-folk head, smooth scaly green-brown turtle head with hooked beak instead of a mouth, small beady black eyes, NO hair, hard shell ridge visible at the back of the head/neck",
    "grimalkin":  "feline cat-folk head, fur covering the whole head, triangular pointed cat ears on top, slit vertical-pupil eyes, small nose, optional whiskers — clearly NOT a human face",
    "mephistkin": "small devilkin head with curving horns at the temples, reddish or purple skin, pointed features",
    "rodentkin":  "anthropomorphic rat-folk head, narrow whiskered snout protruding forward, round ears on top of the head, small dark eyes, fur covering the head — clearly rodent, NOT human",
    "rat":        "anthropomorphic rat-folk head, narrow whiskered snout protruding forward, round ears on top of the head, small dark eyes, fur covering the head — clearly rodent, NOT human",
}

# Per-NPC handcrafted appearance flavor. Pulls heavily from the existing
# NAME_FLAVOR strings in tools/generate_character_icons.py (reused / lightly
# rewritten for top-down framing) and adds entries for NPCs that script
# didn't cover.
HEAD_FLAVOR = {
    # human
    "hadrian_rosemerrow":        "auburn hair, calming aristocratic features, neat trim",
    "sunder_havelton":           "burly, cropped dark hair, weathered scarred face, fierce expression",
    "captain_morgan":            "swarthy sun-bronzed face, curly black hair, thick black goatee and moustache, easy white-toothed grin, single gold hoop earring, wide-brimmed black tricorne hat with a red feather seen from above",
    "captain_jameson":           "stoic auburn hair, weathered ruddy face, salt-and-pepper beard, plain dark seafarer's cap from above",
    "lighthouse_keeper_brother": "elderly weathered, long grey-white hair tied back in a tail, deep crow's feet, salt-stained mossy hood pulled half down",
    "prosecco":                  "elegant noblewoman, champagne-blonde hair piled high with sparkling jeweled pins, refined makeup",
    "joey_feritas":              "wiry young man, neat dark hair, plain features, faint half-smile, simple traveler",
    "reverend_mother_liana":     "middle-aged woman with kind serene face, white-and-purple wimple covering her hair, small silver pendant",
    "mother_inferior_macaria":   "severe older woman with sharp eyes, dark hooded mystery-cult cowl, pale skin",
    "hunter_john":               "burly bearded man with shaggy dark hair and a leather peddler's cap, weather-beaten face",
    "centurion_marcus":          "stern military officer in red-plumed centurion helm with cheek-guards (helm seen from above with the crest running front-to-back)",
    "deputy_gleg":               "young guard recruit in dented kettle helm, plain freckled face under the brim",
    "hedge_witch_magda":         "wiry middle-aged woman with stringy grey-streaked black hair, sharp clever eyes, herb-stained hands, plain dark hood",
    "cletus_samson":             "brutish slavecatcher, shaved head, scarred face, wide cruel smirk",
    "obediah":                   "shabby drunkard with messy unkempt hair, reddened nose, bleary eyes",
    "jezebel":                   "striking urchin woman with messy dark hair, sharp suspicious eyes, dirty cheek",
    "austache_jongle":           "carnival barker, twirled black moustache, slick-backed hair, gaudy striped collar",
    "mostlemyre_drouge":         "older academic hierophant, balding pate ringed with grey hair, hooded purple-and-gold robe",
    "smith_darcy":               "muscular human smith, soot-streaked face, short cropped dark hair, leather forge cap",
    "professor_circino":         "owl-eyed older librarian, round wire spectacles, neat grey-streaked beard, soft hat",
    "professor_easton":          "youngish patrician academic, neatly combed brown hair, refined clean-shaven face",
    "zakariah":                  "lean academic with cropped dark hair, neatly trimmed goatee, intent thoughtful eyes",
    "saul_laelia":               "weathered ex-soldier turned bandit, broken nose, stubble, sour grin",
    "big_al_samson":             "huge brutish bandit with shaved head, jagged scar across one cheek, cruel grin",
    # saurian
    "liziti_don":                "heavyset crocodilian gangster, blunt lizard snout with rows of teeth, slit yellow eyes, dark grey fedora pulled low (seen from above), thick dewlap",
    "iguana_don":                "iguana mafia don with prominent dewlap and ridge of back spines visible above the head, fine pinstripe collar, cigar smoke from snout",
    "roy_demonitor":             "monitor-lizard mobster with sharp narrow snout, dark mottled scales, suit collar at the neck",
    "andrew_tuatara":            "tuatara-saurian, distinctive third-eye spot at the top of the head, ridge of small spines, fedora tilted to one side",
    "gordon_gecko":              "gecko-saurian merchant, wide pad-fingered, slicked-back style, shrewd grin, gold rings",
    "dusk":                      "small skink-saurian rogue, smooth dark scales, narrow snout, shadowy hood half pulled up",
    "chameleon_paglia":          "chameleon-saurian assassin, eyes pointing different directions, mottled green-purple scales fading to translucent on one side",
    "boa":                       "elegant serpent-saurian noblewoman, smooth fine green-purple scales, no visible ears, refined regal bearing, jeweled circlet",
    "mary_guana":                "older female iguana-saurian witch, prominent dewlap, dark green scales, head-wrap with herb sprig tucked in",
    "lot_lizard_zillah":         "young saurian woman with bright green-and-yellow scales, gaudy makeup around slit eyes, cheap brassy earrings",
    "alligator_capone":          "older alligator-saurian carnival skipper, wide armored snout, leathery green hide, weathered cap",
    # elf
    "earl_grey":                 "youngish haughty elven druid in his thirties, sharply pointed elf ears, neat aristocratic features, fine pale skin, neatly trimmed beard, leaf circlet",
    "nude_elf":                  "tall semi-divine elf, luminously moon-pale skin, sharply pointed elf ears, long flowing pale-silver hair, large dazed otherworldly eyes",
    # dwarf
    "brutus_half_off":           "stocky dwarf mercenary, thick brown beard covering the lower face, weather-beaten skin, broad smirking mouth, plain steel skullcap",
    # halfling
    "quillath":                  "halfling outlander, leathered tanned skin, wild tangled hair, savage rage-grin, NO beard",
    # kobold
    "stokes_carfire":            "small kobold tinkerer, scaly red-brown snout, soot-blackened cheeks, brass goggles strapped over the brow, small horn-nubs",
    # grimalkin
    "djargo":                    "scrappy grimalkin cat-folk pickpocket, tabby orange-and-black fur, large pointed cat ears tilted forward, slit green eyes, sly grin",
    # carapacian
    "pesto":                     "anthropomorphic green-brown sea-turtle gangster, scaly turtle head with hooked beak, small beady eyes, black fedora tilted low (from above) casting shadow",
    "tommy":                     "carapacian turtle-folk thug, scaly green-brown turtle head with hooked beak, flat newsboy cap pulled low (from above)",
    # half_elf
    "alewife_juturna":           "warm-faced half-elven alewife, subtly pointed ears, dark braid coiled around her head, kind smiling eyes",
    # rodentkin
    "rodney_the_rat":            "small rat-folk in tattered kerchief tied around the head, narrow whiskered snout, round ears, quick darting black eyes",
}


# ---------- helpers ----------

def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def index_by_id(items, id_key="id"):
    return {item[id_key]: item for item in items if id_key in item}


def init_client():
    api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        sys.exit("ERROR: GEMINI_API_KEY (or GOOGLE_API_KEY) is not set in the environment.")
    try:
        from google import genai  # type: ignore
    except ImportError:
        sys.exit("ERROR: google-genai not installed. Run: pip install google-genai pillow")
    return genai.Client(api_key=api_key)


def call_gemini_image(client, model, prompt, reference_bytes):
    """Call gemini-2.5-flash-image with a style reference image."""
    from google.genai import types  # type: ignore

    contents = []
    if reference_bytes:
        contents.append(types.Part.from_bytes(data=reference_bytes, mime_type="image/png"))
    contents.append(prompt)
    response = client.models.generate_content(model=model, contents=contents)
    for cand in response.candidates or []:
        for part in (cand.content.parts if cand.content else []):
            inline = getattr(part, "inline_data", None)
            if inline and inline.data:
                return inline.data
    raise RuntimeError("No image returned by Gemini.")


def downscale_to_head(image_bytes, size=OUTPUT_SIZE, flip_vertical=True):
    """Resize the AI output to the canonical 68x60 RGBA head sprite size.

    Gemini consistently produces these heads in an orientation that ends up
    facing opposite to the existing race-default heads when used in-game,
    so we vertically flip (top<->bottom) by default. Pass flip_vertical=False
    to opt out.
    """
    from PIL import Image
    img = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    img = img.resize(size, Image.LANCZOS)
    if flip_vertical:
        img = img.transpose(Image.FLIP_TOP_BOTTOM)
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def gender_for(npc_id, gender_overrides):
    if npc_id in gender_overrides:
        return gender_overrides[npc_id]
    return GENDER_MAP.get(npc_id, "male")


def race_anatomy_for(race_id):
    return RACE_ANATOMY_HINTS.get(
        race_id, "humanoid head with race-typical features"
    )


def build_head_prompt(char, gender):
    """Construct the text prompt for one named NPC's head."""
    name = char.get("name", char["id"])
    race_id = char.get("race", "")
    if char["id"] == "earl_grey":
        # Honor the data fix: even though the stored race may still be "human"
        # at prompt-build time, treat Earl Grey as elf for the prompt.
        race_id = "elf"
    anatomy = race_anatomy_for(race_id)
    flavor = HEAD_FLAVOR.get(char["id"], "")

    flavor_part = f" {flavor}." if flavor else ""

    return (
        "Look very carefully at the attached reference image of the brown "
        "bearded man. Things to notice: the visible silhouette is a ROUND, "
        "FAT, COMPRESSED oval — like a chibi bobblehead viewed from above. "
        "There is NO neck, NO shoulders, NO body — just one round head "
        "silhouette filling the canvas. The HAIR / SCALP makes up roughly "
        "the upper 60-70% of the silhouette as a brown dome covering the "
        "crown of the head. The face features (eyes, nose, beard) only "
        "occupy the LOWER 30-40% of the silhouette, tucked under the hair "
        "dome — and even then the eyes are TINY closed slits, not large "
        "open portrait eyes. The whole thing reads as 'I am looking down "
        "at the top of someone's head and just barely glimpse their beard "
        "from above.' This is a TOP-DOWN sprite for a 2D RPG (think "
        "Stardew Valley / Pokemon overhead view). "
        "\n\n"
        f"Subject: the top-down head sprite of {name}, a {gender} {race_id}.{flavor_part} "
        f"Race anatomy from above: {anatomy}. "
        "\n\n"
        "Strict composition rules — every output must obey ALL of these: "
        "  (1) Round / oval / chibi-bobblehead silhouette filling the canvas. "
        "      NO neck, NO shoulders, NO body. "
        "  (2) The TOP 60-70% of the silhouette is HAIR / SCALP / CAP / HOOD "
        "      / HORNS / SHELL viewed from above. (For bald characters, "
        "      bare scalp; for hooded, the hood crown.) "
        "  (3) The face occupies only the BOTTOM 30-40% of the silhouette, "
        "      tucked under the hair dome. "
        "  (4) Eyes are TINY closed slits or small downward-cast dots — "
        "      NEVER large open portrait eyes making eye contact. "
        "  (5) Mouth/beard is at the very bottom of the silhouette. "
        "  (6) For reptilian / saurian / kobold / rodent races: the snout "
        "      protrudes from the silhouette (not centered face features). "
        "      For carapacian: hard shell ridge dominates the upper crown. "
        "  (7) Single isolated head; transparent background; no scenery, "
        "      border, text, or speech bubble. "
        "  (8) Match the reference's stylized painterly look — strong dark "
        "      outlines, warm muted earth-tone palette, soft top-down "
        "      lighting (highlight on crown, shadow under chin). "
        "\n\n"
        "FORBIDDEN — if you produce any of these the output is WRONG: "
        "  ✗ A front-facing portrait or bust shot. "
        "  ✗ Large open eyes making eye contact with the viewer. "
        "  ✗ A visible neck or shoulders. "
        "  ✗ A three-quarter cinematic angle. "
        "  ✗ Hi-res clean digital portrait or anime style. "
        "  ✗ Any background scenery, frame, or text. "
        "\n\n"
        "Output one single top-down head sprite identical in style, "
        "perspective, and silhouette compression to the attached reference."
    )


def select_targets(characters, only_ids):
    """Pick named-NPC entries; honor --only filter; preserve JSON order."""
    targets = []
    seen = set()
    for c in characters:
        cid = c.get("id")
        if not cid or cid not in TARGET_IDS:
            continue
        if only_ids and cid not in only_ids:
            continue
        if cid in seen:
            # Duplicate id in JSON (e.g. andrew_tuatara appears twice).
            # Process only the first occurrence; downstream JSON-update
            # writes to all entries with that id.
            continue
        seen.add(cid)
        targets.append(c)
    return targets


def resolve_race_default_body_sprites(races_index, race_id, gender):
    """Return a flat dict of race-default body part paths for the given gender."""
    actual_race = RACE_ID_ALIASES.get(race_id, race_id)
    race_entry = races_index.get(actual_race)
    if not race_entry:
        raise RuntimeError(
            f"Race '{race_id}' (resolved to '{actual_race}') not found in races.json"
        )
    bs = race_entry.get("body_sprites", {})
    if "male" in bs or "female" in bs:
        resolved = bs.get(gender, bs.get("male", {}))
    else:
        resolved = bs
    if not resolved:
        raise RuntimeError(f"No body_sprites for race '{race_id}' (gender '{gender}')")
    return dict(resolved)


def parse_gender_overrides(s):
    if not s:
        return {}
    out = {}
    for pair in s.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            raise SystemExit(f"--gender expects 'id=female' pairs; got: {pair!r}")
        k, v = pair.split("=", 1)
        v = v.strip().lower()
        if v not in ("male", "female"):
            raise SystemExit(f"--gender values must be 'male' or 'female'; got: {v!r}")
        out[k.strip()] = v
    return out


def _format_body_sprites_block(body_sprites):
    """Format a body_sprites dict in the file's exact mixed-indent style:
    \\t  "body_sprites": {
    \\t\\t"head": "...",
    ...
    \\t  },
    """
    keys = ["head", "torso", "upper_arm", "forearm", "leg"]
    lines = ["\t  \"body_sprites\": {"]
    for i, k in enumerate(keys):
        v = body_sprites[k]
        comma = "," if i < len(keys) - 1 else ""
        lines.append(f"\t\t\"{k}\": \"{v}\"{comma}")
    lines.append("\t  },")
    return "\n".join(lines) + "\n"


def update_topdown_characters_json(updates, race_fixes):
    """Targeted in-file edits to preserve the file's mixed-indentation format.

    `updates`     maps npc_id -> body_sprites dict (flat, gender-resolved).
    `race_fixes`  maps npc_id -> new race string (e.g. {'earl_grey': 'elf'}).

    Body_sprites are inserted immediately after the entry's "faction" line.
    Race fixes replace the entry's "race" value in place.
    Both apply to ALL entries with a matching id (handles duplicate ids).
    """
    # Read in binary mode to preserve the source file's line-ending convention
    # (the file uses Unix LF; Python text mode on Windows would convert to CRLF
    # on write and produce a massive whitespace-only diff).
    raw = CHARACTERS_JSON.read_bytes().decode("utf-8")

    # Find which target ids already have body_sprites in the file so we don't
    # double-insert on re-runs.
    parsed_existing = json.loads(raw)
    existing_bs_ids = {
        e["id"] for e in parsed_existing.get("characters", [])
        if e.get("body_sprites")
    }

    # 1. Race fixes — replace the value of the FIRST "race" field in each
    #    entry whose id matches. Non-greedy [\s\S]*? bounded by the entry's
    #    own "race" line keeps us inside the entry.
    fixed_races = []
    for npc_id, new_race in race_fixes.items():
        pattern = re.compile(
            r'(\"id\":\s*\"' + re.escape(npc_id) + r'\"[\s\S]*?\"race\":\s*)\"[^\"]*\"'
        )
        raw, count = pattern.subn(lambda m: m.group(1) + f'\"{new_race}\"', raw)
        if count > 0:
            fixed_races.append((npc_id, new_race, count))

    # 2. Body_sprites insertions — for each id, insert the formatted block
    #    immediately after the entry's "faction" line. Non-greedy match keeps
    #    us inside the entry. re.subn replaces ALL occurrences (handles
    #    duplicate ids like andrew_tuatara).
    inserted = []
    skipped_existing = []
    for npc_id, body_sprites in updates.items():
        if npc_id in existing_bs_ids:
            skipped_existing.append(npc_id)
            continue
        block = _format_body_sprites_block(body_sprites)
        pattern = re.compile(
            r'(\"id\":\s*\"' + re.escape(npc_id) + r'\"[\s\S]*?\"faction\":[^\n]*\n)'
        )
        raw, count = pattern.subn(lambda m: m.group(1) + block, raw)
        if count > 0:
            inserted.append((npc_id, count))
        else:
            print(f"  WARN: couldn't anchor body_sprites insertion for {npc_id}")

    # Verify the result is still valid JSON before writing.
    try:
        json.loads(raw)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"JSON write would corrupt file (parse error: {e}); aborting."
        )

    tmp = CHARACTERS_JSON.with_suffix(CHARACTERS_JSON.suffix + ".tmp")
    # Binary write to avoid Python translating \n -> \r\n on Windows.
    tmp.write_bytes(raw.encode("utf-8"))
    os.replace(tmp, CHARACTERS_JSON)
    return inserted, fixed_races, skipped_existing


def res_path_for_head(npc_id):
    """Godot-style res:// path that goes into TopDownCharacters.json."""
    return f"res://Characters/Assets/Body Parts/Named/{npc_id}/head.png"


# ---------- main ----------

def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--only", help="Comma-separated NPC ids to (re)generate")
    p.add_argument("--overwrite", action="store_true", help="Re-generate even if PNG exists")
    p.add_argument("--dry-run", action="store_true", help="Print prompts; do not call API or write JSON")
    p.add_argument("--list", action="store_true", help="List target ids and exit")
    p.add_argument("--sleep", type=float, default=2.0, help="Seconds between API calls")
    p.add_argument("--gender", default="", help="Per-NPC gender overrides, e.g. 'jezebel=female,obediah=male'")
    p.add_argument("--no-json-update", action="store_true",
                   help="Generate PNGs only; do NOT touch TopDownCharacters.json")
    p.add_argument("--no-flip", action="store_true",
                   help="Skip the default vertical flip applied after downscale.")
    p.add_argument("--model", default=DEFAULT_MODEL,
                   help=f"Gemini image model id. Default {DEFAULT_MODEL}.")
    return p.parse_args()


def main():
    args = parse_args()
    only_ids = set(args.only.split(",")) if args.only else None
    gender_overrides = parse_gender_overrides(args.gender)

    chars_data = load_json(CHARACTERS_JSON)
    characters = chars_data["characters"]
    races_index = index_by_id(load_json(RACES_JSON).get("races", []))

    targets = select_targets(characters, only_ids)
    if args.list:
        for c in targets:
            print(f"{c['id']:30s} race={c.get('race',''):11s} gender={gender_for(c['id'], gender_overrides)}")
        print(f"\nTotal: {len(targets)}")
        return

    print(f"Model: {args.model}")
    print(f"Reference image: {REFERENCE_HEAD.relative_to(ROOT)}")
    print(f"Targeting {len(targets)} named NPCs.")

    if not args.dry_run:
        if not REFERENCE_HEAD.exists():
            sys.exit(f"ERROR: reference head missing at {REFERENCE_HEAD}")
        reference_bytes = REFERENCE_HEAD.read_bytes()
        client = init_client()
    else:
        reference_bytes = None
        client = None

    NAMED_HEADS_DIR.mkdir(parents=True, exist_ok=True)

    body_sprite_updates = {}  # npc_id -> flat body_sprites dict
    race_fixes = {"earl_grey": "elf"}  # one-line data fix per plan
    failures = []

    for i, char in enumerate(targets, 1):
        cid = char["id"]
        npc_dir = NAMED_HEADS_DIR / cid
        raw_dir = npc_dir / "raw_generated"
        out_path = npc_dir / "head.png"
        raw_path = raw_dir / "head_raw.png"

        gender = gender_for(cid, gender_overrides)
        prompt = build_head_prompt(char, gender)

        # Resolve body_sprites for the JSON wiring step (reads race aliases
        # too — earl_grey is treated as elf for path resolution).
        resolve_race_id = "elf" if cid == "earl_grey" else char.get("race", "")
        try:
            race_default = resolve_race_default_body_sprites(races_index, resolve_race_id, gender)
        except Exception as e:
            print(f"\n[{i}/{len(targets)}] {cid}: FAILED to resolve race body_sprites: {e}")
            failures.append((cid, f"race-resolve: {e}"))
            continue
        wired = dict(race_default)
        wired["head"] = res_path_for_head(cid)
        body_sprite_updates[cid] = wired

        print(f"\n[{i}/{len(targets)}] {cid} ({char.get('race','?')}, {gender})")
        print(f"  prompt (first 200 chars): {prompt[:200]}...")
        print(f"  out: {out_path.relative_to(ROOT)}")

        if args.dry_run:
            continue

        if out_path.exists() and not args.overwrite:
            print(f"  exists, skip image gen (still wires JSON)")
        else:
            try:
                npc_dir.mkdir(parents=True, exist_ok=True)
                raw_dir.mkdir(parents=True, exist_ok=True)
                raw = call_gemini_image(client, args.model, prompt, reference_bytes)
                raw_path.write_bytes(raw)
                final = downscale_to_head(raw, OUTPUT_SIZE, flip_vertical=not args.no_flip)
                out_path.write_bytes(final)
                print(f"  saved: {out_path.relative_to(ROOT)}  ({OUTPUT_SIZE[0]}x{OUTPUT_SIZE[1]})")
            except Exception as e:
                print(f"  FAILED: {e}")
                failures.append((cid, str(e)))
                # Don't wire JSON for a failed generation.
                body_sprite_updates.pop(cid, None)

        if args.sleep > 0 and i < len(targets):
            time.sleep(args.sleep)

    if not args.dry_run and not args.no_json_update and body_sprite_updates:
        inserted, fixed_races, skipped = update_topdown_characters_json(
            body_sprite_updates, race_fixes
        )
        total_inserts = sum(c for _, c in inserted)
        print(f"\nInserted body_sprites blocks: {total_inserts} across {len(inserted)} unique ids in {CHARACTERS_JSON.relative_to(ROOT)}")
        for npc_id, count in inserted:
            if count > 1:
                print(f"  {npc_id}: {count} entries (duplicate id in source)")
        if skipped:
            print(f"Skipped {len(skipped)} ids that already had body_sprites: {', '.join(skipped)}")
        for npc_id, new_race, count in fixed_races:
            print(f"  race-fix: {npc_id} -> {new_race} ({count} entries)")
    elif args.no_json_update:
        print(f"\n--no-json-update set; TopDownCharacters.json untouched.")

    print(f"\nDone. Generated {len(targets) - len(failures)} heads; {len(failures)} failures.")
    if failures:
        for cid, err in failures:
            print(f"  - {cid}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
