#!/usr/bin/env python3
"""Generate fairy-chess armies for every main-game character and export a
roster for the standalone minigame.

Pipeline
--------
1. Read the main game's character database (TopDownCharacters.json).
2. For each character, derive a 5-school affinity (Martial / Arcane / Occult /
   Holy / Primal) from its faction, descriptive traits, magic-school tiers and
   stats, then build a themed but placement-legal army (>=5 peasants, >=4
   nobles/royals with >=2 royals so the player has real setup choices).
   A table of bespoke overrides replaces the generated set for key characters.
3. Write the sets, keyed by character id, to the main game as the source of
   truth:  tfa-simultaneous-gemini-1/data/fairy_chess_sets.json
4. Export a self-contained roster for the minigame (identity + set + a copied
   portrait):  fairy-chess-2/data/character_roster.json  plus portrait PNGs in
   fairy-chess-2/assets/portraits/.

Deterministic: the only randomness is seeded per character id, so re-running
with the same inputs yields identical output while armies still vary between
characters.
Run from the repo root:  python tools/generate_fairy_chess.py
"""

import json
import os
import random
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(REPO, "tfa-simultaneous-gemini-1")
MINI = os.path.join(REPO, "fairy-chess-2")

CHARACTERS_JSON = os.path.join(MAIN, "data", "TopDownCharacters.json")
SETS_JSON = os.path.join(MAIN, "data", "fairy_chess_sets.json")
ROSTER_JSON = os.path.join(MINI, "data", "character_roster.json")
PORTRAIT_DIR = os.path.join(MINI, "assets", "portraits")

SCHOOLS = ["Martial", "Arcane", "Occult", "Holy", "Primal"]

# --- Piece rosters (must match the minigame's PlayerDatabase.PIECE_DEFINITIONS) ---
# Each entry: piece -> (school tags, neutral base weight). The base weight makes
# a flavourless NPC field a classic-ish army (pawns, knights, rooks, a king).
PEASANTS = {
    "Pawn":                  ([], 3.0),
    "Kulak":                 (["Martial", "Primal"], 1.2),
    "Basic Automata":        (["Arcane"], 0.4),
    "Zombie":                (["Occult"], 0.3),
    "Cultist":               (["Occult"], 0.3),
    "Raider":                (["Martial", "Occult"], 0.4),
    "Werewolf (human form)": (["Primal", "Occult"], 0.2),
}
NOBLES = {
    "Knight":         (["Martial"], 2.0),
    "Rook":           (["Martial"], 1.8),
    "Rifleman":       (["Martial"], 1.0),
    "Cannonier":      (["Martial"], 0.7),
    "Elephant Rider": (["Martial", "Primal"], 0.6),
    "Centaur":        (["Primal", "Martial"], 0.6),
    "Dragonrider":    (["Arcane", "Martial"], 0.7),
    "Anarch":         (["Arcane", "Occult"], 0.5),
    "Nightrider":     (["Arcane"], 0.6),
    "Minister":       (["Arcane", "Holy"], 0.4),
    "Grasshopper":    (["Primal", "Arcane"], 0.4),
    "Queen":          (["Arcane"], 1.4),
    "Gorgon":         (["Occult", "Primal"], 0.5),
    "Devil Toad":     (["Occult", "Primal"], 0.5),
    "Monk":           (["Holy"], 0.6),
    "Bishop":         (["Holy", "Arcane"], 1.5),
    "Valkyrie":       (["Holy", "Martial"], 0.6),
    "Princess":       (["Holy"], 0.5),
    "Factory":        (["Arcane"], 0.2),
    "Doppelganger":   (["Occult", "Arcane"], 0.6),
    "Berserker":      (["Martial"], 0.4),
    "Spymaster":      (["Occult", "Arcane"], 0.7),
}
ROYALS = {
    "King":              ([], 3.0),
    "Chancellor":        (["Martial", "Arcane"], 1.0),
    "Pontifex":          (["Holy"], 0.5),
    "Lady of the Lake":  (["Holy", "Primal"], 0.5),
    "Praetor":           (["Arcane"], 0.45),
    "Chieftain":         (["Martial"], 0.15),
}

