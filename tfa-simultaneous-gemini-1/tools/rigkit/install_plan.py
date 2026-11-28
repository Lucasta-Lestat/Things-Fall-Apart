"""Install a guide paint-over (gen_plan candidate) as a race pack.

    python -m tools.rigkit.install_plan <painting.png> --race orc --variant tilt15
        [--guide PREFIX]            default: the painting's own tag, "<tag>_<i>.png" -> "<tag>.guide"
        [--match orc/legacy]        pack whose in-game size the new pack must have (default: <race>/legacy
                                    when it exists, else <race>/default)
        [--match-by span]           span | shoulders | head | arm   (see MEASURES)
        [--world-scale X]           skip the match and set it
        [--keep-legs] [--keep-shoulder-cut] [--no-head-snap] [--debug DIR]
    python -m tools.rigkit.install_plan --sheet OUT.jpg --race orc --variant tilt15 [--match orc/default]
        side-by-side contact sheet, matched pack | new pack, one outfit per row (no install)

Writes Rigs/races/<race>/<variant>/{body.png, labels.png, race.json} and runs
build_race on it (which adds head.png and the derived frames).

What it does, in order:

  key      the flat grey ground becomes alpha from the painting's OWN silhouette. Grey,
           outline-free pixels reachable from the ground (the contact shadow) are peeled
           off; the 1 px rim gets a matte alpha and the colour of the paint just inside
           it, so no grey survives in the edge.
  labels   the guide's label map is the starting point (same canvas as the painting),
           then three corrections, each a property of paint-overs in general:
             * shoulder: the guide draws the deltoid as trunk with the arm capsule
               ending inside it. Trunk pixels outboard of the capsule's inner end become
               upper arm, so the shoulder seam is the armpit line, as in the legacy packs.
             * legs: a tilted guide shows a sliver of thigh beside the belly. Too small
               to carry a leg frame, so the leg label is dropped and those pixels go to
               the nearest remaining label (trunk or foot). derive.py then reports "legs
               not visible from above" by its ordinary rule.
             * head: the model paints the head a little larger than the guide's (the jaw
               drops past it). The face/trunk boundary is re-found on the painting's own
               contour line by a watershed between a core of the guide head and the
               trunk well away from it.
           Finally every pixel takes the label of the nearest labelled pixel and the map
           is cut to the opaque silhouette: labels cover alpha >= 128 and nothing else.
  resample crop to the silhouette + PACK_MARGIN, long side PACK_SIDE (section 4.1).
  scale    world_scale is solved so one measure (default: fingertip span) is the same
           number of world px as on --match. The other measures are printed, because a
           new camera cannot match all of them at once.

This tool imports from gen_plan but never edits it.
"""
import argparse
import os
import re
import sys

import cv2
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

from . import build_race, core
from .derive import PALETTE, derive_frames, label_masks

PACK_SIDE = 1024
PACK_MARGIN = 9           # px of clear canvas around the silhouette, as in the legacy packs
NAMES = [None] + list(PALETTE)          # label index 0 = background
RGB = np.array([(0, 0, 0)] + [PALETTE[n] for n in PALETTE], np.uint8)
IDX = {n: i for i, n in enumerate(NAMES)}
SHADOW_REACH = 6          # px the contact-shadow peel may reach inside the guide's silhouette
HEAD_BAND = 0.55          # head snap: search this share of the skull radius either side of the guide's edge


# ---------------------------------------------------------------- key

