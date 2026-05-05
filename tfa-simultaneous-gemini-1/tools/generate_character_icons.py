#!/usr/bin/env python3
"""Generate Jacana-styled circular character tokens via Gemini's image model.

Reads data/TopDownCharacters.json plus races.json and factions.json, builds a
per-character prompt, and asks gemini-2.5-flash-image to produce a token in the
exact style of Icons/jacana_icon.png. Output is saved to Icons/{id}_icon.png.

Usage:
    python tools/generate_character_icons.py [--only id1,id2,...]
                                              [--overwrite] [--dry-run]
                                              [--list]

Requires GEMINI_API_KEY (or GOOGLE_API_KEY) env var, google-genai, Pillow.
"""

import argparse
import hashlib
import io
import json
import os
import random
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
ICONS_DIR = ROOT / "Icons"
REFERENCE_ICON = ICONS_DIR / "jacana_icon.png"
CHARACTERS_JSON = DATA_DIR / "TopDownCharacters.json"
RACES_JSON = DATA_DIR / "races.json"
FACTIONS_JSON = DATA_DIR / "factions.json"
BACKGROUNDS_JSON = DATA_DIR / "backgrounds.json"
QUIRKS_JSON = DATA_DIR / "npc_quirks.json"

# Characters whose hand-written flavor already establishes a strong personality;
# we still apply a random appearance quirk but skip the demeanor to avoid
# contradicting the existing tone (e.g. don't make a "haughty noble" "obsequious").
SKIP_DEMEANOR_QUIRK = {
    "earl_grey",        # haughty noble
    "iguana_don",       # intimidating mafia don
    "liziti_don",       # intimidating mafia don
    "bandit_chief",     # intimidating warlord
    "demon_imp",        # wicked grin
    "nude_elf",         # confused
    "pirate_captain",   # swaggering
    "captain_morgan",   # easy grin
    "captain_jameson",  # stoic
    "gordon_gecko",     # shrewd
    "siren",            # hypnotic
    "skeleton_warrior", # mindless
    "shambling_zombie", # mindless
    "wild_wolf",        # snarling
    "wild_bear",        # feral
    "stray_horse",      # noble steed
    "dryad",            # ethereal fey
    "chameleon_paglia", # invisible/stealth
    "quillath",         # rage
}

# Animals don't get human quirks at all.
SKIP_ALL_QUIRKS = {"wild_wolf", "wild_bear", "stray_horse"}

OUTPUT_SIZE = 256
DEFAULT_MODEL = "imagen-4.0-ultra-generate-001"
SKIP_IDS = {"protagonist", "jacana"}

# Frame geometry. Inside FRAME_INNER_TAN_R is the AI artwork. The annulus
# [FRAME_INNER_TAN_R, FRAME_OUTER_R] is a procedurally-drawn tan ring with a
# anti-aliased inner edge — color sampled from Jacana's actual ring so it
# visually matches without compositing any of her cloak/portrait pixels.
FRAME_INNER_TAN_R  = 113   # inner edge of the tan ring (artwork ends here)
FRAME_OUTER_R      = 126   # outer edge of the tan ring (image edge)
FRAME_FEATHER      = 1.5   # gaussian blur on alpha edges, in pixels at 256px
RING_TAN_COLOR     = (179, 151, 115)

# Detailed style description baked into prompts when using Imagen (which has no
# image-reference input). Aggressively targets the painterly halftone aesthetic
# of Icons/jacana_icon.png (NOT modern clean cartoon comic).
JACANA_STYLE = (
    "Painted in the exact style of a vintage 1980s AD&D fantasy book "
    "illustration: dim moody atmosphere with heavy halftone newsprint "
    "grain texture across the entire image. Painted in loose gouache and "
    "ink wash with soft brush edges — NOT clean comic-book line art, NOT "
    "bright modern digital painting, NOT a polished video-game splash. "
    "Limited dirty palette of dusky purples, deep teals, muted ochres, "
    "mossy greens and ink-blacks. Subject is dimly lit by subtle pale "
    "moonlight or candle, with most of the image sinking into shadow. "
    "Strong chiaroscuro, somber and quiet mood. The background is SIMPLE "
    "and ATMOSPHERIC — soft shadow, fog, a distant silhouette, a hint of "
    "moonlit sky — never a detailed busy environment, never daylight, "
    "never crowded with objects. The whole image looks like a faded "
    "printed page from an old AD&D module. The painting fills the entire "
    "square canvas edge to edge as a single bleed-off scene. A centered "
    "head-and-shoulders bust portrait, three-quarter view, the subject "
    "filling roughly the central 70% of the canvas with atmospheric "
    "shadow filling the corners."
)