# --- Thematic steering -----------------------------------------------------
# Machines and gunpowder. Drawn to tinkers, kobolds and malcontents; shunned by
# the devout.
TECH_PIECES = {"Basic Automata", "Factory", "Cannonier", "Rifleman", "Praetor"}
TECH_RACES = {"kobold"}
TECH_FACTIONS = {"rebels", "vermincelli"}  # revolutionaries and malcontents

# Secular/parliamentary pieces the pious would rather not field.
DEMOCRATIC_PIECES = {"Chancellor", "Anarch"}

# The wilder, older pieces elves gravitate toward.
PRIMAL_FAVOURITES = {"Centaur", "Elephant Rider", "Grasshopper", "Lady of the Lake", "Devil Toad"}
ELF_RACES = {"elf", "high_elf", "half_elf", "quadrelf", "fey"}

# Norse-flavoured warriors, for the die-fighting-go-home crowd.
VIKING_PIECES = {"Berserker", "Chieftain", "Raider"}
VIKING_FACTIONS = {"skarsgaard", "pirates", "waldau"}

# --- Race -> school affinity (Martial, Arcane, Occult, Holy, Primal) ---
RACE_WEIGHTS = {
    "elf": (0, 1, 0, 0, 3), "high_elf": (0, 2, 0, 0, 3), "half_elf": (0, 1, 0, 0, 2),
    "quadrelf": (0, 1, 0, 0, 3), "fey": (0, 1, 0, 0, 3),
    "kobold": (0, 2, 0, 0, 0),
    "wolf": (0, 0, 0, 0, 3), "bear": (0, 0, 0, 0, 3), "horse": (0, 0, 0, 0, 3),
    "centaur": (1, 0, 0, 0, 3), "goatmen": (0, 0, 1, 0, 2),
    "rat": (0, 0, 1, 0, 2), "rodentkin": (0, 0, 1, 0, 2),
    "saurian": (1, 0, 0, 0, 2), "draconian": (1, 1, 0, 0, 2),
    "carapacian": (1, 0, 0, 0, 2), "carapacians": (1, 0, 0, 0, 2),
    "grimalkin": (0, 0, 1, 0, 2), "siren": (0, 1, 1, 0, 2),
    "human_undead": (0, 0, 3, 0, 0), "mephistkin": (0, 0, 3, 0, 0),
    "dwarf": (2, 1, 0, 0, 0), "orc": (2, 0, 0, 0, 1), "half_orc": (2, 0, 0, 0, 1),
    "halfling": (0, 0, 0, 0, 1),
}

# --- Faction -> school affinity (Martial, Arcane, Occult, Holy, Primal) ---
FACTION_WEIGHTS = {
    "player":             (2, 2, 2, 2, 2),
    "golden_guard":       (3, 1, 0, 3, 0),
    "neutral":            (1, 0, 0, 0, 0),
    "bandits":            (3, 0, 1, 0, 1),
    "rebels":             (3, 1, 0, 0, 0),
    "cultists":           (0, 0, 3, 1, 0),
    "undead":             (0, 0, 3, 0, 1),
    "patriciate":         (2, 3, 0, 1, 0),
    "wildlife":           (0, 0, 0, 0, 3),
    "liziti":             (3, 0, 2, 0, 0),
    "dragatini":          (3, 1, 0, 0, 0),
    "tortellini":         (2, 2, 1, 0, 0),
    "pirates":            (2, 0, 1, 0, 2),
    "adventurers_guild":  (2, 2, 0, 1, 1),
    "spider_party":       (0, 0, 2, 0, 3),
    "druids":             (0, 1, 0, 1, 3),
    "none":               (1, 0, 0, 0, 0),
    "vermincelli":        (1, 0, 2, 0, 2),
    "waldau":             (1, 0, 0, 0, 3),
    "skarsgaard":         (3, 0, 0, 0, 2),
    "alamoneans":         (0, 2, 0, 2, 0),
}

