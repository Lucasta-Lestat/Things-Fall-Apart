"""Generate top-down FURNITURE sprites for BSP-room clutter via Gemini.

Modeled on gen_item_art.py, but anchored on existing top-down WORLD PROPS
(straw_bed, round_table) rather than inventory-icon armor refs, so the output
keeps the exact overhead world-sprite perspective the map items use.

Usage: python tools/gen_furniture_art.py [name ...]   (default: all)
Writes Items/<name>.png with background removed. Items.json entries are added
separately (see the session that introduced this script).
"""
import os, sys, json, base64, urllib.request, urllib.error
from collections import deque
from PIL import Image
import io

KEY = os.environ["GEMINI_API_KEY"]
ITEMS = os.path.join(os.path.dirname(__file__), "..", "Items")
REFS = ["straw_bed.png", "round_table.png"]
MODELS = ["gemini-3-pro-image", "gemini-3.1-flash-image", "gemini-2.5-flash-image"]

STYLE = (
    "A single top-down video-game world sprite for a medieval top-down RPG, drawn from a "
    "directly overhead bird's-eye camera looking straight down, exactly matching the overhead "
    "perspective, proportions, soft lighting and semi-realistic painterly style of the two "
    "reference furniture sprites provided (a straw bed and a round wooden table seen from "
    "directly above). Period-appropriate for a low-medieval village interior: worn wood, plain "
    "cloth, no modern materials. The object fits fully inside the frame, centered, surrounded "
    "on all four sides by a generous empty margin of plain flat pure-white background, fully "
    "isolated as a clean cutout. "
)

PROMPTS = {
    "bed_wooden": STYLE + (
        "The object is a simple wooden frame bed seen from directly above: a rectangular oak "
        "bed frame with visible wooden posts at the four corners, a woolen blanket in muted "
        "madder red covering the lower two thirds, a folded-back linen sheet edge, and a plain "
        "cloth pillow at the head end. Slightly longer than wide."
    ),
    "wardrobe": STYLE + (
        "The object is a closed wooden wardrobe cabinet seen from directly above. Its top is a "
        "STRICTLY RECTANGULAR slab of dark oak — four straight edges, sharp right-angled "
        "corners, absolutely NOT circular and NOT radial — built from three or four straight "
        "parallel planks running along the long axis, with a visible center seam line where the "
        "two doors below meet, two small iron hinge fittings on that seam, and a slight "
        "overhang lip around the rectangular top edge. About twice as long as it is deep."
    ),
}


def b64_image(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def gen(prompt, ref_paths):
    parts = [{"text": prompt}]
    for rp in ref_paths:
        parts.append({"inline_data": {"mime_type": "image/png", "data": b64_image(rp)}})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
    }
    data = json.dumps(body).encode()
    last_err = None
    for model in MODELS:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={KEY}"
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                out = json.loads(resp.read())
            for cand in out.get("candidates", []):
                for p in cand.get("content", {}).get("parts", []):
                    idata = p.get("inlineData") or p.get("inline_data")
                    if idata and idata.get("data"):
                        return base64.b64decode(idata["data"]), model
            last_err = "no image part in response: " + json.dumps(out)[:400]
        except urllib.error.HTTPError as e:
            last_err = f"{model} HTTP {e.code}: {e.read().decode()[:300]}"
        except Exception as e:
            last_err = f"{model} {e}"
    raise RuntimeError(last_err)


def remove_bg(img, tol=28):
    """Edge flood-fill: clear contiguous background matching the corner color."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    alpha_min = min(px[x, y][3] for x in range(0, w, max(1, w // 50)) for y in range(0, h, max(1, h // 50)))
    if alpha_min < 250:
        return img
    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    key = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

    def close(a):
        return abs(a[0] - key[0]) <= tol and abs(a[1] - key[1]) <= tol and abs(a[2] - key[2]) <= tol

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            q.append((x, y))
    while q:
        x, y = q.popleft()
        i = y * w + x
        if seen[i]:
            continue
        seen[i] = 1
        r, g, b, a = px[x, y]
        if not close((r, g, b)):
            continue
        px[x, y] = (r, g, b, 0)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                q.append((nx, ny))
    return img


def autocrop(img, pad=8):
    """Crop to the opaque content + a small pad — existing world sprites are
    tightly cropped, and TFA's scale_sprite scales the FULL canvas by
    base_width/texture_width, so an uncropped 1024 canvas with big margins
    renders the item undersized in game."""
    bbox = img.getbbox()
    if bbox is None:
        return img
    x0, y0, x1, y1 = bbox
    x0 = max(0, x0 - pad)
    y0 = max(0, y0 - pad)
    x1 = min(img.size[0], x1 + pad)
    y1 = min(img.size[1], y1 + pad)
    return img.crop((x0, y0, x1, y1))


def main():
    targets = sys.argv[1:] or list(PROMPTS.keys())
    ref_paths = [os.path.join(ITEMS, r) for r in REFS]
    for name in targets:
        prompt = PROMPTS[name]
        print(f"[gen] {name} ...", flush=True)
        raw, model = gen(prompt, ref_paths)
        img = Image.open(io.BytesIO(raw))
        img = remove_bg(img)
        img = autocrop(img)
        out_path = os.path.join(ITEMS, name + ".png")
        img.save(out_path)
        print(f"[ok ] {name}.png  {img.size}  via {model}", flush=True)


if __name__ == "__main__":
    main()
