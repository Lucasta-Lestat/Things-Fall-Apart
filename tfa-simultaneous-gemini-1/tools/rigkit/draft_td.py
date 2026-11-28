"""Auto-draft a gen_plan race spec (tools/rigkit/races_td/<race>.json) from the race's legacy pack.

    python -m tools.rigkit.draft_td [race ...] [--force] [--no-tune]

ONE-TIME BOOTSTRAP. A spec that exists is left alone unless --force is given, and --force throws a
painter's edits away: after the first draft, edit the JSON by hand (races_td/README.md).

What is measured from Rigs/races/<race>/default (frames in race.json, labels.png, body.png):

  shoulders   shoulder_half = torso half-width / half span + 0.015 (the guide's deltoid is cut back to
              the armpit at install), kept inside 0.24-0.36: on packs whose hair hides the shoulders
              the legacy seam is a label artefact.
  arm joints  elbow_x, wrist_x: the legacy seams, pulled toward the approved orc proxy
              (+0.05 / +0.03) and kept inside 0.53-0.59 / 0.76-0.81. Legacy hands are 26 % of the
              half span, the approved orc's are 17 %.
  limbs       upper-arm, forearm, palm and foot widths from the frames' across-scales.
  trunk       depths are NOT taken from the legacy painting (its camera is the thing being replaced):
              they scale with the arm thickness between the human and the orc proxies.
  head        HEAD-SIZE RULE. derive.py's head frame is the largest circle inside face + hair, so on a
              haired pack it is a circle on the HAIR MASS. The guide matches that same circle to the
              legacy pack's (head_scale, solved by rendering), so a helmet has exactly the world size
              it has today. The skull under the hair is smaller: the hair is a cap `cap.thick` times
              the skull's radius, thick = legacy head ratio / the family's skull ratio (bald packs:
              thick 1, the circle is the skull).
  colours     skin and hair: mid-tone means of the legacy painting under the body / hair labels.
  swatch      a box on the cleaner upper arm (never face or whole body); fur and scales show in it.

What is written by hand below (FAMILIES / PACKS): the features the proxy must carry, the look sentence
and the prompt words, from what each legacy painting shows.

After drafting, each spec is tuned by rendering: head_scale until the head frame matches the legacy
pack, then the head pivot until the core depth / span is inside the band; a head the band cannot hold
gets its own "depth_band" with the reason in "notes".
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

from . import core, gen_plan
from .derive import derive_frames, label_masks
from .install_plan import measures

SKULL_U = 0.108           # every drafted race is built on the orc's skull radius; head_scale sizes it


def clamp(v, lo, hi):
    return float(min(max(v, lo), hi))


# ---------------------------------------------------------------- words

HUMAN_FACE = ("the fringe of the hair, right under it the brow shading the eye sockets into two dark slits, "
              "then the bridge and tip of the nose, and just behind the nose the lips and the front of the chin. "
              "Brow, nose tip and chin sit close together, squeezed by the steep view, and the chin is the bottom "
              "edge of the head, with the chest starting directly below it.")
BALD_FACE = ("a brow ridge whose overhang shades the eye sockets into two dark slits, right under it the tip of "
             "the nose, and just behind the nose the lips and the front of the jaw. Brow, nose tip and jaw sit "
             "close together, squeezed by the steep view, and the jaw is the bottom edge of the head, with the "
             "chest starting directly below it.")
TUSK_FACE = ("a heavy brow ridge whose overhang shades the eye sockets into two dark slits, right under it the "
             "broad tip of the nose, and just behind the nose the front of the jaw with one small ivory tusk "
             "rising from each corner of the lower lip. Brow, nose tip and tusks sit close together, squeezed "
             "by the steep view, and the tusks and lower lip are the bottom edge of the head, with the chest "
             "starting directly below them.")
SNOUT_FACE = ("a brow ridge that shades the eyes into two dark slits, and in front of it %s that juts forward to "
              "%s. Brow and snout sit close together, squeezed by the steep view, and the tip of the snout is "
              "the bottom edge of the head, with the chest starting directly below it.")
EARS = " A %s ear sticks out sideways from each side of the head."

TORSO = {
    "muscular": ("first the top plane of the broad chest with its two pectoral muscles meeting at the breastbone, "
                 "then, tucked under the chest, a short glimpse of the upper belly.",
                 "the torso as one broad chest with two full pectoral muscles and a firm upper belly below them"),
    "athletic": ("first the top plane of the chest with its two pectoral muscles meeting at the breastbone, then, "
                 "tucked under the chest, a short glimpse of the flat upper belly.",
                 "the torso as one athletic chest with two pectoral muscles and a flat upper belly below them"),
    "slim": ("first the top plane of a slim chest, then, tucked under the chest, a short glimpse of the flat upper "
             "belly.",
             "the torso as one slim smooth chest with a flat upper belly below it"),
    "soft": ("first the top plane of the soft chest, then, below the chest, the top of a small round belly.",
             "the torso as one soft chest with a small round belly below it"),
    "stocky": ("first the top plane of a deep barrel chest, then, below the chest, the top of a firm round belly.",
               "the torso as one deep barrel chest with a firm round belly below it"),
}
ARMS = {
    "muscular": None,       # gen_plan's default sentence (the approved orc)
    "athletic": "firm shoulders and collarbones across the shoulder band; level arms with lean, lightly defined muscle",
    "slim": "smooth shoulders and collarbones across the shoulder band; slender level arms with soft, lightly "
            "defined muscle",
    "soft": "soft rounded shoulders across the shoulder band; smooth level arms",
    "stocky": "thick rounded shoulders across the shoulder band; short strong level arms",
}
TEX = {     # texture -> (swatch_of, finish, arms override or None)
    "skin": ("skin", "chalky matte skin", None),
    "fur": ("fur", "matte short fur", "the shoulder band and the level arms covered in short fur that follows the "
                                        "muscles beneath"),
    "scales": ("scaled skin", "matte scaled skin", "the shoulder band and the level arms covered in small "
                                                   "overlapping scales over firm muscle"),
    "feathers": ("feathers", "matte soft feathers", "the shoulder band and the level arms covered in soft layered "
                                                    "feathers"),
    "smooth": ("skin", "matte smooth skin", None),
}
FEET = {
    "claw": ("At the very bottom the front halves of the two feet stand on the floor far below, toes pointing at "
             "the bottom of the picture, each a broad foot front with %s long toes that fan out and end in claws.",
             "each foot front with %s long toes ending in short dark claws"),
    "hoof": ("At the very bottom the fronts of the two cloven hooves stand on the floor far below, pointing at the "
             "bottom of the picture, each hoof two blunt halves side by side.",
             "each hoof as dark horn split into two halves"),
    "paw": ("At the very bottom the front halves of the two paws stand on the floor far below, toes pointing at "
            "the bottom of the picture, each a rounded paw front with %s short round toes side by side.",
            "each paw front with %s short furred toes"),
}
NUM = {2: "two", 3: "three", 4: "four", 5: "five"}


def fam(noun, tex="skin", hue="warm skin", line="dark brown", face=HUMAN_FACE, face_bits="calm brows over shadowed "
        "eyes, a nose tip, closed lips and the front of the chin", skull=0.150, ears=None, ear_len=0.0,
        ear_tilt=None, tusk=0.0, foot=None, hands=None, colours=None, features=None, extra=None):
    """One family's shared words and features. skull: the bare-skull head ratio haired packs are built on."""
    return dict(noun=noun, tex=tex, hue=hue, line=line, face=face, face_bits=face_bits, skull=skull, ears=ears,
                ear_len=ear_len, ear_tilt=ear_tilt, tusk=tusk, foot=foot, hands=hands, colours=colours or {},
                features=features or {}, extra=extra or {})