def key(rgb, gmask=None):
    """rgb: HxWx3 uint8 painting on flat grey. Returns (rgb float HxWx3 with the ground
    replaced by bled paint, alpha float HxW in 0..1, info).

    gmask: the guide's silhouette, when there is one. It makes the key safe for pale grey paint
    (white feathers, silver hair, ashen skin), which is as grey as the ground: paint enclosed by the
    contour line is kept wherever the guide has figure, and the contact-shadow peel never reaches
    more than SHADOW_REACH px inside the guide's silhouette."""
    a = rgb.astype(np.float32)
    k = 24
    corners = np.concatenate([a[:k, :k].reshape(-1, 3), a[:k, -k:].reshape(-1, 3),
                              a[-k:, :k].reshape(-1, 3), a[-k:, -k:].reshape(-1, 3)])
    bg = np.median(corners, 0)
    d = np.abs(a - bg).max(-1)
    chroma = a.max(-1) - a.min(-1)
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    fg = (chroma > 14) | (d > 45)
    if gmask is not None:
        # grey paint inside a contour: fill what the line encloses BEFORE the opening can break a thin line
        fg = fg | (ndi.binary_fill_holes(ndi.binary_closing(fg, iterations=1)) & gmask)
    fg = ndi.binary_opening(fg, iterations=1)
    lab, n = ndi.label(fg)
    if not n:
        raise ValueError("nothing but ground in the painting")
    fg = lab == (1 + int(np.argmax(ndi.sum(fg, lab, range(1, n + 1)))))
    closed = ndi.binary_closing(fg, iterations=2)
    filled = ndi.binary_fill_holes(closed)
    # an enclosed patch of plain ground (between an arm and the trunk, say) stays a hole,
    # unless the guide has figure there (then it is grey paint)
    holes, hn = ndi.label(filled & ~closed)
    for i in range(1, hn + 1):
        m = holes == i
        if m.sum() >= 40 and float(d[m].mean()) < 12 and (gmask is None or float(gmask[m].mean()) < 0.5):
            filled &= ~m
    fg = filled
    # contact shadow: grey (no chroma), lighter than the contour line, and connected to
    # the ground. Peeling stops at the dark outline, so paint is never eaten.
    shadowlike = fg & (chroma < 12) & (lum > 72) & (lum < float(bg.mean()) + 6)
    if gmask is not None:
        shadowlike &= ~ndi.binary_erosion(gmask, iterations=SHADOW_REACH)
    seed = ndi.binary_dilation(~fg, iterations=1) & shadowlike
    shadow = ndi.binary_propagation(seed, mask=shadowlike)
    fg &= ~shadow
    fg = ndi.binary_opening(fg, iterations=1)
    lab, n = ndi.label(fg)
    fg = lab == (1 + int(np.argmax(ndi.sum(fg, lab, range(1, n + 1)))))

    # matte the rim: obs = alpha * F + (1 - alpha) * ground, F = the paint 2 px inside
    core_m = ndi.binary_erosion(fg, iterations=2)
    _, (iy, ix) = ndi.distance_transform_edt(~core_m, return_indices=True)
    F = a[iy, ix]
    rim = ndi.binary_dilation(fg, iterations=1) & ~core_m
    num = ((a - bg) * (F - bg)).sum(-1)
    den = np.maximum(((F - bg) ** 2).sum(-1), 1.0)
    alpha = np.where(core_m, 1.0, 0.0).astype(np.float32)
    alpha[rim] = np.clip(num[rim] / den[rim], 0.0, 1.0)
    out = np.where(core_m[:, :, None], a, F)          # rim and ground carry clean paint colour
    info = {"ground_rgb": [int(round(v)) for v in bg], "shadow_px": int(shadow.sum()),
            "silhouette_px": int(fg.sum())}
    return out, alpha, info


# ---------------------------------------------------------------- labels

def label_index(labels_rgb):
    """Guide label map -> index image (0 = background), nearest palette colour within tolerance."""
    img = labels_rgb.astype(np.int32)
    dist = np.abs(img[:, :, None, :] - RGB[None, None].astype(np.int32)).sum(-1)
    idx = dist.argmin(-1)
    idx[dist.min(-1) > 60] = 0
    return idx.astype(np.int32)


