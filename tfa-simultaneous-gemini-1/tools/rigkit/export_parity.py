"""Write the fixture tests/rig2_parity_test reads: fitted vertices for a spread
of race x item pairs, as computed by core.py. The Godot test recomputes them
with RigFit and fails if any vertex differs by more than a fraction of a pixel.

    python -m tools.rigkit.export_parity
"""
import os
import sys

from . import core

RACES = ["human", "orc", "halfling_male", "goblin_male", "naga_male", "dwarf_female"]
OUT = os.path.join(core.ROOT, "tests", "fixtures", "rig2_parity.json")


def main():
    skel = core.skeleton()
    cases = []
    for race_id in RACES:
        race = core.load_race(race_id)
        for item_id in core.list_items():
            item = core.load_item(item_id)
            if core.missing_frames(item, skel, race):
                continue
            verts, tris = core.mesh_from_cells(item["mesh"])
            for side in core.slot_sides(item, skel):
                pts, names, _ = core.fit_points(item, skel, race, verts, side)
                step = max(1, len(pts) // 12)
                cases.append({"race": race_id, "item": item_id, "side": side or "",
                              "n_verts": len(verts), "n_tris": len(tris), "frames": names,
                              "sample_step": step,
                              "sample": [[round(float(x), 3), round(float(y), 3)] for x, y in pts[::step]]})
    core.save_json(OUT, {"cases": cases})
    print("wrote %s (%d cases)" % (os.path.relpath(OUT, core.ROOT), len(cases)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