CLAWS = "each hand with five well-formed fingers that end in short dark claws"
FAMILIES = {
    "aedelf": fam("dark elf", hue="deep violet skin", line="near-black violet", ears="long pointed", ear_len=0.095,
                  ear_tilt=[0.026, 0.045, 0.02]),
    "cerebrals": fam("cerebral", tex="smooth", hue="pale lilac skin", line="dark plum",
                     face="a smooth brow over two large dark almond eyes, a tiny nose and a small narrow chin. "
                          "Eyes, nose and chin sit close together, squeezed by the steep view, and the chin is the "
                          "bottom edge of the head, with the chest starting directly below it.",
                     face_bits="two large dark almond eyes, a tiny nose and a small narrow chin", skull=0.135),
    "dhampir": fam("dhampir", hue="chalk-pale skin", line="dark grey-brown"),
    "draconian": fam("draconian", tex="scales", hue="rust-red scales", line="near-black red-brown",
                     face=SNOUT_FACE % ("a broad scaled snout", "a blunt tip with two nostrils on top"),
                     face_bits="a scaled brow over shadowed eyes and a broad blunt snout with two nostrils",
                     foot=dict(kind="claw", toes=3), hands=CLAWS, colours=dict(horn=[196, 170, 128]),
                     features=dict(snout=dict(len=0.95, r=[0.60, 0.44]),
                                   horns=dict(style="swept", len=1.7, r=[0.20, 0.03],
                                              guide="A straight horn rises from each side of the top of the head "
                                                    "and sweeps backward.",
                                              paint="the two horns as pale ridged horn"))),
    "dwarf": fam("dwarf", hue="ruddy tan skin", line="dark red-brown", skull=0.175),
    "elf": fam("elf", hue="fair skin", line="dark brown", ears="long pointed", ear_len=0.10,
               ear_tilt=[0.026, 0.050, 0.02]),
    "high_elf": fam("high elf", hue="fair skin", line="dark brown", ears="long pointed", ear_len=0.10,
                    ear_tilt=[0.026, 0.050, 0.02]),
    "gnome": fam("gnome", hue="fair cream skin", line="dark red-brown", skull=0.180),
    "goatmen": fam("goat-folk", tex="fur", hue="shaggy brown fur", line="near-black brown",
                   face=SNOUT_FACE % ("a long goat muzzle", "a soft dark nose"),
                   face_bits="a furred brow over shadowed eyes and a long goat muzzle with a dark nose",
                   ears="long drooping goat", ear_len=0.085, ear_tilt=[0.030, -0.01, -0.05],
                   foot=dict(kind="hoof"), colours=dict(horn=[150, 128, 96]),
                   features=dict(snout=dict(len=1.0, r=[0.52, 0.38]),
                                 horns=dict(style="ram", len=3.0, r=[0.30, 0.05],
                                            guide="A thick ridged horn grows from each side of the top of the head "
                                                  "and curls round beside it in a spiral.",
                                            paint="the two horns as ridged curled horn"))),
    "goblin": fam("goblin", hue="muted olive-green skin", line="near-black green", skull=0.20),
    "goluna": fam("goluna", tex="feathers", hue="pale grey-white feathers", line="dark slate-grey",
                  face="a feathered brow over two dark eyes and between them a short hooked beak that points down "
                       "and forward. Brow, eyes and beak sit close together, squeezed by the steep view, and the tip "
                       "of the beak is the bottom edge of the head, with the chest starting directly below it.",
                  face_bits="a feathered brow over two dark eyes and a short hooked grey beak",
                  foot=dict(kind="claw", toes=3), colours=dict(beak=[150, 150, 140], wing=[196, 204, 204]),
                  hands="each hand with five feathered fingers",
                  features=dict(beak=dict(), ruff=dict(kind="ring", count=12, radius=1.0, size=0.26, z=0.0,
                                                       arc=[40, 320]))),
    "grimalkin": fam("grimalkin", tex="fur", hue="sandy-tan fur", line="dark brown",
                     face="a furred brow over two shadowed eyes, a short cat muzzle with a small nose and whisker "
                          "pads, and the chin behind it. Brow, muzzle and chin sit close together, squeezed by the "
                          "steep view, and the muzzle is the bottom edge of the head, with the chest starting "
                          "directly below it.",
                     face_bits="a furred brow over shadowed cat eyes and a short muzzle with a small nose",
                     foot=dict(kind="paw", toes=4), skull=0.19,
                     features=dict(snout=dict(len=0.45, r=[0.50, 0.36]), ears_up=dict())),
    "half_elf": fam("half-elf", hue="fair skin", line="dark brown", ears="small pointed", ear_len=0.055,
                    ear_tilt=[0.024, 0.030, 0.01]),
    "half_orc": fam("half-orc", hue="olive-green skin", line="near-black green", face=TUSK_FACE,
                    face_bits="a scowling brow over shadowed eye slits, a broad nose tip and the front of a heavy "
                              "jaw with its two small tusks", ears="pointed", ear_len=0.055, tusk=0.018,
                    skull=0.150),
    "halfling": fam("halfling", hue="warm peach skin", line="dark red-brown", skull=0.180),
    "human": fam("human", hue="warm skin", line="dark brown"),
    "human_undead": fam("undead", hue="grey-green decaying skin", line="near-black grey-green",
                        face="a bony brow over two deep dark eye sockets, the hollow of the nose and a row of bare "
                             "teeth along the jaw. Brow, nose hollow and teeth sit close together, squeezed by the "
                             "steep view, and the jaw is the bottom edge of the head, with the chest starting "
                             "directly below it.",
                        face_bits="a bony brow over deep dark eye sockets, a hollow nose and a row of bare teeth"),
    "kobold": fam("kobold", tex="scales", hue="tan-orange scales", line="dark brown",
                  face=SNOUT_FACE % ("a narrow scaled snout", "a pointed tip with two nostrils on top"),
                  face_bits="a scaled brow over shadowed eyes and a narrow pointed snout with two nostrils",
                  foot=dict(kind="claw", toes=3), hands=CLAWS, colours=dict(horn=[214, 190, 140]),
                  features=dict(snout=dict(len=1.0, r=[0.50, 0.30]),
                                horns=dict(style="up", len=1.6, r=[0.18, 0.03],
                                           guide="A slender horn rises from each side of the top of the head and "
                                                 "curves backward.",
                                           paint="the two horns as pale smooth horn"))),
    "mephistkin": fam("mephistkin", hue="crimson skin", line="near-black red", colours=dict(horn=[70, 52, 50])),
    "naga": fam("naga", tex="scales", hue="lavender scales", line="dark violet",
                face=SNOUT_FACE % ("a broad flat snake snout", "a rounded tip"),
                face_bits="a smooth scaled brow over two slit eyes and a broad flat snake snout",
                foot=dict(kind="claw", toes=3), hands=CLAWS,
                features=dict(snout=dict(len=0.65, r=[0.62, 0.46]))),
    "newt": fam("newt-folk", tex="smooth", hue="orange-red skin", line="dark red-brown",
                face=SNOUT_FACE % ("a broad rounded salamander snout", "a wide rounded tip"),
                face_bits="two round dark eyes set wide apart on a broad rounded salamander snout",
                foot=dict(kind="claw", toes=4, claw=0.1, spread=0.5),
                hands="each hand with long soft fingers with rounded tips",
                features=dict(snout=dict(len=0.5, r=[0.78, 0.62]))),
    "orc": fam("orc", hue="fresh saturated olive-green skin", line="near-black green", face=TUSK_FACE,
               face_bits="a scowling brow over shadowed eye slits, a broad nose tip and the front of a heavy jaw "
                         "with its two small tusks", ears="pointed", ear_len=0.062, tusk=0.025, skull=0.160),
    "quadrelf": fam("quadrelf", hue="fair skin", line="dark brown", ears="pointed", ear_len=0.06,
                    ear_tilt=[0.024, 0.035, 0.01]),
    "sahuagin": fam("sahuagin", tex="scales", hue="teal scaled skin", line="near-black teal",
                    face=SNOUT_FACE % ("a blunt fish snout", "a wide mouth"),
                    face_bits="a ridged brow over shadowed eyes and a blunt fish snout with a wide mouth",
                    ears="fin-like", ear_len=0.075, ear_tilt=[0.034, 0.03, 0.0],
                    foot=dict(kind="claw", toes=3, spread=0.5, claw=0.3),
                    hands="each hand with five webbed fingers",
                    features=dict(snout=dict(len=0.6, r=[0.62, 0.46]),
                                  crest=dict(count=4, h=0.5, guide="A thin fin stands along the middle of the "
                                             "scalp from front to back.", paint="the head fin as a thin ribbed "
                                             "membrane"),
                                  dorsal_fin=dict())),
    "saurian": fam("saurian", tex="scales", hue="olive-green scaled hide", line="near-black olive",
                   face=SNOUT_FACE % ("a long reptile snout", "a blunt tip with two nostrils on top"),
                   face_bits="a scaled brow over shadowed eyes and a long blunt reptile snout with two nostrils",
                   foot=dict(kind="claw", toes=3), hands=CLAWS,
                   features=dict(snout=dict(len=1.25, r=[0.52, 0.36]))),
    "sobruaro": fam("sobruaro", tex="smooth", hue="deep green ribbed cactus skin", line="near-black green",
                    face="the ribs of the head running down to a plain smooth brow, two small dark eyes and a short "
                         "mouth line. Brow, eyes and mouth sit close together, squeezed by the steep view, and the "
                         "chin is the bottom edge of the head, with the chest starting directly below it.",
                    face_bits="two small dark eyes and a short mouth under the ribs of the head"),
    "vampire": fam("vampire", hue="ashen pale skin", line="dark grey", ears="pointed", ear_len=0.06,
                   ear_tilt=[0.024, 0.035, 0.01]),
}


