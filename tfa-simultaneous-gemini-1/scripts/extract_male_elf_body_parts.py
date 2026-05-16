"""Extract head, torso, upper_arm, forearm sprites from `contiguous elf 2.png`.

Cut coordinates derived from green annotations in `contiguous elf 2 cutlines.png`:
  - Head outline V:  bbox (692, 589) to (1361, 1197)
  - Shoulder cut (inner arm):  vertical line x = 670
  - Elbow cut (outer arm):     vertical line x = 463
Image center x = 1024, so the right-side shoulder mirrors to x = 1378.

The engine convention (Characters/body_part_sprites.gd) places the proximal-joint
end at the TOP of each sprite. Horizontal arms in the source are rotated 90 CCW
so the shoulder/elbow end ends up at the top.
"""
from pathlib import Path
from PIL import Image
import numpy as np
from scipy.ndimage import binary_dilation

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Characters" / "Assets" / "Body Parts" / "Male Elf"
SOURCE = ASSETS / "contiguous elf 2.png"
CUTLINES = ASSETS / "contiguous elf 2 cutlines.png"
# Headless variant: Nolan manually painted over the head/hair with skin color, so
# the torso extraction reads as one clean shoulder block with no inpainting smear.
SOURCE_HEADLESS = ASSETS / "contiguous elf 2 headless.png"

SHOULDER_X = 670
ELBOW_X = 463
SHOULDER_X_RIGHT = 2048 - SHOULDER_X  # = 1378, by image symmetry

HEAD_BBOX = (692, 589, 1361, 1197)


def remove_background(rgb: np.ndarray) -> np.ndarray:
    """Return an RGBA array with neutral-gray pixels (backdrop + cast shadow) keyed out.

    Skin tones have R > G > B (warm), so chroma = max - min is meaningful: gray
    pixels (R ~ G ~ B) hit alpha 0 regardless of brightness. This keys out both
    the gray background and the slightly darker floor shadow without eating into
    the orange-pink skin.
    """
    r = rgb[..., 0].astype(np.float32)
    g = rgb[..., 1].astype(np.float32)
    b = rgb[..., 2].astype(np.float32)
    chroma = np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b)
    # alpha 0 when chroma < 12, alpha 255 when chroma > 24, smooth in between.
    # Slightly aggressive — eats a 1-2 px edge fringe but kills the cast-shadow
    # halo cleanly. Skin core is well above this threshold (chroma > 30 typical).
    alpha = np.clip((chroma - 12.0) / (24.0 - 12.0), 0.0, 1.0)
    alpha = (alpha * 255).astype(np.uint8)
    rgba = np.dstack([rgb, alpha])
    return rgba


def autocrop(rgba: np.ndarray, pad: int = 4) -> np.ndarray:
    """Trim fully-transparent rows/cols around the sprite, with a small alpha-safe pad."""
    a = rgba[..., 3]
    ys, xs = np.where(a > 8)
    if len(ys) == 0:
        return rgba
    y0, y1 = max(int(ys.min()) - pad, 0), min(int(ys.max()) + pad + 1, rgba.shape[0])
    x0, x1 = max(int(xs.min()) - pad, 0), min(int(xs.max()) + pad + 1, rgba.shape[1])
    return rgba[y0:y1, x0:x1]


def detect_head_cut_mask(source: np.ndarray, cutlines: np.ndarray) -> np.ndarray:
    """Return a boolean mask (same shape as source[:,:,0]) marking the green head outline."""
    cr = cutlines[..., 0].astype(int); cg = cutlines[..., 1].astype(int); cb = cutlines[..., 2].astype(int)
    orr = source[..., 0].astype(int);  og = source[..., 1].astype(int);  ob = source[..., 2].astype(int)
    green_shift = (cg - og) - ((cr - orr) + (cb - ob)) / 2.0
    mark = green_shift > 8
    return binary_dilation(mark, iterations=2)


def fill_outline_per_column(outline_mask: np.ndarray) -> np.ndarray:
    """For each column, fill from topmost to bottommost outline pixel."""
    interior = np.zeros_like(outline_mask, dtype=bool)
    for x in range(outline_mask.shape[1]):
        col = np.where(outline_mask[:, x])[0]
        if len(col) >= 2:
            interior[int(col.min()):int(col.max()) + 1, x] = True
        elif len(col) == 1:
            interior[col[0], x] = True
    return interior


