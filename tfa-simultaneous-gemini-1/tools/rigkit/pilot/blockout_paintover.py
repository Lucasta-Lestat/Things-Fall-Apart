"""Pilot: flat-colour plan-view block-out + Gemini paint-over (method id blockout_paintover).

    python -m tools.rigkit.pilot.blockout_paintover blockout
    python -m tools.rigkit.pilot.blockout_paintover gen --variant crude|refined --prompt A --tag r1_crude [--style orc|human|both]
    python -m tools.rigkit.pilot.blockout_paintover iou <png> [<png> ...]

The block-out is drawn part by part (one layer each) so the same pass also
writes a per-part label image and a silhouette mask.
"""
import argparse
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.abspath(os.path.join(HERE, "..", "out", "overhead2", "blockout_paintover"))
W, H, SS = 1376, 768, 2
CX = W // 2
GREY = (128, 128, 128)

SKIN = (112, 132, 62)
SKIN_DK = (92, 112, 52)
SKIN_LT = (150, 168, 92)
IVORY = (222, 208, 170)
LINE = (44, 56, 28)

LABELS = [  # draw order, bottom to top
    ("foot_r", (255, 128, 0)), ("foot_l", (255, 200, 0)),
    ("body", (200, 0, 0)),
    ("upper_arm_r", (0, 160, 0)), ("upper_arm_l", (0, 230, 120)),
    ("forearm_r", (0, 120, 220)), ("forearm_l", (0, 220, 230)),
    ("hand_r", (130, 0, 220)), ("hand_l", (230, 0, 220)),
    ("head", (255, 255, 0)),
]


def _new():
    return Image.new("L", (W * SS, H * SS), 0)


def _s(v):
    return [x * SS for x in v]


def ell(d, cx, cy, rx, ry, fill=255):
    d.ellipse(_s([cx - rx, cy - ry, cx + rx, cy + ry]), fill=fill)


def poly(d, pts, fill=255):
    d.polygon([(x * SS, y * SS) for x, y in pts], fill=fill)


def cap(d, x0, y0, x1, y1, w, fill=255):
    d.line(_s([x0, y0, x1, y1]), fill=fill, width=int(w * SS))
    for x, y in ((x0, y0), (x1, y1)):
        ell(d, x, y, w / 2.0, w / 2.0, fill)


def _new_ell(cx, cy, rx, ry):
    im = _new()
    ell(ImageDraw.Draw(im), cx, cy, rx, ry)
    return im


# Head geometry per block-out version. v1 let the model paint a whole face into the
# lower half of the disc; v2 shrinks the forward jut to a 10 px ledge and makes the dome rounder.
HEADS = {
    1: dict(dome=(380, 72, 80), jut=(402, 60, 66), nose=(468, 14, 10),
            ear=((62, 362), (116, 366), (66, 404)), tusk=((22, 458), (36, 456), (31, 478))),
    2: dict(dome=(378, 74, 76), jut=(394, 54, 70), nose=(465, 10, 8),
            ear=((64, 364), (114, 370), (68, 398)), tusk=((24, 456), (34, 455), (30, 471))),
    3: dict(dome=(378, 74, 76), jut=(390, 52, 70), nose=(462, 9, 6),
            ear=((64, 364), (114, 370), (68, 398)), tusk=((24, 453), (33, 452), (30, 466))),
    # v4/v5: the ledge is gone altogether; the disc is scalp only, plus a nose nub (and tusk points in v4)
    4: dict(dome=(378, 74, 76), jut=(378, 74, 76), nose=(458, 9, 6),
            ear=((64, 364), (114, 370), (68, 398)), tusk=((22, 450), (32, 448), (29, 464))),
    5: dict(dome=(378, 74, 76), jut=(378, 74, 76), nose=(458, 9, 6),
            ear=((64, 364), (114, 370), (68, 398)), tusk=((0, 378), (1, 378), (0, 379))),
}
V = 1


