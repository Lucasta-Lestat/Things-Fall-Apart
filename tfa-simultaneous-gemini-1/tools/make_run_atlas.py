"""Derive the RUN atlases (Items/<id>_run.png) for long furniture strips.

A run item (Items/RunLayout.gd + RunRenderer.gd) draws one strip of furniture --
a banquet table, a pew, a cloth runner -- at ANY length along its local x axis:
    [capL | mid ... mid | capR]
from one landscape atlas row per id:
    [pad | capL] gut [mid variant(s)] gut [capR | pad]
* pad: transparent texels on all four sides (colour-bled, alpha 0) so the strip's
  OUTER edges stay antialiased at any rotation (a hard rect edge would stair-step);
  RunLayout grows the dst rect by pad * k so the opaque art keeps its size.
* gut: gutters between the parts, edge-extruded, so mipmaps never bleed one
  part's texels into its neighbour.
* mid_mode "stretch": one middle rect stretched over the whole span (column-
  invariant art: plank tops). "tile": TILE_FIT copies of a SEAMLESS middle tile
  (the tile's ends are cross-faded so tile i+1 continues tile i: periodic weave).

Deterministic (PIL only, fixed parameters). Writes the PNG, a .import with
mipmaps ON (only when missing -- Godot completes it on --import), and prints the
Items.json "run" block; --write-items patches those blocks into data/Items.json
(one line per id, inserted after its sprite_path line; idempotent).

usage: python tools/make_run_atlas.py [--root <TFA project>] [--write-items] [ids...]
"""
import argparse
import json
import os
import re
import sys

from PIL import Image
import numpy as np

PAD = 4      # transparent border, atlas px (all four sides)
GUT = 8      # extruded gutter between parts, atlas px

# mirror (stretch mode): the axes RunLayout.tiles may flip the WHOLE strip along,
# picked per run seed, so a row of pews / tables is not one cloned grain. Only
# axes the art's lighting tolerates: the table's top-edge highlight stays on top
# (x only); the bench art is lit near-symmetrically (x and y).
# cap: "auto" = columns until the end band's luminance reaches the middle median
# (long_table: the dark rounded border + its highlight); an int = SOURCE px of the
# (rotated) art. out_h: opaque atlas height (None = keep the source's).
SPECS = {
    "long_table": {"src": "Items/long_table.png", "rotate": 0, "out_h": 256, "cap": "auto",
                   "mode": "stretch", "across_m": 0.94, "shadow": 0.0, "mirror": "x"},
    # portrait art: rotate so the bench's LENGTH runs along x. The cap keeps the
    # end grain + the leg bracket (source rows 0..125 of 640).
    "bench": {"src": "Items/bench.png", "rotate": 90, "out_h": 128, "cap": 128,
              "mode": "stretch", "across_m": 0.48, "shadow": 0.0, "mirror": "xy"},
    # woven runner: the diamond lattice repeats every ~21 source px along the
    # length; the tile is a whole number of periods with cross-faded ends.
    "red_carpet": {"src": "Items/red_carpet.png", "rotate": 90, "out_h": None, "cap": 13,
                   "mode": "tile", "tile_periods": 8, "across_m": 0.62, "shadow": 0.0},
}

PX_PER_M = 64.0 / 1.5   # TFA: 1 tile = 64 px = 1.5 m


