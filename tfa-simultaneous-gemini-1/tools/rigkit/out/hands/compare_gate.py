"""Glove fit-gate numbers before vs after the hand rig.

    python tools/rigkit/out/hands/compare_gate.py

Reads before/fit_before.json (the gate run on the old one-image fit) and fit_after.json.
"""
import json
import os
import statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
B = json.load(open(os.path.join(HERE, "before", "fit_before.json")))["rows"]
A = json.load(open(os.path.join(HERE, "fit_after.json")))["rows"]
FOCUS = [("orc", "default"), ("human", "default"), ("goblin_male", "default")]


def pick(rows, item, race=None, variant=None, pose=None):
    return [r for r in rows if r["item"] == item and (race is None or (r["race"] == race and r["variant"] == variant))
            and (pose is None or r.get("pose") == pose) and "cover" in r]


def line(rows):
    if not rows:
        return "-"
    c = [r["cover"] for r in rows]
    s = [r.get("spill", 0.0) for r in rows]
    t = [r.get("stretch", 1.0) for r in rows]
    return "cover %.2f  spill %.2f  stretch %.2f" % (min(c), max(s), st.mean(t))


def allline(rows):
    c = [r["cover"] for r in rows]
    s = [r.get("spill", 0.0) for r in rows]
    t = [r.get("stretch", 1.0) for r in rows]
    bad = {}
    for r in rows:
        bad[r["status"]] = bad.get(r["status"], 0) + 1
    return "cover min %.2f med %.2f | spill max %.2f | stretch %.2f..%.2f | %s" % (
        min(c), st.median(c), max(s), min(t), max(t), " ".join("%s=%d" % kv for kv in sorted(bad.items())))


for item in ("leather_glove", "plate_gauntlet"):
    print(item)
    for race, variant in FOCUS:
        print("  %-22s before        %s" % (race + "/" + variant, line(pick(B, item, race, variant))))
        for pose in ("open", "grip"):
            print("  %-22s after %-6s  %s" % ("", pose, line(pick(A, item, race, variant, pose))))
    print("  all packs, before        %s" % allline(pick(B, item)))
    for pose in ("open", "grip"):
        print("  all packs, after %-6s  %s" % (pose, allline(pick(A, item, pose=pose))))
for item in ("longsword", "dagger", "spear"):
    rows = [r for r in A if r["item"] == item and "gripped" in r]
    g = [r["gripped"] for r in rows]
    v = [r["visible"] for r in rows]
    print("%-10s gripped min %.2f med %.2f | visible min %.2f med %.2f | %d packs" % (
        item, min(g), st.median(g), min(v), st.median(v), len(rows)))