def _sfx():
    return "" if V == 1 else str(V)


def part_masks():
    """One L mask per part, at SS scale. sx=+1 is image right = the character's left."""
    m = {}
    SH = 374  # shoulder line
    im = _new(); d = ImageDraw.Draw(im)
    ell(d, CX, 380, 218, 100)       # shoulder girdle / upper back seen from above
    ell(d, CX, 424, 168, 74)        # chest and belly jutting south
    m["body"] = im
    for side, sx in (("l", 1), ("r", -1)):
        im = _new(); d = ImageDraw.Draw(im)
        ell(d, CX + sx * 228, SH, 78, 62)                       # deltoid cap
        poly(d, [(CX + sx * 230, SH - 52), (CX + sx * 425, SH - 42),
                 (CX + sx * 425, SH + 42), (CX + sx * 230, SH + 54)])
        ell(d, CX + sx * 340, SH, 80, 50)                       # biceps/triceps mass
        m["upper_arm_" + side] = im
        im = _new(); d = ImageDraw.Draw(im)
        poly(d, [(CX + sx * 410, SH - 42), (CX + sx * 580, SH - 27),
                 (CX + sx * 580, SH + 27), (CX + sx * 410, SH + 42)])
        ell(d, CX + sx * 425, SH, 30, 43)                       # elbow
        ell(d, CX + sx * 475, SH, 62, 46)                       # forearm belly
        m["forearm_" + side] = im
        im = _new(); d = ImageDraw.Draw(im)
        ell(d, CX + sx * 600, SH, 34, 31)                       # back of the hand
        for dy in (-22, -7, 8, 22):
            ln = 650 if abs(dy) < 10 else 642
            cap(d, CX + sx * 612, SH + dy, CX + sx * ln, SH + dy, 13)
        cap(d, CX + sx * 590, SH + 22, CX + sx * 618, SH + 44, 14)  # thumb, toward south
        m["hand_" + side] = im
        im = _new(); d = ImageDraw.Draw(im)
        ell(d, CX + sx * 82, 498, 36, 30)                       # toe box peeking out
        for i, dx in enumerate((-26, -13, 0, 12, 23)):
            ell(d, CX + sx * (82 - dx), 522 - abs(i - 1) * 2, 8, 8)
        m["foot_" + side] = im
    hd = HEADS[V]
    im = _new(); d = ImageDraw.Draw(im)
    ell(d, CX, *hd["dome"])                                     # skull dome
    ell(d, CX, *hd["jut"])                                      # brow ledge jutting south
    ell(d, CX, *hd["nose"])                                     # nose tip
    for sx in (1, -1):
        poly(d, [(CX + sx * x, y) for x, y in hd["ear"]])
        poly(d, [(CX + sx * x, y) for x, y in hd["tusk"]])
    m["head"] = im
    return m


def head_details():
    """Sub-masks inside the head layer: (dome, brow strip, tusks, ears)."""
    hd = HEADS[V]
    dome = _new_ell(CX, *hd["dome"])
    jut = _new(); d = ImageDraw.Draw(jut)
    ell(d, CX, *hd["jut"]); ell(d, CX, *hd["nose"])
    brow = ImageChops.subtract(jut, dome)
    tusk = _new(); d = ImageDraw.Draw(tusk)
    ears = _new(); de = ImageDraw.Draw(ears)
    for sx in (1, -1):
        poly(d, [(CX + sx * x, y) for x, y in hd["tusk"]])
        poly(de, [(CX + sx * x, y) for x, y in hd["ear"]])
    ears = ImageChops.subtract(ears, dome)
    return dome, brow, tusk, ears


def _down(im):
    return im.resize((W, H), Image.LANCZOS)


def _paste(canvas, colour, mask):
    canvas.paste(Image.new("RGB", canvas.size, colour), (0, 0), mask)


def _blob(cx, cy, rx, ry, blur):
    return _new_ell(cx, cy, rx, ry).filter(ImageFilter.GaussianBlur(blur * SS))