def hair(desc, cover="hair", **features):
    return dict(dome="cap of " + desc, dome_cover_tilt=cover, features=features)


LONG = dict(hair_long=dict(), locks=dict())
# pack -> (family, sex, build, look, per-pack dict). Per-pack keys: dome / dome_cover_tilt / features /
# cap (dict laid over the drafted cap) / colours / any spec field.
PACKS = {
    "aedelf_female": ("aedelf", "f", "slim", "an aedelf woman, a dark elf with deep violet skin, long flowing "
                      "silver-white hair parted in the middle, long pointed ears and a slender build",
                      hair("long silver-white hair parted in the middle", hair_long=dict(width=1.9), locks=dict())),
    "aedelf_male": ("aedelf", "m", "athletic", "an aedelf man, a dark elf with deep indigo-violet skin, a long "
                    "wild mane of silver-white hair, long pointed ears and a lean muscular build",
                    hair("long wild silver-white hair", hair_long=dict(width=2.2, depth=1.2),
                         hair_bushy=dict(count=9, size=0.36))),
    "cerebrals_female": ("cerebrals", "f", "slim", "a female cerebral, a slight alien humanoid with smooth pale "
                         "lilac skin, a very large bald domed cranium, large dark almond eyes and thin limbs",
                         dict(dome="very large smooth bald cranium", cap=dict(label="face", tall=0.85))),
    "cerebrals_male": ("cerebrals", "m", "slim", "a male cerebral, a slight alien humanoid with smooth pale lilac "
                       "skin, a very large bald domed cranium, large dark almond eyes and very thin limbs",
                       dict(dome="very large smooth bald cranium", cap=dict(label="face", tall=0.85))),
    "dhampir_female": ("dhampir", "f", "slim", "a dhampir woman with chalk-pale skin, long straight black hair and "
                       "a slim build", hair("long straight black hair", hair_long=dict(width=1.9))),
    "dhampir_male": ("dhampir", "m", "muscular", "a dhampir man with chalk-pale skin, short swept-back black hair "
                     "and a lean muscular build", hair("short swept-back black hair")),
    "draconian_female": ("draconian", "f", "muscular", "a female draconian, a dragon-folk with orange-red scales, a "
                         "horned reptile head with a broad blunt snout, and a heavy muscular build",
                         dict(dome="scaled top of the skull", dome_cover_tilt="skull")),
    "draconian_male": ("draconian", "m", "muscular", "a male draconian, a dragon-folk with dark rust-red scales, a "
                       "horned reptile head with a broad blunt snout, and a heavy muscular build",
                       dict(dome="scaled top of the skull", dome_cover_tilt="skull")),
    "dwarf_female": ("dwarf", "f", "stocky", "a dwarf woman with ruddy tan skin, thick ginger-brown hair in heavy "
                     "braids, and a broad stocky build",
                     hair("thick braided ginger-brown hair",
                          locks=dict(r=[0.34, 0.24], len=1.4, guide="A thick braid hangs forward over each "
                                     "collarbone beside the face.", paint="each braid as a thick plaited rope of "
                                     "hair"))),
    "dwarf_male": ("dwarf", "m", "stocky", "a dwarf man with ruddy tan skin, braided ginger-brown hair, a big "
                   "braided ginger-brown beard and a broad stocky muscular build",
                   hair("braided ginger-brown hair", beard=dict(len=1.25, width=0.95,
                        guide="Below the nose a big beard hangs over the top of the chest.",
                        paint="the beard as thick braided ginger-brown hair"))),
    "elf": ("elf", "m", "slim", "an elf man with fair skin, short tousled golden-blond hair, long pointed ears and "
            "a slim build", hair("short tousled golden-blond hair", hair_bushy=dict(count=9, size=0.30))),
    "gnome_female": ("gnome", "f", "soft", "a mushroom gnome woman with pale cream skin, a small plump body and, in "
                     "place of hair, a wide red toadstool cap with white spots",
                     dict(dome="wide round red toadstool cap with white spots", dome_cover_tilt="toadstool cap",
                          cap=dict(colour="cap", tall=0.7), colours=dict(cap=[176, 44, 36]))),
    "gnome_male": ("gnome", "m", "stocky", "a gnome man with fair skin, a tall pointed red felt cap, a white beard "
                   "and a small sturdy body",
                   dict(dome="tall pointed red felt cap", dome_cover_tilt="cap", cap=dict(colour="hat"),
                        colours=dict(hat=[176, 44, 36], beard=[226, 226, 226]),
                        features=dict(hat_cone=dict(), beard=dict(colour="beard", len=0.9,
                                      paint="the beard as soft white hair")))),
    "goatmen_female": ("goatmen", "f", "athletic", "a female goat-folk with shaggy brown fur, a goat head with a "
                       "long muzzle, two curled ridged horns and long drooping ears",
                       dict(dome="furred top of the skull", dome_cover_tilt="skull",
                            features=dict(horns=dict(len=2.2, r=[0.24, 0.04], curl=170)))),
    "goatmen_male": ("goatmen", "m", "muscular", "a male goat-folk with shaggy brown fur, a goat head with a long "
                     "muzzle, two massive spiral ram horns, long drooping ears and a heavy build",
                     dict(dome="furred top of the skull", dome_cover_tilt="skull",
                          features=dict(horns=dict(len=3.6, r=[0.36, 0.06])))),
    "goblin_male": ("goblin", "m", None, None, {}),
    "goblin_female": ("goblin", "f", None, "a female goblin with olive-green skin, a big bald head, very large "
                      "pointed ears, a long pointed nose and a small wiry body with thin sinewy arms", {}),
    "goluna_female": ("goluna", "f", "athletic", "a female goluna, an owl-like bird-folk covered in pale grey-white "
                      "feathers, with a round feathered head, a short hooked beak and feathered arms",
                      dict(dome="round feathered top of the head", dome_cover_tilt="head")),
    "goluna_male": ("goluna", "m", "muscular", "a male goluna, an owl-like bird-folk covered in pale grey-white "
                    "feathers, with a round feathered head, a short hooked beak, feathered arms, a broad build and "
                    "two folded wings on its back",
                    dict(dome="round feathered top of the head", dome_cover_tilt="head", features=dict(wings=dict()))),
    "grimalkin_female": ("grimalkin", "f", "slim", "a female grimalkin, a cat-folk with short sandy-tan fur, a cat "
                         "head with very large upright ears, and a slim build",
                         dict(dome="furred top of the skull", dome_cover_tilt="skull",
                              features=dict(ears_up=dict(len=1.7, r=[0.60, 0.05])))),
    "grimalkin_male": ("grimalkin", "m", "athletic", "a male grimalkin, a cat-folk with golden-tan spotted fur, a "
                       "shaggy blond mane, large upright ears and an athletic build",
                       hair("shaggy blond mane", cover="mane", hair_bushy=dict(count=11, size=0.42),
                            ears_up=dict(len=1.5, r=[0.55, 0.05]))),
    "half_elf_female": ("half_elf", "f", "slim", "a half-elf woman with fair skin, long wavy strawberry-blonde hair, "
                        "small pointed ears and a slim build", hair("long wavy strawberry-blonde hair", **LONG)),
    "half_elf_male": ("half_elf", "m", "athletic", "a half-elf man with light tan skin, dark brown hair tied in a "
                      "topknot, small pointed ears and an athletic build",
                      hair("dark brown hair pulled back into a topknot", bun=dict(at=[0.0, -0.35, 1.25], size=0.42))),
    "half_orc_female": ("half_orc", "f", "athletic", "a half-orc woman with olive-green skin, a thick mane of dark "
                        "brown hair, pointed ears, two small lower tusks and a strong build",
                        hair("thick dark brown hair", hair_bushy=dict())),
    "half_orc_male": ("half_orc", "m", "muscular", "a half-orc man with dark olive-green skin, a bald scalp, pointed "
                      "ears, two small lower tusks and a heavy muscular build", {}),
    "halfling_male": ("halfling", "m", None, None, {}),
    "halfling_female": ("halfling", "f", "soft", "a halfling woman with warm light skin, dark-blonde hair gathered "
                        "into a high ponytail, and a soft plump build",
                        hair("dark-blonde hair gathered into a ponytail", ponytail=dict(), bun=dict(size=0.4))),
    "high_elf_female": ("high_elf", "f", "slim", "a high elf woman with fair skin, long wavy golden hair, long "
                        "pointed ears and a slender build",
                        hair("long wavy golden hair", hair_long=dict(width=1.9), locks=dict())),
    "human": ("human", "m", None, None, {}),
    "human_female": ("human", "f", "slim", "a human woman with light skin, thick wavy shoulder-length auburn hair "
                     "and a slim build",
                     hair("thick wavy auburn hair", hair_bushy=dict(), hair_long=dict(width=1.6, depth=0.9))),
    "human_undead_female": ("human_undead", "f", "slim", "an undead woman, a walking corpse with grey-green decaying "
                            "skin, lank dark-grey hair, a gaunt skull-like face and a thin wasted build",
                            hair("lank thin dark-grey hair", locks=dict(r=[0.20, 0.10], len=1.2))),
    "human_undead_male": ("human_undead", "m", "athletic", "an undead man, a walking corpse with grey-green "
                          "decaying skin, a bald scalp, a gaunt skull-like face, a few dark red wounds and a thin "
                          "wasted build", {}),
    "kobold_female": ("kobold", "f", "athletic", "a female kobold, a small dragon-like reptile-folk with tan-orange "
                      "scales, a paler belly, a horned head with a narrow pointed snout and a wiry build",
                      dict(dome="scaled top of the skull", dome_cover_tilt="skull")),
    "kobold_male": ("kobold", "m", "athletic", "a male kobold, a small dragon-like reptile-folk with green scales, "
                    "a cream belly, two long pale horns, a narrow pointed snout and a wiry build",
                    dict(dome="scaled top of the skull", dome_cover_tilt="skull", skin_words="green scales",
                         line_words="crisp, near-black green contour line",
                         features=dict(horns=dict(len=1.9)))),
    "mephistkin_female": ("mephistkin", "f", "slim", "a mephistkin woman, a devil-folk with crimson skin, a very "
                          "long wild mane of black hair, two dark curled ram horns and a lean build",
                          hair("long wild black hair", hair_long=dict(width=2.4, depth=1.2),
                               horns=dict(style="ram", len=2.6, r=[0.26, 0.04], curl=200,
                                          guide="A dark ridged horn grows from each side of the top of the head and "
                                                "curls round beside it.",
                                          paint="the two horns as dark ridged horn"))),
    "mephistkin_male": ("mephistkin", "m", "muscular", "a mephistkin man, a devil-folk with crimson skin, short "
                        "black hair, two large dark horns that sweep out and back, and a lean muscular build",
                        hair("short black hair",
                             horns=dict(style="wide", len=2.8, r=[0.30, 0.04],
                                        guide="A large dark horn grows from each side of the top of the head, "
                                              "sweeps out sideways and curves backward.",
                                        paint="the two horns as dark ridged horn"))),
    "naga_female": ("naga", "f", "athletic", "a female naga, a serpent-folk with lavender scales, a smooth snake "
                    "head and a slim build", dict(dome="smooth scaled top of the skull", dome_cover_tilt="skull")),
    "naga_male": ("naga", "m", "muscular", "a male naga, a serpent-folk with lavender scales, a smooth snake head, "
                  "a pale ribbed belly, a muscular build and a long serpent tail",
                  dict(dome="smooth scaled top of the skull", dome_cover_tilt="skull",
                       symmetry_words="the body left-right symmetric",
                       features=dict(tail=dict(len=1.2, r=[0.10, 0.02], curl=250, side=1,
                                               paint="the tail as a thick tapering serpent tail in the same "
                                                     "lavender scales")))),
    "newt_female": ("newt", "f", "slim", "a female newt-folk with smooth orange-red skin, a broad rounded "
                    "salamander head with round dark eyes, a slim build and a tail",
                    dict(dome="smooth rounded top of the skull", dome_cover_tilt="skull",
                         symmetry_words="the body left-right symmetric",
                         features=dict(tail=dict(len=0.85, r=[0.06, 0.012], curl=185, side=-1,
                                                 paint="the tail as a smooth tapering tail in the same orange-red "
                                                       "skin")))),
    "newt_male": ("newt", "m", "muscular", "a male newt-folk with smooth orange-red skin, a broad rounded "
                  "salamander head with round dark eyes, and a strong build",
                  dict(dome="smooth rounded top of the skull", dome_cover_tilt="skull")),
    "orc_female": ("orc", "f", "athletic", "an orc woman with olive-green skin, a thick mane of chestnut-brown hair, "
                   "pointed ears, two ivory tusk tips and a strong muscular build",
                   hair("thick chestnut-brown hair", hair_bushy=dict(count=11, size=0.42))),
    "quadrelf_female": ("quadrelf", "f", "slim", "a quadrelf woman with fair skin, long straight brown hair, pointed "
                        "ears and a slim build", hair("long straight brown hair", hair_long=dict(width=1.8))),
    "quadrelf_male": ("quadrelf", "m", "muscular", "a quadrelf man with fair skin, short brown hair, pointed ears "
                      "and an athletic muscular build", hair("short brown hair")),
    "sahuagin_female": ("sahuagin", "f", "athletic", "a female sahuagin, a fish-folk with teal scaled skin, a finned "
                        "head with a blunt snout, fin-like ears and webbed hands",
                        dict(dome="scaled top of the skull", dome_cover_tilt="skull")),
    "sahuagin_male": ("sahuagin", "m", "muscular", "a male sahuagin, a fish-folk with teal scaled skin, a finned "
                      "head with a blunt snout, fin-like ears, webbed hands, forearm fins and a tall back fin",
                      dict(dome="scaled top of the skull", dome_cover_tilt="skull",
                           features=dict(arm_fins=dict(), dorsal_fin=dict(h=0.17)))),
    "saurian_female": ("saurian", "f", "muscular", "a female saurian, a lizard-folk with olive-brown scales, a long "
                       "reptile snout, a crest of spines along the head and a heavy build",
                       dict(dome="scaled top of the skull", dome_cover_tilt="skull", skin_words="olive-brown scales",
                            features=dict(crest=dict(count=6, h=0.5)))),
    "saurian_male": ("saurian", "m", "muscular", "a male saurian, a lizard-folk with a green crocodile-like scaled "
                     "hide, a long reptile snout, a ridge of spines down the back and a heavy build",
                     dict(dome="scaled top of the skull", dome_cover_tilt="skull",
                          features=dict(dorsal_fin=dict(h=0.12, w=0.016,
                                        guide="A ridge of short spines runs down the middle of the upper back "
                                              "behind the head.", paint="the back ridge as a row of short spines")))),
    "sobruaro_female": ("sobruaro", "f", "athletic", "a female sobruaro, a cactus-folk with deep green ribbed skin "
                        "dotted with small pale spines, and a round ribbed barrel-cactus head",
                        dict(dome="round ribbed barrel-cactus top of the head", dome_cover_tilt="head")),
    "sobruaro_male": ("sobruaro", "m", "muscular", "a male sobruaro, a cactus-folk with deep green ribbed skin "
                      "dotted with small pale spines, a round ribbed barrel-cactus head and a heavy build",
                      dict(dome="round ribbed barrel-cactus top of the head", dome_cover_tilt="head")),
    "vampire_female": ("vampire", "f", "slim", "a vampire woman with ashen pale skin, thick wavy black hair, pointed "
                       "ears and a slim build", hair("thick wavy black hair", hair_bushy=dict())),
    "vampire_male": ("vampire", "m", "muscular", "a vampire man with ashen pale skin, slicked-back black hair, "
                     "pointed ears and a lean muscular build", hair("slicked-back black hair")),
}
PILOT_BASE = {"goblin_male": "goblin", "goblin_female": "goblin", "halfling_male": "halfling", "human": None}