def fix_shoulders(idx, notes):
    """Deltoid -> upper arm: trunk pixels outboard of the arm capsule's inner end."""
    body = IDX["body"]
    ys, xs = np.nonzero(idx > 0)
    cx = (xs.min() + xs.max()) / 2.0
    xx = np.arange(idx.shape[1])[None, :]
    for s, sign in (("l", -1), ("r", 1)):
        up = idx == IDX["upperarm_" + s]
        if not up.any():
            continue
        cols = np.nonzero(up.any(0))[0]
        inner = cols.max() if sign < 0 else cols.min()
        out = (idx == body) & ((xx < inner) if sign < 0 else (xx > inner))
        # only the mass attached to the arm, never a far hip or a foot-side sliver
        lab, n = ndi.label(out | up)
        keep = np.zeros_like(out)
        for i in np.unique(lab[up]):
            keep |= lab == i
        moved = out & keep
        idx[moved] = IDX["upperarm_" + s]
        notes.append("shoulder %s: %d px of trunk outboard of x=%d relabelled upper arm (cut was inside the deltoid)"
                     % (s, int(moved.sum()), int(inner)))
    return idx


def drop_legs(idx, notes):
    n = 0
    for s in ("l", "r"):
        m = idx == IDX["leg_" + s]
        n += int(m.sum())
        idx[m] = 0
    if n:
        notes.append("legs: %d px of thigh sliver folded into the nearest label (no leg frame from this camera)" % n)
    return idx


def voronoi(idx):
    """Every pixel takes the label of the nearest labelled pixel."""
    _, (iy, ix) = ndi.distance_transform_edt(idx == 0, return_indices=True)
    return idx[iy, ix]


def snap_head(idx, rgb, alpha, skull_r, notes):
    """Move the head/trunk boundary onto the painted contour. `idx` must be full-coverage."""
    head_ids = [IDX[n] for n in ("face", "hair") if (idx == IDX[n]).any()]
    if not head_ids:
        return idx
    fg = alpha >= 0.5
    head = np.isin(idx, head_ids) & fg
    band = max(4, int(round(HEAD_BAND * skull_r)))
    inner = max(2, int(round(0.10 * skull_r)))
    sure_head = ndi.binary_erosion(head, iterations=inner)
    near = ndi.binary_dilation(head, iterations=band)
    trunk = fg & (idx == IDX["body"])
    sure_trunk = trunk & ~near
    markers = np.zeros(idx.shape, np.int32)
    markers[~fg] = 1
    markers[fg & ~trunk & ~head] = 1          # arms, feet: never part of this contest
    markers[sure_trunk] = 2
    markers[sure_head] = 3
    img = cv2.GaussianBlur(np.clip(rgb, 0, 255).astype(np.uint8), (0, 0), 1.2)
    cv2.watershed(img, markers)
    won = (markers == 3) | ((markers == -1) & ndi.binary_dilation(markers == 3, iterations=1))
    new_head = (ndi.binary_opening(won, iterations=1) | sure_head) & fg
    # close pinholes only: trunk seen through a horn's curl or between a lock and the neck stays trunk
    gaps, gn = ndi.label(ndi.binary_fill_holes(new_head) & ~new_head)
    for i in range(1, gn + 1):
        g = gaps == i
        if int(g.sum()) < 0.02 * float(head.sum()) or not (trunk & g).any():
            new_head |= g & fg
    # guard: a watershed that leaks down the chest is worse than the guide's own cut
    grow = float(new_head.sum()) / max(float(head.sum()), 1.0)
    if not (0.8 <= grow <= 1.6):
        notes.append("head snap rejected (area x%.2f); kept the guide's head label" % grow)
        return idx
    main = max(head_ids, key=lambda i: int((idx == i).sum()))
    out = idx.copy()
    out[np.isin(idx, head_ids) & ~new_head & (trunk | head)] = IDX["body"]
    out[new_head & (idx == IDX["body"])] = main
    notes.append("head: label snapped to the painted contour (area x%.2f of the guide's head)" % grow)
    return out


TIDY_FREE = ("over_garment", "hair", "face")   # labels that are honestly several blobs