def build():
    os.makedirs(OUT, exist_ok=True)
    masks = part_masks()
    dome, brow, tusk, ears = head_details()
    hd_ = HEADS[V]
    big = (W * SS, H * SS)

    # ---- labels + silhouette
    lab = Image.new("RGB", big, (0, 0, 0))
    sil = _new()
    for name, col in LABELS:
        mk = masks[name].point(lambda v: 255 if v > 127 else 0)
        _paste(lab, col, mk)
        sil = ImageChops.lighter(sil, mk)
    lab.resize((W, H), Image.NEAREST).save(os.path.join(OUT, "blockout_labels%s.png" % _sfx()))
    _down(sil).point(lambda v: 255 if v > 127 else 0).save(os.path.join(OUT, "blockout_mask%s.png" % _sfx()))
    with open(os.path.join(OUT, "blockout_labels%s.txt" % _sfx()), "w") as f:
        for name, col in LABELS:
            f.write("%s %d,%d,%d\n" % (name, col[0], col[1], col[2]))

    # ---- crude: flat colours only
    crude = Image.new("RGB", big, GREY)
    for name, _ in LABELS:
        _paste(crude, SKIN_DK if name == "body" else SKIN, masks[name])
    _paste(crude, SKIN_DK, brow)
    _paste(crude, SKIN_DK, ears)
    _paste(crude, IVORY, tusk)
    _paste(crude, SKIN_LT, _new_ell(CX, hd_["dome"][0] - 4, 26, 28))
    _down(crude).save(os.path.join(OUT, "blockout_crude%s.png" % _sfx()))

    # ---- refined: per-layer edge shading, highlights, soft dark outline
    ref = Image.new("RGB", big, GREY)
    hl = {
        "body": [(CX - 120, 340, 70, 40, 22), (CX + 120, 340, 70, 40, 22),
                 (CX - 80, 440, 60, 34, 20), (CX + 80, 440, 60, 34, 20)],
        "head": [(CX, 372, 34, 36, 16)],
    }
    for side, sx in (("l", 1), ("r", -1)):
        hl["upper_arm_" + side] = [(CX + sx * 228, 366, 46, 30, 16), (CX + sx * 345, 366, 52, 22, 14)]
        hl["forearm_" + side] = [(CX + sx * 478, 368, 44, 20, 12)]
        hl["hand_" + side] = [(CX + sx * 600, 372, 18, 14, 8)]
        hl["foot_" + side] = [(CX + sx * 82, 500, 18, 10, 6)]
    for name, _ in LABELS:
        mk = masks[name]
        base = SKIN_DK if name == "body" else SKIN
        layer = Image.new("RGB", big, base)
        # rim darkening: blurred alpha is low near the part's own edge
        rim = mk.filter(ImageFilter.GaussianBlur(14 * SS)).point(lambda v: min(255, int(max(0, v - 110) * 1.9)))
        dark = Image.new("RGB", big, tuple(int(c * 0.62) for c in base))
        layer = Image.composite(layer, dark, rim)
        for b in hl.get(name, []):
            layer = Image.composite(Image.new("RGB", big, SKIN_LT), layer,
                                    _blob(*b).point(lambda v: int(v * 0.75)))
        if name == "head":
            layer.paste(Image.new("RGB", big, tuple(int(c * 0.72) for c in SKIN)), (0, 0), brow)
            layer.paste(Image.new("RGB", big, SKIN_DK), (0, 0), ears)
            layer.paste(Image.new("RGB", big, IVORY), (0, 0), tusk)
            if V >= 2:  # sphere shading across the whole scalp disc, crown bright, rim dark
                dc = hd_["dome"]
                layer.paste(Image.new("RGB", big, tuple(int(c * 0.7) for c in SKIN)), (0, 0), dome)
                layer = Image.composite(Image.new("RGB", big, SKIN), layer, _blob(CX, dc[0], dc[1] - 14, dc[2] - 14, 12))
                layer = Image.composite(Image.new("RGB", big, SKIN_LT), layer, _blob(CX, dc[0], 40, 40, 18))
                layer = Image.composite(Image.new("RGB", big, (196, 208, 140)), layer, _blob(CX, dc[0] - 4, 14, 12, 8))
                layer.paste(Image.new("RGB", big, tuple(int(c * 0.55) for c in SKIN)), (0, 0), brow)
                layer.paste(Image.new("RGB", big, IVORY), (0, 0), tusk)
            ring = ImageChops.subtract(dome.filter(ImageFilter.MaxFilter(5)), dome.filter(ImageFilter.MinFilter(5)))
            layer.paste(Image.new("RGB", big, LINE), (0, 0), ring.point(lambda v: int(v * 0.6)))
        outline = ImageChops.subtract(mk, mk.filter(ImageFilter.MinFilter(7)))
        layer.paste(Image.new("RGB", big, LINE), (0, 0), outline)
        ref.paste(layer, (0, 0), mk)
    _down(ref).save(os.path.join(OUT, "blockout_refined%s.png" % _sfx()))
    bb = _down(sil).point(lambda v: 255 if v > 127 else 0).getbbox()
    print("silhouette bbox", bb, "depth/span = %.3f" % ((bb[3] - bb[1]) / float(bb[2] - bb[0])))


