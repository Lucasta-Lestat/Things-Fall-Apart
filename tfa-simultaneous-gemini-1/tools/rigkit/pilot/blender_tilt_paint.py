"""Paint a race over the tilted-camera Blender clay guide (pilot: blender_tilt).

    blender -b --python tools/rigkit/pilot/blender_tilt_proxy.py -- tools/rigkit/out/plan_blender/orc
    python tools/rigkit/pilot/blender_tilt_paint.py prep
    python tools/rigkit/pilot/blender_tilt_paint.py gen <prompt_key> <out_name> [<out_name> ...]
    python tools/rigkit/pilot/blender_tilt_paint.py iou <png> [...]
    python tools/rigkit/pilot/blender_tilt_paint.py zoom <png> [...]         head crop x3 beside the guide's
    python tools/rigkit/pilot/blender_tilt_paint.py sheet <out.jpg> <png> [...]

prep  : guide_clay.png (alpha) -> guide.png on (128,128,128), guide_mask.png,
        guide_labels.png (ids snapped to the palette, clipped to the mask), swatch.png
gen   : ONE Gemini call per out_name; inputs are the guide and the skin swatch only
iou   : grey-key the output and compare its silhouette with the guide mask
Every Gemini call is appended to calls.json (the pilot's budget is 12).
"""
import json
import os
import sys

from PIL import Image, ImageFilter, ImageChops, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, ROOT)
OUT = os.path.join(ROOT, "tools", "rigkit", "out", "plan_blender", "orc")
ORC = os.path.join(ROOT, "Rigs", "races", "orc", "default", "body.png")
SWATCH_BOX = (655, 75, 795, 140)   # shoulder / upper arm of the old orc, face excluded
CALL_CAP = 12