# --- Descriptive trait -> school bonus ---
TRAIT_WEIGHTS = {
    "Martial": (2, 0, 0, 0, 0), "Disciplined": (2, 0, 0, 0, 0),
    "Commanding": (2, 0, 0, 0, 0), "Seafaring": (2, 0, 0, 0, 1),
    "Arcane": (0, 3, 0, 0, 0), "Technological": (0, 3, 0, 0, 0),
    "Occult": (0, 0, 3, 0, 0), "Cursed": (0, 0, 2, 0, 1),
    "Criminal": (1, 0, 2, 0, 0), "Greedy": (1, 0, 1, 0, 0),
    "Intimidating": (1, 0, 1, 0, 0), "Savage": (1, 0, 0, 0, 2),
    "Holy": (0, 0, 0, 3, 0), "Catholic": (0, 0, 0, 2, 0),
    "Orthodox": (0, 0, 0, 2, 0), "Noble": (1, 1, 0, 1, 0),
    "Primal": (0, 0, 0, 0, 3), "Nature_Attuned": (0, 0, 0, 0, 2),
    "Amphibious": (0, 0, 1, 0, 2), "Hard_Shell": (1, 0, 0, 0, 1),
    "Small": (0, 0, 0, 0, 1), "sturdy": (1, 0, 0, 0, 1),
}

# Bespoke armies for signature characters (id -> {peasants, nobles, royals}).
OVERRIDES = {
    "protagonist": {
        "peasants": {"Pawn": 2, "Kulak": 1, "Cultist": 1, "Basic Automata": 1},
        "nobles":   {"Knight": 1, "Dragonrider": 1, "Rifleman": 1, "Valkyrie": 1},
        "royals":   {"King": 1, "Pontifex": 1},
    },
    "reverend_mother_liana": {
        "peasants": {"Pawn": 4, "Cultist": 1},
        "nobles":   {"Monk": 2, "Bishop": 1, "Valkyrie": 1},
        "royals":   {"Pontifex": 1, "Lady of the Lake": 1},
    },
    "mother_inferior_macaria": {
        "peasants": {"Pawn": 3, "Cultist": 2},
        "nobles":   {"Bishop": 2, "Monk": 1, "Princess": 1},
        "royals":   {"Pontifex": 1, "Lady of the Lake": 1},
    },
    "mary_guana": {
        "peasants": {"Cultist": 2, "Zombie": 2, "Werewolf (human form)": 1},
        "nobles":   {"Gorgon": 1, "Devil Toad": 1, "Anarch": 1, "Nightrider": 1},
        "royals":   {"King": 1, "Chancellor": 1},
    },
    "alligator_capone": {
        "peasants": {"Raider": 2, "Kulak": 2, "Pawn": 1},
        "nobles":   {"Devil Toad": 2, "Cannonier": 1, "Rifleman": 1},
        "royals":   {"King": 1, "Chancellor": 1},
    },
    "bandit_chief": {
        "peasants": {"Raider": 3, "Kulak": 2},
        "nobles":   {"Rifleman": 1, "Cannonier": 1, "Grasshopper": 1, "Centaur": 1},
        "royals":   {"King": 1, "Chancellor": 1},
    },
    "professor_easton": {
        "peasants": {"Basic Automata": 3, "Pawn": 2},
        "nobles":   {"Dragonrider": 1, "Nightrider": 1, "Anarch": 1, "Minister": 1},
        "royals":   {"Chancellor": 1, "King": 1},
    },
    "draga_centurion": {
        "peasants": {"Kulak": 3, "Pawn": 2},
        "nobles":   {"Knight": 1, "Rook": 1, "Cannonier": 1, "Elephant Rider": 1},
        "royals":   {"Chancellor": 1, "King": 1},
    },
}

# Characters whose own icon path doesn't resolve to a file: borrow another.
PORTRAIT_FALLBACK = {
    "protagonist": "res://Icons/default_human_icon.png",
}

STAT_WEIGHTS = {  # stat -> (school, factor per point above 50)
    "strength":     ("Martial", 0.04),
    "intelligence": ("Arcane", 0.04),
    "dexterity":    ("Martial", 0.02),
}