# ------------------------------------------------------------------ style swatches
SWATCH_BOX = {"orc": (150, 95, 400, 200), "human": (150, 90, 400, 190)}


def swatches():
    """Tight skin crops (shoulder/upper arm only) on the grey ground."""
    out = {}
    for race, box in SWATCH_BOX.items():
        im = Image.open(os.path.join(ROOT, "Rigs", "races", race, "default", "body.png")).convert("RGBA")
        bg = Image.new("RGBA", im.size, GREY + (255,))
        bg.alpha_composite(im)
        c = bg.convert("RGB").crop(box)
        c = c.resize((c.width * 3, c.height * 3), Image.LANCZOS)
        p = os.path.join(OUT, "style_%s_arm.png" % race)
        c.save(p)
        out[race] = p
    return out


# ------------------------------------------------------------------ prompts
PROMPTS = {
    "C": (
        "Image 1 is a nearly finished game sprite painting: a plan view of an orc standing in a "
        "T-pose, seen by an orthographic camera hovering directly above him and looking straight "
        "down at the floor, like a tabletop battle-map token. The body, arms, hands and toes are "
        "already painted. The head in the centre is still a rough block-out: a round disc that is "
        "his bald head seen from directly above, smooth olive-green scalp from rim to rim like the "
        "top of an egg, shaded as a dome with the crown and its highlight in the exact centre, and "
        "just past the bottom rim a narrow dark ledge that is the brow ridge and nose tip seen "
        "from above, with two small ivory tusk points. "
        "Finish the head so it matches the rest of the painting: render the smooth scalp dome with "
        "the same brushwork, olive-green colours, soft shading and soft dark outline as the "
        "shoulders, keep the dome the same size and in the same place with the crown highlight in "
        "its centre, keep the pointed ears at its sides, keep the narrow brow ledge and tusk tips "
        "at its bottom rim, and paint the neck and trapezius muscles meeting the back rim of the "
        "scalp. Keep everything else in the picture exactly as it is, on the same flat even "
        "mid-grey background."
    ),
    "B": (
        "Image 1 is a colour block-out for a game sprite: a plan view of an orc standing in a "
        "T-pose, drawn as seen by an orthographic camera hovering directly above him and looking "
        "straight down at the floor, like a tabletop battle-map token or an architect's plan of a "
        "person. The round disc in the centre is his bald head seen from directly above: smooth "
        "olive-green scalp covers the whole disc from rim to rim, like the top of an egg, shaded as "
        "a dome with the crown and its highlight in the exact centre. The pointed ears stick out "
        "sideways from the middle of the disc. Just past the bottom rim of the scalp a narrow dark "
        "ledge peeks out: the brow ridge and the tip of the nose seen from above, in shadow, with "
        "two small ivory tusk points. The wide horizontal bar is the tops of his shoulders, upper "
        "back and both arms stretched straight out to the left and right, ending in the backs of "
        "his hands with the fingers spread flat. The darker bulge below the bar is the upper "
        "surface of his chest seen from above, and the two small bumps at the bottom are his toe "
        "tips peeking out from under it. "
        "Finish this colour block-out into a fully rendered painting, keeping every shape exactly "
        "where it is: the same silhouette, the same sizes, the same positions, the same "
        "straight-down plan-view camera, the same smooth scalp dome filling the head disc. Paint "
        "olive-green orc skin with heavy musculature seen from above: trapezius and deltoids as "
        "rounded tops, the neck muscles running from the back rim of the scalp into the shoulders, "
        "knuckles and fingernails on the backs of the hands. Use the hand-painted semi-realistic "
        "style, colours, soft shading and soft dark outline of image 2, which is a small swatch of "
        "the target skin rendering. Keep the flat even mid-grey background."
    ),
    "A": (
        "Image 1 is a rough colour block-out for a game sprite: a plan view of an orc standing in a "
        "T-pose, drawn as seen by an orthographic camera hovering directly above him and looking "
        "straight down at the floor, like a tabletop battle-map token. The round shape in the centre "
        "is the bald top of his skull seen from above, with the crown of the head at its centre; the "
        "two small points beside it are his pointed ears; the thin darker strip on the bottom edge of "
        "the skull is the brow ridge and nose tip jutting forward, with two ivory tusk tips. The wide "
        "horizontal bar is the tops of his shoulders, upper back and both arms stretched straight out "
        "to the left and right, ending in the backs of his hands with the fingers spread flat. The "
        "darker bulge below the bar is his chest and belly seen from above, and the two small bumps "
        "at the bottom are his toe tips peeking out from under the belly. "
        "Finish this rough colour block-out into a fully rendered painting, keeping every shape "
        "exactly where it is: the same silhouette, the same sizes, the same positions, the same "
        "straight-down plan-view camera. Paint olive-green orc skin with heavy musculature seen from "
        "above: trapezius and deltoids as rounded tops, the smooth bald scalp with a soft highlight "
        "at the crown, knuckles and fingernails on the backs of the hands. Use the hand-painted "
        "semi-realistic style, colours, soft shading and soft dark outline of image 2, which is a "
        "small swatch of the target skin rendering. Keep the flat even mid-grey background."
    ),
}


