import os, sys, json, base64, urllib.request, urllib.error
from collections import deque
from PIL import Image
import io

KEY = os.environ["GEMINI_API_KEY"]
ITEMS = os.path.join(os.path.dirname(__file__), "..", "Items")
REFS = ["leather_armor.png", "legionnaires_armor.png"]
MODELS = ["gemini-3-pro-image", "gemini-3.1-flash-image", "gemini-2.5-flash-image"]

STYLE = (
    "A single top-down video-game inventory icon for a top-down RPG, drawn from a directly "
    "overhead bird's-eye camera looking straight down at the garment as it would be worn on a "
    "character lying flat, exactly matching the overhead perspective, proportions, framing, soft "
    "lighting and semi-realistic painterly style of the two reference armor icons provided. "
    "Seen from above: the two shoulders spread outward to the upper-left and upper-right, a rounded "
    "neck-and-head opening sits at the top-center, the sleeves extend out to the sides, and the "
    "foreshortened torso fills the lower portion of the frame. The entire garment fits fully inside "
    "the frame, centered, surrounded on all four sides by a generous empty margin of plain flat "
    "pure-white background, fully isolated as a clean cutout. "
)

PROMPTS = {
    "dark_robes": STYLE + (
        "The garment is a cultist's heavy dark ritual robe in charcoal black with deep-purple "
        "undertones, thick draping cloth folds radiating outward from the shoulders, a thin twisted "
        "rope cord across the waist lower in the frame, and frayed cloth edges."
    ),
    "dark_hood": (
        "A single top-down video-game inventory icon for a top-down RPG, drawn from a directly "
        "overhead bird's-eye camera looking straight down at a hood, exactly matching the overhead "
        "perspective, framing, soft lighting and semi-realistic painterly style of the reference "
        "armor icons provided. Seen from directly above: a charcoal-black cloth hood with rounded "
        "draped fabric forming the outer cowl and a dark open hole at the center where the face "
        "looks up, soft radiating folds around the rim. Fully isolated as a clean cutout on a plain "
        "flat pure-white background."
    ),
    "padded_vest": STYLE + (
        "The garment is a quilted padded gambeson vest in warm brown and tan, with vertical stitched "
        "channels, short leather lacing at the top-center neck opening, rugged practical street-tough "
        "styling, lightly worn."
    ),
    "peasants_stained_shirt": STYLE + (
        "The garment is a humble loose homespun peasant shirt in faded off-white and beige rough "
        "linen, a simple laced collar at the top-center neck opening, dirt smudges and brown stains, "
        "creased well-worn fabric spreading from the shoulders."
    ),
    "breastplate_2": STYLE + (
        "The garment is a polished steel plate breastplate (metal torso armor), rounded pauldrons "
        "at the shoulders, a fitted curved chest plate with subtle engraved gold trim along the "
        "edges, a small neck opening at the top-center, sturdy and noble, with realistic brushed-"
        "metal highlights and soft reflections."
    ),
    "nobles_blouse": STYLE + (
        "The garment is an elegant noble's blouse in rich deep-burgundy silk accented with gold "
        "embroidery, a ruffled high collar around the top-center neck opening, and ruffled cuffs at "
        "the ends of the sleeves that spread out to the sides."
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
    # already has meaningful transparency? keep it
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


def main():
    targets = sys.argv[1:] or list(PROMPTS.keys())
    ref_paths = [os.path.join(ITEMS, r) for r in REFS]
    for name in targets:
        prompt = PROMPTS[name]
        print(f"[gen] {name} ...", flush=True)
        raw, model = gen(prompt, ref_paths)
        img = Image.open(io.BytesIO(raw))
        img = remove_bg(img)
        out_path = os.path.join(ITEMS, name + ".png")
        img.save(out_path)
        print(f"[ok ] {name}.png  {img.size}  via {model}", flush=True)


if __name__ == "__main__":
    main()