# The earlier (looser, less restrictive) style block used when generating
# Patrician Knight, which the user liked. Differs from the current block by
# allowing brighter atmosphere and busier backgrounds.
PATRICIAN_STYLE = (
    "Render this in the style of a painterly vintage fantasy book "
    "illustration from the 1980s, painted in muted moody gouache and ink "
    "wash with heavy halftone newsprint grain texture across the entire "
    "image. The painting fills the entire square canvas edge to edge as a "
    "single bleed-off scene. A centered head-and-shoulders bust portrait, "
    "three-quarter view, the subject filling roughly the central 70% of "
    "the canvas with atmospheric background filling the corners. Soft "
    "brushwork rendering, sketchy organic ink hatching combined with "
    "painted color washes, soft edges where light meets shadow, visible "
    "halftone dotting in skin and cloth. Desaturated dirty palette of "
    "muted purples, dusky blues, ochres, mossy greens and ink-blacks, "
    "with subtle pale candle or moonlight highlights. Dramatic "
    "chiaroscuro, moody somber atmosphere. Looks slightly faded, like a "
    "printed page from an old AD&D module. The subject's head and "
    "shoulders sit comfortably within the central 80% of the canvas with "
    "breathing room around them."
)

STYLE_BLOCKS = {
    "current": JACANA_STYLE,
    "patrician": PATRICIAN_STYLE,
}

# Visual flavor for factions (factions.json has no description field).
FACTION_FLAVOR = {
    "neutral":           "an unaffiliated commoner with plain dress",
    "player":            "a member of the player's adventuring party",
    "adventurers_guild": "a practical sword-for-hire in blues, mixed-race guild gear",
    "golden_guard":      "a disciplined military officer in gold-trimmed plate, formal armor",
    "liziti":            "a saurian street gangster in simple, makeshift gear, mafia underworld",
    "patriciate":        "a refined aristocrat in ornate purple-and-gold robes, decadent luxury",
    "bandits":           "a rough outlaw in crude leathers and earth-tone rags",
    "rebels":            "a working-class insurgent with simple, scrappy equipment",
    "undead":            "a rotting servant with grey, decayed flesh, no discipline",
    "wildlife":          "a feral creature of the wilds",
    "cultists":          "a hooded zealot with occult sigils, dark cursed aesthetic",
    "dragatini":         "a draconian legionnaire in red-and-gold lorica, military discipline",
    "tortellini":        "a turtle-shelled mafia thug in green organic mafia attire",
    "pirates":           "a freebooter in dark grey-and-blue seafaring coat with cutlass and flintlock",
    "rival_party":       "a rival adventurer",
    "druids":            "a nature hermit in roughspun robes draped with leaves and bones",
    "vermincelli":       "a shifty rat-folk underclass member with ragged urban clothing",
    "spider_party":      "an adventurer (treat as a flavor-only group; no spider iconography)",
    "from_faction":      "a generic fighter",
    "none":              "an unaligned individual",
}

