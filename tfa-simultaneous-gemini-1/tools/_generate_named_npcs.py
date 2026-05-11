"""Generate portraits for the new batch of named NPCs (no JSON integration yet).

Each entry maps an id (file slug) to a complete subject description. We
prepend the standard subject framing and append the chosen style block, then
run through the same generate_image / apply_jacana_frame pipeline used by
generate_character_icons.py. Outputs go to Icons/{id}_icon.png.

Usage:
    python tools/_generate_named_npcs.py [--model MODEL] [--style-block KEY]
                                          [--only id1,id2,...] [--overwrite]
                                          [--dry-run] [--list]
"""
import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from generate_character_icons import (
    generate_image, init_client, apply_jacana_frame, downscale_to_token,
    STYLE_BLOCKS, OUTPUT_SIZE, ICONS_DIR, is_imagen, REFERENCE_ICON
)

DEFAULT_MODEL = "imagen-4.0-ultra-generate-001"
DEFAULT_STYLE = "patrician"

# id -> (display name, full subject description without framing)
NPCS = {
    "reverend_mother_liana": (
        "Reverend Mother Liana",
        "a plump rosy-cheeked elderly half-snake half-human priestess in her late prime, "
        "pale skin, white hair tied in a neat bun, ONE orange snake-slit pupil eye and "
        "ONE normal human eye, dressed in fine white robes embroidered with vine-like "
        "patterns of gold thread dotted with yellow glass beads, ascetic candlelit "
        "temple interior behind"
    ),
    "mother_inferior_macaria": (
        "Mother Inferior Macaria",
        "a stern human cultist priestess in dark robes, her face covered in small "
        "peck-mark scars arranged in patterns of angelic heads, severe eyes, hair tied "
        "back tightly, dim candlelit chapel behind"
    ),
    "pit_monitor": (
        "Pit Monitor",
        "a wiry weather-beaten saurian monitor-lizard houndmaster, scaly grey-brown "
        "hide, sharp lizard snout, slit yellow eyes, scarred leather coat with hound "
        "leashes coiled at his belt, a small bronze sun-medallion of Mithras hidden "
        "under his collar, dim torchlit baiting-pit behind"
    ),
    "alewife_juturna": (
        "Alewife Juturna",
        "a half-saurian half-human woman in her thirties, mottled greenish skin patches "
        "across face and arms over otherwise human features, slit-pupil reptilian eyes, "
        "wild tangled hair, faint smile of intoxicated bliss with hints of glossolalia, "
        "wearing a stained linen apron over a rough dress, holding a clay tankard, dim "
        "smoky dock-bar behind"
    ),
    "mary_guana": (
        "Mary Guana",
        "a saurian iguana woman drug dealer, prominent green-brown iguana scales across "
        "face, hooked dewlap under her chin, slit yellow eyes, a small leather pouch of "
        "dried mushrooms in her clawed hand, sly half-smile, dim alley behind"
    ),
    "hunter_john": (
        "Hunter John",
        "a massive hulking human butcher and hunter, broad shoulders, thick beard, blood-"
        "stained leather apron over coarse linen shirt, holding a heavy cleaver, slabs "
        "of meat and animal skulls in a dim shop behind"
    ),
    "centurion_marcus": (
        "Centurion Marcus",
        "a paranoid human guardsman in dented Golden-Legion plate armor, sleepless "
        "shadowed eyes constantly darting, salt-and-pepper stubble, peeking nervously "
        "over the half-shut door of a barricaded hut behind"
    ),
    "deputy_gleg": (
        "Deputy Gleg",
        "an extremely earnest gung-ho young human deputy in a slightly-too-large iron "
        "kettle helm and a brass-buttoned watch coat, a bright eager grin, holding a "
        "polished cudgel proudly, sunny town square behind"
    ),
    "hedge_witch_magda": (
        "Hedge-Witch Magda",
        "a stout middle-aged human hedge-witch with grey-streaked dark hair under a "
        "linen kerchief, knowing narrow eyes, holding a small bundle of dried herbs, "
        "wearing a woollen shawl and apron with herb-stained pockets, dim warm cottage "
        "interior behind with hanging plants"
    ),
    "lot_lizard_zillah": (
        "Lot Lizard Zillah",
        "a sweet bubbly young saurian lizard woman of eighteen, cheerful upbeat smile "
        "showing missing teeth and signs of tooth decay, soft greenish scales across "
        "face, big trusting eyes, simple river-side dress, golden coins and small gifts "
        "in her hands, distant docks and singing pose behind"
    ),
    "skipper_alligator_capone": (
        "Skipper Alligator Capone",
        "an anthropomorphic alligator riverboat skipper, long armored alligator snout "
        "with rows of jagged teeth peeking out, slit reptile eyes, wearing a tattered "
        "naval cap and a worn striped sweater, gripping a wooden tiller, foggy swampy "
        "river behind"
    ),
    "slavecatcher_cletus": (
        "Slavecatcher Cletus",
        "a mean-looking human peasant slavecatcher, lean weathered face with cruel narrow "
        "eyes, tobacco-stained crooked teeth, greasy unkempt hair under a wide-brim "
        "leather hat, wearing rough hide and rope coils across his chest, dim dock "
        "shadow behind"
    ),
    "austache_jongle": (
        "Austache Jongle",
        "an awkward pudgy human man in his early thirties with misty pale-blue eyes "
        "and unkempt blonde hair and beard, wearing a ridiculous harlequin patchwork "
        "coat of mismatched coloured cloth, slightly trembling shaky hands, mid-whoop "
        "with mouth open, rural village square behind"
    ),
    "obediah": (
        "Obediah",
        "a bleary aging human swamp-shanty drunkard in his late sixties, wispy grey "
        "hair, ruddy nose, stained linen tunic with shirt half-untucked, holding a mug "
        "of cheap ale, easy gap-toothed grin, dim swamp-stilted shanty interior behind"
    ),
    "jezebel": (
        "Jezebel",
        "a young human woman in her early twenties, dark hair loose around her "
        "shoulders, bored seductive eyes, simple coarse linen dress with the laces "
        "loosened, dim swamp-cabin interior with a sleeping figure in the background"
    ),
    "mostlemyre_drouge": (
        "Mostlemyre Drouge",
        "a fat human magician in his late fifties, shaven head, pudgy clammy hands "
        "clad with bejewelled rings (one a glowing red ruby), wearing purple silk "
        "robes with an octagonal orange skullcap and a curious pair of thick prismatic-"
        "lensed spectacles, smiling enigmatically, dim study with arcane tomes behind"
    ),
    "smith_darcy": (
        "Smith Darcy",
        "a young scrawny human teenage blacksmith of fifteen, soot-smudged face, "
        "uncertain hesitant expression, ill-fitting leather apron over a thin shirt, "
        "holding a clumsy half-finished iron blade with tongs, dim cluttered smithy "
        "with cold forge behind"
    ),
    "professor_circino": (
        "Professor Circino",
        "an austere middle-aged human university professor, neatly trimmed grey beard, "
        "spectacles, wearing dark scholar's robes with a black mortarboard cap, holding "
        "an open leather-bound book, dim wood-panelled university library behind"
    ),
    "professor_easton": (
        "Professor Easton",
        "a thin-faced elderly human university professor with thinning white hair and "
        "a sharp inquisitive gaze, wearing dark scholar's robes with a black "
        "mortarboard cap, ink-stained fingers, holding a quill, dim wood-panelled "
        "university study with star-charts behind"
    ),
    "zakariah": (
        "Zakariah",
        "a serious young human university student, dark hair, intense focused eyes, "
        "wearing a plain scholar's robe over linen shirt, clutching a leather-bound "
        "book to his chest, dim university hall behind"
    ),
    "elder_roa": (
        "Roa",
        "an elderly weathered human fisherman in his late seventies, deeply lined face, "
        "wispy white hair, salt-stained wool cloak and oilskin hat, holding a fishing "
        "rod, dim misty riverbank behind"
    ),
    "sarah": (
        "Sarah",
        "an elderly thin human woman in her late seventies, white hair tied back in a "
        "tight bun, pursed lips, wearing a plain dark dress and apron, holding an "
        "intricate string-doily she has crocheted, dim immaculate cottage interior "
        "covered in doilies behind"
    ),
    "atticus": (
        "Atticus",
        "a burly middle-aged human laborer with broad shoulders and thick forearms, "
        "rugged stubbled face, wearing a coarse linen shirt with rolled sleeves, "
        "holding an axe across his chest, dim grassy hilltop cottage behind"
    ),
    "roa_jr": (
        "Roa Jr.",
        "a burly middle-aged human laborer with thick beard and squinting eyes, broad "
        "chest, wearing a coarse linen shirt and leather suspenders, holding a heavy "
        "wooden club, dim grassy hilltop cottage behind"
    ),
    "cain": (
        "Cain",
        "a hulking burly human-bodied figure with the FACE OF A LEECH — a smooth pale "
        "fleshy round-mouthed leech head with concentric circles of small needle teeth "
        "where a face should be, no eyes, wearing tattered linen rags, hunched in dim "
        "shadow under wooden floorboards"
    ),
    "saul_laelia": (
        "Saul Laelia",
        "a young friendly human polygamist with a clean shaven bald head, simple woollen "
        "robe over a linen tunic, kind earnest eyes, broad warm smile, dim hayloft home "
        "interior with three women silhouettes behind him"
    ),
    "saul_wife_mary": (
        "Mary (wife of Saul)",
        "a quiet young human woman with long dark hair tied back, soft features, plain "
        "linen dress, modest demeanor, dim hayloft interior with cooking stove behind"
    ),
    "saul_wife_delilah": (
        "Delilah (wife of Saul)",
        "a quiet young human woman with auburn hair in a loose braid, gentle eyes, "
        "plain linen dress, modest demeanor, dim hayloft interior with straw mattresses "
        "behind"
    ),
    "saul_wife_irene": (
        "Irene (wife of Saul)",
        "a quiet young human woman with blonde hair tied in a kerchief, soft round "
        "face, plain linen dress, modest demeanor, dim hayloft interior with a hanging "
        "lantern behind"
    ),
    "big_al_samson": (
        "Big Al Samson",
        "a giant of a human man, six and a half feet tall and 320 pounds, heavy-set "
        "frame with a thick gut, sun-browned weather-beaten face with a heart-as-pitch "
        "scowl, wearing dyed-black canvas overalls and a tattered straw hat, holding a "
        "harpoon, glassy half-stoned eyes, dim swampy fishing shack behind"
    ),
    "peggy_samson": (
        "Peggy Samson",
        "a tragic afflicted figure cursed by an infectious disease, with a smooth "
        "bald scalp and the MOUTH OF A SPIDER where her mouth should be — eight "
        "small chitinous fanged mandibles arranged in a circle around the mouth "
        "opening — sad haunted eyes, wearing simple tattered linen rags, dim "
        "shabby cottage interior behind"
    ),
    "sally_samson": (
        "Sally Samson",
        "a skittish teenage human girl with stringy dark hair, an unsettling vacant "
        "DEAD STARE in her unblinking eyes, plain linen dress, standing very still, "
        "dim shabby cottage interior behind, eerie"
    ),
    # (Pit Monitor's hounds — Julius, Augustus, Octavius, Cleopatra, Philbert —
    # do not need individual portraits per user instruction.)
}


