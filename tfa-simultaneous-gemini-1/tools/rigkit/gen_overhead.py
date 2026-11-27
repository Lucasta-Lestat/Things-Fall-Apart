"""Repaint a race at the art spec's overhead camera (docs/rigging_rewrite.md, 4.1).

    python -m tools.rigkit.gen_overhead <race> [--out DIR] [--n 2]

Image-to-image with two references: the race's current painting (identity:
skin, build, features) and the reference race's painting (camera, pose, canvas).
Writes candidates to tools/rigkit/out/overhead/ for review. It never touches a
race pack: a chosen candidate still needs a label map and `build_race`.

Prompts are phrased positively only: image models latch onto anything a
sentence tries to rule out. Needs GEMINI_API_KEY.
"""
import argparse
import base64
import io
import json
import os
import sys
import urllib.error
import urllib.request

from PIL import Image

from . import core

MODELS = ["gemini-3-pro-image", "gemini-3-pro-image-preview"]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "overhead")

PROMPT = (
    "Two reference paintings of game characters. Image 1 shows the CHARACTER to keep: "
    "its species, skin colour and texture, musculature, build, hands, feet and painted style. "
    "Image 2 shows the CAMERA and POSE to match exactly: the viewer hovers directly above the "
    "character and looks straight down, so the crown of the head sits in the middle of the head, "
    "the top of the skull and the tops of the shoulders and upper back fill the view, the brow "
    "and nose tip are the only parts of the face in sight, the shoulders are the widest part of "
    "the body, the trunk hides the legs, and only the toes peek out below the trunk. "
    "Paint the character from image 1 as seen by the camera of image 2: a symmetric T-pose with "
    "both arms stretched straight out to the sides, palms down, facing the bottom of the picture, "
    "bare unclothed base body, centred, the same flat mid-grey background, soft contact shadow, "
    "the same hand-painted semi-realistic style, lighting and framing as image 2, wide landscape "
    "composition with the fingertips near the left and right edges."
)


# Camera-first mode: the ONLY image is the reference race, and the target is
# described in words. Use it when the identity image drags its own camera along
# (the 2026-11-26 orc pilot: with both images the model repainted the orc at its
# old three-quarter angle both times).
PROMPT_DESCRIBE = (
    "This painting shows a game character from directly overhead: the viewer hovers above and "
    "looks straight down, so the crown of the head sits in the middle of the head, the tops of "
    "the shoulders and upper back fill the view, the trunk hides the legs, and only the toes "
    "peek out below. Repaint this exact picture, keeping the identical overhead camera, the "
    "identical symmetric T-pose with arms straight out to the sides, the identical framing, "
    "scale, flat mid-grey background, contact shadow and hand-painted style, with the character "
    "changed into {desc}. The crown of the head stays in the centre and the face stays hidden "
    "under the brow, exactly as in this picture."
)


def _part(path, max_side=1024):
    im = Image.open(path).convert("RGB")
    im.thumbnail((max_side, max_side))
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return {"inline_data": {"mime_type": "image/png", "data": base64.b64encode(buf.getvalue()).decode()}}


def _flat(path):
    """A race pack body on the spec's grey ground (packs are keyed)."""
    im = Image.open(path).convert("RGBA")
    bg = Image.new("RGBA", im.size, (128, 128, 128, 255))
    bg.alpha_composite(im)
    tmp = path + ".flat.tmp.png"
    bg.convert("RGB").save(tmp)
    return tmp


def generate(parts):
    key = os.environ["GEMINI_API_KEY"]
    body = json.dumps({"contents": [{"parts": parts}],
                       "generationConfig": {"responseModalities": ["IMAGE"],
                                            "imageConfig": {"aspectRatio": "16:9"}}}).encode()
    last = ""
    for model in MODELS:
        req = urllib.request.Request(
            "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % model,
            data=body, headers={"Content-Type": "application/json", "x-goog-api-key": key})
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                data = json.load(r)
            for cand in data.get("candidates", []):
                for p in cand.get("content", {}).get("parts", []):
                    blob = p.get("inlineData") or p.get("inline_data")
                    if blob:
                        return base64.b64decode(blob["data"]), model
            last = "%s returned no image" % model
        except urllib.error.HTTPError as e:
            last = "%s HTTP %s: %s" % (model, e.code, e.read().decode()[:200])
    raise RuntimeError(last)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("race")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--n", type=int, default=2)
    ap.add_argument("--describe", default="", help="camera-first mode: describe the race in words")
    ap.add_argument("--tag", default="overhead")
    a = ap.parse_args(argv)
    skel = core.skeleton()
    race = core.load_race(a.race)
    ref = core.load_race(skel["reference_race"])
    tmp = [_flat(core.race_file(race, "art")), _flat(core.race_file(ref, "art"))]
    try:
        parts = [{"text": PROMPT}, _part(tmp[0]), _part(tmp[1])]
        if a.describe:
            parts = [{"text": PROMPT_DESCRIBE.format(desc=a.describe)}, _part(tmp[1])]
        os.makedirs(a.out, exist_ok=True)
        for i in range(a.n):
            raw, model = generate(parts)
            p = os.path.join(a.out, "%s_%s_%d.png" % (a.race, a.tag, i + 1))
            with open(p, "wb") as f:
                f.write(raw)
            print("[ok ] %s via %s" % (p, model))
    finally:
        for t in tmp:
            os.remove(t)
    return 0


if __name__ == "__main__":
    sys.exit(main())