def affinity(char):
    score = {s: 0.0 for s in SCHOOLS}
    fac = FACTION_WEIGHTS.get(char.get("faction", "neutral"), (1, 0, 0, 0, 0))
    for i, s in enumerate(SCHOOLS):
        score[s] += fac[i]
    race = RACE_WEIGHTS.get(char.get("race", ""), None)
    if race:
        for i, s in enumerate(SCHOOLS):
            score[s] += race[i]
    for trait, val in (char.get("extra_traits") or {}).items():
        if trait in SCHOOLS:  # a magic-school tier: strong, scaled by tier
            score[trait] += float(val) * 2.0
        elif trait in TRAIT_WEIGHTS:
            for i, s in enumerate(SCHOOLS):
                score[s] += TRAIT_WEIGHTS[trait][i]
    stats = char.get("stats", {}) or {}
    for stat, (school, factor) in STAT_WEIGHTS.items():
        score[school] += (float(stats.get(stat, 50)) - 50.0) * factor
    # High will feeds the "faithful vs forbidden" axis: split Holy/Occult.
    will = (float(stats.get("will", 50)) - 50.0) * 0.03
    score["Holy"] += will
    score["Occult"] += will
    return score


def tech_affinity(char):
    """How drawn this character is to machines and gunpowder."""
    tech = 0.0
    if char.get("race", "") in TECH_RACES:
        tech += 3.0
    if "Technological" in (char.get("extra_traits") or {}):
        tech += 3.0
    if char.get("faction", "") in TECH_FACTIONS:
        tech += 2.0
    # Clever characters tinker.
    tech += (float((char.get("stats") or {}).get("intelligence", 50)) - 50.0) * 0.06
    return tech


def piece_bias(name, char, score, tech):
    """Per-piece nudges that sit on top of the five-school affinity."""
    bias = 0.0
    devout = score["Holy"] >= max(score[s] for s in SCHOOLS) and score["Holy"] > 1.0
    if name in TECH_PIECES:
        bias += tech
        if devout:
            bias -= 4.0  # the pious keep their distance from machines
    if name in DEMOCRATIC_PIECES and devout:
        bias -= 3.0      # ...and from parliaments
    if name in PRIMAL_FAVOURITES and char.get("race", "") in ELF_RACES:
        bias += 2.5      # elves keep the old wild company
    if name in VIKING_PIECES and char.get("faction", "") in VIKING_FACTIONS:
        bias += 2.0
    return bias


def _rank(pieces, score, char=None, tech=0.0, rng=None):
    # Sort by (affinity desc, name asc). A small seeded jitter keeps armies
    # from looking identical across characters with similar profiles.
    scored = []
    for name, (tags, base) in pieces.items():
        s = base + sum(score[t] for t in tags)
        if char is not None:
            s += piece_bias(name, char, score, tech)
        if rng is not None:
            s += rng.uniform(0.0, 1.4)
        scored.append((-s, name))
    scored.sort()
    return [name for _, name in scored]


def _distribute(types, counts):
    out = {}
    for t, c in zip(types, counts):
        out[t] = out.get(t, 0) + c
    return out


def build_set(char):
    score = affinity(char)
    tech = tech_affinity(char)
    # Seeded per character: stable across runs, different between characters.
    rng = random.Random("fairy-chess:" + str(char.get("id", "")))

    peasant_rank = _rank(PEASANTS, score, char, tech, rng)
    noble_rank = _rank(NOBLES, score, char, tech, rng)
    royal_rank = _rank(ROYALS, score, char, tech, rng)

    # 5 peasants: top type doubled, plus the next two (2+2+1).
    peasants = _distribute(peasant_rank[:3], [2, 2, 1])
    # 4 nobles: top type doubled, plus the next two (2+1+1).
    nobles = _distribute(noble_rank[:3], [2, 1, 1])
    # 2 distinct royals: the best themed royal plus a fallback (King if absent).
    royal_types = royal_rank[:2]
    if "King" not in royal_types:
        royal_types = [royal_rank[0], "King"]
    royals = {t: 1 for t in royal_types[:2]}

    # A couple of wildcards for variety, drawn from further down each character's
    # own ranking so they stay in flavour without being the obvious pick.
    for _ in range(rng.randint(1, 2)):
        pick = rng.choice(noble_rank[3:9]) if len(noble_rank) > 3 else None
        if pick:
            nobles[pick] = nobles.get(pick, 0) + 1
    if rng.random() < 0.6 and len(peasant_rank) > 3:
        pick = rng.choice(peasant_rank[3:6])
        peasants[pick] = peasants.get(pick, 0) + 1

    return {"peasants": peasants, "nobles": nobles, "royals": royals}