framing = (
    "head-and-shoulders bust portrait, three-quarter view, looking toward the viewer."
)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--style-block", choices=list(STYLE_BLOCKS.keys()), default=DEFAULT_STYLE)
    p.add_argument("--only", help="Comma-separated ids to (re)generate")
    p.add_argument("--overwrite", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--list", action="store_true")
    p.add_argument("--sleep", type=float, default=2.0)
    return p.parse_args()


def main():
    args = parse_args()
    only = set(args.only.split(",")) if args.only else None
    style = STYLE_BLOCKS[args.style_block]

    targets = [
        (cid, name, desc)
        for cid, (name, desc) in NPCS.items()
        if only is None or cid in only
    ]

    if args.list:
        for cid, _name, _ in targets:
            print(cid)
        return

    print(f"Model: {args.model}; style: {args.style_block}; targets: {len(targets)}")

    if not args.dry_run:
        client = init_client()
        reference_bytes = REFERENCE_ICON.read_bytes() if not is_imagen(args.model) else None
    else:
        client = None
        reference_bytes = None

    ICONS_DIR.mkdir(parents=True, exist_ok=True)
    failures = []
    for i, (cid, name, desc) in enumerate(targets, 1):
        out_path = ICONS_DIR / f"{cid}_icon.png"
        if out_path.exists() and not args.overwrite:
            print(f"[{i}/{len(targets)}] {cid}: exists, skip")
            continue

        prompt = (
            f"Subject of the painting: {name} — {desc}. "
            f"{framing} {style}"
        )
        print(f"\n[{i}/{len(targets)}] {cid}")
        if args.dry_run:
            print(f"  prompt: {prompt[:200]}...")
            continue
        try:
            raw = generate_image(client, args.model, prompt, reference_bytes)
            png = downscale_to_token(raw, OUTPUT_SIZE)
            png = apply_jacana_frame(png, OUTPUT_SIZE)
            out_path.write_bytes(png)
            print(f"  saved: {out_path.relative_to(ICONS_DIR.parent)}")
        except Exception as e:
            print(f"  FAILED: {e}")
            failures.append((cid, str(e)))
        if args.sleep > 0 and i < len(targets):
            time.sleep(args.sleep)

    print(f"\nDone. {len(targets) - len(failures)} succeeded, {len(failures)} failed.")
    if failures:
        for cid, err in failures:
            print(f"  - {cid}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
