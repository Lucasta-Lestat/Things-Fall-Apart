#!/usr/bin/env python3
"""Wire the newly generated hybrid maps into data/Maps.json.

Adds a full map entry for each new map (images, spawns, party_spawns, empty
npc/item spawns, and warp_points), creates bidirectional warp links between
maps, appends reciprocal warps + arrival spawns to the existing maps that
gain new connections (town_square, dock_tavern, argentiara_square), and adds
world-map warps so each new region is reachable from the overworld.

Image paths follow the established repo convention (matching town_square /
argentiara_square): map = <id>_clean.png, structures = <id>.png, plus
<id>_mask.png and <id>_structures_mask.png (the color masks are painted by
hand later — same pending status as the existing argentiara_* entries).

Idempotent: re-running replaces previously added entries/warps by id.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAPS_JSON = ROOT / "data" / "Maps.json"

# id -> (width, height) of the generated regular image (= structures image,
# which is what the loader measures the map by).
DIMS = {
    "perrow_river_stronghold": (3392, 5056),
    "perrow_heart_village": (3584, 4800),
    "perrow_vale_tavern": (3392, 5056),
    "perrow_village_market": (3072, 5504),
    "perrow_adventurers_guild": (4800, 3584),
    "perrow_eeler_tavern": (4800, 3584),
    "perrow_goblin_fortress": (3584, 4800),
    "perrow_forest_pass": (3712, 4608),
    "bortellini_amphitheatre": (3584, 4800),
    "bortellini_royal_stables": (4800, 3584),
    "bortellini_adventurers_guild": (4800, 3584),
    "bortellini_hippodrome": (3072, 5504),
    "bortellini_training_camp": (3584, 4800),
    "bortellini_city_market": (3072, 5504),
    "alamone_floating_market": (3584, 4800),
    "alamone_black_market": (5056, 3392),
    "alamone_adventurers_guild": (4800, 3584),
    "argentiara_mine_town": (3392, 5056),
    "argentiara_wild_west_town": (3584, 4800),
    "lighthouse": (4608, 3712),
}

NEW_MAPS = {
    "perrow_river_stronghold": ("River Stronghold", "perrow",
        "A riverside stone stronghold half-claimed by the bullywug swamp, its walls rising from reed-choked black water."),
    "perrow_heart_village": ("Heart of the Village", "perrow",
        "The old heart of the village, its square and cottages slowly sinking into a misty swamp graveyard."),
    "perrow_vale_tavern": ("Ages of the Vale Tavern", "perrow",
        "A timber tavern raised on stilts over the swampy shallows, linked by creaking boardwalks across dark water."),
    "perrow_village_market": ("Village Market", "perrow",
        "A walled village market edged by encroaching bog, its stalls set on raised planking above muddy channels."),
    "perrow_adventurers_guild": ("Adventurers' Guild", "perrow",
        "A guildhall on the rim of a fog-laden swamp graveyard, where the courtyard gives way to mossy tombs and still water."),
    "perrow_eeler_tavern": ("The Eeler's Tavern", "perrow",
        "A dockside eel-fishers' tavern over brackish swamp water, hung with traps and nets along weathered jetties."),
    "perrow_goblin_fortress": ("Goblin Forest Fortress", "perrow",
        "A ramshackle goblin fortress lashed together among the tangled roots and channels of a flooded mangrove forest."),
    "perrow_forest_pass": ("Mangrove Forest Pass", "perrow",
        "A winding trail of raised paths and footbridges threading through dense, tidal mangrove woodland."),
    "bortellini_amphitheatre": ("Bortellini Amphitheatre", "bortellini",
        "A grand stone amphitheatre on the banks of the tidal river, its tiered seating descending toward the water."),
    "bortellini_royal_stables": ("Royal Stables", "bortellini",
        "Royal riverside stables, their paddocks and yards opening onto the broad tidal riverbank."),
    "bortellini_adventurers_guild": ("Adventurers' Guild", "bortellini",
        "A guildhall on the tidal riverfront, its courtyard meeting stone quays along the flowing water."),
    "bortellini_hippodrome": ("Bortellini Hippodrome", "bortellini",
        "A great chariot hippodrome running alongside the tidal river, its long oval track parallel to the bank."),
    "bortellini_training_camp": ("Training Camp", "bortellini",
        "A military training camp on the tidal riverbank, its sparring yards and drill grounds beside the water."),
    "bortellini_city_market": ("Bortellini City Market", "bortellini",
        "A bustling walled market beside the tidal river, its quays and stalls lining the busy waterfront."),
    "alamone_floating_market": ("Floating Market", "alamone",
        "A floating market of boats and pontoons drifting among lush druidic islands, walkways linking the verdant islets."),
    "alamone_black_market": ("Black Market Streets", "alamone",
        "A shadowy black-market quarter strung across small druid islands, its alleys and bridges spanning overgrown channels."),
    "alamone_adventurers_guild": ("Adventurers' Guild", "alamone",
        "A guildhall on a lush druid island, ringed by water, standing stones, and ancient trees."),
    "argentiara_mine_town": ("Royal Mine Town", "argentiara",
        "A royal silver-mining town carved into rocky dragon-memorial highlands, its ore-works clustered among weathered monuments."),
    "argentiara_wild_west_town": ("Frontier Town", "argentiara",
        "A dusty frontier mining town in rocky badlands, a wide main street flanked by timber buildings beneath stone outcrops."),
    "lighthouse": ("Lighthouse", "perrow",
        "A rugged coastal lighthouse on a rocky isle within a sheltered harpy cove, its tower rising over tide-washed rocks."),
}

# Adjacency for NEW maps. Each new map lists every map it connects to (new or
# existing). The builder creates, on THIS map's side, a warp to the neighbor
# plus an arrival spawn for travellers coming from that neighbor.
ADJ = {
    "perrow_heart_village": ["town_square", "perrow_village_market", "perrow_vale_tavern", "perrow_forest_pass"],
    "perrow_village_market": ["perrow_heart_village", "perrow_adventurers_guild"],
    "perrow_vale_tavern": ["perrow_heart_village", "perrow_eeler_tavern"],
    "perrow_adventurers_guild": ["perrow_village_market"],
    "perrow_eeler_tavern": ["perrow_vale_tavern", "perrow_river_stronghold"],
    "perrow_river_stronghold": ["perrow_eeler_tavern"],
    "perrow_forest_pass": ["perrow_heart_village", "perrow_goblin_fortress"],
    "perrow_goblin_fortress": ["perrow_forest_pass"],
    "lighthouse": ["dock_tavern"],
    "bortellini_city_market": ["bortellini_amphitheatre", "bortellini_hippodrome", "bortellini_royal_stables", "bortellini_adventurers_guild"],
    "bortellini_amphitheatre": ["bortellini_city_market", "bortellini_training_camp"],
    "bortellini_hippodrome": ["bortellini_city_market"],
    "bortellini_royal_stables": ["bortellini_city_market"],
    "bortellini_adventurers_guild": ["bortellini_city_market"],
    "bortellini_training_camp": ["bortellini_amphitheatre"],
    "alamone_floating_market": ["alamone_black_market", "alamone_adventurers_guild"],
    "alamone_black_market": ["alamone_floating_market"],
    "alamone_adventurers_guild": ["alamone_floating_market"],
    "argentiara_mine_town": ["argentiara_square", "argentiara_wild_west_town"],
    "argentiara_wild_west_town": ["argentiara_mine_town"],
}

# Display names for warp labels (new maps + existing targets).
LABELS = {mid: spec[0] for mid, spec in NEW_MAPS.items()}
LABELS.update({
    "town_square": "Town Square", "dock_tavern": "Dock Tavern",
    "argentiara_square": "Argentiara Square",
})

SIDE_ORDER = ["bottom", "top", "left", "right"]


def edge(w, h, side, m=100):
    """Return (warp_pos, warp_size, spawn_pos, spawn_facing) for an edge."""
    cx, cy = w // 2, h // 2
    if side == "left":
        return [m, cy], [40, 80], [m + 90, cy], 0
    if side == "right":
        return [w - m, cy], [40, 80], [w - m - 90, cy], 180
    if side == "top":
        return [cx, m], [80, 40], [cx, m + 90], 90
    # bottom
    return [cx, h - m], [80, 40], [cx, h - m - 90], 270


def build_new_entry(mid):
    name, region, desc = NEW_MAPS[mid]
    w, h = DIMS[mid]
    neighbors = ADJ.get(mid, [])
    player_spawns = {"default": {"position": [w // 2, h // 2], "facing": 0}}
    warps = []
    for i, n in enumerate(neighbors):
        side = SIDE_ORDER[i % len(SIDE_ORDER)]
        wpos, wsize, spos, facing = edge(w, h, side)
        player_spawns[f"from_{n}"] = {"position": spos, "facing": facing}
        warps.append({
            "id": f"to_{n}",
            "position": wpos,
            "size": wsize,
            "target_map": n,
            "target_spawn": f"from_{mid}",
            "label": f"To {LABELS.get(n, n)}",
        })
    return {
        "id": mid,
        "name": name,
        "description": desc,
        "region": region,
        "images": {
            # Photographic layers are JPEG (Gemini output); color masks are
            # lossless PNG (hand-painted later).
            "map": f"res://Maps/{mid}_clean.jpg",
            "mask": f"res://Maps/{mid}_mask.png",
            "structures": f"res://Maps/{mid}.jpg",
            "structures_mask": f"res://Maps/{mid}_structures_mask.png",
        },
        "tile_size": 64,
        "music_track": "",
        "weather_group": "",
        "fog_ids": [],
        "player_spawns": player_spawns,
        "party_spawns": {"default": {"formation": "cluster", "offset_radius": 30}},
        "npc_spawns": [],
        "item_spawns": [],
        "warp_points": warps,
    }


# Explicit additions to existing maps: (map_id, neighbor_id, side, src_w, src_h)
EXISTING_ADDS = [
    ("town_square", "perrow_heart_village", "top", 2048, 2048),
    ("dock_tavern", "lighthouse", "top", 842, 1157),
    ("argentiara_square", "argentiara_mine_town", "left", 1024, 1024),
]

# World-map warps: (warp_id, target_map, label, [x, y])
WORLD_WARPS = [
    ("to_bortellini", "bortellini_city_market", "Bortellini", [1500, 1300]),
    ("to_alamone", "alamone_floating_market", "Alamone", [900, 1300]),
    ("to_argentiara", "argentiara_square", "Argentiara", [1500, 500]),
]


def main():
    data = json.loads(MAPS_JSON.read_text(encoding="utf-8"))
    maps = data["maps"]
    by_id = {m["id"]: m for m in maps}

    # 1. Add / replace new map entries.
    new_ids = set(NEW_MAPS)
    maps[:] = [m for m in maps if m["id"] not in new_ids]
    for mid in NEW_MAPS:
        maps.append(build_new_entry(mid))
    by_id = {m["id"]: m for m in maps}
    print(f"Added {len(NEW_MAPS)} new map entries.")

    # 2. Reciprocal warps + arrival spawns on existing maps.
    for map_id, neighbor, side, w, h in EXISTING_ADDS:
        m = by_id.get(map_id)
        if not m:
            print(f"  WARN: existing map {map_id} not found")
            continue
        wpos, wsize, spos, facing = edge(w, h, side)
        m.setdefault("player_spawns", {})[f"from_{neighbor}"] = {"position": spos, "facing": facing}
        warps = m.setdefault("warp_points", [])
        warps[:] = [wp for wp in warps if wp.get("id") != f"to_{neighbor}"]
        warps.append({
            "id": f"to_{neighbor}",
            "position": wpos,
            "size": wsize,
            "target_map": neighbor,
            "target_spawn": f"from_{map_id}",
            "label": f"To {LABELS.get(neighbor, neighbor)}",
        })
        print(f"  linked {map_id} -> {neighbor} ({side})")

    # 3. World-map warps.
    world = by_id.get("scarlatti_world")
    if world:
        warps = world.setdefault("warp_points", [])
        existing_world_targets = {wp["id"] for wp in warps}
        for wid, target, label, pos in WORLD_WARPS:
            if wid in existing_world_targets:
                warps[:] = [wp for wp in warps if wp["id"] != wid]
            warps.append({
                "id": wid,
                "position": pos,
                "size": [64, 64],
                "target_map": target,
                "target_spawn": "default",
                "label": label,
                "world_warp": True,
                "reveal_radius_px": 220,
            })
        print(f"  added {len(WORLD_WARPS)} world-map warps.")

    MAPS_JSON.write_text(
        json.dumps(data, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"Wrote {MAPS_JSON.relative_to(ROOT)}  ({len(maps)} maps total).")


if __name__ == "__main__":
    main()
