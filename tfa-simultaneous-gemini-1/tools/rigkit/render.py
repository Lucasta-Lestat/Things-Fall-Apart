"""Offline renderer: a race pack wearing an outfit, composited with numpy/cv2.

It draws exactly what the engine draws: the same mesh (core.item_mesh), the same
vertex positions (core.fit_points), triangle by triangle, in the same z order.
Bind pose only for now (the T-pose the art is painted in), which is the pose a
fit is judged in.
"""
import functools
import os

import cv2
import numpy as np
from PIL import Image

from . import core
from .derive import label_masks

PAD_FRAC = 0.30      # canvas padding around the pack, for capes and long weapons


@functools.lru_cache(maxsize=256)
def _image(path):
    return np.array(Image.open(path).convert("RGBA"))


def _premul(rgba):
    out = rgba.astype(np.float32)
    out[:, :, :3] *= out[:, :, 3:4] / 255.0
    return out


def _over(dst, src):
    """Premultiplied float RGBA 'over'."""
    dst *= 1.0 - src[:, :, 3:4] / 255.0
    dst += src


def warp_mesh(art_premul, src_verts, dst_verts, tris, size):
    """Draw the textured triangle mesh into a (h, w) premultiplied RGBA layer."""
    h, w = size
    layer = np.zeros((h, w, 4), np.float32)
    for t in tris:
        s = src_verts[t].astype(np.float32)
        d = dst_verts[t].astype(np.float32)
        x0, y0 = np.floor(d.min(axis=0)).astype(int) - 1
        x1, y1 = np.ceil(d.max(axis=0)).astype(int) + 2
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, w), min(y1, h)
        if x1 <= x0 or y1 <= y0:
            continue
        sx0, sy0 = np.maximum(np.floor(s.min(axis=0)).astype(int) - 2, 0)
        sx1, sy1 = np.ceil(s.max(axis=0)).astype(int) + 3
        m = cv2.getAffineTransform(s - np.float32([sx0, sy0]), d - np.float32([x0, y0]))
        patch = cv2.warpAffine(art_premul[sy0:sy1, sx0:sx1], m, (int(x1 - x0), int(y1 - y0)), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        mask = np.zeros((y1 - y0, x1 - x0), np.uint8)
        # +0.5px grow so neighbouring triangles leave no crack
        cv2.fillConvexPoly(mask, np.round((d - np.float32([x0, y0])) * 16).astype(np.int32), 255,
                           lineType=cv2.LINE_AA, shift=4)
        mask = cv2.dilate(mask, np.ones((2, 2), np.uint8))
        region = layer[y0:y1, x0:x1]
        take = (mask > 0) & (patch[:, :, 3] > region[:, :, 3])
        region[take] = patch[take]
    return layer


@functools.lru_cache(maxsize=256)
def _item_art(path):
    return _premul(_image(path))


class RaceCanvas:
    """A loaded race pack plus the padded canvas everything is drawn on."""

    def __init__(self, race, variant="default"):
        self.data = core.load_race(race, variant)
        self.body = _image(core.race_file(self.data, "art"))
        self.labels = _image(core.race_file(self.data, "labels"))[:, :, :3]
        self.masks = label_masks(self.labels)
        h, w = self.body.shape[:2]
        self.pad = int(PAD_FRAC * max(h, w))
        self.size = (h + 2 * self.pad, w + 2 * self.pad)

    def place(self, rgba_premul):
        out = np.zeros((self.size[0], self.size[1], 4), np.float32)
        h, w = rgba_premul.shape[:2]
        out[self.pad:self.pad + h, self.pad:self.pad + w] = rgba_premul
        return out

    def mask(self, *names):
        m = np.zeros(self.size, bool)
        h, w = self.body.shape[:2]
        for n in names:
            if n in self.masks:
                m[self.pad:self.pad + h, self.pad:self.pad + w] |= self.masks[n]
        return m


def recolour(rgba, stops, ramp):
    """RGBA uint8 -> RGBA uint8 with the colour replaced through a ramp (alpha kept)."""
    from .derive import luma
    out = rgba.copy()
    out[:, :, :3] = np.clip(core.ramp_colour(luma(rgba[:, :, :3]), stops, ramp) * 255.0 + 0.5, 0, 255).astype(np.uint8)
    return out


def part_mask(canvas, name):
    """A stored cut-out (race.json "parts") as a mask on the padded canvas."""
    m = np.zeros(canvas.size, np.uint8)
    h, w = canvas.body.shape[:2]
    for x0, y0, x1, y1 in core.part_quads(canvas.data["parts"][name], 0.0):
        cv2.rectangle(m, (int(x0) + canvas.pad, int(y0) + canvas.pad),
                      (min(int(x1), w) - 1 + canvas.pad, min(int(y1), h) - 1 + canvas.pad), 1, -1)
    return m > 0


def hand_layer(canvas, skel, side, pose, ramp=None):
    """The hand of one side in one pose, as a premultiplied layer. `ramp` = None draws
    skin (the fist through the race's skin ramp; the open hand as painted), else the
    hand in that material (a glove)."""
    race = canvas.data
    if pose == "grip":
        hs = core.race_hand_set(race, skel)
        g = hs["poses"]["grip"]
        art = recolour(_image(os.path.join(hs["_dir"], g["art"])), g["stops"], ramp or race["skin"]["ramp"])
        if ramp is not None:
            # a glove ends at the wrist: no faded forearm stub (the shader's `cut` uniform)
            art[:, :int(round(core.glove_cut(hs)))] = 0
        verts, tris = core.mesh_from_cells(g["mesh"])
        dst = core.fist_points(race, hs, side, verts)
        return warp_mesh(_premul(art), verts, dst + canvas.pad, tris, canvas.size)
    body = canvas.body if ramp is None else recolour(canvas.body, race["skin"]["stops"], ramp)
    return canvas.place(_premul(body)) * part_mask(canvas, "hand_" + side)[:, :, None]


def item_layers(canvas, item, skel, poses=None):
    """[(z, premultiplied layer, side)] for one item on one race. Raises KeyError
    when the race lacks a frame the item needs. `poses` = {"l": pose, "r": pose}
    (default: what the item itself implies)."""
    race = canvas.data
    if poses is None:
        poses = core.hand_poses([item], skel, race)
    pm = _item_art(os.path.join(item["_dir"], item["art"]))
    verts, tris = core.mesh_from_cells(item["mesh"])
    slot = skel["slots"][item["slot"]]
    z = slot["z"] + (item.get("layer", 1) - 1 if "layers" in slot else 0)
    out = []
    for side in core.slot_sides(item, skel):
        if item["slot"] == "hands" and core.glove_ok(item, race, side):
            hz = skel["hands"]
            hs = core.race_hand_set(race, skel)
            pose = poses.get(side, "open")
            if item["hand"].get("fingers", "tint") != "none":
                out.append((hz["z_glove"], hand_layer(canvas, skel, side, pose, item["hand"]["ramp"]), side))
            for piece in item["hand"]["pieces"]:
                pv, pt = core.mesh_from_cells(piece["mesh"])
                dst = core.glove_piece_points(piece, skel, race, hs, side, pose, pv, item.get("authored_side", "r"))
                out.append((hz["z_cuff"] if piece["name"] == "cuff" else hz["z_back"],
                            warp_mesh(pm, pv, dst + canvas.pad, pt, canvas.size), side))
            continue
        dst, _, _ = core.fit_points(item, skel, race, verts, side)
        if item["slot"] in ("main_hand", "off_hand"):
            zf, zt = core.held_layers(item, skel, race, side)
            if zt is not None:
                tail = np.repeat(core.held_tail(item, item["mesh"]), 2)
                out.append((zf, warp_mesh(pm, verts, dst + canvas.pad, tris[~tail], canvas.size), side))
                if tail.any():
                    out.append((zt, warp_mesh(pm, verts, dst + canvas.pad, tris[tail], canvas.size), side))
            else:
                out.append((zf, warp_mesh(pm, verts, dst + canvas.pad, tris, canvas.size), side))
            continue
        out.append((z, warp_mesh(pm, verts, dst + canvas.pad, tris, canvas.size), side))
    return out


def compose(race, item_ids, variant="default", skel=None, background=None, poses=None):
    """Returns (RGBA uint8 image, {item_id: [(side, alpha mask)]}, canvas).
    `poses` overrides the hand poses the outfit implies, e.g. {"r": "grip"}."""
    skel = skel or core.skeleton()
    canvas = RaceCanvas(race, variant)
    alphas = {}
    skipped = []
    items = []
    for iid in item_ids:
        item = core.load_item(iid)
        miss = core.missing_frames(item, skel, canvas.data)
        if miss:
            skipped.append((iid, miss))
            continue
        items.append(item)
    hp = core.hand_poses(items, skel, canvas.data)
    for side, pose in (poses or {}).items():
        if core.hand_rig_ok(canvas.data, side):
            hp[side] = pose
    body = canvas.place(_premul(canvas.body))
    head = body * canvas.mask("face", "hair")[:, :, None]
    over = canvas.mask("over_garment")
    over_layer = body * over[:, :, None] if over.any() else None
    layers = []
    for side, pose in hp.items():
        if pose != "open":
            # the open hand leaves the body; the pose's hand is drawn above held items
            body = body * (~part_mask(canvas, "hand_" + side))[:, :, None]
            layers.append((skel["hands"]["z_fist"], hand_layer(canvas, skel, side, pose)))
    layers.append((skel["body_layers"]["body"], body))
    layers.append((skel["body_layers"]["head"], head))
    if over_layer is not None:
        layers.append((skel["body_layers"]["arms_over_garments"], over_layer))
    for item in items:
        for z, layer, side in item_layers(canvas, item, skel, hp):
            layers.append((z, layer))
            alphas.setdefault(item["id"], []).append((side, layer[:, :, 3] > 24))
    out = np.zeros((canvas.size[0], canvas.size[1], 4), np.float32)
    if background is not None:
        out[:, :, :3] = background
        out[:, :, 3] = 255
    for _, layer in sorted(layers, key=lambda t: t[0]):
        _over(out, layer.copy())
    a = np.maximum(out[:, :, 3:4], 1e-3)
    rgb = np.clip(out[:, :, :3] * 255.0 / a, 0, 255)
    img = np.dstack([rgb, np.clip(out[:, :, 3], 0, 255)]).astype(np.uint8)
    canvas.skipped = skipped
    canvas.poses = hp
    return img, alphas, canvas
