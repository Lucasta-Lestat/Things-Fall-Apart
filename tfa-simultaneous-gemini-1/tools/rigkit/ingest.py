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
  hands      ONE open hand seen from above, fingers toward the right of the image (or
             pass the axis). Only the cuff and the back of the hand are used as art; the
             fingers give the colour ramp (docs/rigging_rewrite.md 3.6)
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


HAND_PIECE_CELLS = 16
HOLD_HALF_FIST = 4.0      # world px: half a typical fist, for items held around their grip point
GUARD_TUCK = 0.3          # world px the back of a guard tucks under the knuckles


def measure_glove(rgba, axis=(1.0, 0.0), wrist=None, knuckle=None, palm_half=None, want=("cuff", "back")):
    """The hand-rig description of a glove (docs 3.6): its colour ramp and up to two rigid
    pieces cut from the art.

      cuff   everything behind the wrist line; sits on the race's wrist frame (uniform)
      back   wrist line -> knuckle line, as wide as the palm; sits on the palm frame,
             knuckles on knuckles and edge on edge

    The fingers are not used: on a race they are that race's own fingers (or the shared
    fist) drawn through `ramp`, which is why a glove covers any hand in any pose.
    The art's cut lines are found from its alpha: the knuckle line is where the hand
    splits into three or more fingers, the wrist is the thinnest section behind it.
    `wrist`, `knuckle` (fractions of the art's length from the cuff end) and `palm_half`
    (px) override the measurement; ingest keeps them when they are pinned in item.json.
    """
    alpha = rgba[:, :, 3]
    op = alpha > 40
    ax = np.asarray(axis, float)
    perp = np.array([-ax[1], ax[0]])
    ys, xs = np.nonzero(op)
    pts = np.stack([xs, ys], axis=1).astype(float)
    u = pts @ ax
    v = pts @ perp
    u0, length = float(u.min()), float(u.max() - u.min() + 1)
    n = int(length)
    ui = np.clip((u - u0).astype(int), 0, n - 1)
    lo = np.full(n, np.inf)
    hi = np.full(n, -np.inf)
    np.minimum.at(lo, ui, v)
    np.maximum.at(hi, ui, v)
    count = np.bincount(ui, minlength=n).astype(float)
    runs = np.zeros(n, int)
    for i in range(n):
        vv = np.sort(v[ui == i])
        runs[i] = 1 + int((np.diff(vv) > 3.0).sum()) if len(vv) else 0
    measured = {}
    if knuckle is None:
        split = runs >= 3
        k = n - 1
        for i in range(int(0.2 * n), n - 4):
            if split[i:i + max(4, n // 40)].all():
                k = i
                break
        knuckle = k / float(n)
        measured["knuckle"] = round(knuckle, 3)
    ki = int(knuckle * n)
    if wrist is None:
        th = _smooth(count, n * 0.04)
        a0 = int(0.25 * ki)
        wi = a0 + int(np.argmin(th[a0:max(a0 + 1, int(0.9 * ki))]))
        if th[int(0.03 * n):wi].max(initial=0.0) < 1.15 * th[wi]:
            wi = int(0.03 * n)          # nothing flares behind it: the art starts at the wrist
        wrist = wi / float(n)
        measured["wrist"] = round(wrist, 3)
    wi = int(wrist * n)
    vc = float((lo[wi] + hi[wi]) / 2.0)
    wrist_half = float(hi[wi] - lo[wi] + 1) / 2.0
    if palm_half is None:
        band = slice(wi + (ki - wi) // 2, ki + 1)
        palm_half = float(np.median(count[band])) / 2.0
        measured["palm_half"] = round(palm_half, 1)
    o = ax * (u0 + wi) + perp * vc
    pieces = []
    uu = (np.indices(alpha.shape)[1] * ax[0] + np.indices(alpha.shape)[0] * ax[1]) - u0
    vv = (np.indices(alpha.shape)[1] * perp[0] + np.indices(alpha.shape)[0] * perp[1])
    overlap = 0.03 * n
    if wi > 0.08 * n and "cuff" in want:
        m = op & (uu <= wi + overlap)
        pieces.append({"name": "cuff", "frame": "wrist",
                       "frames": {"wrist": make_frame(o, ax=ax, lx=wrist_half, ly=wrist_half)},
                       "mesh": core.mesh_cells(np.where(m, alpha, 0), HAND_PIECE_CELLS)})
    if ki - wi > 0.1 * n and "back" in want:
        m = op & (uu >= wi - overlap) & (uu <= ki) & (np.abs(vv - vc) <= palm_half * 1.1)
        pieces.append({"name": "back", "frame": "palm",
                       "frames": {"palm": make_frame(o, ax=ax, lx=ki - wi, ly=palm_half)},
                       "mesh": core.mesh_cells(np.where(m, alpha, 0), HAND_PIECE_CELLS)})
    from .derive import colour_ramp
    sel = (alpha > 230) & (uu >= wi)
    ramp = colour_ramp(rgba[:, :, :3], sel)["ramp"]
    hand = {"ramp": ramp, "cuts": {"wrist": round(wrist, 3), "knuckle": round(knuckle, 3),
                                   "palm_half": round(palm_half, 1)},
            "pieces": pieces}
    return hand, measured


def measure_hold(alpha, total_length, grip_position, grip_length, two_handed=False):
    """Where a fist closes on a held item (upright art, tip at the top).

    The hold point is what lands on the FRONT of the fist (the race's grip frame).
    Items.json `grip_position` is the gameplay grip point; on a sword it sits on the
    crossguard. The fist belongs on the HANDLE, behind the guard (the widest rows near
    the grip point), so the hold point is the back of the guard: the guard then rests
    against the knuckles on any size of hand. An item with no guard (spear, staff) is
    held around the grip point, so its hold point is half a nominal fist (HOLD_HALF_FIST
    world px) toward the tip. Returns the `hold` block; `at` is the hold point as a
    fraction of the length from the tip, `offset` how far that is behind the gameplay
    grip point in world px (negative = toward the tip; ProceduralCharacter's holder
    must account for it in phase 3)."""
    x0, y0, x1, y1 = _bbox(alpha)
    n = int(y1 - y0)
    w = _smooth((alpha[int(y0):int(y1)] > 40).sum(axis=1).astype(float), max(3, n * 0.01))
    g = int(np.clip(grip_position * n, 0, n - 1))
    behind = w[g + int(0.03 * n):]
    med = float(np.percentile(behind, 10)) if len(behind) else float(w[g])   # the handle, not the pommel
    a, b = max(g - int(0.08 * n), 0), min(g + int(0.08 * n), n - 1)
    peak = a + int(np.argmax(w[a:b + 1]))
    start = end = None
    if w[peak] > 1.6 * med:
        i = peak
        while i < n - 1 and w[i] > 1.25 * med:
            i += 1
        start = i
        j = start + max(2, int(0.02 * n))
        while j < n - 1 and w[j] <= 1.4 * med:
            j += 1
        end = j
    if start is None or end - start < 0.03 * n:
        half = 0.5 * grip_length / total_length * n
        start, end = int(max(g - half, 0)), int(min(g + half, n - 1))
        at = max(g - HOLD_HALF_FIST * n / float(total_length), 0.0)
        guard = False
    else:
        at = start + GUARD_TUCK * n / float(total_length)
        guard = True
    k = n / float(total_length)
    hold = {"at": round(at / n, 4), "handle": [round(start / n, 4), round(end / n, 4)],
            "offset": round((at - g) / k, 2), "width": round(float(np.median(w[start:end + 1])) / k, 2),
            "guard": guard, "tail": "under", "layer": "through", "pose": "grip",
            "hands": 2 if two_handed else 1}
    return hold


def measure_back(alpha, spread=1.0, peek=0.3):
    """`spread` = art width in shoulder spans; `peek` = share of the height that shows
    beyond the shoulder line toward the back."""
    x0, y0, x1, y1 = _bbox(alpha)
    half = (x1 - x0) / 2.0 / spread
    return {"back": make_frame(((x0 + x1) / 2.0, y0 + peek * (y1 - y0)), ax=(1.0, 0.0), lx=half, ly=half)}


def measure_held(alpha, total_length, grip_position, hold=None):
    """Upright art, tip at the top. lx = art px per world px. The grip frame's origin is
    the HOLD point (the middle of the handle, see measure_hold), which is what lands in
    the middle of the fist. `grip2` is where a second hand closes on a two-handed item."""
    x0, y0, x1, y1 = _bbox(alpha)
    k = (y1 - y0) / float(total_length)
    at = hold["at"] if hold else grip_position
    o = ((x0 + x1) / 2.0, y0 + at * (y1 - y0))
    out = {"grip": make_frame(o, ax=(0.0, -1.0), lx=k, ly=k)}
    if hold and hold.get("hands") == 2:
        gap = max(9.0, 0.5 * float(hold.get("grip_length", 18.0)))
        out["grip2"] = make_frame((o[0], min(o[1] + gap * k, y1 - 1)), ax=(0.0, -1.0), lx=k, ly=k)
    return out


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
    if opt.get("frames"):
        # frames supplied by the caller (gen_item: the guide proxy's own anatomy), not measured
        frames = {k: dict(v) for k, v in opt["frames"].items()}
        data["frames_from"] = "given"
        if slot == "torso":
            data["sleeve"] = opt.get("sleeve") or "sleeveless"
            data["layer"] = int(opt.get("layer") or 1)
        elif slot == "hands":
            data["authored_side"] = "r"
    elif slot == "torso":
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
        cuts = dict(opt.get("cuts") or {})
        if os.path.exists(os.path.join(out, "item.json")):
            prev = core.load_json(os.path.join(out, "item.json"))
            if "cuts" in prev.get("pinned", []):
                cuts = dict(prev["hand"]["cuts"])
        rgba = np.array(Image.open(dst).convert("RGBA"))
        data["hand"], measured = measure_glove(rgba, axis, cuts.get("wrist"), cuts.get("knuckle"),
                                               cuts.get("palm_half"),
                                               tuple(opt["pieces"]) if opt.get("pieces") is not None
                                               else ("cuff", "back"))
        data["hand"]["axis"] = [float(axis[0]), float(axis[1])]
        if opt.get("fingers"):
            data["hand"]["fingers"] = opt["fingers"]
    elif slot == "back":
        frames = measure_back(alpha, float(opt.get("spread") or 1.0), float(opt.get("peek") or 0.3))
    elif slot in ("main_hand", "off_hand"):
        gp = float(opt.get("grip_position") or 0.75)
        hold = measure_hold(alpha, float(opt["total_length"]), gp, float(opt.get("grip_length") or 12.0),
                            opt.get("grip_style") == "two_handed")
        hold["grip_length"] = float(opt.get("grip_length") or 12.0)
        if opt.get("hold"):
            hold.update(opt["hold"])
        frames = measure_held(alpha, float(opt["total_length"]), gp, hold)
        data["total_length"] = float(opt["total_length"])
        data["grip_position"] = gp
        data["hold"] = hold
    else:
        raise SystemExit("slot %r has no ingest rule yet" % slot)
    for k in ("ease", "scale", "item_ids"):
        if opt.get(k) is not None:
            data[k] = opt[k]
    if opt.get("meta"):                 # extra provenance keys, never geometry
        for k, v in opt["meta"].items():
            data.setdefault(k, v)
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
    # cuts: the wrist and knuckle lines of the art, set by eye (the automatic ones are
    # off on these two: splayed fingers split late, and a thumb widens the palm)
    # leather_glove is soft and cuffless: colour only, no rigid pieces
    "leather_glove": dict(art="gloves and boots/isolated/leather glove.png", slot="hands", pieces=(),
                          cuts=dict(wrist=0.03, knuckle=0.47, palm_half=105.0)),
    "plate_gauntlet": dict(art="gloves and boots/isolated/plate gauntlet.png", slot="hands",
                           axis=(0.0, -1.0), cuts=dict(wrist=0.47, knuckle=0.73, palm_half=115.0)),
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
        own = os.path.join(core.RIGS, "items", item_id, "art.png")
        if not os.path.exists(art) and os.path.exists(own):
            art = own                   # re-ingest an installed pack from its own art
        slot = spec.pop("slot")
        game = spec.pop("game_item", None)
        if game:
            spec["total_length"] = items[game]["total_length"]
            spec["grip_position"] = items[game]["grip_position"]
            spec["grip_length"] = items[game].get("grip_length", 12.0)
            spec["grip_style"] = items[game].get("grip_style", "")
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
    ap.add_argument("--grip-length", type=float, dest="grip_length")
    ap.add_argument("--grip-style", dest="grip_style", help="two_handed adds the grip2 frame")
    ap.add_argument("--wrist", type=float, help="hands: wrist line, fraction of the art's length from the cuff end")
    ap.add_argument("--knuckle", type=float, help="hands: knuckle line, same units")
    ap.add_argument("--pieces", help="hands: rigid pieces to cut from the art: cuff,back (default) or none")
    ap.add_argument("--frames", help="JSON file holding the item's frames ({name: frame}); skips measuring")
    ap.add_argument("--ease", type=float)
    ap.add_argument("--legacy", action="store_true")
    ap.add_argument("--src", default=os.environ.get("RIG_LEGACY_SRC", DEFAULT_SRC))
    a = ap.parse_args(argv)
    if a.legacy:
        ingest_legacy(a.src, [a.id] if a.id else None)
        return 0
    if not (a.id and a.art and a.slot):
        ap.error("need <id> <art.png> --slot, or --legacy")
    opt = {k: v for k, v in vars(a).items() if k not in ("id", "art", "slot", "legacy", "src")}
    cuts = {k: opt.pop(k) for k in ("wrist", "knuckle") if opt.get(k) is not None}
    opt.pop("wrist", None)
    opt.pop("knuckle", None)
    if cuts:
        opt["cuts"] = cuts
    if opt.get("pieces") is not None:
        opt["pieces"] = [x for x in opt["pieces"].split(",") if x and x != "none"]
    if opt.get("frames"):
        opt["frames"] = core.load_json(opt["frames"])
        opt["frames"] = opt["frames"].get("frames", opt["frames"])
    d = ingest(a.id, a.art, a.slot, **opt)
    print("wrote Rigs/items/%s  frames: %s" % (a.id, ", ".join(d["frames"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