def fill_outline_per_row(outline_mask: np.ndarray) -> np.ndarray:
    """For each row, fill from leftmost to rightmost outline pixel."""
    interior = np.zeros_like(outline_mask, dtype=bool)
    for y in range(outline_mask.shape[0]):
        row = np.where(outline_mask[y, :])[0]
        if len(row) >= 2:
            interior[y, int(row.min()):int(row.max()) + 1] = True
        elif len(row) == 1:
            interior[y, row[0]] = True
    return interior


def fill_outline_interior(outline_mask: np.ndarray) -> np.ndarray:
    """Union of per-column and per-row spans. For a roughly-convex closed outline
    with sparse pixels, this gives a robust approximation of the interior even when
    the outline isn't fully connected."""
    return fill_outline_per_column(outline_mask) | fill_outline_per_row(outline_mask)


def extract_head(source_rgb: np.ndarray, head_outline_mask: np.ndarray) -> Image.Image:
    """Crop the head bbox, fill the outline's interior column-by-column, keep only
    pixels inside.

    The green outline traces the full head perimeter (top of hair, sides, chin).
    For each column, "inside" is the span from the topmost outline pixel to the
    bottommost. This is robust to outline gaps where binary_fill_holes would fail.
    """
    x0, y0, x1, y1 = HEAD_BBOX
    rgb_crop = source_rgb[y0:y1, x0:x1].copy()
    outline_crop = head_outline_mask[y0:y1, x0:x1]

    interior = fill_outline_interior(outline_crop)
    rgba = remove_background(rgb_crop)
    rgba[~interior, 3] = 0           # erase anything outside the head boundary

    rgba = autocrop(rgba, pad=4)
    return Image.fromarray(rgba, mode="RGBA")


def extract_torso(headless_rgb: np.ndarray) -> Image.Image:
    """Crop the shoulders + upper body block from the HEADLESS source.

    Bounds: x between the two shoulder cuts (670..1378), y from where the
    shoulders begin tapering inward (~870) down to just above the feet (1218).
    No inpainting needed — the headless source already has skin where the head
    used to be.
    """
    y_top = 870
    y_bottom = 1218
    rgb_crop = headless_rgb[y_top:y_bottom, SHOULDER_X:SHOULDER_X_RIGHT].copy()
    rgba = remove_background(rgb_crop)
    rgba = autocrop(rgba, pad=4)
    return Image.fromarray(rgba, mode="RGBA")


def extract_arm_segment(source_rgb: np.ndarray, x0: int, x1: int) -> Image.Image:
    """Crop a horizontal arm strip, background-remove, autocrop, then rotate 90 CCW.

    After rotation the high-x end of the strip (shoulder side for upper_arm,
    elbow side for forearm) lands at the TOP of the sprite, matching the engine
    convention that sprite-top = proximal joint.
    """
    # Vertical band: arm sits between roughly y=850 and y=1120 in the source.
    y_top, y_bottom = 850, 1120
    rgb_crop = source_rgb[y_top:y_bottom, x0:x1].copy()
    rgba = remove_background(rgb_crop)
    rgba = autocrop(rgba, pad=4)
    img = Image.fromarray(rgba, mode="RGBA")
    return img.rotate(90, expand=True)  # CCW in PIL


def main() -> None:
    source = np.array(Image.open(SOURCE).convert("RGB"))
    headless = np.array(Image.open(SOURCE_HEADLESS).convert("RGB"))
    cutlines = np.array(Image.open(CUTLINES).convert("RGB"))
    head_outline = detect_head_cut_mask(source, cutlines)

    outputs = {
        "head.png":       extract_head(source, head_outline),
        "torso.png":      extract_torso(headless),
        "upper_arm.png":  extract_arm_segment(source, x0=ELBOW_X, x1=SHOULDER_X),  # 463-670
        "forearm.png":    extract_arm_segment(source, x0=0,        x1=ELBOW_X),    # 0-463
    }
    for name, img in outputs.items():
        path = ASSETS / name
        img.save(path)
        print(f"wrote {path}  ({img.size[0]}x{img.size[1]})")


if __name__ == "__main__":
    main()