# ---------------------------------------------------------------- measuring the legacy pack

def legacy(race):
    d = core.load_race(race, "default")
    f = d["frames"]
    hs = measures(f)["span"] / 2.0
    cx = f["torso"]["o"][0]
    lab = np.array(Image.open(core.race_file(d, "labels")).convert("RGB"))
    body = np.array(Image.open(core.race_file(d, "art")).convert("RGBA"))
    m = label_masks(lab)
    pair = lambda n, k: float(np.mean([f[n + "_l"][k], f[n + "_r"][k]])) / hs
    xoff = lambda n: float(np.mean([abs(f[n + s]["o"][0] - cx) for s in ("_l", "_r")])) / hs
    out = dict(head=f["head"]["lx"] / hs, shld=f["torso"]["lx"] / hs, elb=xoff("forearm"), wri=xoff("hand"),
               uar=pair("upperarm", "ly"), far=pair("forearm", "ly"), palm=pair("palm", "ly"),
               footw=pair("foot", "ly") if "foot_l" in f else 0.06, footx=xoff("foot") if "foot_l" in f else 0.14,
               hair_share=float(m["hair"].sum()) / float(m["hair"].sum() + m["face"].sum()) if "hair" in m and "face" in m
               else (1.0 if "hair" in m else 0.0))

    def tone(sel):
        sel = sel & (body[:, :, 3] > 230)
        px = body[:, :, :3][sel].astype(float)
        if len(px) < 200:
            return None
        lum = px @ np.array([0.299, 0.587, 0.114])
        lo, hi = np.percentile(lum, [45, 85])
        return [int(round(v)) for v in px[(lum >= lo) & (lum <= hi)].mean(0)]
    skin = np.zeros(lab.shape[:2], bool)
    for n in ("body", "upperarm_l", "upperarm_r", "forearm_l", "forearm_r"):
        skin |= m[n]
    out["skin"] = tone(skin)
    out["hair"] = tone(m["hair"]) if "hair" in m else None
    out["swatch"] = swatch_box(m, body)
    return out


