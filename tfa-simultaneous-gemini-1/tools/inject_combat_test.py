"""Inject combat-test spawns into the combat_test map entry (idempotent).

Run AFTER any re-export of combat_test (the exporter rewrites the entry and
wipes these fields):  python tools/inject_combat_test.py

Places, using the loader's tile rule (a solid blocks any 64px tile whose
CENTRE is within half + 22.4px):
- party spawn on clear ground in the SOUTH band, LOS-broken from every enemy
- 6 bandit-faction enemies across the NORTH band (tank / melee / shaman /
  occultist / archer / pyromancer), each on a clear tile
- an oil pool on open ground between party and enemies
"""
import json
import math
import os
import sys

TILE = 64.0
HALO = 22.4
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "data", "Maps.json")

ENEMIES = [
    ("orc_warrior", "melee tank"),
    ("bandit", "melee"),
    ("bandit_shaman", "support"),
    ("bandit_occultist", "occult"),
    ("bandit_archer", "ranged"),
    ("bandit_pyromancer", "caster"),
]


def seg_dist(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / l2))
    return math.hypot(p[0] - (ax + t * dx), p[1] - (ay + t * dy))


def main():
    raw = json.load(open(PATH, encoding="utf-8"))
    m = next(e for e in raw["maps"] if e["id"] == "combat_test")
    w, h = m["world_size"]
    walls = []
    for s in m["structures"]:
        if isinstance(s, dict) and s.get("kind") == "wall":
            walls.append((s["a"], s["b"], float(s.get("half", 8.0))))
        elif isinstance(s, dict) and s.get("kind") == "door":
            hg = s["hinge"]
            rad = math.radians(float(s.get("deg", 0.0)))
            end = [hg[0] + math.cos(rad) * s["width"], hg[1] + math.sin(rad) * s["width"]]
            walls.append((hg, end, float(s.get("half", 7.0))))

    def tile_clear(p):
        tc = ((math.floor(p[0] / TILE) + 0.5) * TILE, (math.floor(p[1] / TILE) + 0.5) * TILE)
        return all(seg_dist(tc, a, b) >= half + HALO + 2.0 for a, b, half in walls)

    def snap(p):
        return [int((math.floor(p[0] / TILE) + 0.5) * TILE), int((math.floor(p[1] / TILE) + 0.5) * TILE)]

    def los_blocked(p, q):
        steps = int(math.hypot(q[0] - p[0], q[1] - p[1]) / 8.0) + 1
        for i in range(1, steps):
            sp = (p[0] + (q[0] - p[0]) * i / steps, p[1] + (q[1] - p[1]) * i / steps)
            for a, b, half in walls:
                if seg_dist(sp, a, b) < half:
                    return True
        return False

    def find_clear(x0, x1, y0, y1, taken, min_gap=90.0):
        for ty in range(int(y0 / TILE), int(y1 / TILE)):
            for tx in range(int(x0 / TILE), int(x1 / TILE)):
                p = ((tx + 0.5) * TILE, (ty + 0.5) * TILE)
                if not tile_clear(p):
                    continue
                if all(math.hypot(p[0] - q[0], p[1] - q[1]) >= min_gap for q in taken):
                    yield p

    # party: south band, preferring spots LOS-broken from the whole north band
    enemy_zone = (int(TILE), w - TILE, int(TILE), int(h * 0.38))
    party = None
    for p in find_clear(w * 0.2, w * 0.8, h * 0.72, h - TILE, []):
        probes = [(w * 0.25, h * 0.2), (w * 0.5, h * 0.2), (w * 0.75, h * 0.2)]
        if all(los_blocked(p, q) for q in probes):
            party = p
            break
    if party is None:  # fall back to any clear southern tile (distance still gates)
        party = next(find_clear(w * 0.2, w * 0.8, h * 0.72, h - TILE, []))

    # enemies: north band — farthest-point sampling over all clear tiles so
    # the warband scatters around the buildings instead of lining one row
    cands = [p for p in find_clear(*enemy_zone, taken=[party], min_gap=0.0)
             if math.hypot(p[0] - party[0], p[1] - party[1]) >= 640.0]
    assert len(cands) >= len(ENEMIES), "only %d clear enemy tiles" % len(cands)
    cx = sum(p[0] for p in cands) / len(cands)
    cy = sum(p[1] for p in cands) / len(cands)
    spots = [min(cands, key=lambda p: math.hypot(p[0] - cx, p[1] - cy))]
    while len(spots) < len(ENEMIES):
        spots.append(max(cands, key=lambda p: min(
            math.hypot(p[0] - q[0], p[1] - q[1]) for q in spots)))
    taken = [party] + spots

    # oil pool: open ground between the bands, off the direct party->enemy axis
    oil = None
    for p in find_clear(w * 0.15, w * 0.85, h * 0.45, h * 0.65, taken, min_gap=120.0):
        oil = p
        break
    assert oil, "no oil spot"

    m["player_spawns"] = {"default": {"position": snap(party), "facing": -90}}
    m["party_spawns"] = {"default": {"formation": "cluster", "offset_radius": 40.0}}
    m["npc_spawns"] = [
        {"template_id": tid, "count": 1, "position": snap(p), "spread_radius": 0.0}
        for (tid, _), p in zip(ENEMIES, spots)]
    m["fluid_spawns"] = [
        {"type": "oil", "amount": 0.55, "radius": 2,
         "position": [int(oil[0] // TILE), int(oil[1] // TILE)]}]

    with open(PATH, "w", encoding="utf-8", newline="") as f:
        json.dump(raw, f, indent="\t", ensure_ascii=False)
    blocked = sum(1 for p in spots if los_blocked(party, p))
    dmin = min(math.hypot(p[0] - party[0], p[1] - party[1]) for p in spots)
    print("party", snap(party), "| enemies", [snap(p) for p in spots])
    print("oil", snap(oil), "| min party-enemy dist %.0f | LOS blocked %d/%d" % (dmin, blocked, len(spots)))


if __name__ == "__main__":
    sys.exit(main())
