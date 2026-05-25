#!/usr/bin/env python3
"""Migration: strip legacy cooldown + MP cost fields from data/Abilities.json.

The school-resource rework drops ability cooldowns entirely and derives costs
from each ability's school traits (Martial→adrenaline, Arcane→focus, etc.),
so the `cooldown` field and the `costs.MP` field are now dead weight.

Run from the project root:
    python tools/migrate_abilities_to_school_resources.py

Writes audit/abilities_without_school.txt listing every ability that lacks a
school trait — those need hand-tagging before they can charge a resource.
"""
from __future__ import annotations

import json
import pathlib
import sys

SCHOOL_TRAITS = {"Martial", "Arcane", "Occult", "Holy", "Primal"}

# Inference rules for legacy abilities that lack a school trait.
# Matches against the ability id (substring) OR against the trait dict.
# First match wins; tier is conservative (1) — designers can tune up later.
INFERENCE_RULES: list[tuple[str, str, int]] = [
    # (rule_kind, key_or_trait, tier) → applied as {school: tier}
]

# Explicit per-id assignments for the 28 known untagged abilities.
EXPLICIT_SCHOOL: dict[str, dict[str, int]] = {
    "fireball":        {"Arcane": 1},
    "cloud_kill":      {"Arcane": 2},
    "ice_storm":       {"Arcane": 2},
    "lightning_bolt":  {"Arcane": 1},
    "magnetic_pull":   {"Arcane": 1},
    "repulsion_wave":  {"Arcane": 1},
    "gravity_well":    {"Arcane": 2},
    "vortex":          {"Arcane": 1},
    "heal":            {"Holy": 1},
    "chasten":         {"Holy": 1},
    "shield_bash":     {"Martial": 1},
    "rage":            {"Martial": 1},
    "creepy_beam":     {"Occult": 1},
    "acid_splash":     {"Arcane": 1},
    "thunderwave":     {"Arcane": 1},
    "beguile":         {"Occult": 1},
    "confess":         {"Occult": 1},
    "hitch":           {"Occult": 1},
    "fatal_attraction":{"Occult": 1},
    "test_confused":   {"Occult": 0},
    "test_frightened": {"Occult": 0},
    "test_panicked":   {"Occult": 0},
    "test_sickened":   {"Occult": 0},
    "test_nauseated":  {"Occult": 0},
    "test_animal_magnetism": {"Occult": 0},
    "pounce":          {"Primal": 1},
    "ram":             {"Primal": 1},
    "natural_bite":    {"Primal": 1},
}

ROOT = pathlib.Path(__file__).resolve().parents[1]
ABILITIES_PATH = ROOT / "data" / "Abilities.json"
AUDIT_DIR = ROOT / "audit"
AUDIT_PATH = AUDIT_DIR / "abilities_without_school.txt"


def main() -> int:
    if not ABILITIES_PATH.exists():
        print(f"Could not find {ABILITIES_PATH}", file=sys.stderr)
        return 1

    with ABILITIES_PATH.open("r", encoding="utf-8") as fh:
        data = json.load(fh)

    abilities = data["abilities"]
    no_school: list[str] = []

    tagged_via_inference: list[str] = []
    for ab in abilities:
        if "cooldown" in ab:
            del ab["cooldown"]
        costs = ab.get("costs")
        if isinstance(costs, dict) and "MP" in costs:
            del costs["MP"]
            if not costs:
                ab["costs"] = {}
        traits = ab.get("traits", {})
        if not any(t in SCHOOL_TRAITS for t in traits):
            aid = ab.get("id", "")
            if aid in EXPLICIT_SCHOOL:
                for school, tier in EXPLICIT_SCHOOL[aid].items():
                    traits[school] = tier
                ab["traits"] = traits
                tagged_via_inference.append(aid)
            else:
                no_school.append(aid or "<unknown>")

    with ABILITIES_PATH.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent="\t", ensure_ascii=False)
        fh.write("\n")

    AUDIT_DIR.mkdir(exist_ok=True)
    with AUDIT_PATH.open("w", encoding="utf-8") as fh:
        if no_school:
            fh.write("Abilities missing a school trait (Martial/Arcane/Occult/Holy/Primal):\n")
            for aid in no_school:
                fh.write(f"  - {aid}\n")
        else:
            fh.write("All abilities have a school trait.\n")

    print(f"Migrated {len(abilities)} abilities.")
    print(f"Auto-tagged via inference: {len(tagged_via_inference)}.")
    print(f"{len(no_school)} still need hand-tagging — see {AUDIT_PATH.relative_to(ROOT)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