PROMPTS = {}
PROMPTS["tilt1"] = (
    "Image 1 is a smooth clay sculpt of a heavy, muscular orc standing upright in a T-pose and "
    "facing the bottom of the picture. An orthographic camera hangs almost directly overhead, "
    "leaning 15 degrees toward his front, so the view is the top of the figure with a thin "
    "foreshortened strip of his front. The big dome in the centre is the top of his bald skull "
    "with the crown just above its middle; the two points beside it are his ears; the narrow "
    "strip along the dome's lower edge is his face seen from steeply above: a heavy brow ridge, "
    "the bridge and tip of the nose under it, and two short tusks rising from the lower jaw. "
    "The wide band behind the head is his trapezius, shoulders and upper back; the two "
    "horizontal bars are his arms held level at shoulder height with the backs of the hands "
    "up; the rounded mass below the head is the front of his chest and belly, foreshortened; "
    "the two small shapes at the bottom are the fronts of his feet, toes forward, under short "
    "foreshortened shins. "
    "Paint over this sculpt, turning the clay into a finished hand-painted 2D game sprite of a "
    "living orc, keeping the silhouette, pose, proportions, placement and camera of image 1, "
    "every shape staying the size it has in image 1, with natural believable anatomy. "
    "Olive-green skin; a smooth bald scalp; pointed green ears; a shadowed brow with small "
    "deep-set eyes, a short broad nose and two small ivory tusks, all inside that narrow strip; "
    "the top planes of the trapezius, deltoids and shoulder blades; broad pectorals and a firm "
    "belly; biceps, elbows and forearms seen from above; knuckles and the backs of the hands; "
    "bare green feet with five short toes each. "
    "Style: clean cartoon game art with one crisp dark-green outline of medium, slightly "
    "varying weight around the figure and its main forms, saturated skin, smooth cel-like "
    "painted shading in two or three tones, broad soft matte highlights, matte skin. The "
    "figure is left-right symmetric. A flat, even mid-grey background (RGB 128,128,128) fills "
    "the rest of the 16:9 picture. "
    "Image 2 is a small swatch of this orc's painted skin: match its skin colour, shading and "
    "outline style."
)
PROMPTS["tilt2"] = (
    "Image 1 is a smooth clay sculpt of a heavy, muscular orc standing upright in a T-pose and "
    "facing the bottom of the picture. An orthographic camera hangs almost directly overhead, "
    "leaning 15 degrees toward his front, so the view is the top of the figure with a thin "
    "foreshortened strip of his front. The big dome in the centre is the top of his bald skull "
    "with the crown just above its middle; the two points beside it are his ears; the narrow "
    "strip along the dome's lower edge, about a quarter of the head, is his face seen from "
    "steeply above: a heavy brow ridge, the tip of the nose under it, and two short tusks. "
    "The wide band behind the head is his trapezius, shoulders and upper back; the two "
    "horizontal bars are his arms held level at shoulder height with the backs of the hands "
    "up; the rounded mass below the head is the front of his chest and belly, foreshortened; "
    "the two small shapes at the bottom are the fronts of his feet, toes forward, under short "
    "foreshortened shins. "
    "Paint over this sculpt, turning the clay into a finished hand-painted 2D game sprite of a "
    "living orc, keeping the silhouette, pose, proportions, placement and camera of image 1, "
    "every shape staying the size it has in image 1, with natural believable anatomy. "
    "Olive-green skin; a smooth bald scalp; pointed green ears; the bald scalp filling three quarters of the head; a heavy shadowed brow, a short "
    "broad nose and two small ivory tusks, strongly foreshortened inside that narrow strip; "
    "the top planes of the trapezius, deltoids and shoulder blades; broad hard pectorals and a "
    "firm muscular abdomen; biceps, elbows and forearms seen from above; knuckles and the backs of the hands; "
    "bare green feet with five short toes each. "
    "Style: clean cartoon game art with one crisp dark-green outline of medium, slightly "
    "varying weight around the figure and its main forms, saturated skin, smooth cel-like "
    "painted shading in two or three tones, broad soft matte highlights, matte skin. The "
    "figure is left-right symmetric. A flat, even mid-grey background (RGB 128,128,128) fills "
    "the rest of the 16:9 picture. "
    "Image 2 is a small swatch of this orc's painted skin: match its skin colour, shading and "
    "outline style."
)
PROMPTS["tilt3"] = (
    "Image 1 is a smooth clay sculpt of a heavy, muscular orc standing upright in a T-pose and "
    "facing the bottom of the picture. An orthographic camera hangs almost directly overhead, "
    "leaning 15 degrees toward his front, so the view is the top of the figure with a thin "
    "foreshortened strip of his front. The big dome in the centre is the top of his bald skull "
    "with the crown just above its middle; the two points beside it are his ears; the narrow "
    "strip along the dome's lower edge, about a quarter of the head, is his face seen from "
    "steeply above: a heavy brow ridge, the tip of the nose under it, and two short tusks. "
    "The wide band behind the head is his trapezius, shoulders and upper back; the two "
    "horizontal bars are his arms held level at shoulder height with the backs of the hands "
    "up; the rounded mass below the head is the front of his chest and belly, foreshortened; "
    "the two small shapes at the bottom are the fronts of his feet, toes forward, under short "
    "foreshortened shins. "
    "Paint over this sculpt, turning the clay into a finished hand-painted 2D game sprite of a "
    "living orc, keeping the silhouette, pose, proportions, placement and camera of image 1, "
    "every shape staying the size it has in image 1, with natural believable anatomy. "
    "Olive-green skin; a smooth bald scalp; pointed green ears; the bald scalp filling three quarters of the head; the heavy brow ridge exactly where image 1 "
    "has it, overhanging a band of deep shadow, with a short broad nose tip and two small ivory "
    "tusks just below it, strongly foreshortened inside that narrow strip; "
    "the top planes of the trapezius, deltoids and shoulder blades; broad hard pectorals and a "
    "firm muscular abdomen; biceps, elbows and forearms seen from above; knuckles and the backs of the hands; "
    "bare green feet with five short toes each. "
    "Style: clean cartoon game art with one crisp dark-green outline of medium, slightly "
    "varying weight around the figure and its main forms, saturated skin, smooth cel-like "
    "painted shading in two or three tones, broad soft low-contrast highlights, dry matte skin. The "
    "figure is left-right symmetric. A flat, even mid-grey background (RGB 128,128,128) fills "
    "the rest of the 16:9 picture. "
    "Image 2 is a small swatch of this orc's painted skin: match its skin colour, shading and "
    "outline style."
)