# Compact visual fallback for races.
RACE_FLAVOR_FALLBACK = {
    "human":         "ordinary human",
    "half_elf":      "half-elf with subtly pointed ears and refined features",
    "high_elf":      "tall fair-skinned elf with golden hair and pointed ears",
    "elf":           "slender elf with pointed ears",
    "quadrelf":      "four-legged centauroid elf, feminine humanoid torso on a four-legged elf body",
    "halfling":      "short, earthy, agile halfling",
    "dwarf":         "short stocky bearded dwarf",
    "kobold":        "small misshapen draconic kobold (~3ft) with scaled snout",
    "saurian":       "semi-aquatic lizard-folk with draconic head, scaled hide and clawed hands",
    "draconian":     "tall dragon-blooded warrior with scaled face and proud crested brow",
    "carapacian":    "turtle-folk with thick green-brown carapace shell, broad and slow",
    "carapacians":   "turtle-folk with thick green-brown carapace shell",
    "grimalkin":     "lithe feline humanoid (cat-folk) with vertical-slit eyes and tufted ears",
    "mephistkin":    "small devilkin with horns, reddish or purple skin",
    "rodentkin":     "small rat-folk humanoid with whiskered snout and clever eyes",
    "siren":         "alluring aquatic humanoid with iridescent scales and gill slits",
    "fey":           "tiny whimsical fey creature with bright translucent skin",
    "orc":           "fungal orc with greenish skin and red mushroom-cap atop the head",
    "centaur":       "centaur — human torso atop a horse body",
    "goatmen":       "aristocratic goat-headed humanoid with curling horns and erudite mien",
    "human_undead":  "shambling human zombie with grey rotting flesh and milky eyes",
    "wolf":          "feral grey wolf",
    "bear":          "massive forest bear",
    "horse":         "noble stray horse",
    "from_faction":  "humanoid",
    "fey_creature":  "fey creature",
}

