"""Process Nolan's hand-isolated Male Elf body parts.

Inputs (in Characters/Assets/Body Parts/Male Elf/, all on a shared 1024×1024
canvas so natural relative sizes are preserved):
  - male elf cont 2 head.png
  - male elf cont 2 torso.png
  - male elf cont 2 upper arm.png
  - male elf cont 2 arm.png      (forearm)

Outputs (overwrites the existing ones):
  - head.png   (vertical-flipped so face end is at TOP, per the convention
                already used by legs/arms)
  - torso.png  (vertical-flipped same reason)
  - upper_arm.png
  - forearm.png

Pipeline per part:
  1. Chroma-key the gray backdrop (R≈G≈B → alpha 0, smooth band for AA edges).
  2. Auto-crop to the tight skin bounding box (preserves relative sizes:
     since all four sources share the 1024 canvas, their cropped pixel
     dimensions reflect the artist-authored proportions exactly).
  3. Flip head and torso vertically.

After this, BodyPartSprites needs to scale every sprite by the same uniform
factor so those source-pixel ratios survive to the rendered character.
"""
from pathlib import Path
from PIL import Image
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Characters" / "Assets" / "Body Parts" / "Male Elf"

# (src filename, flip_v, rotate_ccw_deg) per output. Arms are horizontal in
# the source with their proximal joint (shoulder for upper_arm, elbow for
# forearm) on the RIGHT — confirmed by pixel-density profile — so a 90° CCW
# rotation puts that proximal end at the TOP of the sprite, matching the
# engine convention.
SOURCES = {
    "head.png":      ("male elf cont 2 head.png",      True,  0),
    "torso.png":     ("male elf cont 2 torso.png",     True,  0),
    "upper_arm.png": ("male elf cont 2 upper arm.png", False, 90),
    "forearm.png":   ("male elf cont 2 arm.png",       False, 90),
}


def remove_background(rgba: np.ndarray) -> np.ndarray:
    """Chroma-key the gray backdrop. Skin (R>G>B) has high chroma; gray bg/shadow
    has chroma ≈ 0. Smooth band keeps anti-aliased edges clean. Preserves any
    pre-existing alpha (so transparent border pixels stay transparent)."""
    r = rgba[..., 0].astype(np.float32)
    g = rgba[..., 1].astype(np.float32)
    b = rgba[..., 2].astype(np.float32)
    chroma = np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b)
    chroma_alpha = np.clip((chroma - 12.0) / (24.0 - 12.0), 0.0, 1.0)
    chroma_alpha = (chroma_alpha * 255).astype(np.uint8)
    new_alpha = np.minimum(rgba[..., 3], chroma_alpha)
    out = rgba.copy()
    out[..., 3] = new_alpha
    return out


def autocrop(rgba: np.ndarray, pad: int = 4) -> np.ndarray:
    a = rgba[..., 3]
    ys, xs = np.where(a > 8)
    if len(ys) == 0:
        return rgba
    y0, y1 = max(int(ys.min()) - pad, 0), min(int(ys.max()) + pad + 1, rgba.shape[0])
    x0, x1 = max(int(xs.min()) - pad, 0), min(int(xs.max()) + pad + 1, rgba.shape[1])
    return rgba[y0:y1, x0:x1]


def process(src_path: Path, flip_v: bool, rotate_ccw_deg: int) -> Image.Image:
    rgba = np.array(Image.open(src_path).convert("RGBA"))
    rgba = remove_background(rgba)
    rgba = autocrop(rgba, pad=4)
    img = Image.fromarray(rgba, mode="RGBA")
    if rotate_ccw_deg:
        img = img.rotate(rotate_ccw_deg, expand=True)  # PIL rotate is CCW
    if flip_v:
        img = img.transpose(Image.FLIP_TOP_BOTTOM)
    return img


def main() -> None:
    for out_name, (src_name, flip_v, rot) in SOURCES.items():
        img = process(ASSETS / src_name, flip_v, rot)
        out_path = ASSETS / out_name
        img.save(out_path)
        print(f"wrote {out_path.name}  ({img.size[0]}x{img.size[1]}, flip_v={flip_v}, rot={rot})")


if __name__ == "__main__":
    main()
