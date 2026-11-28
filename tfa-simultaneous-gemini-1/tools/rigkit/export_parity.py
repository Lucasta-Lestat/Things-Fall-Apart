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
HAND_RACES = [("orc", "tilt15_head"), ("orc", "ashen"), ("human", "default"), ("goblin_male", "default"),
              ("naga_male", "default"), ("kobold_female", "default")]
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


BODY_RACES = HAND_RACES + [("orc", "default"), ("halfling_male", "default"), ("dwarf_female", "default")]


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
    core.save_json(OUT, {"cases": cases, "hands": h, "body": body(skel)})
    print("wrote %s (%d cases, %d hand races, %d held items)" % (os.path.relpath(OUT, core.ROOT), len(cases),
                                                                len(h["races"]), len(h["held"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
