"""Item art -> item pack (Rigs/items/<id>/{art.png, item.json}).

    python -m tools.rigkit.ingest <id> <art.png> --slot torso [--sleeve short] ...
    python -m tools.rigkit.ingest --legacy          # the starter catalogue below

The frames are MEASURED from the art's alpha, per slot, so dropping in a new
piece needs no numbers. Anything measured can be overridden by hand in
item.json afterwards (`"frames": {...}`); ingest keeps keys listed in
`"pinned"` when it is re-run.

Authoring conventions the measurements assume (docs/rigging_rewrite.md, art spec):
  torso      T-pose, collar up, sleeves out to the sides, left/right symmetric
  head       seen from above, centred on the skull
  feet       ONE foot, toes toward the bottom of the image
  hands      ONE hand, fingers toward the right of the image
  back       hangs from the top edge (the neck end)
  held       upright, business end at the top
"""
import argparse
import os
import shutil
import sys

import numpy as np
from PIL import Image

from . import core
from .core import make_frame

DEFAULT_SRC = r"C:\dev\Procedural Character from Scratch"

SHORT_SLEEVE_COVERS = 0.85      # share of the upper arm a short sleeve reaches
LONG_SLEEVE_COVERS = 0.97       # share of the whole arm a long sleeve reaches
ARMPIT_DROP = 0.62              # column thickness, relative to the chest, that marks the armpit
MIN_SLEEVE = 0.18               # sleeves shorter than this x half-span are shoulder caps


def load_alpha(path):
    im = Image.open(path).convert("RGBA")
    return im, np.array(im)[:, :, 3]


def _smooth(a, n):
    n = max(1, int(n)) | 1
    return np.convolve(a, np.ones(n) / n, mode="same")


def measure_torso(alpha, sleeve=None, back_share=0.42):
    """Frames for a T-pose garment. Returns (frames, sleeve_kind)."""
    h, w = alpha.shape
    op = alpha > 8
    th = op.sum(axis=0).astype(float)
    cols = np.nonzero(th > 0)[0]
    x0, x1 = int(cols[0]), int(cols[-1])
    cx = float((np.arange(w) * th).sum() / th.sum())
    ths = _smooth(th, (x1 - x0) * 0.03)
    chest = float(np.median(ths[int(cx - 0.12 * (x1 - x0)):int(cx + 0.12 * (x1 - x0)) + 1]))
    top = np.where(op.any(axis=0), op.argmax(axis=0), 0).astype(float)
    bot = np.where(op.any(axis=0), h - 1 - op[::-1].argmax(axis=0), 0).astype(float)
    mid = (top + bot) / 2.0

    def armpit(step):
        x = int(cx)
        edge = x1 if step > 0 else x0
        while x != edge:
            if ths[x] < ARMPIT_DROP * chest:
                return x
            x += step
        return None

    pits = {"l": armpit(-1), "r": armpit(+1)}
    edges = {"l": x0, "r": x1}
    half_guess = (x1 - x0) / 2.0
    sleeves = {}
    for s in ("l", "r"):
        pit = pits[s]
        if pit is None or abs(edges[s] - pit) < MIN_SLEEVE * half_guess:
            sleeves = {}
            break
        sleeves[s] = pit
    frames = {}
    if not sleeves or sleeve == "sleeveless":
        # shoulder caps: the art's own edges are the shoulder seams
        inset = 0.04 * (x1 - x0)
        sx = {"l": x0 + inset, "r": x1 - inset}
        tcols = slice(int(sx["l"]), int(sx["r"]) + 1)
        ytop, ybot = float(top[tcols].min()), float(bot[tcols].max())
        oy = ytop + back_share * (ybot - ytop)
        o = ((sx["l"] + sx["r"]) / 2.0, oy)
        frames["torso"] = make_frame(o, ax=(1.0, 0.0), lx=(sx["r"] - sx["l"]) / 2.0,
                                     ly=ybot - oy, ly_neg=oy - ytop)
        return frames, "sleeveless"

    pts = {}
    for s in ("l", "r"):
        pit, edge = sleeves[s], edges[s]
        step = 1 if s == "r" else -1
        n = abs(edge - pit)
        near = [pit + step * i for i in range(1, max(3, int(0.12 * n)))]
        far = [edge - step * i for i in range(max(3, int(0.15 * n)))]
        a = np.array([pit, float(np.mean(mid[near]))])
        b = np.array([edge, float(np.mean(mid[far]))])
        span = sorted((pit, edge))
        rad = float(np.median(th[span[0]:span[1] + 1])) / 2.0
        pts[s] = (a, b, rad)
    length = float(np.mean([np.hypot(*(pts[s][1] - pts[s][0])) for s in pts]))
    half = abs(pts["r"][0][0] - pts["l"][0][0]) / 2.0
    kind = sleeve or ("long" if length > 1.5 * half else "short")
    for s in ("l", "r"):
        a, b, rad = pts[s]
        if kind == "short":
            frames["upperarm_" + s] = make_frame(a, b, np.hypot(*(b - a)) / SHORT_SLEEVE_COVERS, rad)
        else:
            wrist = a + (b - a) / LONG_SLEEVE_COVERS
            elbow = (a + wrist) / 2.0
            frames["upperarm_" + s] = make_frame(a, elbow, np.hypot(*(elbow - a)), rad)
            frames["forearm_" + s] = make_frame(elbow, wrist, np.hypot(*(wrist - elbow)), rad)
    o = (pts["l"][0] + pts["r"][0]) / 2.0
    tcols = slice(int(pts["l"][0][0]), int(pts["r"][0][0]) + 1)
    ytop, ybot = float(top[tcols].min()), float(bot[tcols].max())
    torso = make_frame(o, pts["r"][0], half, ybot - o[1], ly_neg=o[1] - ytop)
    return dict(torso=torso, **frames), kind