def tidy(idx, min_keep=0.25):
    """A label is one blob: stray islands of a label go to the label around them. Not for
    over-garment anatomy (a tail shows on both sides of the trunk, wings come in pairs), nor for the
    head's labels (locks, braids, horns and ears stand apart from the skull); those only lose specks."""
    out = idx.copy()
    for i in np.unique(idx):
        if i == 0:
            continue
        lab, n = ndi.label(idx == i)
        if NAMES[i] in TIDY_FREE:
            if n > 1:
                sizes = ndi.sum(idx == i, lab, range(1, n + 1))
                for j, sz in enumerate(sizes, 1):
                    if sz < 30:
                        out[lab == j] = -1
            continue
        if n <= 1:
            continue
        sizes = ndi.sum(idx == i, lab, range(1, n + 1))
        big = sizes.max()
        for j, sz in enumerate(sizes, 1):
            if sz < min_keep * big:
                out[lab == j] = -1
    if (out == -1).any():
        hole = out == -1
        tmp = out.copy()
        tmp[hole] = 0
        _, (iy, ix) = ndi.distance_transform_edt((tmp == 0), return_indices=True)
        fill = tmp[iy, ix]
        out[hole] = fill[hole]
    return out


def shoulder_pins(lab, frames, notes, reach=6, tol=1.5):
    """derive.py finds the shoulder seam where the upper arm touches the trunk OR over-garment
    anatomy. A tail or a wing that passes behind an upper arm in the picture drags that seam (and
    with it the torso frame every garment hangs on) toward itself. When that happens the torso, back
    and upper-arm frames are measured again with the over-garment pixels near the arms left out, and
    pinned, so build_race keeps them. Returns {frame name: frame} (empty when nothing touches)."""
    og = np.abs(lab.astype(np.int32) - np.array(PALETTE["over_garment"], np.int32)).sum(2) <= 40
    if not og.any():
        return {}
    arms = np.zeros(og.shape, bool)
    for s in "lr":
        arms |= np.abs(lab.astype(np.int32) - np.array(PALETTE["upperarm_" + s], np.int32)).sum(2) <= 40
    near = og & ndi.binary_dilation(arms, iterations=reach)
    if not near.any():
        return {}
    clean = lab.copy()
    clean[near] = 0
    try:
        f2, _ = derive_frames(clean, 1.0)
    except Exception as e:                       # the arm hangs on the over-garment form alone: keep derive's answer
        notes.append("over-garment anatomy touches an upper arm and the seam could not be re-measured (%s)" % e)
        return {}
    names = ("torso", "back", "upperarm_l", "upperarm_r")
    moved = max(float(np.hypot(*(np.array(frames[n]["o"]) - np.array(f2[n]["o"])))) for n in names)
    if moved <= tol:
        return {}
    notes.append("over-garment anatomy touches an upper arm: torso, back and upper-arm frames pinned to the "
                 "trunk's own seam (it had moved %.1f px)" % moved)
    return {n: f2[n] for n in names}


# ---------------------------------------------------------------- scale

def measures(frames):
    """World-comparable lengths of a pack, in pack px."""
    tips = []
    for s in ("l", "r"):
        h = frames["hand_" + s]
        tips.append(np.array(h["o"]) + np.array(h["ax"]) * h["lx"])
    arm = np.mean([frames[p + s]["lx"] for s in ("_l", "_r") for p in ("upperarm", "forearm", "hand")]) * 3
    return {"span": float(np.hypot(*(tips[1] - tips[0]))),       # fingertip to fingertip
            "shoulders": 2.0 * float(frames["torso"]["lx"]),     # shoulder seam to shoulder seam
            "head": 2.0 * float(frames["head"]["lx"]),           # skull diameter
            "arm": float(arm)}                                   # shoulder seam -> fingertip, along the bones


# ---------------------------------------------------------------- install

def guide_prefix_for(painting):
    d, name = os.path.split(painting)
    m = re.match(r"(.+)_\d+(?:_dome)?\.png$", name)
    if not m:
        raise ValueError("cannot tell the guide from %r: pass --guide PREFIX" % name)
    return os.path.join(d, m.group(1) + ".guide")