def _calls():
    p = os.path.join(OUT, "calls.json")
    return p, (json.load(open(p)) if os.path.exists(p) else [])


def prep():
    clay = Image.open(os.path.join(OUT, "guide_clay.png")).convert("RGBA")
    bg = Image.new("RGBA", clay.size, (128, 128, 128, 255))
    bg.alpha_composite(clay)
    bg.convert("RGB").save(os.path.join(OUT, "guide.png"))
    mask = clay.getchannel("A").point(lambda v: 255 if v > 127 else 0)
    mask.save(os.path.join(OUT, "guide_mask.png"))
    meta = json.load(open(os.path.join(OUT, "guide_meta.json")))
    ids = Image.open(os.path.join(OUT, "guide_ids.png")).convert("RGBA")
    pal = [tuple(v) for v in meta["ids"].values()]
    flat = []
    for p in pal:
        flat += list(p)
    pim = Image.new("P", (1, 1))
    pim.putpalette(flat + flat[:3] * (256 - len(pal)))
    snapped = ids.convert("RGB").quantize(palette=pim, dither=Image.NONE).convert("RGB")
    known = ids.getchannel("A").point(lambda v: 255 if v > 127 else 0)
    # grow labels a few px so the smoothed clay silhouette is fully covered, then clip to it
    lab = Image.new("RGB", ids.size, (0, 0, 0))
    lab.paste(snapped, (0, 0), known)
    for _ in range(6):
        grown = lab.filter(ImageFilter.MaxFilter(3))
        k2 = known.filter(ImageFilter.MaxFilter(3))
        ring = ImageChops.subtract(k2, known)
        lab.paste(grown, (0, 0), ring)
        known = k2
    outl = Image.new("RGBA", ids.size, (0, 0, 0, 0))
    outl.paste(lab, (0, 0), ImageChops.multiply(mask, known))
    outl.save(os.path.join(OUT, "guide_labels.png"))
    orc = Image.open(ORC).convert("RGBA")
    g = Image.new("RGBA", orc.size, (128, 128, 128, 255))
    g.alpha_composite(orc)
    sw = g.convert("RGB").crop(SWATCH_BOX)
    sw = sw.resize((sw.size[0] * 3, sw.size[1] * 3), Image.LANCZOS)
    sw.save(os.path.join(OUT, "swatch.png"))
    bb = mask.getbbox()
    print("prep ok  bbox=%s depth/span=%.3f" % (bb, (bb[3] - bb[1]) / float(bb[2] - bb[0])))


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
    pad = Image.new("L", (w + 2, h + 2), 0)
    pad.paste(m, (1, 1))
    ImageDraw.floodfill(pad, (0, 0), 128)
    filled = pad.point(lambda v: 0 if v == 128 else 255).crop((1, 1, w + 1, h + 1))
    return filled, bgc


def iou(path):
    guide = Image.open(os.path.join(OUT, "guide_mask.png")).convert("L")
    m, bgc = key_grey(path, guide.size)
    inter = ImageChops.multiply(guide, m).histogram()[255]
    union = ImageChops.lighter(guide, m).histogram()[255]
    gb, ob = guide.getbbox(), m.getbbox()
    # left-right symmetry of the painted silhouette about the guide's centre line
    cx = (gb[0] + gb[2]) // 2
    half = min(cx, guide.size[0] - cx)
    L = m.crop((cx - half, 0, cx, m.size[1]))
    R = m.crop((cx, 0, cx + half, m.size[1])).transpose(Image.FLIP_LEFT_RIGHT)
    si = ImageChops.multiply(L, R).histogram()[255]
    su = ImageChops.lighter(L, R).histogram()[255]
    res = {"file": os.path.basename(path), "iou": round(inter / float(union), 4), "bg": bgc,
           "guide_bbox": gb, "out_bbox": ob, "symmetry_iou": round(si / float(su), 4),
           "guide_depth_over_span": round((gb[3] - gb[1]) / float(gb[2] - gb[0]), 3),
           "out_depth_over_span": round((ob[3] - ob[1]) / float(ob[2] - ob[0]), 3)}
    print(json.dumps(res))
    return res


