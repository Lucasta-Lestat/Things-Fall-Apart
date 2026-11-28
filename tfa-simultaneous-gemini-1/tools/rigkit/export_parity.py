"""Write the fixture tests/rig2_parity_test reads: fitted vertices for a spread
of race x item pairs, as computed by core.py. The Godot test recomputes them
with RigFit and fails if any vertex differs by more than a fraction of a pixel.

    python -m tools.rigkit.export_parity

The "hands" block covers the hand rig (docs 3.6): the body cut-outs, the fist on
each side, glove pieces in both poses, and which cells of a held item are tail.
The "body" block covers the body polygon of packs with a head box (enclosing
headwear) and the layers the engine must build: the quads the body is drawn with,
the head box, whether the pack has a trunk-over-feet overlay, and which item packs
enclose the head.
"""
import os
import sys

import numpy as np

from . import core

RACES = ["human", "orc", "halfling_male", "goblin_male", "naga_male", "dwarf_female"]
HAND_RACES = [("orc", "default"), ("orc", "ashen"), ("orc", "legacy"), ("human", "default"),
              ("goblin_male", "default"), ("naga_male", "default"), ("kobold_female", "default")]
GLOVES = ["plate_gauntlet", "leather_glove"]
OUT = os.path.join(core.ROOT, "tests", "fixtures", "rig2_parity.json")


def _sample(pts):
    step = max(1, len(pts) // 12)
    return step, [[round(float(x), 3), round(float(y), 3)] for x, y in pts[::step]]


def _quads(quads):
    a = np.array(quads, float).reshape(-1, 4)
    return {"n": len(a), "sum": round(float(a.sum()), 2)}


def hands(skel):
    out = {"races": [], "held": []}
    for race_id, variant in HAND_RACES:
        race = core.load_race(race_id, variant)
        hs = core.race_hand_set(race, skel)
        if hs is None or not all(core.hand_rig_ok(race, s) for s in "lr"):
            continue
        parts = [race["parts"]["hand_l"], race["parts"]["hand_r"]]
        row = {"race": race_id, "variant": variant, "rest": _quads(core.rest_quads(race["size"], parts)),
               "sides": {}}
        verts, _ = core.mesh_from_cells(hs["poses"]["grip"]["mesh"])
        for side in "lr":
            step, sample = _sample(core.fist_points(race, hs, side, verts))
            s = {"part": _quads(core.part_quads(race["parts"]["hand_" + side])),
                 "fist_step": step, "fist": sample, "pieces": []}
            for gid in GLOVES:
                item = core.load_item(gid)
                for piece in item.get("hand", {}).get("pieces", []):
                    pv, _ = core.mesh_from_cells(piece["mesh"])
                    for pose in ("open", "grip"):
                        pts = core.glove_piece_points(piece, skel, race, hs, side, pose, pv,
                                                      item.get("authored_side", "r"))
                        pstep, psample = _sample(pts)
                        s["pieces"].append({"item": gid, "piece": piece["name"], "pose": pose,
                                            "step": pstep, "sample": psample})
            row["sides"][side] = s
        out["races"].append(row)
    for item_id in core.list_items():
        item = core.load_item(item_id)
        if item["slot"] in ("main_hand", "off_hand"):
            tail = core.held_tail(item, item["mesh"])
            out["held"].append({"item": item_id, "cells": int(len(tail)), "tail": int(tail.sum()),
                                "has_hold": "hold" in item})
    return out


BODY_RACES = HAND_RACES + [("goblin_male", "legacy"), ("halfling_male", "default"), ("dwarf_female", "default")]


def body(skel):
    out = {"races": [], "encloses": sorted(i for i in core.list_items() if core.load_item(i).get("encloses"))}
    for race_id, variant in BODY_RACES:
        race = core.load_race(race_id, variant)
        quads = core.body_quads(race, skel)
        box = core.head_box(race)
        out["races"].append({"race": race_id, "variant": variant,
                             "quads": _quads(quads) if quads is not None else None,
                             "head_box": [round(v, 2) for v in box] if box else None,
                             "trunk": "trunk" in race.get("overlays", {})})
    return out


def _frame(lx):
    return {"o": [1.0, 2.0], "ax": [1.0, 0.0], "lx": lx, "ly": 3.0}


def variants():
    """Variant inheritance (core.merge_variant): two synthetic parent/child pairs with the merged
    result, and the frame names every real pack resolves to. A new build that drops frames (no legs
    from its camera) must not get them back from its parent; a re-skin must keep them all."""
    base = {"id": "x", "variant": "default", "art": "body.png", "labels": "labels.png", "world_scale": 0.1,
            "size": [100, 80], "pinned": ["torso"], "notes": ["n"], "parts": {"hand_l": {"step": 2, "runs": []}},
            "overlays": {"head": {"file": "head.png", "offset": [1, 2]}},
            "frames": {"torso": _frame(10.0), "leg_l": _frame(4.0), "leg_r": _frame(4.0)}}
    cases = []
    for name, own in (("re-skin", {"inherits": "default", "variant": "ashen", "art": "body.png"}),
                      ("re-skin with a frame", {"inherits": "default", "variant": "scar", "frames": {"torso": _frame(11.0)}}),
                      ("new build, legs gone", {"inherits": "default", "variant": "heavy", "labels": "labels.png",
                                                "size": [120, 90], "frames": {"torso": _frame(12.0)}}),
                      ("new build, not built yet", {"inherits": "default", "variant": "tall", "labels": "labels.png"})):
        cases.append({"name": name, "base": base, "own": own, "merged": core.merge_variant(base, own)})
    packs = [{"race": r, "variant": v, "frames": sorted(core.load_race(r, v)["frames"])} for r, v in core.list_races()]
    return {"cases": cases, "packs": packs}


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
    h = hands(skel)
    core.save_json(OUT, {"cases": cases, "hands": h, "body": body(skel), "variants": variants()})
    print("wrote %s (%d cases, %d hand races, %d held items)" % (os.path.relpath(OUT, core.ROOT), len(cases),
                                                                len(h["races"]), len(h["held"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