def _bbox(alpha):
    ys, xs = np.nonzero(alpha > 8)
    return float(xs.min()), float(ys.min()), float(xs.max() + 1), float(ys.max() + 1)


def measure_head(alpha, skull=1.0):
    """`skull` = share of the art's width the skull itself occupies (a brim makes it < 1)."""
    x0, y0, x1, y1 = _bbox(alpha)
    r = (x1 - x0) / 2.0 * skull
    return {"head": make_frame(((x0 + x1) / 2.0, (y0 + y1) / 2.0), ax=(1.0, 0.0), lx=r, ly=r)}


def measure_foot(alpha):
    x0, y0, x1, y1 = _bbox(alpha)
    return {"foot": make_frame(((x0 + x1) / 2.0, (y0 + y1) / 2.0), ax=(0.0, 1.0),
                               lx=(y1 - y0) / 2.0, ly=(x1 - x0) / 2.0)}


def measure_hand(alpha, axis=(1.0, 0.0)):
    x0, y0, x1, y1 = _bbox(alpha)
    ax = np.asarray(axis, float)
    c = np.array([(x0 + x1) / 2.0, (y0 + y1) / 2.0])
    along = (x1 - x0) if abs(ax[0]) > abs(ax[1]) else (y1 - y0)
    across = (y1 - y0) if abs(ax[0]) > abs(ax[1]) else (x1 - x0)
    wrist = c - ax * along / 2.0
    # mean half-thickness (area / 2L), the same measure derive.py uses for limbs
    rad = float((alpha > 8).sum()) / (2.0 * along)
    return {"hand": make_frame(wrist, ax=ax, lx=along, ly=rad)}


def measure_back(alpha, spread=1.0, peek=0.3):
    """`spread` = art width in shoulder spans; `peek` = share of the height that shows
    beyond the shoulder line toward the back."""
    x0, y0, x1, y1 = _bbox(alpha)
    half = (x1 - x0) / 2.0 / spread
    return {"back": make_frame(((x0 + x1) / 2.0, y0 + peek * (y1 - y0)), ax=(1.0, 0.0), lx=half, ly=half)}