def swatch_box(m, body):
    """A box on the upper arm with the least of anything else in it (hair, trunk, ground)."""
    best = None
    h, w = body.shape[:2]
    for s in ("r", "l"):
        up = m["upperarm_" + s]
        ys, xs = np.nonzero(up)
        x0, x1 = int(xs.min()), int(xs.max())
        for inset in (0.12, 0.25, 0.35):
            for shift in (0.0, 0.15, -0.15):
                a = x0 + (inset + shift * (1 if s == "r" else -1)) * (x1 - x0)
                b = x1 - (inset - shift * (1 if s == "r" else -1)) * (x1 - x0)
                a, b = int(max(a, x0)), int(min(b, x1))
                if b - a < 24:
                    continue
                col = up[:, a:b]
                rows = np.nonzero(col.any(1))[0]
                y0, y1 = max(int(rows.min()) - 8, 0), min(int(rows.max()) + 9, h)
                box = (a, y0, b, y1)
                inside = up[y0:y1, a:b]
                other = (body[y0:y1, a:b, 3] > 127) & ~inside
                score = float(other.mean()) + 0.15 * inset + (0.0 if s == "r" else 0.01)
                if best is None or score < best[0]:
                    best = (score, box)
    return [int(v) for v in best[1]]


# ---------------------------------------------------------------- drafting