# Per-character flavor — name puns, story hooks. Empty string = nothing extra.
NAME_FLAVOR = {
    "default_human":             "neutral expression, ordinary peasant clothing",
    "town_guard":                "iron kettle helm, watchful sergeant, stone wall behind",
    "merchant":                  "plump middle-aged human shopkeeper, balding with friendly eyes, simple linen shirt under a leather apron, holding a small ledger in one hand and weighing coins on a brass scale with the other, lit by lamps in a marketplace stall full of barrels and jars",
    "bandit":                    "scarred face, bandana, leering grin",
    "bandit_chief":              "battle-scarred warlord with war-axe over shoulder, intimidating",
    "rebel_fighter":             "young human peasant fighter, plain face smudged with dirt, dirty grey cloth wrapped around his forehead, red cloth sash tied diagonally across his chest over a patched roughspun tunic, gripping a sturdy pitchfork upright, scorched fields and a smoldering village burning behind him at sunset",
    "forest_elf":                "moss-cloaked archer in dappled forest light, longbow in hand",
    "cultist":                   "shadowed hood, candlelit ritual chamber, occult sigil pendant",
    "skeleton_warrior":          "yellowed skull face, rusted helm, dead glowing eye-sockets",
    "demon_imp":                 "tiny bat-winged purple imp with wicked grin and clawed fingers",
    "noble_lord":                "haughty patrician aristocrat with golden circlet and embroidered robe",
    "wild_wolf":                 "grey wolf snarling, head-on bust, glowing yellow eyes, moonlit forest",
    "liziti_thug":               "a lizard-man thug with green-grey scales covering his face, blunt lizard snout, slit yellow eyes, fangs, wearing a black newsboy cap and grimy striped waistcoat, dim alley shadow behind",
    "liziti_don":                "a heavyset lizard-man with thick green-grey scales covering his entire face, a blunt lizard snout, slit yellow pupils, a fanged sneer — wearing Al Capone's signature outfit from his 1929 mugshot: a dark grey fedora pulled low, a charcoal pinstripe three-piece suit with vest and tie, a lit cigar in his mouth, dim moody speakeasy shadow behind",
    "draga_legionnaire":         "a dragon-blooded warrior with bronze-green scales covering his face, a draconic snout, slit reptile eyes, fangs, wearing a simple red-and-gold scale lorica with a plain iron helm, dim banner-shadow behind",
    "draga_centurion":           "a dragon-blooded officer with crimson scales covering his face, a draconic snout, slit reptile eyes, fangs, wearing an ornate red-plumed centurion helm with cheek-guards over polished red-and-gold lorica, dim legion-banner silhouettes behind",
    "tort_enforcer":             "huge carapacian turtle-folk thug in dockworker mafia attire, heavy shell visible",
    "pirate_buccaneer":          "weathered pirate in tricorne and stained coat, gold tooth gleam",
    "pirate_captain":            "swaggering pirate captain with feathered tricorne, ornate flintlock and cutlass, sea behind",
    "guild_hunter":              "sharp-eyed adventurer in blue-and-leather guild gear, crossbow slung",
    "patrician_knight":          "polished steel knight with purple-and-gold patrician tabard",
    "djargo":                    "scrappy grimalkin cat-folk pickpocket with patched cloak, sly grin",
    "hadrian_rosemerrow":        "refined human noble with auburn hair and a calming, soothing expression, embroidered doublet",
    "sunder_havelton":           "burly human soldier with cropped hair and a battered breastplate, fierce stance",
    "brutus_half_off":           "stocky dwarf mercenary with thick beard, shield strapped to back, bargain-barker grin",
    "quillath":                  "halfling outlander with leathered skin, wild eyes, savage grin (rage)",
    "stokes_carfire":            "small kobold tinkerer with goggles and soot-blackened cheeks, ember-glow tools",
    "captain_morgan":            "a swarthy sun-bronzed human pirate captain with curly black hair, a thick black goatee and moustache, easy white-toothed grin, wearing a wide-brimmed black tricorne hat with a red feather, an open white shirt under a dark naval coat, a single gold hoop earring, dim foggy harbor behind",
    "captain_jameson":           "stoic human pirate captain with auburn hair and weathered face (Jameson whiskey visual joke)",
    "earl_grey":                 "youngish haughty noble human druid in his thirties with sharp aristocratic features, neatly trimmed beard, raised chin, holding a delicate porcelain teacup with pinky out, fine embroidered green-and-gold robe with leaf motifs, refined and aloof, mossy ancient grove behind",
    "dryad":                     "fey nymph with bark-textured skin, leafy hair, glowing green eyes, forest grove",
    "nude_elf":                  "a tall semi-divine mythological elf with luminously pale moon-white skin, sculptural finely-cut features of unearthly beauty, long flowing pale-silver hair, sharply pointed ears, large otherworldly eyes carrying a faint dazed confusion, draped only in a simple linen loincloth, drifting silver mist in a moonlit ancient grove behind",
    "lighthouse_keeper_brother": "an elderly weathered human hermit with deep crow's feet around tired eyes, long grey-white hair tied back, a salt-stained mossy green wool cloak, distant lighthouse silhouette and stormy sea behind",
    "iguana_don":                "saurian iguana mafia don with prominent dewlap and back spines, fine pinstripe vest, cigar smoke",
    "roy_demonitor":             "saurian monitor-lizard mobster with sharp snout and dark scales, suit collar",
    "andrew_tuatara":            "an anthropomorphic crocodile-man pimp, long armored crocodile snout with bumpy ridges and rows of jagged teeth peeking out, slit yellow eyes, leathery green-brown hide with dark tubercles down the brow, wearing a flashy purple velvet pimp suit with wide-collared lapels, a wide-brim feathered fedora pulled low, thick gold chains around his neck, gold-ringed fingers, holding an ornate gold-tipped cane, dim moody backstreet behind",
    "gordon_gecko":              "saurian gecko merchant with wide pad-fingers and shrewd grin, slicked-back style, gold rings (Wall Street allusion)",
    "dusk":                      "saurian skink rogue with darting dark eyes and shadowy hood",
    "chameleon_paglia":          "saurian chameleon assassin, eyes pointing different directions, mottled green-purple scales fading to invisibility",
    "siren":                     "an aquatic mermaid woman with a smooth bare forehead and long wet seaweed-tangled dark hair flowing around her face, iridescent blue-green fish scales running across her temples, cheekbones and shoulders, webbed pointed ears, gill slits along the sides of her neck, hypnotic luminous teal eyes with reflective pupils, surrounded by drifting underwater bubbles in a moonlit kelp forest",
    "pesto":                     "an anthropomorphic green-brown sea-turtle gangster, smooth scaly turtle head with a hooked beak and small beady eyes, hard ridged turtle shell rising at his shoulders, wearing a tightly-buttoned black-and-white pinstripe vest over a white shirt, a black fedora tilted low casting shadow over his eyes, a cigar clamped between his teeth with smoke curling up, dimly lit 1920s speakeasy interior behind",
    "tommy":                     "carapacian turtle-folk mafia thug with a flat newsboy cap pulled low, hard-shell shoulders",
    "prosecco":                  "elegant human noblewoman with sparkling jewelry and champagne-blonde hair, decadent gown",
    "boa":                       "saurian aristocrat with smooth serpent-like scales and a regal bearing, rich purple robes",
    "rodney_the_rat":            "small rat-folk in tattered urban clothing with quick darting eyes",
    "joey_feritas":              "a wiry young human pied-piper with neat dark hair, ordinary plain features, a faint half-smile, plain travelling clothes, holding a tin flute in one hand, a small burlap sack at his hip with one rat tail poking out, dim alley behind",
    "orc_warrior":               "a brutish orc trench raider with sickly grey-green diseased skin (jaundiced, mottled, unhealthy — not bright green), wearing a pale beige canvas hood-style Macpherson WWI gas mask covering his entire head: a loose unfitted canvas hood pulled down over the head, two simple solid black round goggle lenses set in the front, a small dark breathing tube valve protruding at the mouth area, two large yellowed upward-curving tusks pushing out from beneath the lower edge of the canvas hood, hand-stitched grey wool WWI tunic and webbing with a few crude iron spikes on the shoulders, holding a homemade trench shovel, distant trench smoke and a low red sun behind",
    "centaur_druid":             "centaur druid with antlers entwined in vines, glaive in hand, forest sunbeams",
    "goatman_druid":             "aristocratic goat-headed druid with curling horns, ritual quarterstaff",
    "half_elf_wanderer":         "a tall semi-divine half-elven wanderer with luminously pale moon-pale skin, sculptural finely-cut features of unearthly beauty, gracefully arched eyebrows, long flowing silvery hair, subtly pointed ears, deep otherworldly eyes, wearing a simple grey traveler's cloak with longsword at hip, pale moonlit mountain horizon behind",
    "carapacian_hermit":         "an ancient anthropomorphic turtle-folk hermit, his head is fully a green-brown scaly turtle head with a hooked beak instead of a mouth, small beady black eyes, leathery scaly skin all over his face and neck, a hard ridged turtle carapace shell rising visibly above his shoulders and back, gnarled scaly clawed hands gripping a wooden quarterstaff, mossy patches on his shell, dim wooded swamp behind",
    "shambling_zombie":          "shambling human zombie with grey rotting flesh, sunken eyes, tattered burial shroud",
    "wild_bear":                 "massive graveyard bear with matted fur, half-moon behind, headstones",
    "stray_horse":               "lone stray horse with windblown mane, twilight field behind",
}


