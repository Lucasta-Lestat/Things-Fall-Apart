"""Paint a race over the Blender top-down clay guide (pilot: blender_guide).

    python tools/rigkit/pilot/blender_guide_paint.py prep
    python tools/rigkit/pilot/blender_guide_paint.py gen <prompt_key> <out_name> [--swatch] [--input PNG]
    python tools/rigkit/pilot/blender_guide_paint.py iou <png> [...]

prep  : guide_clay.png (alpha) -> guide_clay_grey.png on (128,128,128), guide_mask.png,
        guide_labels.png (ids snapped to the palette), swatch.png (old-orc skin patch)
gen   : ONE Gemini call; the clay guide is the only camera image
iou   : grey-key the output and compare its silhouette with the guide mask
"""
import json
import os
import sys

from PIL import Image, ImageFilter, ImageChops

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, ROOT)
OUT = os.path.join(ROOT, "tools", "rigkit", "out", "overhead2", "blender_guide")
ORC = os.path.join(ROOT, "Rigs", "races", "orc", "default", "body.png")
SWATCH_BOX = (655, 75, 795, 140)   # shoulder / upper arm of the old orc, face excluded

PROMPTS = {
    "paint1": (
        "Image 1 is a clay sculpt of a heavy, muscular orc photographed by an orthographic camera "
        "placed directly above the top of his head and looking straight down at the floor: a plan "
        "view, like a tabletop game token. He stands upright in a T-pose and faces the bottom of the "
        "picture. The egg-shaped dome in the centre is the top of his bald skull with the crown at "
        "its middle; the two small points beside it are the tips of his ears; the small bumps along "
        "the dome's bottom edge are his brow ridge, nose tip and two tusk tips. The wide band behind "
        "the skull is his shoulders, trapezius and upper back seen from above; the two horizontal "
        "bars are his arms with the backs of the hands up; the rounded mass below the skull is the "
        "front of his chest and belly jutting forward; the two small shapes at the bottom are his "
        "toe tips. "
        "Paint over this sculpt, turning the clay into a finished hand-painted game sprite of the "
        "orc while keeping the exact silhouette, pose, proportions, placement and straight-down "
        "viewpoint of image 1. Olive-green skin; the bald scalp shaded as a smooth dome with a "
        "highlight on the crown; pointed green ears; ivory tusk tips; the top planes of the "
        "deltoids, trapezius and shoulder blades; triceps and forearm muscles seen from above; "
        "knuckles and backs of the hands; green toes. Semi-realistic painterly style with a soft "
        "dark outline around the figure and soft light from overhead. A flat, even mid-grey "
        "background (RGB 128,128,128) fills the rest of the 16:9 picture."
    ),
}
PROMPTS["paint2"] = (
    "Image 1 is a clay sculpt of a heavy, muscular orc photographed by an orthographic camera "
    "placed directly above the top of his head and looking straight down at the floor: a plan "
    "view, like a tabletop game token. He stands upright in a T-pose and faces the bottom of the "
    "picture. The egg-shaped dome in the centre is the top of his bald skull with the crown at "
    "its middle; the two small points beside it are the tips of his ears; the small bumps along "
    "the dome's bottom edge are his brow ridge, nose tip and two tusk tips. The wide band behind "
    "the skull is his trapezius and upper back seen from above, and the two round masses at its "
    "ends are the tops of his deltoids; the two horizontal bars are his arms with the backs of "
    "the hands up; the two broad rounded masses just below the skull are his pectoral muscles "
    "seen from above, the front of his chest; the two rows of small beads at the very bottom are "
    "the tips of his toes. "
    "Paint over this sculpt, turning the clay into a finished hand-painted game sprite of the "
    "orc while keeping the exact silhouette, pose, proportions, placement and straight-down "
    "viewpoint of image 1. Olive-green skin; the bald scalp shaded as a smooth dome with a "
    "highlight on the crown; pointed green ears; ivory tusk tips; the top planes of the "
    "deltoids, trapezius and shoulder blades with the spine groove between them; the upper "
    "surface of the pectorals; triceps, elbows and forearm muscles seen from above; knuckles and "
    "backs of the hands; five green toes on each foot. Semi-realistic painterly style with a "
    "clear soft dark outline around the whole figure and soft light from overhead. A flat, even "
    "mid-grey background (RGB 128,128,128) fills the rest of the 16:9 picture."
)
PROMPTS["paint3"] = (
    "Image 1 is a clay sculpt of a heavy, muscular orc photographed by an orthographic camera "
    "placed directly above the top of his head and looking straight down at the floor: a plan "
    "view, like a tabletop game token. He stands upright in a T-pose and faces the bottom of the "
    "picture. The large egg-shaped dome in the centre is the top of his bald skull, crown at its "
    "middle, and it stays a plain smooth scalp from edge to edge; the two small points beside it "
    "are the tips of his ears. Along the dome's bottom edge a thin rim is his heavy brow ridge "
    "seen from above, and the three tiny bumps just beyond it are the tip of his nose and the "
    "tips of his two tusks. The wide band behind the skull is his trapezius and upper back seen "
    "from above, and the two round masses at its ends are the tops of his deltoids; the two "
    "horizontal bars are his arms with the backs of the hands up; the two broad rounded masses "
    "just below the skull are his pectoral muscles seen from above, the front of his chest; the "
    "two small clusters of beads at the very bottom are the tips of his toes peeking out from "
    "under his chest. "
    "Paint over this sculpt, turning the clay into a finished hand-painted game sprite of the "
    "orc while keeping the exact silhouette, pose, proportions, placement and straight-down "
    "viewpoint of image 1, every shape staying the size it has in image 1. Olive-green skin; "
    "the bald scalp shaded as a smooth dome with a highlight on the crown; pointed green ears; "
    "a dark green brow rim; ivory tusk tips; the top planes of the deltoids, trapezius and "
    "shoulder blades with the spine groove between them; the upper surface of the pectorals; "
    "triceps, elbows and forearm muscles seen from above; knuckles and backs of the hands; "
    "small green toe tips. Semi-realistic painterly style with a clear soft dark outline around "
    "the whole figure and soft light from overhead. A flat, even mid-grey background "
    "(RGB 128,128,128) fills the rest of the 16:9 picture."
)
SWATCH_TEXT = (" Image 2 is a small swatch of this orc's painted skin: match its skin colour, "
               "brushwork and outline style.")