def proportions(L, build):
    """Legacy measurements -> proxy numbers (see the module docstring)."""
    b = clamp((L["uar"] / 1.1) / 0.080, 0.55, 1.12)        # bulk: 0.71 = the human proxy, 1.0 = the orc
    lin = lambda human, slope: round(human + slope * (b - 0.71), 4)
    ua = clamp(L["uar"] / 1.1, 0.045, 0.090)
    fa = clamp(L["far"] / 0.95, 0.036, 0.075)
    wx = clamp(L["wri"] + 0.03, 0.76, 0.81)
    pry = clamp(L["palm"] / 1.06, 0.045, 0.078)
    cs, bs = lin(0.165, 0.162), lin(0.150, 0.138)
    if build in ("soft", "stocky"):
        bs = round(cs + 0.018, 4)
    p = dict(shoulder_half=round(clamp(L["shld"] + 0.015, 0.24, 0.36), 4), delt_r=lin(0.08, 0.086),
             trunk_depth_n=lin(0.125, 0.138), chest_depth_s=cs, belly_depth_s=bs,
             belly_half=lin(0.17, 0.103), pec_half=lin(0.11, 0.062),
             skull_r=SKULL_U, skull_y=0.004, nose=[0.0, 0.0], tusk=0.0, tusk_x=0.05, ear_len=0.0,
             upper_arm_r=[round(ua * 1.10, 4), round(ua * 0.90, 4)], forearm_r=[round(fa * 1.20, 4), round(fa * 0.80, 4)],
             elbow_x=round(clamp(L["elb"] + 0.05, 0.53, 0.59), 4), wrist_x=round(wx, 4),
             palm_rx=round((1.0 - wx) * 0.36, 4), palm_ry=round(pry, 4), finger_r=round(pry * 0.226, 4),
             foot_x=0.12, toe_y=0.2, toe_r=0.02,
             foot_x_tilt=round(clamp(L["footx"] * 1.02, 0.10, 0.17), 4),
             foot_w=round(clamp(L["footw"] / 1.09, 0.040, 0.075), 4),
             toe_y_tilt=round(max(cs, bs) * 0.62 + 0.06, 4),
             leg_r=[lin(0.070, 0.052), lin(0.048, 0.024)],
             ivory=[236, 226, 196])
    return p