def load_json(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


_QUIRKS_CACHE = None


def _quirks():
    global _QUIRKS_CACHE
    if _QUIRKS_CACHE is None:
        if QUIRKS_JSON.exists():
            _QUIRKS_CACHE = load_json(QUIRKS_JSON)
        else:
            _QUIRKS_CACHE = {"appearance": [], "demeanor": []}
    return _QUIRKS_CACHE


def _seeded(char_id, kind):
    h = hashlib.md5(f"{char_id}:{kind}".encode("utf-8")).digest()
    seed = int.from_bytes(h[:8], "big")
    return random.Random(seed)


def pick_quirk(char_id, kind):
    pool = _quirks().get(kind, [])
    if not pool:
        return ""
    return _seeded(char_id, kind).choice(pool)


def quirk_phrase(char_id):
    """Return a string fragment like ', appearance: X, demeanor: Y' or ''."""
    if char_id in SKIP_ALL_QUIRKS:
        return ""
    parts = []
    appearance = pick_quirk(char_id, "appearance")
    if appearance:
        parts.append(f"appearance quirk: {appearance}")
    if char_id not in SKIP_DEMEANOR_QUIRK:
        demeanor = pick_quirk(char_id, "demeanor")
        if demeanor:
            parts.append(f"demeanor: {demeanor}")
    if not parts:
        return ""
    return ". " + "; ".join(parts)


def index_by_id(items, id_key="id"):
    return {item[id_key]: item for item in items if id_key in item}


def race_description(races_index, race_id):
    if not race_id:
        return RACE_FLAVOR_FALLBACK.get("from_faction", "humanoid")
    if race_id in races_index:
        entry = races_index[race_id]
        # Prefer the lore description if present, else fall back to compact map.
        if "description" in entry and entry["description"]:
            short = RACE_FLAVOR_FALLBACK.get(race_id, race_id.replace("_", " "))
            return short
    return RACE_FLAVOR_FALLBACK.get(race_id, race_id.replace("_", " "))


def faction_description(faction_id):
    return FACTION_FLAVOR.get(faction_id, FACTION_FLAVOR["neutral"])


def trait_phrase(traits):
    if not traits:
        return ""
    parts = [k.replace("_", " ").lower() for k in traits.keys()]
    return f"traits: {', '.join(parts)}"


def ability_phrase(abilities):
    if not abilities:
        return ""
    pretty = [a.replace("_", " ") for a in abilities]
    return f"signature abilities: {', '.join(pretty)}"


def build_prompt(char, races_index, use_reference=False, style_key="current"):
    name = char.get("name", char["id"])
    race_id = char.get("race", "")
    gender = char.get("gender", "")
    traits = trait_phrase(char.get("extra_traits", {}))
    abilities = ability_phrase(char.get("extra_abilities", []))
    name_flavor = NAME_FLAVOR.get(char["id"], "")
    framing = "head-and-shoulders bust portrait, three-quarter view, looking toward the viewer"
    if race_id in ("wolf", "bear", "horse"):
        framing = "head-and-shoulders animal portrait, three-quarter view, intense gaze"

    if use_reference:
        style_block = (
            "Render this in the exact art style of the attached reference image: "
            "moody painterly illustrated bust portrait, halftone grain texture, "
            "heavy ink hatching mixed with painted color washes, limited muted "
            "palette of deep purples, dusky blues, ochres and blacks, atmospheric "
            "background hint."
        )
    else:
        style_block = STYLE_BLOCKS.get(style_key, JACANA_STYLE)

    # Build the subject sentence. When a hand-written NAME_FLAVOR exists we
    # trust it as a complete description and skip the auto-generated race/
    # faction strings (they sometimes contradict the named character — e.g.
    # the Siren whose tortellini-faction blurb leaked turtle-mafia language).
    subject_parts = [f"Subject of the painting: {name}"]
    if name_flavor:
        subject_parts.append(f"— {name_flavor}.")
    else:
        race_desc = race_description(races_index, race_id)
        faction_desc = faction_description(char.get("faction", "neutral"))
        bg = char.get("background", "")
        bg_phrase = f", background of {bg.replace('_', ' ')}" if bg and bg != "from_faction" else ""
        gender_phrase = f" ({gender})" if gender else ""
        subject_parts.append(f", a {race_desc}{gender_phrase}, {faction_desc}{bg_phrase}.")
    if traits:
        subject_parts.append(traits + ".")
    if abilities:
        subject_parts.append(abilities + ".")
    quirks = quirk_phrase(char["id"])
    if quirks:
        # quirk_phrase returns a fragment beginning with ". "; strip the dot.
        subject_parts.append(quirks.lstrip(". ") + ".")
    subject_parts.append(framing + ".")

    # Subject first, style block last — the model locks onto identity before
    # being primed by the fantasy-art descriptors.
    return " ".join(subject_parts) + " " + style_block


def select_targets(characters, only_ids):
    targets = []
    for c in characters:
        cid = c["id"]
        if cid in SKIP_IDS:
            continue
        if only_ids and cid not in only_ids:
            continue
        targets.append(c)
    return targets


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
    """Call an Imagen model (text-to-image only) and return the first image's bytes."""
    from google.genai import types  # type: ignore

    response = client.models.generate_images(
        model=model,
        prompt=prompt,
        config=types.GenerateImagesConfig(
            number_of_images=1,
            aspect_ratio="1:1",
        ),
    )
    for gen in response.generated_images or []:
        img = gen.image
        if img and img.image_bytes:
            return img.image_bytes
    raise RuntimeError("No image returned by Imagen.")


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


def generate_image(client, model, prompt, reference_bytes):
    if is_imagen(model):
        return call_imagen(client, model, prompt)
    return call_gemini_image(client, model, prompt, reference_bytes)


def downscale_to_token(image_bytes, size=OUTPUT_SIZE):
    from PIL import Image
    img = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    img = img.resize((size, size), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


_RING_OVERLAY_CACHE = {}


def _build_ring_overlay(size):
    """Build a clean procedural tan ring overlay at the requested size, with
    anti-aliased inner and outer edges. No dark hairline — the artwork meets
    the tan directly, matching Jacana's actual look closely without the
    overly-prominent black band the earlier hairline created."""
    from PIL import Image, ImageDraw, ImageFilter
    import random
    if size in _RING_OVERLAY_CACHE:
        return _RING_OVERLAY_CACHE[size]
    cx = cy = size / 2.0
    scale = size / 256.0
    r_outer = FRAME_OUTER_R * scale
    r_tan_in = FRAME_INNER_TAN_R * scale

    # Render at 4x then downsample for smooth anti-aliasing.
    ss = 4
    big = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    bd = ImageDraw.Draw(big)
    bcx = cx * ss
    bcy = cy * ss
    R_out = r_outer * ss
    R_tan = r_tan_in * ss
    # Tan disc to outer radius, then carve out the artwork interior.
    bd.ellipse([bcx - R_out, bcy - R_out, bcx + R_out, bcy + R_out],
               fill=RING_TAN_COLOR + (255,))
    bd.ellipse([bcx - R_tan, bcy - R_tan, bcx + R_tan, bcy + R_tan],
               fill=(0, 0, 0, 0))
    overlay = big.resize((size, size), Image.LANCZOS)
    # Tiny grain noise on the tan ring to mimic painterly halftone, kept very
    # subtle so the ring stays visually clean and identical across icons.
    rnd = random.Random(91234)
    px = overlay.load()
    for y in range(size):
        for x in range(size):
            r2 = (x - cx) ** 2 + (y - cy) ** 2
            if r_tan_in ** 2 <= r2 <= r_outer ** 2:
                pr, pg, pb, pa = px[x, y]
                if pa > 0:
                    n = rnd.randint(-8, 8)
                    px[x, y] = (
                        max(0, min(255, pr + n)),
                        max(0, min(255, pg + n)),
                        max(0, min(255, pb + n)),
                        pa,
                    )
    _RING_OVERLAY_CACHE[size] = overlay
    return overlay


def apply_jacana_frame(image_bytes, size=OUTPUT_SIZE):
    """Composite the painted artwork inside the Jacana-style frame. The
    artwork is masked to a disc whose radius extends well INTO the ring zone
    (so any model-drawn frame edge is hidden under the procedural ring), and
    the procedural tan ring is composited on top."""
    from PIL import Image, ImageDraw, ImageFilter
    cx = cy = size // 2
    scale = size / 256.0
    # Artwork covers the full visible token area; the ring covers the outer
    # part. There is intentionally no gap.
    art_disc = round(FRAME_OUTER_R * scale)
    art = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    if art.size != (size, size):
        art = art.resize((size, size), Image.LANCZOS)
    art_mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(art_mask)
    d.ellipse([cx - art_disc, cy - art_disc, cx + art_disc, cy + art_disc], fill=255)
    if FRAME_FEATHER > 0:
        art_mask = art_mask.filter(ImageFilter.GaussianBlur(FRAME_FEATHER))
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    base.paste(art, (0, 0), art_mask)
    base = Image.alpha_composite(base, _build_ring_overlay(size))
    out = io.BytesIO()
    base.save(out, format="PNG")
    return out.getvalue()


def reframe_existing(path, size=OUTPUT_SIZE):
    """Apply the Jacana frame to an already-saved icon in place."""
    raw = Path(path).read_bytes()
    Path(path).write_bytes(apply_jacana_frame(raw, size))


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--only", help="Comma-separated character ids to (re)generate")
    p.add_argument("--overwrite", action="store_true", help="Re-generate even if file exists")
    p.add_argument("--dry-run", action="store_true", help="Print prompts; do not call API")
    p.add_argument("--list", action="store_true", help="List target ids and exit")
    p.add_argument("--sleep", type=float, default=2.0, help="Seconds between API calls")
    p.add_argument(
        "--model", default=DEFAULT_MODEL,
        help=(f"Image model id. Default {DEFAULT_MODEL}. "
              "Imagen models are text-only (style baked into prompt). "
              "gemini-2.5-flash-image accepts the Jacana png as a reference image."),
    )
    p.add_argument(
        "--reframe-existing", action="store_true",
        help="Skip API calls; just composite Jacana's frame onto already-saved icons.",
    )
    p.add_argument(
        "--style-block", choices=list(STYLE_BLOCKS.keys()), default="current",
        help="Which style-block prompt to bake in. 'current' = the dim/moody "
             "block; 'patrician' = the looser block used when Patrician Knight "
             "was generated (allows slightly brighter, busier results).",
    )
    return p.parse_args()


def main():
    args = parse_args()
    only_ids = set(args.only.split(",")) if args.only else None
    model = args.model
    using_reference = not is_imagen(model)

    chars_data = load_json(CHARACTERS_JSON)
    characters = chars_data["characters"]
    races_index = index_by_id(load_json(RACES_JSON).get("races", []))

    targets = select_targets(characters, only_ids)
    if args.list:
        for c in targets:
            print(c["id"])
        return

    if args.reframe_existing:
        print(f"Reframing {len(targets)} existing icons (no API calls).")
        reframed = 0
        for c in targets:
            p_ = ICONS_DIR / f"{c['id']}_icon.png"
            if not p_.exists():
                print(f"  skip {c['id']} (no file)")
                continue
            reframe_existing(p_, OUTPUT_SIZE)
            print(f"  reframed: {p_.relative_to(ROOT)}")
            reframed += 1
        print(f"Done. Reframed {reframed} icons.")
        return

    print(f"Model: {model} ({'with reference image' if using_reference else 'text-only'})")
    print(f"Targeting {len(targets)} characters.")
    if not args.dry_run:
        reference_bytes = None
        if using_reference:
            if not REFERENCE_ICON.exists():
                sys.exit(f"ERROR: reference icon missing at {REFERENCE_ICON}")
            reference_bytes = REFERENCE_ICON.read_bytes()
        client = init_client()
    else:
        reference_bytes = None
        client = None

    ICONS_DIR.mkdir(parents=True, exist_ok=True)

    failures = []
    for i, char in enumerate(targets, 1):
        cid = char["id"]
        out_path = ICONS_DIR / f"{cid}_icon.png"
        if out_path.exists() and not args.overwrite:
            print(f"[{i}/{len(targets)}] {cid}: exists, skip")
            continue

        prompt = build_prompt(char, races_index, use_reference=using_reference, style_key=args.style_block)
        print(f"\n[{i}/{len(targets)}] {cid}")
        print(f"  prompt: {prompt}")
        if args.dry_run:
            continue

        try:
            raw = generate_image(client, model, prompt, reference_bytes)
            png = downscale_to_token(raw, OUTPUT_SIZE)
            png = apply_jacana_frame(png, OUTPUT_SIZE)
            out_path.write_bytes(png)
            print(f"  saved: {out_path.relative_to(ROOT)}")
        except Exception as e:
            print(f"  FAILED: {e}")
            failures.append((cid, str(e)))

        if args.sleep > 0 and i < len(targets):
            time.sleep(args.sleep)

    print(f"\nDone. Generated/updated {len(targets) - len(failures)} icons; {len(failures)} failures.")
    if failures:
        for cid, err in failures:
            print(f"  - {cid}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
