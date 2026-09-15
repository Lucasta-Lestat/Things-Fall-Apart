# Preview a tg_* editor export the way TFA renders it, without booting the
# game: ground PNG + structures overlay + the map's runtime item_spawns
# composited from Items/*.png. Item sprites scale to base_width px (the export
# renders at 2 px/wu, same scale Item.scale_sprite targets on screen) and
# rotation is Godot's CW radians (PIL rotates CCW, hence the negation).
#
#   python tools/preview_map.py <map_id> <out.png> [x0 y0 x1 y1] [half]
#
# The optional crop box is in export pixels; "half" downscales the result 2x.
import json, sys, math, os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
mid = sys.argv[1]
out = sys.argv[2]

maps = json.load(open(os.path.join(ROOT, "data", "Maps.json"), encoding="utf-8"))["maps"]
m = [x for x in maps if x.get("id") == mid][0]
items_db = {it["id"]: it for it in json.load(open(os.path.join(ROOT, "data", "Items.json"), encoding="utf-8"))
            if isinstance(it, dict) and "id" in it}

g = Image.open(os.path.join(ROOT, "Maps", mid + ".png")).convert("RGBA")
s = Image.open(os.path.join(ROOT, "Maps", mid + "_structures.png")).convert("RGBA")
base = Image.alpha_composite(g, s)

sprites = {}
def sprite(iid):
    if iid not in sprites:
        db = items_db.get(iid)
        if db is None:
            sprites[iid] = None
        else:
            p = db.get("sprite_path", "res://Items/%s.png" % iid).replace("res://", ROOT + "/")
            try:
                sprites[iid] = (Image.open(p).convert("RGBA"), float(db.get("base_width", 32.0)))
            except FileNotFoundError:
                sprites[iid] = None
    return sprites[iid]

spawns = sorted(m.get("item_spawns", []), key=lambda e: (e.get("z", 0), e["position"][1]))
missing = set()
for e in spawns:
    sp = sprite(e["id"])
    if sp is None:
        missing.add(e["id"])
        continue
    img, bw = sp
    sc = float(e.get("scale", 1.0)) * bw / img.width
    # per-axis stretch over the art's own axes (before rotation, matching the
    # game's node-local scale); negative values mirror the sprite
    sx = sc * float(e.get("scale_x", 1.0))
    sy = sc * float(e.get("scale_y", 1.0))
    it = img.resize((max(1, round(img.width * abs(sx))), max(1, round(img.height * abs(sy)))), Image.LANCZOS)
    if sx < 0:
        it = it.transpose(Image.FLIP_LEFT_RIGHT)
    if sy < 0:
        it = it.transpose(Image.FLIP_TOP_BOTTOM)
    rot = float(e.get("rotation", 0.0))
    if abs(rot) > 1e-3:
        it = it.rotate(-math.degrees(rot), expand=True, resample=Image.BICUBIC)
    x, y = e["position"]
    base.alpha_composite(it, (round(x - it.width / 2), round(y - it.height / 2)))
if missing:
    print("MISSING sprites:", sorted(missing))

if len(sys.argv) >= 7:
    x0, y0, x1, y1 = map(int, sys.argv[3:7])
    base = base.crop((x0, y0, x1, y1))
if "half" in sys.argv:
    base = base.resize((base.width // 2, base.height // 2), Image.LANCZOS)
base.convert("RGB").save(out, quality=92)
print("saved", out, base.size)