def measure_held(alpha, total_length, grip_position):
    """Upright art, tip at the top. lx = art px per world px."""
    x0, y0, x1, y1 = _bbox(alpha)
    k = (y1 - y0) / float(total_length)
    o = ((x0 + x1) / 2.0, y0 + grip_position * (y1 - y0))
    return {"grip": make_frame(o, ax=(0.0, -1.0), lx=k, ly=k)}


def ingest(item_id, art_path, slot, **opt):
    skel = core.skeleton()
    if slot not in skel["slots"]:
        raise SystemExit("unknown slot %r (have: %s)" % (slot, ", ".join(skel["slots"])))
    out = os.path.join(core.RIGS, "items", item_id)
    os.makedirs(out, exist_ok=True)
    dst = os.path.join(out, "art.png")
    if os.path.abspath(art_path) != os.path.abspath(dst):
        Image.open(art_path).convert("RGBA").save(dst, optimize=True)
    _, alpha = load_alpha(dst)
    data = {"id": item_id, "slot": slot, "art": "art.png",
            "size": [int(alpha.shape[1]), int(alpha.shape[0])]}
    if slot == "torso":
        frames, kind = measure_torso(alpha, opt.get("sleeve"))
        data["sleeve"] = kind
        data["layer"] = int(opt.get("layer") or 1)
    elif slot == "head":
        frames = measure_head(alpha, float(opt.get("skull") or 1.0))
        if opt.get("skull"):
            data["skull"] = float(opt["skull"])
    elif slot == "feet":
        frames = measure_foot(alpha)
    elif slot == "hands":
        axis = opt.get("axis") or (1.0, 0.0)
        frames = measure_hand(alpha, axis)
        data["authored_side"] = "r"
    elif slot == "back":
        frames = measure_back(alpha, float(opt.get("spread") or 1.0), float(opt.get("peek") or 0.3))
    elif slot in ("main_hand", "off_hand"):
        frames = measure_held(alpha, float(opt["total_length"]), float(opt.get("grip_position") or 0.75))
        data["total_length"] = float(opt["total_length"])
    else:
        raise SystemExit("slot %r has no ingest rule yet" % slot)
    for k in ("ease", "scale", "item_ids"):
        if opt.get(k) is not None:
            data[k] = opt[k]
    # keep hand-pinned frames from a previous run
    old_path = os.path.join(out, "item.json")
    if os.path.exists(old_path):
        old = core.load_json(old_path)
        for name in old.get("pinned", []):
            frames[name] = old["frames"][name]
        if old.get("pinned"):
            data["pinned"] = old["pinned"]
    data["frames"] = frames
    data["mesh"] = core.mesh_cells(alpha)
    core.save_json(old_path, data)
    return data