def _swap_ledge(key, sentence):
    """Prompt B with its brow-ledge sentence swapped for `sentence` (D, E: face words removed)."""
    t = PROMPTS["B"]
    i0, i1 = t.index("Just past the bottom rim"), t.index("The wide horizontal bar")
    t = t[:i0] + sentence + " " + t[i1:]
    PROMPTS[key] = t.replace("keep the narrow brow ledge and tusk tips at its bottom rim, ", "")


_RIM = "The rim of the disc all the way round is the widest part of the skull. "
_swap_ledge("D", _RIM + "At the bottom rim the small rounded tip of his nose pokes out a few pixels, "
            "with two tiny ivory tusk tips beside it.")
_swap_ledge("E", _RIM + "At the bottom rim the small rounded tip of his nose pokes out a few pixels.")


def patch_head(painting, tag):
    """Two-pass input: a first-pass painting whose head region is overwritten with the
    v2 block-out's scalp dome + brow ledge, for the model to blend in."""
    global V
    V = 1
    old = part_masks()["head"]
    V = 2
    dome, brow, tusk, ears = head_details()
    area = ImageChops.subtract(old, ImageChops.subtract(part_masks()["head"], ImageChops.lighter(dome, brow)))
    area = ImageChops.lighter(area, ImageChops.lighter(dome, brow))
    area = _down(area.filter(ImageFilter.MaxFilter(13))).filter(ImageFilter.GaussianBlur(1.5))
    base = Image.open(painting).convert("RGB").resize((W, H), Image.LANCZOS)
    blk = Image.open(os.path.join(OUT, "blockout_refined2.png"))  # v2 on purpose.convert("RGB")
    out = Image.composite(blk, base, area)
    p = os.path.join(OUT, "%s.png" % tag)
    out.save(p)
    print("[ok ] %s" % p)
    return p