def install(painting, race, variant, guide=None, match=None, match_by="span", world_scale=None,
            keep_legs=False, keep_shoulder_cut=False, head_snap=True, debug=None):
    guide = guide or guide_prefix_for(painting)
    stats = core.load_json(guide + ".json")
    rgb = np.asarray(Image.open(painting).convert("RGB"))
    glab = np.asarray(Image.open(guide + "_labels.png").convert("RGB"))
    gmask = np.asarray(Image.open(guide + "_mask.png").convert("L")) > 127
    if rgb.shape[:2] != glab.shape[:2]:
        rgb = np.asarray(Image.fromarray(rgb).resize(glab.shape[1::-1], Image.LANCZOS))
    notes = []
    paint, alpha, kinfo = key(rgb, gmask)
    sil = alpha >= 0.5
    iou = float((sil & gmask).sum()) / float((sil | gmask).sum())
    if iou < 0.85:
        raise ValueError("painting and guide silhouettes overlap only %.2f: wrong guide?" % iou)

    idx = label_index(glab)
    if not keep_shoulder_cut:
        idx = fix_shoulders(idx, notes)
    if not keep_legs:
        idx = drop_legs(idx, notes)
    idx = voronoi(idx)
    if head_snap:
        idx = snap_head(idx, paint, alpha, float(stats.get("skull_r_px", 60.0)), notes)

    # crop + resample to the pack convention
    ys, xs = np.nonzero(alpha > 0)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    k = float(PACK_SIDE - 2 * PACK_MARGIN) / float(max(x1 - x0, y1 - y0))
    m = int(round(PACK_MARGIN / k))
    x0, y0 = max(x0 - m, 0), max(y0 - m, 0)
    x1, y1 = min(x1 + m, alpha.shape[1]), min(y1 + m, alpha.shape[0])
    k = min(k, float(PACK_SIDE) / float(max(x1 - x0, y1 - y0)))
    w, h = int(round((x1 - x0) * k)), int(round((y1 - y0) * k))
    interp = cv2.INTER_AREA if k < 1.0 else cv2.INTER_CUBIC
    pa = cv2.resize(alpha[y0:y1, x0:x1], (w, h), interpolation=interp)
    pm = cv2.resize(paint[y0:y1, x0:x1] * alpha[y0:y1, x0:x1, None], (w, h), interpolation=interp)
    bleed = cv2.resize(paint[y0:y1, x0:x1], (w, h), interpolation=interp)
    col = np.where(pa[:, :, None] > 1e-3, pm / np.maximum(pa[:, :, None], 1e-3), bleed)
    a8 = np.clip(np.round(pa * 255.0), 0, 255).astype(np.uint8)
    a8[a8 < 6] = 0
    body = np.dstack([np.clip(np.round(col), 0, 255).astype(np.uint8), a8])
    opaque = a8 >= 128
    li = cv2.resize(idx[y0:y1, x0:x1].astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST).astype(np.int32)
    li[~opaque] = 0
    li = tidy(li)
    li[~opaque] = 0
    assert ((li > 0) == opaque).all()
    lab = RGB[li]

    out = core.race_dir(race, variant)
    os.makedirs(out, exist_ok=True)
    Image.fromarray(body, "RGBA").save(os.path.join(out, "body.png"), optimize=True)
    Image.fromarray(lab, "RGB").save(os.path.join(out, "labels.png"), optimize=True)

    # world scale: same in-game size as the matched pack, by one stated measure
    frames, _ = derive_frames(lab, 1.0)
    pins = shoulder_pins(lab, frames, notes)
    frames.update(pins)
    mine = measures(frames)
    ratios = {}
    ref_ws = None
    if match:
        mr, mv = (match.split("/") + ["default"])[:2]
        ref = core.load_race(mr, mv)
        ref_ws = float(ref["world_scale"])
        theirs = measures(ref["frames"])
        ratios = {name: theirs[name] * ref_ws / mine[name] for name in mine}
    if world_scale is None:
        if not ratios:
            raise ValueError("need --match or --world-scale")
        world_scale = ratios[match_by]
    path = os.path.join(out, "race.json")
    old = core.load_json(path) if os.path.exists(path) else {}
    data = {"id": race, "variant": variant, "art": "body.png", "labels": "labels.png",
            "size": [w, h], "world_scale": round(float(world_scale), 5), "facing": "south"}
    if match:
        data.update({k_: ref[k_] for k_ in ("race", "gender") if k_ in ref})
    data["source"] = "gen_plan paint-over: %s (guide %s, tilt %s deg)" % (
        os.path.basename(painting), os.path.basename(guide), stats.get("tilt_deg", "?"))
    data["install"] = {"match": match, "match_by": match_by, "guide_iou": round(iou, 4),
                       "px_per_source_px": round(k, 5), "key": kinfo, "label_fixes": notes}
    hand = [n for n in old.get("pinned", []) if n not in old.get("auto_pinned", [])]    # set by a person: kept
    kept = {n: old["frames"][n] for n in hand}
    kept.update({n: f for n, f in pins.items() if n not in kept})
    if kept:
        data["pinned"] = sorted(kept)
        data["frames"] = kept
    if pins:
        data["auto_pinned"] = sorted(n for n in pins if n not in hand)
    core.save_json(path, data)
    _, msg = build_race.build(race, variant)

    if debug:
        os.makedirs(debug, exist_ok=True)
        ov = (body[:, :, :3] * 0.45 + lab * 0.55).astype(np.uint8)
        ov[~opaque] = (40, 40, 40)
        Image.fromarray(ov).save(os.path.join(debug, "%s_%s_labels_over.png" % (race, variant)))
        for name, bgc in (("white", 255), ("black", 0), ("magenta", None)):
            c = np.array([255, 0, 255] if bgc is None else [bgc] * 3, np.float32)
            af = a8[:, :, None] / 255.0
            comp = (body[:, :, :3] * af + c * (1 - af)).astype(np.uint8)
            Image.fromarray(comp).save(os.path.join(debug, "%s_%s_on_%s.png" % (race, variant, name)))

    report = {"dir": out, "size": [w, h], "world_scale": data["world_scale"], "guide_iou": iou,
              "measures_px": mine, "match_ratios": ratios, "ref_world_scale": ref_ws,
              "notes": notes, "key": kinfo, "build": msg}
    return report


