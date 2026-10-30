"""Paint the TABLE DECOR item sprites (Items/<id>.png) for run furniture.

A run (Items/RunLayout.gd + RunRenderer.gd) carries drawn decor. Export contract 1
names the built-in procedural painters _plate / _cup / _candle
(RunLayout.draw_builtin); under contract 2 Terrain Generation writes Items.json ids
instead, drawn from these sprites (P2-D, TG docs/export_contract.md):
    _plate v%3 -> pewter_plate | wooden_trencher | earthenware_plate
    _cup   v%2 -> pewter_tankard | wooden_cup
    _candle    -> candle   (emits_light: RunRenderer gives it a capped light)
Each sprite repaints its built-in (same palette, same proportions) top-down at
sprite resolution, with real shading instead of flat discs. The canvas is the
built-in's diameter d times EXTENT, and the Items.json base_width is
BUILTIN_D * EXTENT, so a decor entry's "scale" means the same size under both
contracts. The cup's handle points along +x (the decor "rot" turns it).

Deterministic (numpy + PIL, fixed seeds): 4x4 supersampled, premultiplied box
downsample. Writes the PNG and a .import with mipmaps ON (only when missing --
Godot completes it on --import; the art is drawn ~6-30 px across).

usage: python tools/make_decor_sprites.py [--root <TFA project>] [ids...]
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

SS = 4   # supersampling per axis

# RunLayout.BUILTIN_DECOR: built-in diameter px at scale 1
BUILTIN_D = {"_plate": 16.0, "_cup": 6.0, "_candle": 5.0}

# id: (built-in, canvas px, EXTENT = canvas / built-in diameter)
SPECS = {
    "pewter_plate": ("_plate", 128, 1.25),
    "wooden_trencher": ("_plate", 128, 1.25),
    "earthenware_plate": ("_plate", 128, 1.25),
    "pewter_tankard": ("_cup", 96, 1.9),
    "wooden_cup": ("_cup", 96, 1.9),
    "candle": ("_candle", 64, 1.4),
}


def _grid(n, extent):
    """Supersampled coordinates in units of the built-in radius r (centre 0,0;
    +x right, +y down)."""
    m = n * SS
    half = extent   # canvas = extent * d = 2 * extent * r: half-width extent (r units)
    t = (np.arange(m) + 0.5) / m * 2.0 * half - half
    x, y = np.meshgrid(t, t)
    return x, y, (2.0 * half) / m   # px size in r units


class Canvas:
    def __init__(self, n, extent):
        self.x, self.y, self.px = _grid(n, extent)
        self.rgb = np.zeros(self.x.shape + (3,))   # premultiplied
        self.a = np.zeros(self.x.shape)
        self.n = n

    def over(self, cov, col, alpha=1.0):
        """Composite colour col (array HxWx3 or rgb tuple) at coverage cov*alpha."""
        a = np.clip(cov * alpha, 0.0, 1.0)
        c = np.asarray(col, dtype=float)
        if c.ndim == 1:
            c = c[None, None, :]
        self.rgb = self.rgb * (1.0 - a[..., None]) + c * a[..., None]
        self.a = self.a * (1.0 - a) + a

    def disc(self, cx, cy, r, soft=None):
        """Coverage of a disc; soft = edge width in r units (default one sample)."""
        d = np.hypot(self.x - cx, self.y - cy)
        w = soft if soft is not None else self.px
        return np.clip((r - d) / w + 0.5, 0.0, 1.0)

    def dist(self, cx=0.0, cy=0.0):
        return np.hypot(self.x - cx, self.y - cy)

    def image(self):
        m = self.n
        rgb = self.rgb.reshape(m, SS, m, SS, 3).mean(axis=(1, 3))
        a = self.a.reshape(m, SS, m, SS).mean(axis=(1, 3))
        out = np.zeros((m, m, 4))
        nz = a > 1e-6
        out[..., :3][nz] = rgb[nz] / a[nz][:, None]
        out[..., 3] = a
        return Image.fromarray(np.clip(out * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGBA")


def _noise(shape, seed, scale_px):
    """Smooth value noise in -1..1 (bilinear upsampled random lattice)."""
    rng = np.random.default_rng(seed)
    h, w = shape
    gh, gw = max(2, h // scale_px + 2), max(2, w // scale_px + 2)
    g = rng.uniform(-1.0, 1.0, (gh, gw))
    yy = np.linspace(0, gh - 1.001, h)
    xx = np.linspace(0, gw - 1.001, w)
    y0, x0 = np.floor(yy).astype(int), np.floor(xx).astype(int)
    fy, fx = (yy - y0)[:, None], (xx - x0)[None, :]
    fy, fx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)
    a = g[y0][:, x0]
    b = g[y0][:, x0 + 1]
    c = g[y0 + 1][:, x0]
    d = g[y0 + 1][:, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def _shade(base, k):
    """base * k per channel (k: HxW field), clipped."""
    return np.clip(np.asarray(base)[None, None, :] * k[..., None], 0.0, 1.0)


def _mix(a, b, t):
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    t = np.clip(t, 0.0, 1.0)[..., None]
    return a[None, None, :] * (1.0 - t) + b[None, None, :] * t


def _contact_shadow(cv, r, alpha):
    # concentric, slightly down-right: the decor rotates, so keep the offset small
    cv.over(cv.disc(0.05, 0.07, r, soft=0.16), (0.0, 0.0, 0.0), alpha)


def _highlight(cv, cx, cy, r, alpha, clip):
    g = np.exp(-((cv.x - cx) ** 2 + (cv.y - cy) ** 2) / (2.0 * r * r))
    cv.over(g * clip, (1.0, 1.0, 0.96), alpha)


def paint_plate(cv, kind):
    base = {"pewter_plate": (0.60, 0.60, 0.57), "wooden_trencher": (0.55, 0.38, 0.22),
            "earthenware_plate": (0.70, 0.52, 0.36)}[kind]
    d = cv.dist()
    _contact_shadow(cv, 1.0, 0.30)
    body = cv.disc(0, 0, 1.0)
    n1 = _noise(d.shape, 11, 24 * SS // 4)
    n2 = _noise(d.shape, 12, 7 * SS // 4)
    if kind == "wooden_trencher":
        # end-grain-free board: grain along x, a darker turned rim
        grain = np.sin(cv.y * 26.0 + n1 * 2.2) * 0.5 + 0.5
        k = 0.92 + 0.10 * grain + 0.05 * n2
        col = _shade(base, k)
    elif kind == "pewter_plate":
        k = 0.97 + 0.05 * n1 + 0.03 * n2   # soft mottling of worn pewter
        col = _shade(base, k)
    else:
        k = 0.98 + 0.03 * n2
        col = _shade(base, k)
    # rim (outer ring, darker, rolled edge lit on the inner side)
    rim = np.clip((d - 0.86) / 0.14, 0.0, 1.0)
    edge_k = 0.72 + 0.14 * np.cos(np.clip((d - 0.86) / 0.14, 0, 1) * np.pi)
    col_rim = col * edge_k[..., None]
    cv.over(body, col * (1.0 - rim[..., None]) + col_rim * rim[..., None])
    # the well: slightly lighter, a fine darker ring at its lip
    well = cv.disc(0, 0, 0.58, soft=0.05)
    cv.over(well, np.clip(col * 1.07, 0, 1))
    lip = np.clip(1.0 - np.abs(d - 0.58) / 0.035, 0.0, 1.0)
    cv.over(lip * body, np.clip(col * 0.86, 0, 1), 0.8)
    if kind == "earthenware_plate":
        # slip-trailed band on the rim and a speckled glaze
        band = np.clip(1.0 - np.abs(d - 0.74) / 0.035, 0.0, 1.0)
        cv.over(band * body, (0.86, 0.74, 0.52), 0.85)
        speck = (_noise(d.shape, 13, 2) > 0.80).astype(float)
        cv.over(speck * body, (0.42, 0.28, 0.17), 0.35)
    _highlight(cv, -0.42, -0.46, 0.22, 0.30 if kind != "wooden_trencher" else 0.14, body)


def paint_cup(cv, kind):
    wood = kind == "wooden_cup"
    body = (0.60, 0.44, 0.27) if wood else (0.66, 0.67, 0.66)
    edge = (0.20, 0.18, 0.17) if wood else tuple(c * 0.45 for c in body)
    d = cv.dist()
    _contact_shadow(cv, 1.04, 0.32)
    # handle along +x: a rounded bar 0.55r..1.55r
    hx = np.clip(cv.x, 0.55, 1.45)
    hd = np.hypot(cv.x - hx, cv.y)
    cv.over(np.clip((0.35 - hd) / cv.px + 0.5, 0, 1), edge)
    cv.over(np.clip((0.21 - hd) / cv.px + 0.5, 0, 1), tuple(c * 0.88 for c in body))
    cv.over(np.clip((0.08 - np.hypot(cv.x - hx, cv.y + 0.07)) / cv.px + 0.5, 0, 1) * (cv.x > 0.7),
            (1.0, 0.97, 0.88), 0.35)
    # rim and wall top
    cv.over(cv.disc(0, 0, 1.0), edge)
    n = _noise(d.shape, 21, 5)
    if wood:
        grain = np.sin(np.arctan2(cv.y, cv.x) * 18.0 + n * 1.5) * 0.5 + 0.5
        k = 0.90 + 0.12 * grain
    else:
        k = 0.96 + 0.05 * n
    cv.over(cv.disc(0, 0, 0.86), _shade(body, k))
    if wood:
        # the iron hoop shows as a dark band just inside the rim
        hoop = np.clip(1.0 - np.abs(d - 0.93) / 0.05, 0.0, 1.0)
        cv.over(hoop, (0.24, 0.22, 0.21), 0.9)
    # ale: dark, deepest at the centre, a thin foam crescent at the far wall
    ale = cv.disc(0, 0, 0.58)
    cv.over(ale, _mix((0.36, 0.23, 0.10), (0.22, 0.14, 0.06), d / 0.58))
    foam = np.clip(1.0 - np.abs(d - 0.52) / 0.05, 0.0, 1.0) * np.clip(0.4 + cv.x * 0.5 + cv.y * 0.5, 0.0, 1.0)
    cv.over(foam * ale, (0.90, 0.84, 0.66), 0.65)
    # lit rim arc toward the upper left
    ang = np.arctan2(cv.y, cv.x)
    ga = np.arctan2(-0.72, -0.68)
    arc = np.clip(1.0 - np.abs(d - 0.72) / 0.09, 0, 1) * np.clip(1.0 - np.abs(np.angle(np.exp(1j * (ang - ga)))) / 1.15, 0, 1)
    cv.over(arc, tuple(min(1.0, c * 1.55) for c in body), 0.8)
    _highlight(cv, -0.20, -0.22, 0.10, 0.35, ale)


def paint_candle(cv):
    d = cv.dist()
    _contact_shadow(cv, 1.27, 0.30)
    # brass dish: bright rim, a darker pan
    dish = cv.disc(0, 0, 1.25)
    ang = np.arctan2(cv.y, cv.x)
    lit = 0.5 + 0.5 * np.cos(ang - np.arctan2(-0.72, -0.68))
    cv.over(dish, _shade((0.58, 0.43, 0.20), 0.82 + 0.30 * lit))
    cv.over(cv.disc(0, 0, 1.0), _shade((0.42, 0.30, 0.13), 0.92 + 0.12 * (1.0 - lit)))
    # wax column top: cream, a rounded shoulder, a drip
    wax = cv.disc(0, 0, 0.72)
    cv.over(wax, _mix((0.97, 0.94, 0.85), (0.83, 0.78, 0.66), (d / 0.72) ** 2))
    cv.over(cv.disc(0.55, 0.38, 0.17), (0.92, 0.88, 0.76), 0.9)
    # flame from above: a warm halo, the bright flame, a white core
    cv.over(np.exp(-(d / 0.42) ** 2), (1.0, 0.80, 0.42), 0.55)
    cv.over(cv.disc(0, 0, 0.36), (1.0, 0.86, 0.45))
    cv.over(cv.disc(0, 0, 0.16), (1.0, 0.98, 0.85))


IMPORT_TMPL = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://%(src)s"

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
"""


def build(root, item_id):
    builtin, n, extent = SPECS[item_id]
    cv = Canvas(n, extent)
    if builtin == "_plate":
        paint_plate(cv, item_id)
    elif builtin == "_cup":
        paint_cup(cv, item_id)
    else:
        paint_candle(cv)
    rel = "Items/%s.png" % item_id
    path = os.path.join(root, *rel.split("/"))
    cv.image().save(path, optimize=True)
    imp = path + ".import"
    if not os.path.exists(imp):
        with open(imp, "w", encoding="utf-8", newline="\n") as f:
            f.write(IMPORT_TMPL % {"src": rel})
    bw = BUILTIN_D[builtin] * extent
    print("%-18s %s  %dpx  base_width %.1f" % (item_id, rel, n, bw))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("ids", nargs="*")
    args = ap.parse_args()
    ids = args.ids or list(SPECS)
    for i in ids:
        if i not in SPECS:
            sys.exit("unknown decor sprite id %r (known: %s)" % (i, ", ".join(SPECS)))
        build(os.path.abspath(args.root), i)


if __name__ == "__main__":
    main()