def gen(variant, prompt_id, tag, style, base=None):
    sys.path.insert(0, ROOT)
    from tools.rigkit.gen_overhead import generate, _part
    sw = swatches()
    src = base or os.path.join(OUT, "blockout_%s%s.png" % (variant, _sfx()))
    text = PROMPTS[prompt_id]
    if style == "human":  # the human swatch is a brushwork target only; skin colour stays in the words
        text = text.replace("style, colours, soft shading", "brushwork, soft shading")
    parts = [{"text": text}, _part(src, 1376)]
    for s in (("orc", "human") if style == "both" else (style,)):
        parts.append(_part(sw[s]))
    raw, model = generate(parts)
    p = os.path.join(OUT, "%s.png" % tag)
    with open(p, "wb") as f:
        f.write(raw)
    print("[ok ] %s via %s" % (p, model))
    iou([p])


# ------------------------------------------------------------------ metric
def keyed(path):
    im = Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS)
    px = im.load()
    cs = [px[x, y] for x in (4, W - 5) for y in (4, H - 5)]
    bg = tuple(sorted(c[i] for c in cs)[len(cs) // 2] for i in range(3))
    diff = ImageChops.difference(im, Image.new("RGB", im.size, bg)).convert("L")
    r, g, b = im.split()
    # background is neutral grey; figure is green/ivory (chroma) or dark outline
    chroma = ImageChops.difference(g, b)
    m = ImageChops.lighter(diff.point(lambda v: 255 if v > 40 else 0), chroma.point(lambda v: 255 if v > 22 else 0))
    return m.filter(ImageFilter.MedianFilter(5))


def iou(paths):
    ref = Image.open(os.path.join(OUT, "blockout_mask%s.png" % _sfx())).convert("L")
    for p in paths:
        m = keyed(p)
        m.save(os.path.splitext(p)[0] + "_mask.png")
        inter = ImageChops.multiply(ref, m).histogram()[255]
        union = ImageChops.lighter(ref, m).histogram()[255]
        bb = m.getbbox()
        print("%s  IoU=%.3f  bbox=%s  depth/span=%.3f" % (
            os.path.basename(p), inter / float(union), bb, (bb[3] - bb[1]) / float(bb[2] - bb[0])))


def main():
    global V
    ap = argparse.ArgumentParser()
    ap.add_argument("--v", type=int, default=1, help="block-out version")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("blockout")
    g = sub.add_parser("gen")
    g.add_argument("--variant", default="refined")
    g.add_argument("--prompt", default="A")
    g.add_argument("--tag", required=True)
    g.add_argument("--style", default="orc")
    g.add_argument("--base", default=None, help="use this image as image 1 instead of a block-out")
    ph = sub.add_parser("patch")
    ph.add_argument("painting")
    ph.add_argument("--tag", required=True)
    i = sub.add_parser("iou")
    i.add_argument("paths", nargs="+")
    a = ap.parse_args()
    V = a.v
    if a.cmd == "blockout":
        build()
        swatches()
    elif a.cmd == "gen":
        gen(a.variant, a.prompt, a.tag, a.style, a.base)
    elif a.cmd == "patch":
        patch_head(a.painting, a.tag)
    elif a.cmd == "iou":
        iou(a.paths)


if __name__ == "__main__":
    main()
