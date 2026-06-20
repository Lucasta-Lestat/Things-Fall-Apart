import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from gen_item_art import gen, remove_bg, ITEMS
from PIL import Image
import io

LEATHER = os.path.join(ITEMS, "leather_armor.png")

PROMPT = (
    "A single top-down video-game inventory icon for a top-down RPG, drawn in the exact same "
    "strict overhead bird's-eye perspective and semi-realistic painterly art style as the reference "
    "leather-armor icon provided. The camera points straight down (a 90-degree overhead view) at a "
    "steel plate breastplate as if it is worn by a figure lying flat and seen from directly above. "
    "Composition exactly like the reference: a rounded neck-and-head opening sits at the very "
    "top-center as a dark hole you look down into; the shoulders are compact and sit close around "
    "that neck opening at the top; below the neck the curved chest plate spreads downward and "
    "outward and is strongly foreshortened, so only the upper surfaces of the armor are visible "
    "from above. Polished steel with subtle engraved gold trim along the edges, realistic "
    "brushed-metal highlights and soft reflections. The whole piece is centered with a generous "
    "empty margin of plain flat pure-white background on all sides, fully isolated as a clean cutout."
)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    for i in range(1, n + 1):
        print(f"[gen] breastplate variant {i} ...", flush=True)
        raw, model = gen(PROMPT, [LEATHER])
        img = remove_bg(Image.open(io.BytesIO(raw)))
        out = os.path.join(ITEMS, f"_bp_try{i}.png")
        img.save(out)
        print(f"[ok ] _bp_try{i}.png {img.size} via {model}", flush=True)


if __name__ == "__main__":
    main()