def draft(race):
    family, sex, build, look, own = PACKS[race]
    F = FAMILIES[family]
    L = legacy(race)
    own = dict(own)
    spec = {}
    notes = []
    base = PILOT_BASE.get(race, "")
    if base is None:                            # the pack IS a pilot spec (human): keep it, add what is missing
        spec = json.load(open(os.path.join(gen_plan.SPEC_DIR, race + ".json"), encoding="utf-8"))
        spec.setdefault("features", {})
        spec["pack"] = race + "/default"
        if "cap" not in spec.get("anat", {}):   # the pilot drew the hair cap AS the skull: split them
            an = spec["anat"]
            an["skull_r"] = 0.097
            an["cap"] = dict(thick=round(clamp(L["head"] / F["skull"], 1.06, 1.75), 3), label="hair")
            an.pop("face_scale", None)
            an.pop("face_fwd", None)
        return spec, L
    if base:
        spec["base"] = base
    spec["pack"] = race + "/default"
    if base and build is None:                  # the pilot's own race: its tuned proxy, plus the head-size rule
        spec["features"] = {}
        if look:                                # the other sex: same proxy, its own words, colour and swatch
            spec["look"] = look
            spec["skin"] = L["skin"]
            spec["swatch"] = dict(src="Rigs/races/%s/default/body.png" % race, box=L["swatch"])
        return spec, L
    spec.update(proportions(L, build))
    spec["skin"] = L["skin"]
    haired = "dome" in own and own.get("dome_cover_tilt", "") in ("hair", "mane")
    capd = dict(own.pop("cap", {}))
    if haired or capd:
        skull = F["skull"]
        thick = clamp(L["head"] / skull, 1.06, 2.4 if capd else 1.75)
        spec["cap"] = dict(dict(thick=round(thick, 3)), **capd)
        if haired:
            spec["cap"].setdefault("label", "hair")
            spec["hair"] = L["hair"] or [90, 70, 50]
            notes.append("head-size rule: the legacy head frame (%.3f of the half span) is a circle on the hair "
                         "mass; skull built at %.3f, hair cap x%.2f" % (L["head"], L["head"] / thick, thick))
    if L["head"] / (spec.get("cap", {}).get("thick", 1.0)) > 0.17:
        spec["head_z"] = 1.76
    spec["tusk"] = F["tusk"]
    spec["tusk_x_tilt"] = 0.046
    spec["ear_len"] = F["ear_len"]
    if F["ear_tilt"]:
        spec["ear_tilt"] = F["ear_tilt"]
    if F["foot"]:
        spec["foot"] = F["foot"]
    spec["swatch"] = dict(src="Rigs/races/%s/default/body.png" % race, box=L["swatch"])
    swatch_of, finish, arms_tex = TEX[F["tex"]]
    spec["look"] = look
    spec["dome"] = own.pop("dome", "smooth bald scalp")
    spec["dome_cover_tilt"] = own.pop("dome_cover_tilt", "scalp")
    spec["skin_words"] = own.pop("skin_words", F["hue"]) + ", its lighter highlights"
    spec["line_words"] = own.pop("line_words", "crisp, %s contour line" % F["line"])
    face = F["face"]
    if face is HUMAN_FACE and not haired:
        face = BALD_FACE
    if F["ears"]:
        face += EARS % F["ears"]
    spec["face_tilt"] = face
    spec["torso_tilt"], spec["torso_paint"] = TORSO[build]
    top = "a " + spec["dome"]
    spec["face_paint"] = ("the head as %s seen from above with, in the narrow strip along its bottom edge, a natural "
                          "%s face strongly foreshortened from above, %s" % (top, F["noun"], F["face_bits"]))
    arms = arms_tex or ARMS[build]
    if arms:
        spec["arms_paint"] = arms
    if F["hands"]:
        spec["hands_paint"] = F["hands"]
    if F["foot"]:
        n = NUM.get(F["foot"].get("toes", 3), "three")
        ft, fp = FEET[F["foot"]["kind"]]
        spec["feet_tilt"] = ft % n if "%s" in ft else ft
        spec["feet_paint"] = fp % n if "%s" in fp else fp
    if swatch_of != "skin":
        spec["swatch_of"] = swatch_of
    if finish != "chalky matte skin":
        spec["finish"] = finish
    cols = dict(F["colours"], **own.pop("colours", {}))
    if cols:
        spec["colours"] = cols
    feats = {k: dict(v) for k, v in F["features"].items()}
    for k, v in own.pop("features", {}).items():
        feats[k] = dict(feats.get(k, {}), **v)
    if sex == "f" and F["tex"] in ("skin", "smooth") and family not in ("cerebrals", "sobruaro", "human_undead"):
        feats["bust"] = dict(size=0.6)
    spec["features"] = feats
    spec.update(own)
    if notes:
        spec["notes"] = notes
    return spec, L


