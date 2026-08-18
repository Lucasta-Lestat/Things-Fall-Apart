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

# Held gear (weapons, shields) is drawn in a different register from the armor
# icons: a bold contour with flat cel shading, matching longsword.png and
# battleaxe.png.
#
# A shield drawn as a full circle reads as a disc lying flat on the ground. Held
# on a raised forearm and seen from above it foreshortens hard, and the parts
# that sell it are the ones a squashed face-on drawing loses: the rim's material
# THICKNESS all the way round, and a boss that domes up out of the face and
# catches the light. So ask for the perspective directly rather than flattening
# a front view afterwards.
#
# One of the reference images is deliberately a WIDE sprite: the model matches
# the references' aspect ratio, and tall weapon refs alone produce an upright
# portrait shield every time.
def shield_style(silhouette, placement, aspect):
    """Prompt for a shield seen from above.

    ROUND shields are easy: intrinsically 1:1, they foreshorten to a ~2.4:1
    ellipse and stay legible. ELONGATED shields (kite, heater) are not, and the
    reason is arithmetic rather than art: that same camera is a squash of ~0.42,
    so a 2:1 kite laid out horizontally comes to 2 / 0.42 = 4.8:1. At the ~36px
    these render at, that is a sliver — every attempt at it got called a canoe.

    Two things fix it, both encoded below: lay the shield DIAGONALLY in the
    ground plane rather than square-on (which buys back short-axis pixels), and
    cheat the foreshortening shallower than physically correct, capping the
    bounding box under 3:1. Generate at the final rotation and light it after —
    rotating a finished render drags the key light round with it.
    """
    return (
        "A single item sprite for a top-down RPG, drawn with bold dark contour lines and flat cel "
        "shading in the style of the reference sprites provided. The whole image is a WIDE LANDSCAPE "
        "picture. "
        "The camera sits high above the shield and looks down onto it at about sixty degrees, a high "
        "three-quarter overhead view: clearly looking ONTO the shield rather than at its face, while "
        f"keeping a generous amount of that face visible. SILHOUETTE: {silhouette} "
        "DEPTH: a thick slab of rim runs along the lower edge nearest the viewer and wraps around "
        "the far end, showing its full material thickness there, and thins away to almost nothing "
        "along the far upper edge. The face is dished, shaded in flat cel bands that step from "
        "lighter at the near lower edge to darker toward the far upper edge. The whole shield casts "
        "a soft dark shadow onto the ground beneath its near edge. "
        "The key light comes from the upper left of the finished picture. "
        "The shading is built from a few large flat areas so the sprite stays readable when it is "
        "shrunk to thirty pixels across, and the material is matte, shaded in flat steps. "
        f"PLACEMENT: {placement} The shield's bounding box is about {aspect} times as wide as it is "
        "tall. "
        "The shield sits centered and complete inside the frame, surrounded on all four sides by a "
        "generous empty margin of plain flat pure-white background, fully isolated as a clean cutout. "
    )

PROMPTS = {
    # The generic quest-proof trophy: whatever the bounty was, this is what you
    # carry back. Deliberately anonymous where the king's head is characterful —
    # it gets renamed per victim at runtime ("Severed Head of Ser Brannoc"), so
    # the art has to read as "somebody's head" rather than as one person's.
    # Kept stylised and cel-shaded to match its shelf-mate rather than pushed
    # toward realism, and it has to survive being shrunk to about twenty pixels.
    "severed_head": (
        "A single item sprite for a top-down RPG inventory, drawn with bold dark contour lines and "
        "flat cel shading, exactly matching the framing, proportions, line weight, muted palette and "
        "painted cel-shaded style of the reference severed-head sprite provided. "
        "SUBJECT: the severed head of an ordinary grown man, a slain roadside brigand, carried as "
        "proof of a bounty. He faces the viewer straight on and fills the frame the same way the "
        "reference head does. "
        "FACE: gaunt and slack, the eyes closed and sunken into shadowed sockets, the mouth hanging "
        "slightly open, the skin drained to a pallid grey with faint cold blue-green tones in the "
        "hollows of the cheeks and under the jaw. A short unkempt stubbled beard and a crooked nose "
        "that has been broken before. "
        "HAIR: dark brown, matted, hanging in lank clumps, bare-headed and plainly kept. "
        "NECK: the head ends at a ragged cut across the neck near the bottom of the frame, the "
        "cut edge dark and clotted in deep desaturated maroon. "
        "The key light comes from the upper left. The shading is built from a few large flat areas "
        "so the sprite stays readable when it is shrunk to twenty pixels across. "
        "The head's bounding box is very slightly taller than it is wide. "
        "The head sits centered and complete inside the frame, surrounded on all four sides by a "
        "generous empty margin of plain flat pure-white background, fully isolated as a clean cutout. "
    ),
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

    # ── Shields ──
    # Held items live in the hand next to swords and axes, so they follow the
    # WEAPON style (bold black contour, flat cel shading) rather than STYLE's
    # painterly armor register — hence the REFS_OVERRIDE entries below.
    #
    # Perspective: a shield drawn as a full circle reads as a disc lying flat on
    # the ground — a tray, not something strapped to a raised forearm. Overhead,
    # an upright shield foreshortens to a wide shallow oval, so that is what these
    # ask for, with a strip of rim thickness along the bottom to sell the depth.
    "buckler": shield_style(
        silhouette=(
            "the shield is round, so it foreshortens into a smooth even ellipse with no corners "
            "and no taper."
        ),
        placement="The ellipse lies flat across the middle of the frame.",
        aspect="two and a half",
    ) + (
        "The shield is a small round wooden buckler. Pale warm timber planks run across the face in "
        "parallel bands with visible grain and a few nicks, an iron-banded rim wraps the outer edge, "
        "and a pale domed steel boss crowns the centre, standing proud of the planks."
    ),
    # The asymmetry has to be stated twice over. Described as a teardrop or a
    # smooth lens, the model produces something pointed at BOTH ends and every
    # reader calls it a canoe; describing one blunt end and one sharp end, and
    # then saying outright that the two ends look different, is what fixes it.
    "iron_shield": shield_style(
        silhouette=(
            "the shield is a kite. It has ONE broad rounded shoulder at one end which holds almost "
            "its full width for the first third of its length, and from there both sides run in a "
            "long straight taper to ONE single sharp point at the other end. The broad end is wide "
            "and blunt and the far end is a single point, so the two ends look completely different "
            "from each other."
        ),
        placement=(
            "The shield lies at a shallow diagonal across the ground, its broad rounded shoulder "
            "toward the upper right of the frame and its single point aimed down toward the lower "
            "left corner, the long axis about thirty degrees off horizontal."
        ),
        aspect="two and a third",
    ) + (
        "The shield is a knight's iron kite shield. The camera looks onto its OUTER face, which is "
        "dished and crossed by a raised iron band. A domed steel boss stands proud of the face near "
        "the broad shoulder, catching the light on its upper left and casting a soft shadow down "
        "onto the face beside it. The boss is the one detail that must survive the sprite being "
        "shrunk, so it is bold and high in contrast."
    ),
}