def _mask_of_alpha(im):
    return im.getchannel("A").point(lambda v: 255 if v > 127 else 0)


def prep():
    clay = Image.open(os.path.join(OUT, "guide_clay.png")).convert("RGBA")
    bg = Image.new("RGBA", clay.size, (128, 128, 128, 255))
    bg.alpha_composite(clay)
    bg.convert("RGB").save(os.path.join(OUT, "guide_clay_grey.png"))
    _mask_of_alpha(clay).save(os.path.join(OUT, "guide_mask.png"))
    meta = json.load(open(os.path.join(OUT, "guide_meta.json")))
    ids = Image.open(os.path.join(OUT, "guide_ids.png")).convert("RGBA")
    pal = [tuple(v) for v in meta["ids"].values()]
    px = ids.load()
    lab = Image.new("RGBA", ids.size, (0, 0, 0, 0))
    lp = lab.load()
    for y in range(ids.size[1]):
        for x in range(ids.size[0]):
            r, g, b, a = px[x, y]
            if a > 127:
                c = min(pal, key=lambda p: (p[0] - r) ** 2 + (p[1] - g) ** 2 + (p[2] - b) ** 2)
                lp[x, y] = c + (255,)
    lab.save(os.path.join(OUT, "guide_labels.png"))
    orc = Image.open(ORC).convert("RGBA")
    g = Image.new("RGBA", orc.size, (128, 128, 128, 255))
    g.alpha_composite(orc)
    sw = g.convert("RGB").crop(SWATCH_BOX)
    sw = sw.resize((sw.size[0] * 3, sw.size[1] * 3), Image.LANCZOS)
    sw.save(os.path.join(OUT, "swatch.png"))
    print("prep ok")


def key_grey(path, size=None, tol=14):
    """Silhouette of a painting on the grey ground: far from the border colour, holes filled."""
    im = Image.open(path).convert("RGB")
    if size and im.size != size:
        im = im.resize(size, Image.LANCZOS)
    w, h = im.size
    px = im.load()
    samples = [px[x, y] for x in range(0, w, 16) for y in (2, h - 3)]
    bgc = tuple(sorted(c[i] for c in samples)[len(samples) // 2] for i in range(3))
    diff = ImageChops.difference(im, Image.new("RGB", im.size, bgc))
    r, g, b = diff.split()
    m = ImageChops.lighter(ImageChops.lighter(r, g), b).point(lambda v: 255 if v > tol else 0)
    m = m.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(5))
    # fill holes: flood the outside, invert
    from PIL import ImageDraw
    pad = Image.new("L", (w + 2, h + 2), 0)
    pad.paste(m, (1, 1))
    ImageDraw.floodfill(pad, (0, 0), 128)
    filled = pad.point(lambda v: 0 if v == 128 else 255).crop((1, 1, w + 1, h + 1))
    return filled, bgc


def bbox_stats(m):
    bb = m.getbbox()
    return bb, (bb[3] - bb[1]) / float(bb[2] - bb[0])


def iou(path):
    guide = Image.open(os.path.join(OUT, "guide_mask.png")).convert("L")
    m, bgc = key_grey(path, guide.size)
    inter = ImageChops.multiply(guide, m).histogram()[255]
    union = ImageChops.lighter(guide, m).histogram()[255]
    gb, gr = bbox_stats(guide)
    ob, orr = bbox_stats(m)
    m.save(os.path.splitext(path)[0] + "_mask.png")
    res = {"file": os.path.basename(path), "iou": round(inter / float(union), 4), "bg": bgc,
           "guide_bbox": gb, "out_bbox": ob,
           "guide_depth_over_span": round(gr, 3), "out_depth_over_span": round(orr, 3)}
    print(json.dumps(res))
    return res


def gen(key, name, swatch, inp):
    from tools.rigkit.gen_overhead import generate, _part
    text = PROMPTS[key] + (SWATCH_TEXT if swatch else "")
    parts = [{"text": text}, _part(inp or os.path.join(OUT, "guide_clay_grey.png"), 1536)]
    if swatch:
        parts.append(_part(os.path.join(OUT, "swatch.png")))
    raw, model = generate(parts)
    p = os.path.join(OUT, name + ".png")
    with open(p, "wb") as f:
        f.write(raw)
    with open(os.path.join(OUT, name + ".prompt.txt"), "w") as f:
        f.write("model: %s\ninputs: %s%s\n\n%s\n" % (
            model, inp or "guide_clay_grey.png", " + swatch.png" if swatch else "", text))
    print("[ok ] %s via %s" % (p, model))
    iou(p)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "prep":
        prep()
    elif cmd == "iou":
        for p in sys.argv[2:]:
            iou(p)
    elif cmd == "gen":
        a = sys.argv[2:]
        inp = a[a.index("--input") + 1] if "--input" in a else None
        gen(a[0], a[1], "--swatch" in a, inp)