# ---------------------------------------------------------------- tuning by rendering

def _ratio(race, over=None, ss=1):
    _, _, _, lab, st, _ = gen_plan.render_ex(race, ss=ss, over=over)
    fr, _ = derive_frames(np.array(gen_plan.PART_RGB, np.uint8)[lab], 1.0)
    return fr["head"]["lx"] / (st["span_px"] / 2.0), st


def tune(race, spec, L):
    """head_scale -> the legacy head frame; then the head pivot -> the depth band. Edits `spec`."""
    gen_plan.RACES.pop(race, None)

    def put():
        tmp = dict(spec)
        base = tmp.pop("base", None)
        gen_plan.RACES[race] = gen_plan._merge(gen_plan.load_spec(base), tmp) if base else tmp
        gen_plan.RACES[race].pop("abstract", None)
    want = L["head"]
    spec["head_scale"] = 1.0
    put()
    hs = 1.0
    for _ in range(4):
        now, st = _ratio(race)
        if abs(now / want - 1.0) < 0.006:
            break
        hs *= want / now
        spec["head_scale"] = round(hs, 3)
        put()
    lo, hi = gen_plan.DEPTH_BAND_TILT
    tried = []
    for pz, hb in ((None, None), (1.70, -0.012), (1.76, -0.02), (1.80, -0.03)):
        if pz is not None:
            spec["head_pivot_z"], spec["head_back"] = pz, hb
            put()
        now, st = _ratio(race)
        v = st.get("core_depth_over_span", st["depth_over_span"])
        tried.append((v, pz, hb))
        if v <= hi - 0.004:
            break
    else:
        v, pz, hb = min(tried)
        if pz is None:
            spec.pop("head_pivot_z", None)
            spec.pop("head_back", None)
        else:
            spec["head_pivot_z"], spec["head_back"] = pz, hb
        spec["depth_band"] = [lo, round(v + 0.012, 3)]
        spec.setdefault("notes", []).append(
            "depth band widened to %.3f: with the legacy head size the humanoid figure is %.3f deep (the head, "
            "not the camera, sets the depth)" % (v + 0.012, v))
        put()
    # the pivot moved the head: settle head_scale once more
    for _ in range(2):
        now, st = _ratio(race)
        if abs(now / want - 1.0) < 0.006:
            break
        spec["head_scale"] = round(spec["head_scale"] * want / now, 3)
        put()
    now, st = _ratio(race)
    return dict(head_vs_legacy=round(now / want, 3), head_scale=spec["head_scale"],
                core_depth_over_span=st.get("core_depth_over_span", st["depth_over_span"]))


def write(race, spec):
    path = os.path.join(gen_plan.SPEC_DIR, race + ".json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=1, ensure_ascii=False)
        f.write("\n")
    gen_plan.RACES.pop(race, None)
    return path


SHARED_SKIP = ("pack", "swatch", "notes", "look", "base")


def factor(family, races):
    """Sex variants share a base: what two drafted specs have in common moves to
    races_td/<family>_base.json ("abstract": a base nobody paints) and each keeps only what differs."""
    specs = [json.load(open(os.path.join(gen_plan.SPEC_DIR, r + ".json"), encoding="utf-8")) for r in races]
    if any("base" in sp for sp in specs):
        return None
    a, b = specs
    base = {"abstract": True}
    for k, v in a.items():
        if k in SHARED_SKIP or k not in b:
            continue
        if k in ("features", "colours") and isinstance(v, dict):
            common = {kk: vv for kk, vv in v.items() if b[k].get(kk) == vv}
            if common:
                base[k] = common
        elif b[k] == v:
            base[k] = v
    for r, sp in zip(races, specs):
        out = {"base": family + "_base"}
        for k, v in sp.items():
            if k in ("features", "colours") and isinstance(v, dict):
                own = {kk: vv for kk, vv in v.items() if base.get(k, {}).get(kk) != vv}
                if own or k == "features":
                    out[k] = own
            elif k not in base or base[k] != v:
                out[k] = v
        write(r, out)
    return write(family + "_base", base)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("races", nargs="*")
    ap.add_argument("--force", action="store_true", help="overwrite existing specs (loses hand edits)")
    ap.add_argument("--no-tune", action="store_true")
    ap.add_argument("--factor", action="store_true",
                    help="afterwards, move what x_male / x_female share into <family>_base.json")
    a = ap.parse_args(argv)
    for race in a.races or sorted(PACKS):
        path = os.path.join(gen_plan.SPEC_DIR, race + ".json")
        if os.path.exists(path) and not a.force and PILOT_BASE.get(race, "") is not None:
            print("[skip] %s exists (use --force to redraft)" % race)
            continue
        if os.path.exists(path) and PILOT_BASE.get(race, "") is None and not a.force \
                and "head_scale" in json.load(open(path, encoding="utf-8")):
            print("[skip] %s exists (use --force to redraft)" % race)
            continue
        spec, L = draft(race)
        info = {} if a.no_tune else tune(race, spec, L)
        write(race, spec)
        print("[ok ] %-20s %s" % (race, json.dumps(info)))
    if a.factor:
        fams = {}
        for race, row in PACKS.items():
            fams.setdefault(row[0], []).append(race)
        for family, races in sorted(fams.items()):
            if len(races) == 2 and all(os.path.exists(os.path.join(gen_plan.SPEC_DIR, r + ".json")) for r in races):
                if factor(family, sorted(races)):
                    print("[base] %s_base <- %s" % (family, ", ".join(sorted(races))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