# Items whose style comes from a different set of reference sprites than REFS.
# shield_topdown_aspect.png is a WIDE landscape sprite and is what stops the
# model copying the tall weapon refs' portrait framing; longsword.png supplies
# the contour-and-cel-shading register. (tools/refs carries a .gdignore so Godot
# leaves these out of the project's asset import.)
_REFS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "refs")
SHIELD_REFS = [
    os.path.join(_REFS_DIR, "shield_topdown_aspect.png"),
    os.path.join(ITEMS, "longsword.png"),
]
# The generic bounty trophy has to sit beside skarsgaard_king_head.png in the
# same bag, so that sprite IS the reference: same face-on framing, same bold
# contour and flat cel shading, same roughly-square aspect. Adding longsword.png
# reinforces the contour register without dragging the aspect portrait-tall.
HEAD_REFS = [
    os.path.join(ITEMS, "skarsgaard_king_head.png"),
    os.path.join(ITEMS, "longsword.png"),
]
REFS_OVERRIDE = {
    "buckler": SHIELD_REFS,
    "iron_shield": SHIELD_REFS,
    "severed_head": HEAD_REFS,
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


def trim(img, margin=6, max_side=640):
    """Crop to the artwork and drop it to a sane resolution.

    The prompts all ask for a generous empty margin, so a raw render is a 1024
    square that is mostly nothing. Every sprite already in Items/ is cropped
    close to its alpha bounding box (buckler 512x215, skarsgaard_king_head
    266x320), and the in-world footprint comes from base_width in Items.json
    rather than from the pixel dimensions — so the untrimmed square is pure
    waste, and it also throws off any code that reasons about the art's aspect.

    Cropping to the bounding box preserves the content's aspect ratio, which is
    what the shield work cared about; it is the empty margin that gets removed,
    not any of the shape.
    """
    bbox = img.convert("RGBA").getchannel("A").getbbox()
    if bbox is None:
        return img
    w, h = img.size
    box = (max(0, bbox[0] - margin), max(0, bbox[1] - margin),
           min(w, bbox[2] + margin), min(h, bbox[3] + margin))
    img = img.crop(box)
    longest = max(img.size)
    if longest > max_side:
        scale = max_side / float(longest)
        img = img.resize((max(1, round(img.size[0] * scale)),
                          max(1, round(img.size[1] * scale))), Image.LANCZOS)
    return img


def main():
    targets = sys.argv[1:] or list(PROMPTS.keys())
    for name in targets:
        prompt = PROMPTS[name]
        # REFS entries are bare Items/ filenames; REFS_OVERRIDE entries are full paths.
        ref_paths = REFS_OVERRIDE.get(name) or [os.path.join(ITEMS, r) for r in REFS]
        print(f"[gen] {name} ...", flush=True)
        raw, model = gen(prompt, ref_paths)
        img = Image.open(io.BytesIO(raw))
        img = remove_bg(img)
        img = trim(img)
        out_path = os.path.join(ITEMS, name + ".png")
        img.save(out_path)
        print(f"[ok ] {name}.png  {img.size}  via {model}", flush=True)


if __name__ == "__main__":
    main()