def _alpha_crop(a):
    al = a[..., 3]
    ys, xs = np.nonzero(al > 8)
    return a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def _lum(a):
    return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def _auto_cap(a):
    """Cap width (px): columns from each end until the middle-row luminance settles
    within 6% of the strip's middle median, plus 1 px of safety. Symmetric (max)."""
    h, w = a.shape[:2]
    lum = _lum(a)[h // 4: 3 * h // 4]
    col = lum.mean(axis=0)
    med = float(np.median(col[w // 4: 3 * w // 4]))
    tol = max(6.0, med * 0.06)

    def scan(cols):
        for i, v in enumerate(cols):
            # settled once the next 4 columns all sit inside the band
            if all(abs(float(c) - med) <= tol for c in cols[i:i + 4]):
                return i
        return len(cols) // 4
    return max(scan(col), scan(col[::-1])) + 1


def _period(a, lo=10, hi=120):
    """Dominant repeat (px) along x of the strip's middle band (autocorrelation)."""
    h, w = a.shape[:2]
    band = _lum(a)[h // 5: 4 * h // 5, w // 10: 9 * w // 10]
    band = band - band.mean()
    best = (-2.0, lo)
    for p in range(lo, min(hi, band.shape[1] // 3)):
        x0, x1 = band[:, :-p], band[:, p:]
        c = float((x0 * x1).sum() / np.sqrt((x0 * x0).sum() * (x1 * x1).sum()))
        if c > best[0]:
            best = (c, p)
    return best[1]


def _seamless(tile, fade):
    """Cross-fade the tile's last `fade` columns toward the columns that FOLLOW its
    start (tile[:fade] continues after the end), so copies abut without a seam."""
    t = tile.astype(np.float64)
    n = t.shape[1]
    out = t[:, :n - fade].copy()
    # the extra source columns are passed in: tile has n = L + fade columns
    w = np.linspace(0.0, 1.0, fade)[None, :, None]
    head = t[:, :fade]
    tail = t[:, n - fade:]
    out[:, :fade] = head * w + tail * (1.0 - w)
    return out


def _bleed(a):
    """Copy the nearest opaque colour into fully transparent texels (alpha stays 0)
    so linear/mip filtering at the AA edge never darkens toward black."""
    a = a.copy()
    al = a[..., 3]
    mask = al > 0
    if mask.all():
        return a
    rgb = a[..., :3].copy()
    filled = mask.copy()
    for _ in range(PAD + GUT + 2):
        if filled.all():
            break
        nf = filled.copy()
        acc = np.zeros_like(rgb)
        cnt = np.zeros(filled.shape, dtype=np.float64)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sf = np.roll(filled, (dy, dx), axis=(0, 1))
            sr = np.roll(rgb, (dy, dx), axis=(0, 1))
            m = sf & ~filled
            acc[m] += sr[m]
            cnt[m] += 1.0
        m = cnt > 0
        rgb[m] = acc[m] / cnt[m][:, None]
        nf[m] = True
        filled = nf
    a[..., :3] = rgb
    return a


def build(root, iid, spec):
    src = Image.open(os.path.join(root, spec["src"])).convert("RGBA")
    if spec["rotate"]:
        src = src.rotate(spec["rotate"], expand=True)
    a = _alpha_crop(np.asarray(src).astype(np.float64))
    h0, w0 = a.shape[:2]
    out_h = spec["out_h"] or h0
    s = out_h / float(h0)
    if spec["cap"] == "auto":
        cap_src = _auto_cap(a)
    else:
        cap_src = int(spec["cap"])
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")
    if abs(s - 1.0) > 1e-9:
        im = im.resize((max(1, int(round(w0 * s))), out_h), Image.LANCZOS)
    a = np.asarray(im).astype(np.float64)
    h, w = a.shape[:2]
    cap = int(round(cap_src * s))
    capL = a[:, :cap]
    capR = a[:, w - cap:]
    mids = []
    if spec["mode"] == "stretch":
        # the whole middle, minus 2 px each side of the cap seam
        mids.append(a[:, cap + 2: w - cap - 2])
    else:
        per = int(_period(a[:, cap: w - cap]))
        L = int(spec.get("tile_periods", 8)) * per
        fade = max(4, per // 2)
        c0 = (w - L - fade) // 2
        mids.append(_seamless(a[:, c0: c0 + L + fade], fade))
    # atlas row: pad | capL | gut | mid | gut | ... | capR | pad   (+ pad rows)
    parts = [capL]
    for m in mids:
        parts.append(m)
    parts.append(capR)
    W = PAD + cap + sum(GUT + m.shape[1] for m in mids) + GUT + cap + PAD
    H = h + 2 * PAD
    atlas = np.zeros((H, W, 4), dtype=np.float64)
    x = PAD
    atlas[PAD:PAD + h, x:x + cap] = capL
    x += cap
    mid_ranges = []
    for m in mids:
        # gutter = extruded neighbour columns (left half from the previous part's
        # last column, right half from this part's first) -- opaque, filter-safe
        prev_last = atlas[PAD:PAD + h, x - 1:x]
        atlas[PAD:PAD + h, x:x + GUT // 2] = prev_last
        atlas[PAD:PAD + h, x + GUT // 2:x + GUT] = m[:, :1]
        x += GUT
        atlas[PAD:PAD + h, x:x + m.shape[1]] = m
        mid_ranges.append([x, x + m.shape[1]])
        x += m.shape[1]
    atlas[PAD:PAD + h, x:x + GUT // 2] = atlas[PAD:PAD + h, x - 1:x]
    atlas[PAD:PAD + h, x + GUT // 2:x + GUT] = capR[:, :1]
    x += GUT
    atlas[PAD:PAD + h, x:x + cap] = capR
    x += cap
    assert x + PAD == W, (x, W)
    atlas = _bleed(atlas)
    out = Image.fromarray(np.clip(np.rint(atlas), 0, 255).astype(np.uint8), "RGBA")
    rel = "Items/%s_run.png" % iid
    out.save(os.path.join(root, rel), optimize=False)
    imp = os.path.join(root, rel + ".import")
    if not os.path.exists(imp):
        with open(imp, "w", newline="\n") as f:
            f.write(IMPORT_TMPL % {"src": rel})
    meta = {"atlas": "res://" + rel, "w": W, "h": H, "pad": PAD, "cap": cap,
            "mid": mid_ranges, "mid_mode": spec["mode"],
            "across": round(spec["across_m"] * PX_PER_M, 1), "shadow": spec["shadow"]}
    if spec.get("mirror"):
        meta["mirror"] = spec["mirror"]
    return meta


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


def write_items(root, metas):
    """Insert/replace one '"run": {...},' line per id right after its sprite_path
    line (Items.json keeps its tab-indented one-key-per-line layout)."""
    path = os.path.join(root, "data", "Items.json")
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    nl = "\r\n" if "\r\n" in text else "\n"
    for iid, meta in metas.items():
        blob = json.dumps(meta, separators=(", ", ": "))
        pat = re.compile(r'(\t"id": "%s",%s(?:\t[^\n]*%s)*?)(\t"sprite_path": "[^"]*",%s)(\t"run": [^\n]*%s)?'
                         % (re.escape(iid), re.escape(nl), re.escape(nl), re.escape(nl), re.escape(nl)))
        m = pat.search(text)
        if m is None:
            raise SystemExit("Items.json: no sprite_path line for %s" % iid)
        rep = m.group(1) + m.group(2) + '\t"run": %s,%s' % (blob, nl)
        text = text[:m.start()] + rep + text[m.end():]
    json.loads(text)   # still valid JSON
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--write-items", action="store_true")
    ap.add_argument("ids", nargs="*")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    ids = a.ids or list(SPECS)
    metas = {}
    for iid in ids:
        metas[iid] = build(root, iid, SPECS[iid])
        print(iid, json.dumps(metas[iid]))
    if a.write_items:
        write_items(root, metas)
        print("Items.json: run blocks written for", ", ".join(ids))
    return 0


if __name__ == "__main__":
    sys.exit(main())
