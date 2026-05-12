"""One-shot helper: assigns sound_cast and sound_impact to every ability in
data/Abilities.json that the generate_ability_sfx.py recipes cover.

Loads the JSON, mutates each ability's `visuals` dict in place, and writes
back with tab indentation. Idempotent — running twice gives the same result.

Run from tfa-simultaneous-gemini-1/:
    python tools/_apply_ability_sfx.py
"""
from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ABILITIES_PATH = ROOT / "data" / "Abilities.json"

# Map: ability id -> (sound_cast filename or None, sound_impact filename or None)
# None means "leave unset". Files referenced here must exist in sfx/.
ASSIGNMENTS: dict[str, dict] = {
    # Damage spells with cast windup
    "cloud_kill":         {"cast": "arcane_cast",   "impact": "poison_cloud"},
    "ice_storm":          {"cast": "arcane_cast",   "impact": "ice_storm_impact"},
    "lightning_bolt":     {"cast": "arcane_cast",   "impact": "lightning_strike"},
    "gravity_well":       {"cast": "arcane_cast",   "impact": "gravity_well"},
    "vortex":             {"cast": "arcane_cast",   "impact": "vortex_wind"},
    "acid_splash":        {"cast": "arcane_cast",   "impact": "acid_splash"},
    "thunderwave":        {"cast": "arcane_cast",   "impact": "sonic_boom"},
    "wave_of_dysthymia":  {"cast": "arcane_cast",   "impact": "apathy_wave"},

    # Holy / radiant
    "heal":               {"cast": "holy_cast",     "impact": "heal_chime"},
    "chasten":            {"cast": "holy_cast",     "impact": "holy_cleanse"},
    "deny_ending":        {"cast": "holy_cast",     "impact": "holy_cleanse"},
    "psych_up":           {"cast": "holy_cast",     "impact": "holy_cleanse"},

    # Necrotic
    "creepy_beam":        {"cast": "necrotic_cast", "impact": "necrotic_drain"},
    "alms_of_the_vein":   {"cast": "necrotic_cast", "impact": "necrotic_drain"},

    # Nature
    "bumper_crop":        {"cast": "nature_cast",   "impact": "nature_bloom"},

    # Defensive
    "bide":               {"cast": "defensive_cast","impact": "shield_brace"},

    # Fire — keep existing fire_cast for cast, add fire_roar impact for fire_spin.
    # fireball already has fire_cast + explosion (untouched).
    "fire_spin":          {"cast": "fire_cast",     "impact": "fire_roar"},

    # Weather abilities — sound_cast plays at windup, looping audio takes over
    # via WeatherVFXController; intentionally NO sound_impact to avoid double-up.
    "rain":               {"cast": "weather_cast",  "impact": None},
    "acid_rain":          {"cast": "weather_cast",  "impact": None},
    "freezing_rain":      {"cast": "weather_cast",  "impact": None},

    # Instant-cast abilities (cast_time == 0): no sound_cast, just sound_impact.
    "magnetic_pull":      {"cast": None, "impact": "magnetic_pull"},
    "repulsion_wave":     {"cast": None, "impact": "force_blast"},
    "shield_bash":        {"cast": None, "impact": "armor-impact"},  # reuse existing
    "rage":               {"cast": None, "impact": "rage_roar"},
    "beguile":            {"cast": None, "impact": "charm_chime"},
    "confess":            {"cast": None, "impact": "charm_chime"},
    "hitch":              {"cast": None, "impact": "charm_chime"},
    "fatal_attraction":   {"cast": None, "impact": "charm_chime"},
    "test_confused":      {"cast": None, "impact": "mental_confuse"},
    "test_frightened":    {"cast": None, "impact": "fear_shriek"},
    "test_panicked":      {"cast": None, "impact": "fear_shriek"},
    "test_sickened":      {"cast": None, "impact": "disease_cough"},
    "test_nauseated":     {"cast": None, "impact": "nausea_retch"},
    "test_animal_magnetism": {"cast": None, "impact": "animal_call"},
}


def sfx_path(name: str) -> str:
    return f"res://sfx/{name}.mp3"


def main() -> int:
    text = ABILITIES_PATH.read_text(encoding="utf-8")
    data = json.loads(text)

    abilities = data.get("abilities", [])
    by_id = {a.get("id"): a for a in abilities}

    missing = [aid for aid in ASSIGNMENTS if aid not in by_id]
    if missing:
        print(f"ERROR: assignments reference unknown ability ids: {missing}")
        return 1

    touched = 0
    for aid, asgn in ASSIGNMENTS.items():
        ability = by_id[aid]
        visuals = ability.setdefault("visuals", {})
        if asgn["cast"] is not None:
            visuals["sound_cast"] = sfx_path(asgn["cast"])
        if asgn["impact"] is not None:
            visuals["sound_impact"] = sfx_path(asgn["impact"])
        touched += 1

    out = json.dumps(data, indent="\t", ensure_ascii=False)
    ABILITIES_PATH.write_text(out + "\n", encoding="utf-8")
    print(f"Updated {touched} abilities. Wrote {ABILITIES_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