SHEET_OUTFITS = [
    ("bare", []),
    ("shirt (torso garment)", ["peasants_stained_shirt"]),
    ("blouse (torso garment)", ["nobles_blouse"]),
    ("breastplate (body armour)", ["breastplate"]),
    ("legionnaire + kettle helm", ["legionnaires_armor", "kettle_helm"]),
    ("great helm", ["great_helm"]),
    ("leather boots + gloves", ["leather_boot", "leather_glove"]),
    ("sabatons + gauntlets", ["plate_sabaton", "plate_gauntlet"]),
    ("longsword (held)", ["longsword"]),
    ("pack (back)", ["adventurer_pack"]),
    ("robes + hood + cape", ["dark_robes", "dark_hood", "red_cape"]),
    ("knight, everything", ["breastplate", "great_helm", "plate_sabaton", "plate_gauntlet", "longsword"]),
]


def compare_sheet(packs, out_path, outfits=None, px_per_world=3.0, tile=(760, 300)):
    """One column per pack, one row per outfit, every tile at the SAME world scale
    (px_per_world sheet px per world px), so a size mismatch between packs is visible."""
    from PIL import ImageDraw
    from .render import compose
    from .sheet import BG
    outfits = outfits or SHEET_OUTFITS
    skel = core.skeleton()
    side, head = 190, 24
    sheet = Image.new("RGB", (side + tile[0] * len(packs), head + tile[1] * len(outfits)), (30, 32, 30))
    dr = ImageDraw.Draw(sheet)
    for j, (race, variant) in enumerate(packs):
        dr.text((side + j * tile[0] + 6, 6), "%s/%s" % (race, variant), fill=(230, 230, 220))
    for i, (name, items) in enumerate(outfits):
        dr.text((6, head + i * tile[1] + 6), name, fill=(230, 230, 220))
        dr.text((6, head + i * tile[1] + 22), "\n".join(items), fill=(170, 170, 160))
        for j, (race, variant) in enumerate(packs):
            img, _, canvas = compose(race, items, variant, skel, background=BG)
            k = px_per_world * float(canvas.data["world_scale"])
            small = cv2.resize(img[:, :, :3], None, fx=k, fy=k, interpolation=cv2.INTER_AREA)
            # centre the tile on the torso origin, a little above the tile's middle
            o = (np.array(canvas.data["frames"]["torso"]["o"]) + canvas.pad) * k
            t = np.zeros((tile[1], tile[0], 3), np.uint8)
            t[:] = BG
            x0, y0 = int(round(o[0] - tile[0] / 2.0)), int(round(o[1] - tile[1] * 0.38))
            sx0, sy0 = max(x0, 0), max(y0, 0)
            sx1, sy1 = min(x0 + tile[0], small.shape[1]), min(y0 + tile[1], small.shape[0])
            t[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = small[sy0:sy1, sx0:sx1]
            sheet.paste(Image.fromarray(t), (side + j * tile[0], head + i * tile[1]))
            for n, (iid, miss) in enumerate(canvas.skipped):
                dr.text((side + j * tile[0] + 6, head + (i + 1) * tile[1] - 18 - 14 * n),
                        "%s not worn: no %s" % (iid, ", ".join(miss)), fill=(255, 190, 120))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    sheet.save(out_path, quality=90)
    return out_path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("painting", nargs="?")
    ap.add_argument("--sheet", default=None, help="write a matched-pack | new-pack contact sheet here")
    ap.add_argument("--race", required=True)
    ap.add_argument("--variant", required=True)
    ap.add_argument("--guide", default=None, help="guide prefix: <prefix>_labels.png, _mask.png, .json")
    ap.add_argument("--match", default=None, help="race[/variant] to match in-game size with (default <race>/legacy if it exists, else <race>/default)")
    ap.add_argument("--match-by", default="span", choices=["span", "shoulders", "head", "arm"])
    ap.add_argument("--world-scale", type=float, default=None)
    ap.add_argument("--keep-legs", action="store_true")
    ap.add_argument("--keep-shoulder-cut", action="store_true")
    ap.add_argument("--no-head-snap", action="store_true")
    ap.add_argument("--debug", default=None, help="folder for label-overlay and matte previews")
    a = ap.parse_args(argv)
    match = a.match
    if match is None and a.world_scale is None:
        # the legacy painting sets the in-game size: <race>/legacy once a repaint has been promoted
        has_legacy = os.path.exists(os.path.join(core.race_dir(a.race, "legacy"), "race.json"))
        match = a.race + ("/legacy" if has_legacy and a.variant != "legacy" else "/default")
    if match and (a.race, a.variant) == tuple((match.split("/") + ["default"])[:2]):
        ap.error("--match is the pack being written")
    if a.painting is None and not a.sheet:
        ap.error("give a painting to install, or --sheet")
    if a.painting is None:
        ref = tuple(((match or a.race + "/default").split("/") + ["default"])[:2])
        print("wrote", compare_sheet([ref, (a.race, a.variant)], a.sheet))
        return 0
    r = install(a.painting, a.race, a.variant, guide=a.guide, match=match, match_by=a.match_by,
                world_scale=a.world_scale, keep_legs=a.keep_legs, keep_shoulder_cut=a.keep_shoulder_cut,
                head_snap=not a.no_head_snap, debug=a.debug)
    print("[ok ] %s/%s  %dx%d  world_scale %.5f  guide IoU %.3f  (%s)" % (
        a.race, a.variant, r["size"][0], r["size"][1], r["world_scale"], r["guide_iou"], r["build"]))
    for n in r["notes"]:
        print("      " + n)
    print("      key: ground %s, contact shadow %d px peeled" % (r["key"]["ground_rgb"], r["key"]["shadow_px"]))
    if r["match_ratios"]:
        print("      world_scale each measure would ask for (chosen: %s):" % a.match_by)
        for name, v in r["match_ratios"].items():
            print("        %-10s %.5f   (%.1f pack px)" % (name, v, r["measures_px"][name]))
    if a.sheet and match:
        print("wrote", compare_sheet([tuple((match.split("/") + ["default"])[:2]), (a.race, a.variant)], a.sheet))
    return 0


if __name__ == "__main__":
    sys.exit(main())
