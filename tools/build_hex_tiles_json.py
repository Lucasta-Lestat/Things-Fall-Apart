"""Build tfa-simultaneous-gemini-1/data/hex_tiles.json from the carved hex PNGs.

The JSON mirrors the floor pattern (see data/floors.json + Global/FloorDatabase.gd):
one entry per scene/biome, with `alternate_textures` listing all carved hexes from
that scene so the runtime can pick_random() at instantiation time.

Per-biome game properties (walkability, flammable, vision_modifier, movement_cost,
resources, ...) come from BIOME_DEFAULTS below. To re-curate which carved hexes
are used for a given biome, edit the JSON directly (the script will not overwrite
an existing entry's curation if --merge is passed... TODO future work).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path("tfa-simultaneous-gemini-1")
HEX_DIR = ROOT / "Assets" / "HexTiles"
OUT_PATH = ROOT / "data" / "hex_tiles.json"
CURATION_PATH = ROOT / "data" / "hex_tile_curation.json"
RES_PREFIX = "res://Assets/HexTiles/"

# -----------------------------------------------------------------------------
# Per-scene defaults. Anything not listed here gets the GENERIC_DEFAULTS values.
# walkability: 1.0 = free walk, 0.0 = impassable. Mirrors floors.json convention.
# movement_cost: world-map movement cost multiplier (higher = slower).
# vision_modifier: multiplier on sight range for units on this tile (forests block sight).
# blocks_sight: hard line-of-sight block (e.g. mountains, dense city walls).
# passable_overworld: false = land units can't enter (deep ocean, etc.).
# -----------------------------------------------------------------------------
GENERIC_DEFAULTS = {
    "biome": "mixed",
    "season": None,
    "walkability": 0.75,
    "flammable": False,
    "conductive": False,
    "max_health": 100,
    "resources": {},
    "damage_resistances": {},
    "blocks_sight": False,
    "vision_modifier": 1.0,
    "movement_cost": 1.0,
    "passable_overworld": True,
    "rarity": "common",
}

BIOME_DEFAULTS: dict[str, dict] = {
    # ---- pure biomes -------------------------------------------------------
    "plains": {
        "name": "Plains",
        "description": "Open rolling grassland; easy travel.",
        "biome": "plains",
        "walkability": 1.0,
        "flammable": True,
        "max_health": 50,
        "resources": {"hay": 5, "wildflowers": 1},
        "vision_modifier": 1.0,
        "movement_cost": 1.0,
    },
    "forest_summer": {
        "name": "Summer Forest",
        "description": "Dense leafy forest in midsummer.",
        "biome": "forest",
        "season": "summer",
        "walkability": 0.6,
        "flammable": True,
        "max_health": 120,
        "resources": {"wood": 50, "berries": 5},
        "damage_resistances": {"fire": -5},
        "blocks_sight": True,
        "vision_modifier": 0.5,
        "movement_cost": 1.5,
    },
    "forest_autumn": {
        "name": "Autumn Forest",
        "description": "Deciduous forest in autumn; the canopy is on fire with color.",
        "biome": "forest",
        "season": "autumn",
        "walkability": 0.6,
        "flammable": True,
        "max_health": 110,
        "resources": {"wood": 50, "mushrooms": 3},
        "damage_resistances": {"fire": -10},
        "blocks_sight": True,
        "vision_modifier": 0.55,
        "movement_cost": 1.5,
    },
    "forest_winter": {
        "name": "Winter Forest",
        "description": "Bare branches and snowy ground; the trees offer little cover.",
        "biome": "forest",
        "season": "winter",
        "walkability": 0.7,
        "flammable": False,
        "max_health": 90,
        "resources": {"wood": 40, "firewood": 10},
        "damage_resistances": {"cold": 5, "fire": 5},
        "blocks_sight": False,
        "vision_modifier": 0.75,
        "movement_cost": 1.75,
    },
    "forest_spring": {
        "name": "Spring Forest",
        "description": "Fresh green leaves and blossoms.",
        "biome": "forest",
        "season": "spring",
        "walkability": 0.65,
        "flammable": True,
        "max_health": 100,
        "resources": {"wood": 45, "herbs": 5},
        "blocks_sight": True,
        "vision_modifier": 0.6,
        "movement_cost": 1.5,
    },
    "swamp": {
        "name": "Swamp",
        "description": "Murky stagnant water and gnarled trees; difficult terrain.",
        "biome": "swamp",
        "walkability": 0.3,
        "flammable": False,
        "max_health": 80,
        "resources": {"reeds": 5, "herbs": 3},
        "damage_resistances": {"fire": 10, "poison": -5},
        "blocks_sight": False,
        "vision_modifier": 0.7,
        "movement_cost": 2.5,
    },
    "mountain_range": {
        "name": "Mountains",
        "description": "Rocky peaks and scree slopes; very slow travel.",
        "biome": "mountain",
        "walkability": 0.2,
        "flammable": False,
        "max_health": 500,
        "resources": {"stone": 50, "iron": 5},
        "damage_resistances": {"bludgeoning": 5, "piercing": 5, "fire": 10, "cold": -5},
        "blocks_sight": True,
        "vision_modifier": 1.2,  # high vantage point
        "movement_cost": 3.0,
    },
    "lake_district": {
        "name": "Lake District",
        "description": "Plains dotted with freshwater ponds and small lakes.",
        "biome": "plains",
        "walkability": 0.8,
        "flammable": False,
        "max_health": 60,
        "resources": {"freshwater": 5, "fish": 3},
        "vision_modifier": 1.0,
        "movement_cost": 1.2,
    },
    "shallow_ocean": {
        "name": "Shallow Ocean",
        "description": "Coastal seas; passable to ships.",
        "biome": "ocean",
        "walkability": 0.0,
        "flammable": False,
        "max_health": 9999,
        "resources": {"fish": 3, "salt": 2},
        "vision_modifier": 1.5,  # open water = long sight
        "movement_cost": 2.0,
        "passable_overworld": False,
    },
    "deep_ocean": {
        "name": "Deep Ocean",
        "description": "Open seas; treacherous without a deep-water vessel.",
        "biome": "ocean",
        "walkability": 0.0,
        "flammable": False,
        "max_health": 9999,
        "resources": {"fish": 5, "whale": 1},
        "vision_modifier": 1.5,
        "movement_cost": 3.0,
        "passable_overworld": False,
    },

    # ---- transitions (treated as the biome with the slower side dominant) --
    "forest_to_plains_vertical": {
        "name": "Forest/Plains Edge (N-S)",
        "description": "Where forest meets open plains, running north-south.",
        "biome": "transition",
        "walkability": 0.8,
        "flammable": True,
        "max_health": 90,
        "resources": {"wood": 20, "hay": 3},
        "vision_modifier": 0.8,
        "movement_cost": 1.25,
    },
    "forest_to_plains_diagonal": {
        "name": "Forest/Plains Edge (diagonal)",
        "description": "Where forest meets open plains, on a diagonal.",
        "biome": "transition",
        "walkability": 0.8,
        "flammable": True,
        "max_health": 90,
        "resources": {"wood": 20, "hay": 3},
        "vision_modifier": 0.8,
        "movement_cost": 1.25,
    },
    "plains_to_mountains": {
        "name": "Foothills",
        "description": "Plains rising into rocky foothills.",
        "biome": "transition",
        "walkability": 0.5,
        "flammable": True,
        "max_health": 120,
        "resources": {"stone": 10, "hay": 2},
        "vision_modifier": 1.0,
        "movement_cost": 2.0,
    },
    "forest_to_swamp": {
        "name": "Marshy Forest",
        "description": "Where forest grows mossy and gives way to swampland.",
        "biome": "transition",
        "walkability": 0.4,
        "flammable": True,
        "max_health": 100,
        "resources": {"wood": 30, "herbs": 3},
        "blocks_sight": True,
        "vision_modifier": 0.55,
        "movement_cost": 2.0,
    },

    # ---- coasts ------------------------------------------------------------
    "coast_plains_horizontal": {
        "name": "Plains Coast (E-W)",
        "description": "Grasslands meeting the sea.",
        "biome": "coast",
        "walkability": 0.8,
        "flammable": True,
        "max_health": 60,
        "resources": {"hay": 3, "salt": 1, "fish": 1},
        "vision_modifier": 1.3,
        "movement_cost": 1.2,
    },
    "coast_plains_diagonal": {
        "name": "Plains Coast (diagonal)",
        "description": "Grasslands meeting the sea on a diagonal.",
        "biome": "coast",
        "walkability": 0.8,
        "flammable": True,
        "max_health": 60,
        "resources": {"hay": 3, "salt": 1, "fish": 1},
        "vision_modifier": 1.3,
        "movement_cost": 1.2,
    },
    "coast_forest_horizontal": {
        "name": "Forest Coast",
        "description": "Forest meeting the sea.",
        "biome": "coast",
        "walkability": 0.5,
        "flammable": True,
        "max_health": 100,
        "resources": {"wood": 40, "fish": 2},
        "blocks_sight": True,
        "vision_modifier": 0.7,
        "movement_cost": 1.6,
    },
    "coast_mountain": {
        "name": "Mountain Coast",
        "description": "Rocky cliffs and the sea below.",
        "biome": "coast",
        "walkability": 0.2,
        "flammable": False,
        "max_health": 300,
        "resources": {"stone": 30, "fish": 1},
        "blocks_sight": True,
        "vision_modifier": 1.4,
        "movement_cost": 2.5,
    },
    "coast_swamp": {
        "name": "Swamp Coast",
        "description": "Brackish swamp meeting open sea.",
        "biome": "coast",
        "walkability": 0.3,
        "flammable": False,
        "max_health": 80,
        "resources": {"reeds": 4, "fish": 2, "herbs": 2},
        "vision_modifier": 0.7,
        "movement_cost": 2.5,
    },

    # ---- rivers (biome = the surrounding terrain; river is the feature) ----
    "river_through_plains_NS": {
        "name": "River Through Plains (N-S)",
        "description": "Open grassland crossed by a river running north-south.",
        "biome": "plains_river",
        "walkability": 0.9,
        "flammable": True,
        "max_health": 50,
        "resources": {"hay": 5, "freshwater": 5, "fish": 2},
        "vision_modifier": 1.0,
        "movement_cost": 1.1,
    },
    "river_through_plains_diagonal": {
        "name": "River Through Plains (diagonal)",
        "description": "Open grassland crossed by a river on a diagonal.",
        "biome": "plains_river",
        "walkability": 0.9,
        "flammable": True,
        "max_health": 50,
        "resources": {"hay": 5, "freshwater": 5, "fish": 2},
        "vision_modifier": 1.0,
        "movement_cost": 1.1,
    },
    "river_through_forest_NS": {
        "name": "River Through Forest (N-S)",
        "description": "Summer forest with a wide river running through.",
        "biome": "forest_river",
        "season": "summer",
        "walkability": 0.55,
        "flammable": True,
        "max_health": 100,
        "resources": {"wood": 40, "freshwater": 5, "fish": 2},
        "blocks_sight": True,
        "vision_modifier": 0.55,
        "movement_cost": 1.7,
    },
    "river_through_forest_autumn_NS": {
        "name": "River Through Autumn Forest (N-S)",
        "description": "Autumn forest with a wide river running through.",
        "biome": "forest_river",
        "season": "autumn",
        "walkability": 0.55,
        "flammable": True,
        "max_health": 100,
        "resources": {"wood": 40, "freshwater": 5, "fish": 2},
        "blocks_sight": True,
        "vision_modifier": 0.6,
        "movement_cost": 1.7,
    },
    "river_through_forest_winter_NS": {
        "name": "River Through Winter Forest (N-S)",
        "description": "Snowy winter forest with a wide river running through.",
        "biome": "forest_river",
        "season": "winter",
        "walkability": 0.65,
        "flammable": False,
        "max_health": 80,
        "resources": {"wood": 30, "freshwater": 5, "fish": 1},
        "vision_modifier": 0.8,
        "movement_cost": 1.9,
    },
    "river_through_forest_spring_NS": {
        "name": "River Through Spring Forest (N-S)",
        "description": "Spring forest with a wide river running through.",
        "biome": "forest_river",
        "season": "spring",
        "walkability": 0.6,
        "flammable": True,
        "max_health": 90,
        "resources": {"wood": 35, "freshwater": 5, "fish": 2, "herbs": 3},
        "blocks_sight": True,
        "vision_modifier": 0.65,
        "movement_cost": 1.65,
    },

    # ---- settlements (treated as plains with a settlement feature) ---------
    "small_village_in_plains": {
        "name": "Small Village",
        "description": "A small rural village set in open plains.",
        "biome": "settlement",
        "walkability": 1.0,
        "flammable": True,
        "max_health": 120,
        "resources": {"food": 10, "hay": 3},
        "vision_modifier": 1.0,
        "movement_cost": 0.9,
    },
    "large_village_in_plains": {
        "name": "Large Village",
        "description": "A larger village with a market square and chapel.",
        "biome": "settlement",
        "walkability": 1.0,
        "flammable": True,
        "max_health": 200,
        "resources": {"food": 20, "hay": 5, "goods": 5},
        "vision_modifier": 1.0,
        "movement_cost": 0.85,
    },
    "city_in_plains": {
        "name": "City",
        "description": "A walled fantasy city.",
        "biome": "settlement",
        "walkability": 1.0,
        "flammable": True,
        "max_health": 1000,
        "resources": {"food": 50, "goods": 20, "stone": 10},
        "damage_resistances": {"piercing": 5, "bludgeoning": 5},
        "vision_modifier": 1.2,  # high towers
        "movement_cost": 0.75,
        "blocks_sight": True,
    },
}


def load_curation() -> dict:
    """Return {scene_name: [allowed_filename, ...]}; empty dict if no curation file."""
    if not CURATION_PATH.exists():
        return {}
    try:
        return json.loads(CURATION_PATH.read_text())
    except Exception as e:  # noqa: BLE001
        print(f"WARN: failed to parse {CURATION_PATH}: {e}")
        return {}


def build_entry(scene_name: str, scene_dir: Path, curation: dict) -> dict:
    textures = sorted(p.name for p in scene_dir.glob(f"{scene_name}_c*_r*.png"))
    if not textures:
        return {}
    # If a curation list exists for this scene, restrict to it.
    if scene_name in curation:
        allowed = set(curation[scene_name])
        textures = [t for t in textures if t in allowed]
        if not textures:
            print(f"WARN: curation for '{scene_name}' selected zero files; skipping entry")
            return {}
    rel_textures = [f"{RES_PREFIX}{scene_name}/{t}" for t in textures]

    defaults = {**GENERIC_DEFAULTS, **BIOME_DEFAULTS.get(scene_name, {})}
    primary = rel_textures[len(rel_textures) // 2]

    return {
        "id": scene_name,
        "name": defaults.get("name", scene_name.replace("_", " ").title()),
        "description": defaults.get("description", ""),
        "biome": defaults["biome"],
        "season": defaults["season"],
        "icon_path": primary,
        "texture": primary,
        "alternate_textures": rel_textures,
        "walkability": defaults["walkability"],
        "rarity": defaults.get("rarity", "common"),
        "flammable": defaults["flammable"],
        "conductive": defaults["conductive"],
        "max_health": defaults["max_health"],
        "current_health": defaults["max_health"],
        "damage_resistances": defaults["damage_resistances"],
        "resources": defaults["resources"],
        "blocks_sight": defaults["blocks_sight"],
        "vision_modifier": defaults["vision_modifier"],
        "movement_cost": defaults["movement_cost"],
        "passable_overworld": defaults["passable_overworld"],
        "source_image": f"{RES_PREFIX}sources/{scene_name}_cropped.png",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(OUT_PATH), help="output JSON path")
    args = ap.parse_args()

    out_path = Path(args.out)

    curation = load_curation()
    if curation:
        print(f"Applying curation from {CURATION_PATH} ({len(curation)} scenes)")

    entries: dict[str, dict] = {}
    for scene_dir in sorted(HEX_DIR.iterdir()):
        if not scene_dir.is_dir():
            continue
        if scene_dir.name.startswith("_") or scene_dir.name in ("sources", "icons"):
            continue
        entry = build_entry(scene_dir.name, scene_dir, curation)
        if entry:
            entries[scene_dir.name] = entry

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(entries, indent=2))
    print(f"Wrote {len(entries)} hex tile entries -> {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