def validate(cid, cset):
    peasant_total = sum(cset["peasants"].values())
    noble_total = sum(cset["nobles"].values())
    royal_total = sum(cset["royals"].values())
    errs = []
    if peasant_total < 4:
        errs.append("only %d peasants (need >=4)" % peasant_total)
    if noble_total + royal_total < 4:
        errs.append("only %d nobles+royals (need >=4)" % (noble_total + royal_total))
    if royal_total < 1:
        errs.append("no royal")
    for bucket, table in [("peasants", PEASANTS), ("nobles", NOBLES), ("royals", ROYALS)]:
        for t in cset[bucket]:
            if t not in table:
                errs.append("invalid %s piece %r" % (bucket, t))
    return errs


def resolve_icon(icon_path):
    """res://Foo/bar.png -> absolute path under the main project, or None."""
    if not icon_path or not icon_path.startswith("res://"):
        return None
    rel = icon_path[len("res://"):]
    cand = os.path.join(MAIN, rel)
    if os.path.exists(cand):
        return cand
    # Windows FS is case-insensitive but be defensive about the Icons/icons split.
    alt = os.path.join(MAIN, rel.replace("Icons/", "icons/", 1))
    return alt if os.path.exists(alt) else None


def main():
    chars = json.load(open(CHARACTERS_JSON, encoding="utf-8"))["characters"]
    os.makedirs(PORTRAIT_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(ROSTER_JSON), exist_ok=True)

    sets = {}
    roster = []
    problems = []
    copied = 0
    for char in chars:
        cid = char["id"]
        cset = OVERRIDES.get(cid) or build_set(char)
        errs = validate(cid, cset)
        if errs:
            problems.append("%s: %s" % (cid, "; ".join(errs)))
            continue
        sets[cid] = cset

        # Copy the portrait into the minigame and rewrite the path.
        portrait_res = ""
        src = resolve_icon(char.get("icon", "")) or resolve_icon(PORTRAIT_FALLBACK.get(cid, ""))
        if src:
            dst = os.path.join(PORTRAIT_DIR, cid + ".png")
            shutil.copyfile(src, dst)
            portrait_res = "res://assets/portraits/%s.png" % cid
            copied += 1

        titles = char.get("titles") or []
        roster.append({
            "id": cid,
            "name": char.get("name", cid),
            "title": titles[0] if titles else "",
            "faction": char.get("faction", "neutral"),
            "portrait": portrait_res,
            "chess_set": cset,
        })

    if problems:
        print("VALIDATION FAILURES:")
        for p in problems:
            print("  " + p)
        sys.exit(1)

    json.dump(sets, open(SETS_JSON, "w", encoding="utf-8"), indent="\t", ensure_ascii=False)
    roster.sort(key=lambda r: r["name"].lower())
    json.dump({"roster": roster}, open(ROSTER_JSON, "w", encoding="utf-8"), indent="\t", ensure_ascii=False)

    print("Generated %d chess sets (%d bespoke, %d generated)."
          % (len(sets), len(OVERRIDES), len(sets) - len(OVERRIDES)))
    print("Copied %d/%d portraits." % (copied, len(chars)))
    print("Wrote:\n  %s\n  %s\n  %s/*.png" % (SETS_JSON, ROSTER_JSON, PORTRAIT_DIR))


if __name__ == "__main__":
    main()