# The proof catalogue: enough of each kind to exercise every fit path.
# art paths are relative to the old generator repo (or res:// for game art).
LEGACY = {
    "peasants_stained_shirt": dict(art="peasants_stained_shirt.png", slot="torso", layer=1,
                                   item_ids=["peasant's_stained_shirt"]),
    "nobles_blouse": dict(art="nobles_blouse.png", slot="torso", layer=1, item_ids=["noble's_blouse"]),
    "dark_robes": dict(art="dark_robes.png", slot="torso", layer=2, item_ids=["dark_robes"]),
    "padded_vest": dict(art="padded_vest.png", slot="torso", layer=2, item_ids=["padded_vest"]),
    "leather_armor": dict(art="Leather Armor.png", slot="torso", layer=2, item_ids=["leather_armor"]),
    "chain_shirt": dict(art="chain shirt.png", slot="torso", layer=3),
    "legionnaires_armor": dict(art="legionnaires_armor.png", slot="torso", layer=3,
                               item_ids=["legionnaires_armor"]),
    "breastplate": dict(art="breastplate.png", slot="torso", layer=4, item_ids=["breastplate_2"]),
    "kettle_helm": dict(art="item art/kettle_helm.png", slot="head", skull=0.62, item_ids=["kettle_helm"]),
    "great_helm": dict(art="helmets/isolated/great helm.png", slot="head"),
    "dark_hood": dict(art="item art/dark_hood.png", slot="head", item_ids=["dark_hood"]),
    "golden_helm": dict(art="item art/golden_helm.png", slot="head", item_ids=["golden_crown_helm"]),
    "leather_boot": dict(art="gloves and boots/isolated/leather boot.png", slot="feet",
                         item_ids=["leather_boots"]),
    "plate_sabaton": dict(art="gloves and boots/isolated/plate sabaton.png", slot="feet"),
    "leather_glove": dict(art="gloves and boots/isolated/leather glove.png", slot="hands"),
    "plate_gauntlet": dict(art="gloves and boots/isolated/plate gauntlet.png", slot="hands",
                           axis=(0.0, -1.0)),
    "red_cape": dict(art="item art/red_cape.png", slot="back", spread=1.5, peek=0.30,
                     item_ids=["red_travel_cape"]),
    "adventurer_pack": dict(art="item art/adventurer_pack.png", slot="back", spread=0.95, peek=0.35,
                            item_ids=["adventurer's_pack"]),
    "longsword": dict(art="res://Items/longsword.png", slot="main_hand", game_item="longsword"),
    "dagger": dict(art="res://Items/dagger.png", slot="main_hand", game_item="dagger"),
    "spear": dict(art="res://Items/spear.png", slot="main_hand", game_item="spear"),
}


def ingest_legacy(src, only=None):
    items = {i.get("id"): i for i in core.load_json(os.path.join(core.ROOT, "data", "Items.json"))}
    for item_id, spec in LEGACY.items():
        if only and item_id not in only:
            continue
        spec = dict(spec)
        art = spec.pop("art")
        art = os.path.join(core.ROOT, art[6:]) if art.startswith("res://") else os.path.join(src, art)
        slot = spec.pop("slot")
        game = spec.pop("game_item", None)
        if game:
            spec["total_length"] = items[game]["total_length"]
            spec["grip_position"] = items[game]["grip_position"]
            spec["item_ids"] = [game]
        d = ingest(item_id, art, slot, **spec)
        print("[ok ] %-24s %-9s frames: %s%s" % (item_id, slot, ", ".join(d["frames"]),
                                                ("  sleeve=" + d["sleeve"]) if "sleeve" in d else ""))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("id", nargs="?")
    ap.add_argument("art", nargs="?")
    ap.add_argument("--slot")
    ap.add_argument("--layer", type=int)
    ap.add_argument("--sleeve", choices=["sleeveless", "short", "long"])
    ap.add_argument("--skull", type=float)
    ap.add_argument("--spread", type=float)
    ap.add_argument("--peek", type=float)
    ap.add_argument("--total-length", type=float, dest="total_length")
    ap.add_argument("--grip-position", type=float, dest="grip_position")
    ap.add_argument("--legacy", action="store_true")
    ap.add_argument("--src", default=os.environ.get("RIG_LEGACY_SRC", DEFAULT_SRC))
    a = ap.parse_args(argv)
    if a.legacy:
        ingest_legacy(a.src, [a.id] if a.id else None)
        return 0
    if not (a.id and a.art and a.slot):
        ap.error("need <id> <art.png> --slot, or --legacy")
    opt = {k: v for k, v in vars(a).items() if k not in ("id", "art", "slot", "legacy", "src")}
    d = ingest(a.id, a.art, a.slot, **opt)
    print("wrote Rigs/items/%s  frames: %s" % (a.id, ", ".join(d["frames"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