def _fig_box(pad=30):
    g = Image.open(os.path.join(OUT, "guide_mask.png")).convert("L")
    b = g.getbbox()
    return (max(0, b[0] - pad), max(0, b[1] - pad), min(g.size[0], b[2] + pad),
            min(g.size[1], b[3] + pad)), g.size


def zoom(path):
    """Head/torso/feet crop at x3, guide on the left, painting on the right."""
    (x0, y0, x1, y1), size = _fig_box(10)
    cx = (x0 + x1) // 2
    box = (cx - 300, y0, cx + 300, y1)
    tiles = []
    for p in (os.path.join(OUT, "guide.png"), path):
        im = Image.open(p).convert("RGB")
        if im.size != size:
            im = im.resize(size, Image.LANCZOS)
        c = im.crop(box)
        tiles.append(c.resize((c.size[0] * 2, c.size[1] * 2), Image.LANCZOS))
    sheet = Image.new("RGB", (tiles[0].size[0] * 2 + 8, tiles[0].size[1]), (40, 40, 40))
    sheet.paste(tiles[0], (0, 0))
    sheet.paste(tiles[1], (tiles[0].size[0] + 8, 0))
    out = os.path.splitext(path)[0] + "_zoom.jpg"
    sheet.save(out, quality=90)
    print(out)


def sheet(out, paths):
    box, size = _fig_box(30)
    rows = []
    for p in paths:
        im = Image.open(p).convert("RGB")
        if im.size != size:
            im = im.resize(size, Image.LANCZOS)
        rows.append(im.crop(box))
    w, h = rows[0].size
    s = Image.new("RGB", (w, h * len(rows)), (128, 128, 128))
    for i, r in enumerate(rows):
        s.paste(r, (0, i * h))
    s.save(out, quality=92)
    print(out, s.size)


def gen(key, names):
    from tools.rigkit.gen_overhead import generate, _part
    text = PROMPTS[key]
    parts = [{"text": text}, _part(os.path.join(OUT, "guide.png"), 1536),
             _part(os.path.join(OUT, "swatch.png"))]
    for name in names:
        cp, calls = _calls()
        if len(calls) >= CALL_CAP:
            raise SystemExit("call cap %d reached" % CALL_CAP)
        raw, model = generate(parts)
        calls.append({"name": name, "prompt": key, "model": model})
        with open(cp, "w") as f:
            json.dump(calls, f, indent=1)
        p = os.path.join(OUT, name + ".png")
        with open(p, "wb") as f:
            f.write(raw)
        with open(os.path.join(OUT, name + ".prompt.txt"), "w") as f:
            f.write("model: %s\ninputs: guide.png + swatch.png\n\n%s\n" % (model, text))
        print("[ok ] %s via %s  (call %d/%d)" % (p, model, len(calls), CALL_CAP))
        res = iou(p)
        with open(os.path.join(OUT, name + ".json"), "w") as f:
            json.dump(res, f, indent=1)
        zoom(p)


if __name__ == "__main__":
    cmd, a = sys.argv[1], sys.argv[2:]
    if cmd == "prep":
        prep()
    elif cmd == "iou":
        for p in a:
            iou(p)
    elif cmd == "zoom":
        for p in a:
            zoom(p)
    elif cmd == "sheet":
        sheet(a[0], a[1:])
    elif cmd == "gen":
        gen(a[0], a[1:])
