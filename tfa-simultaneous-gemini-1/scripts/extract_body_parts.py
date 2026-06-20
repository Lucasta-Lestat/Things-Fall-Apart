"""Generalized body-part slicer for contiguous-art races.

Cuts head / torso / upper_arm / forearm from a single contiguous top-down drawing
AND emits a joint manifest (body_manifest.json) for the manifest-driven body rig
(Characters/skeletal_body_rig.gd). A manifest sitting next to a race's head.png
auto-activates SkeletalBodyRig (gap-free, proportion-preserving) in place of the
legacy per-axis BodyPartSprites. Legs stay procedural (a true top-down pose
foreshortens legs to feet) and are never cut.

This is the parameterized successor to extract_male_elf_body_parts.py. Cut
coordinates and source filenames are no longer hardcoded — they come from
scripts/body_slice_config.json, one entry per race folder. Each race's geometry
is either:
  * AUTO-DERIVED from a green cutline-annotation PNG (the artist paints the head
    outline + two vertical arm cut strokes; see derive_cuts_from_cutlines), or
  * given EXPLICITLY in the config (explicit always wins over derived).
Male Elf pins all of its constants explicitly so its output stays byte-identical
to the legacy script — grimalkin / djargo reuse Male Elf's part PNGs through the
legacy BodyPartSprites path and must not regress.

=== JOINT MANIFEST (schema 1) ===
Per part we record the pixel coordinates of its skeletal joints IN THE PART'S OWN
FINAL SPRITE SPACE (after crop/rotate/flip). Every joint is pinned to the CUT LINE
it shares with its neighbour, so when the runtime chains a child's proximal joint
onto its parent's named joint the segments meet with no gap by construction:
    torso.neck       == head.neck
    torso.shoulder_l == upper_arm_l.shoulder ;  upper_arm.elbow == forearm.elbow

unit_px = shoulder-to-shoulder span on the source canvas; the runtime divides all
px values by it to get scale-independent proportions, then multiplies by the
character's body_scale.

Usage:
    python extract_body_parts.py                # every race in the config
    python extract_body_parts.py "Male Elf"     # one or more named races
    python extract_body_parts.py "Male Orc" "Male Human"
"""
from pathlib import Path
import json
import sys
from PIL import Image
import numpy as np
from scipy.ndimage import binary_dilation, binary_fill_holes, label

ROOT = Path(__file__).resolve().parent.parent
BODY_PARTS = ROOT / "Characters" / "Assets" / "Body Parts"
CONFIG_PATH = Path(__file__).resolve().parent / "body_slice_config.json"

DEFAULT_PAD = 4
DEFAULT_TUNING = {
    "head_overlap_px": 320.0,
    # Per-base-part extra rotation. Arms can be tuned per side via the *_l/*_r keys
    # (fall back to the un-suffixed key when a side-specific one is absent).
    "rot_offset_deg": {"head": 0.0, "torso": 0.0, "upper_arm": 0.0, "forearm": 0.0},
    "leg_reverse": False,
}


# === background / silhouette helpers (race-agnostic) =====================

def remove_background(rgb: np.ndarray) -> np.ndarray:
    """Return an RGBA array with neutral-gray pixels (backdrop + cast shadow) keyed out.

    Skin tones have meaningful chroma = max - min; gray pixels (R ~ G ~ B) hit
    alpha 0 regardless of brightness. This keys out both the gray background and
    the slightly darker floor shadow without eating into the warm skin. Works for
    any race because it keys on chroma, not a specific hue."""
    r = rgb[..., 0].astype(np.float32)
    g = rgb[..., 1].astype(np.float32)
    b = rgb[..., 2].astype(np.float32)
    chroma = np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b)
    alpha = np.clip((chroma - 12.0) / (24.0 - 12.0), 0.0, 1.0)
    alpha = (alpha * 255).astype(np.uint8)
    return np.dstack([rgb, alpha])


def autocrop_box(rgba: np.ndarray, pad: int):
    """Return (x0, y0, x1, y1) of the padded alpha bounding box (no slicing)."""
    a = rgba[..., 3]
    ys, xs = np.where(a > 8)
    if len(ys) == 0:
        return 0, 0, rgba.shape[1], rgba.shape[0]
    y0 = max(int(ys.min()) - pad, 0)
    y1 = min(int(ys.max()) + pad + 1, rgba.shape[0])
    x0 = max(int(xs.min()) - pad, 0)
    x1 = min(int(xs.max()) + pad + 1, rgba.shape[1])
    return x0, y0, x1, y1


def green_mark_mask(source: np.ndarray, cutlines: np.ndarray) -> np.ndarray:
    """Boolean mask of GREEN annotation strokes (cutlines greener than source).

    Robust only when the skin under the strokes is NOT green (e.g. pink elf skin).
    For green-skinned races the strokes barely out-green the skin, so use the
    'diff' method instead. Kept as the Male Elf path to preserve byte-identity."""
    cr = cutlines[..., 0].astype(int); cg = cutlines[..., 1].astype(int); cb = cutlines[..., 2].astype(int)
    orr = source[..., 0].astype(int);  og = source[..., 1].astype(int);  ob = source[..., 2].astype(int)
    green_shift = (cg - og) - ((cr - orr) + (cb - ob)) / 2.0
    return green_shift > 8


def diff_mark_mask(source: np.ndarray, cutlines: np.ndarray, threshold: int = 18) -> np.ndarray:
    """Boolean mask of annotation strokes by plain colour DIFFERENCE from source.

    Colour-agnostic, so it finds strokes of ANY hue on skin of ANY hue (including
    green annotation on a green orc, where the green-shift metric is too weak).
    This is the default for new races."""
    d = np.abs(cutlines.astype(int) - source.astype(int)).sum(axis=2)
    return d > threshold


def annotation_mask(source, cutlines, method="diff", threshold=18) -> np.ndarray:
    """Raw (undilated) stroke mask via the chosen detection method."""
    if method == "green":
        return green_mark_mask(source, cutlines)
    return diff_mark_mask(source, cutlines, threshold)


def detect_head_cut_mask(source, cutlines, method="diff", threshold=18) -> np.ndarray:
    """Dilated mask of the head-outline annotation (same shape as source[:,:,0])."""
    return binary_dilation(annotation_mask(source, cutlines, method, threshold), iterations=2)


def fill_outline_per_column(outline_mask: np.ndarray) -> np.ndarray:
    interior = np.zeros_like(outline_mask, dtype=bool)
    for x in range(outline_mask.shape[1]):
        col = np.where(outline_mask[:, x])[0]
        if len(col) >= 2:
            interior[int(col.min()):int(col.max()) + 1, x] = True
        elif len(col) == 1:
            interior[col[0], x] = True
    return interior


def fill_outline_per_row(outline_mask: np.ndarray) -> np.ndarray:
    interior = np.zeros_like(outline_mask, dtype=bool)
    for y in range(outline_mask.shape[0]):
        row = np.where(outline_mask[y, :])[0]
        if len(row) >= 2:
            interior[y, int(row.min()):int(row.max()) + 1] = True
        elif len(row) == 1:
            interior[y, row[0]] = True
    return interior


def fill_outline_interior(outline_mask: np.ndarray) -> np.ndarray:
    return fill_outline_per_column(outline_mask) | fill_outline_per_row(outline_mask)


# === joint transform helpers ============================================
# Joints are tracked in the part's current local pixel space and pushed through
# the SAME ops as the image, so they stay pinned to the art.

def jt_translate(pts: dict, dx: float, dy: float) -> dict:
    return {k: [x + dx, y + dy] for k, (x, y) in pts.items()}


def jt_rot90_ccw(pts: dict, w: int) -> dict:
    """PIL.rotate(90, expand=True) is CCW. For a WxH image, (x,y) -> (y, (w-1)-x)."""
    return {k: [y, (w - 1) - x] for k, (x, y) in pts.items()}


def jt_rot90_cw(pts: dict, h: int) -> dict:
    """PIL.rotate(-90, expand=True) is CW. For a WxH image (h rows), (x,y) -> (h-1-y, x)."""
    return {k: [h - 1 - y, x] for k, (x, y) in pts.items()}


# === cutline-image auto-derivation ======================================

def derive_cuts_from_cutlines(source_rgb: np.ndarray, cutlines_rgb: np.ndarray,
                              method: str = "diff", threshold: int = 18) -> dict:
    """Derive shoulder_x, elbow_x, head_bbox and arm_y from a green cutline PNG.

    The green annotation contains: one large blob = the head outline curve; two
    short VERTICAL strokes across one arm = the shoulder cut (inner) and elbow cut
    (outer); and OPTIONALLY a short HORIZONTAL stroke marking the hip/waist line
    (the torso's bottom edge). Split them with connected-component labeling: the
    largest blob is the head outline; vertical strokes (height >> width) on the
    figure's LEFT half are the arm cuts; a wide/short stroke below the arm band is
    the hip line. Returns a dict of whatever it could derive (caller merges these
    UNDER any explicit config values)."""
    canvas_w = source_rgb.shape[1]
    canvas_h = source_rgb.shape[0]
    marks = annotation_mask(source_rgb, cutlines_rgb, method, threshold)
    if not marks.any():
        return {}
    # Dilate to bridge dashed strokes before labeling.
    lab, n = label(binary_dilation(marks, iterations=3))
    comps = []
    for i in range(1, n + 1):
        ys, xs = np.where(lab == i)
        comps.append({
            "n": len(xs),
            "x0": int(xs.min()), "y0": int(ys.min()),
            "x1": int(xs.max()), "y1": int(ys.max()),
            "cx": float(xs.mean()),
        })
    if not comps:
        return {}
    comps.sort(key=lambda c: c["n"], reverse=True)

    out: dict = {}
    head = comps[0]                       # largest green blob = head outline curve
    out["head_bbox"] = [head["x0"], head["y0"], head["x1"], head["y1"]]

    # Classify the remaining strokes by shape.
    verticals, horizontals = [], []
    for c in comps[1:]:
        if c["n"] < 50:
            continue
        w = max(c["x1"] - c["x0"], 1)
        h = max(c["y1"] - c["y0"], 1)
        if h >= 3 * w and c["cx"] < canvas_w / 2.0:
            verticals.append(c)           # arm cut stroke (left arm)
        elif w >= 2 * h:
            horizontals.append(c)         # candidate hip line (wide, short)

    verticals.sort(key=lambda c: c["cx"])  # ascending x: outer (elbow) ... inner (shoulder)
    if len(verticals) >= 2:
        out["elbow_x"] = int(round(verticals[0]["cx"]))      # outer, nearer the hand
        out["shoulder_x"] = int(round(verticals[-1]["cx"]))  # inner, nearer the body
        ytop = min(s["y0"] for s in verticals)
        ybot = max(s["y1"] for s in verticals)
        # Pad the cut-stroke band a touch so the arm crop never clips the silhouette
        # (symmetric pad keeps the shoulder-joint center y unchanged).
        pad = max(4, int(round(0.006 * canvas_h)))
        out["arm_y"] = [max(0, ytop - pad), min(canvas_h, ybot + pad)]
        # A horizontal stroke below the arm band marks the hip / torso-bottom line.
        arm_cy = (ytop + ybot) / 2.0
        below = [c for c in horizontals if c["y0"] > arm_cy]
        if below:
            hip = min(below, key=lambda c: c["y0"])          # the highest hip stroke
            out["torso_y_bottom"] = int(hip["y0"])
    return out


# === part extraction ====================================================

def extract_head(source_rgb, headless_rgb, head_outline_mask, head_bbox, pad):
    """Build the head silhouette from head_bbox. Returns (legacy_img, rig_img, joints).

    legacy_img is vertically FLIPPED (chin top) — the long-standing head.png
    convention for BodyPartSprites. rig_img is UN-flipped (crown top, neck bottom)
    for SkeletalBodyRig. Joints: neck (bottom-center) + crown (top-center).

    Interior mask = union of whatever silhouette cues are available:
      (a) green-outline interior fill (when a cutline image is present);
      (b) |full - headless| diff (when a headless source is present) — captures
          hair the outline fill can leave hollow;
      (c) chroma background-removal alpha (always) as the fallback silhouette.
    binary_fill_holes then closes interior gaps."""
    x0, y0, x1, y1 = head_bbox
    rgb_crop = source_rgb[y0:y1, x0:x1].copy()
    rgba = remove_background(rgb_crop)

    interior = np.zeros(rgb_crop.shape[:2], dtype=bool)
    if head_outline_mask is not None:
        interior |= fill_outline_interior(head_outline_mask[y0:y1, x0:x1])
    if headless_rgb is not None:
        headless_crop = headless_rgb[y0:y1, x0:x1].astype(np.int32)
        diff = np.abs(rgb_crop.astype(np.int32) - headless_crop).sum(axis=2)
        interior |= (diff > 40)
    if not interior.any():
        interior |= (rgba[..., 3] > 8)    # bg-removal silhouette fallback
    interior = binary_fill_holes(interior)

    rgba[~interior, 3] = 0

    ys, xs = np.where(interior)
    cx = float((xs.min() + xs.max()) / 2.0)
    neck = [cx, float(ys.max())]
    crown = [cx, float(ys.min())]

    ax0, ay0, ax1, ay1 = autocrop_box(rgba, pad)
    rgba = rgba[ay0:ay1, ax0:ax1]
    joints = jt_translate({"neck": neck, "crown": crown}, -ax0, -ay0)
    rig_img = Image.fromarray(rgba, mode="RGBA")
    legacy_img = rig_img.transpose(Image.FLIP_TOP_BOTTOM)
    return legacy_img, rig_img, joints


def head_interior_canvas(source_rgb, headless_rgb, head_outline_mask, head_bbox):
    """Canvas-sized bool mask of the head silhouette (same interior logic as
    extract_head). Used to subtract the head from the torso when no headless
    source exists, so the torso reads as a clean shoulder block."""
    x0, y0, x1, y1 = head_bbox
    rgb_crop = source_rgb[y0:y1, x0:x1]
    interior = np.zeros(rgb_crop.shape[:2], dtype=bool)
    if head_outline_mask is not None:
        interior |= fill_outline_interior(head_outline_mask[y0:y1, x0:x1])
    if headless_rgb is not None:
        diff = np.abs(rgb_crop.astype(np.int32) - headless_rgb[y0:y1, x0:x1].astype(np.int32)).sum(axis=2)
        interior |= (diff > 40)
    if not interior.any():
        interior |= (remove_background(rgb_crop)[..., 3] > 8)
    interior = binary_fill_holes(interior)
    full = np.zeros(source_rgb.shape[:2], dtype=bool)
    full[y0:y1, x0:x1] = interior
    return full


def extract_torso(torso_rgb, shoulder_x, shoulder_x_right, torso_y, arm_y, pad, head_cut=None):
    """Crop shoulders+upper body. `torso_rgb` is the headless source if available,
    else the plain source. `head_cut` (optional, canvas-space bool) is the head
    silhouette to delete when there is no headless source. Returns (legacy_img,
    rig_img, rig_joints).

    legacy_img is vertically FLIPPED (chest top) — the convention grimalkin and
    other races depend on. rig_img is UN-flipped (neck top, hips bottom). Joints:
    neck (top-edge midpoint), shoulders (the two arm cut lines at arm center-y),
    hips (bottom-edge quartiles)."""
    ty0, ty1 = torso_y
    rgb_crop = torso_rgb[ty0:ty1, shoulder_x:shoulder_x_right].copy()
    rgba = remove_background(rgb_crop)
    if head_cut is not None:
        rgba[head_cut[ty0:ty1, shoulder_x:shoulder_x_right], 3] = 0

    arm_cy = (arm_y[0] + arm_y[1]) / 2.0 - ty0
    width = shoulder_x_right - shoulder_x
    a = rgba[..., 3]
    rows = np.where(a.any(axis=1))[0]
    top_y = int(rows.min()); bot_y = int(rows.max())
    top_xs = np.where(a[top_y, :] > 8)[0]
    bot_xs = np.where(a[bot_y, :] > 8)[0]
    bw = bot_xs.max() - bot_xs.min()
    joints = {
        "neck": [float((top_xs.min() + top_xs.max()) / 2.0), float(top_y)],
        "shoulder_l": [0.0, arm_cy],
        "shoulder_r": [float(width), arm_cy],
        "hip_l": [float(bot_xs.min() + bw * 0.25), float(bot_y)],
        "hip_r": [float(bot_xs.min() + bw * 0.75), float(bot_y)],
    }

    ax0, ay0, ax1, ay1 = autocrop_box(rgba, pad)
    rgba = rgba[ay0:ay1, ax0:ax1]
    joints = jt_translate(joints, -ax0, -ay0)
    rig_img = Image.fromarray(rgba, mode="RGBA")
    legacy_img = rig_img.transpose(Image.FLIP_TOP_BOTTOM)
    return legacy_img, rig_img, joints


def extract_arm_segment(source_rgb, x0, x1, proximal_x, distal_x, arm_y, pad):
    """Cut ONE native arm segment (no mirroring) and rotate it so its proximal
    (body-side) joint lands at the TOP of the sprite, matching the rig convention.

    proximal_x / distal_x are CANVAS x of the two joints; distal_x None -> use the
    silhouette's far edge (forearm wrist has no cut line). The body side is whichever
    of proximal_x is larger/smaller:
      * LEFT arm  -> proximal is the HIGH-x (inner) edge; rotate 90 CCW puts it on top.
      * RIGHT arm -> proximal is the LOW-x (inner) edge;  rotate 90 CW  puts it on top.
    Because each arm is cut from its OWN pixels, left and right are distinct, correctly
    handed sprites — the rig never flips them, so a shared rotation offset can't make
    one bend the wrong way."""
    ay_top, ay_bot = arm_y
    rgb_crop = source_rgb[ay_top:ay_bot, x0:x1].copy()
    rgba = remove_background(rgb_crop)

    a = rgba[..., 3]
    ys = np.where(a.any(axis=1))[0]
    arm_cy = float((ys.min() + ys.max()) / 2.0)
    xs = np.where(a.any(axis=0))[0]
    mid = (x0 + x1) / 2.0
    proximal_is_high = proximal_x > mid          # body side on the right of the strip => LEFT arm
    if distal_x is None:
        distal_local_x = float(xs.min()) if proximal_is_high else float(xs.max())
    else:
        distal_local_x = float(distal_x - x0)
    joints = {
        "proximal": [float(proximal_x - x0), arm_cy],
        "distal":   [distal_local_x, arm_cy],
    }

    ax0, ay0, ax1, ay1 = autocrop_box(rgba, pad)
    rgba = rgba[ay0:ay1, ax0:ax1]
    joints = jt_translate(joints, -ax0, -ay0)
    if proximal_is_high:
        # LEFT arm: CCW so the inner (high-x) end goes to the top.
        w = rgba.shape[1]
        img = Image.fromarray(rgba, mode="RGBA").rotate(90, expand=True)
        joints = jt_rot90_ccw(joints, w)
    else:
        # RIGHT arm: CW so the inner (low-x) end goes to the top.
        h = rgba.shape[0]
        img = Image.fromarray(rgba, mode="RGBA").rotate(-90, expand=True)
        joints = jt_rot90_cw(joints, h)
    return img, joints


def extract_foot(source_rgb, foot_bbox, pad):
    """Cut a single foot/toe stub from the source. The art's foot points toward the
    character FRONT (+Y down in the source). We keep it un-rotated; the rig orients
    it via the leg animation. Joint 'ankle' = top-center (toward the hip), 'toe' =
    bottom-center (toward the front). Returns (img, joints)."""
    x0, y0, x1, y1 = foot_bbox
    rgba = remove_background(source_rgb[y0:y1, x0:x1].copy())
    a = rgba[..., 3]
    rows = np.where(a.any(axis=1))[0]
    if len(rows) == 0:
        img = Image.fromarray(rgba, mode="RGBA")
        return img, {"ankle": [0.0, 0.0], "toe": [0.0, float(img.size[1])]}
    top_y = int(rows.min()); bot_y = int(rows.max())
    top_xs = np.where(a[top_y, :] > 8)[0]
    bot_xs = np.where(a[bot_y, :] > 8)[0]
    joints = {
        "ankle": [float((top_xs.min() + top_xs.max()) / 2.0), float(top_y)],
        "toe":   [float((bot_xs.min() + bot_xs.max()) / 2.0), float(bot_y)],
    }
    ax0, ay0, ax1, ay1 = autocrop_box(rgba, pad)
    rgba = rgba[ay0:ay1, ax0:ax1]
    joints = jt_translate(joints, -ax0, -ay0)
    return Image.fromarray(rgba, mode="RGBA"), joints


# === geometry resolution ================================================

def _derive_torso_y(source_rgb, shoulder_x, shoulder_x_right, arm_y, bottom_hint):
    """Fallback torso crop window when none is configured. Top = the arm band top
    (shoulders sit at the arm line); bottom = the hip-line annotation if the cutline
    image marked one (bottom_hint), else the lowest central silhouette row — which
    usually overshoots into the legs and is worth tuning explicitly per race."""
    top = int(arm_y[0])
    if bottom_hint is not None:
        return [top, int(bottom_hint)]
    crop = remove_background(source_rgb[:, shoulder_x:shoulder_x_right])
    rows = np.where(crop[..., 3].any(axis=1))[0]
    bottom = int(rows.max()) if len(rows) else source_rgb.shape[0]
    return [top, bottom]


def resolve_geometry(cfg: dict, source_rgb, cutlines_rgb):
    """Merge explicit config over cutline-derived values; fill remaining defaults."""
    canvas_h, canvas_w = source_rgb.shape[0], source_rgb.shape[1]
    method = cfg.get("annotation_detect", "diff")
    threshold = int(cfg.get("annotation_diff_threshold", 18))
    derived = derive_cuts_from_cutlines(source_rgb, cutlines_rgb, method, threshold) \
        if cutlines_rgb is not None else {}

    def pick(key):
        v = cfg.get(key, None)
        return v if v is not None else derived.get(key, None)

    geo = {"canvas_w": canvas_w, "canvas_h": canvas_h, "pad": int(cfg.get("pad", DEFAULT_PAD))}
    geo["shoulder_x"] = pick("shoulder_x")
    geo["elbow_x"] = pick("elbow_x")
    geo["head_bbox"] = pick("head_bbox")
    geo["arm_y"] = pick("arm_y")
    missing = [k for k in ("shoulder_x", "elbow_x", "head_bbox", "arm_y") if geo[k] is None]
    if missing:
        raise ValueError(
            "could not resolve %s - add a 'cutlines' PNG or set them explicitly in "
            "body_slice_config.json" % ", ".join(missing))

    sxr = pick("shoulder_x_right")
    geo["shoulder_x_right"] = int(sxr) if sxr is not None else canvas_w - int(geo["shoulder_x"])
    geo["shoulder_x"] = int(geo["shoulder_x"]); geo["elbow_x"] = int(geo["elbow_x"])
    geo["head_bbox"] = [int(v) for v in geo["head_bbox"]]
    geo["arm_y"] = [int(v) for v in geo["arm_y"]]

    # Right arm cuts. Explicit elbow_x_right wins; else mirror the left arm about
    # the canvas center so the right arm is cut from its OWN (native) pixels.
    exr = pick("elbow_x_right")
    geo["elbow_x_right"] = int(exr) if exr is not None else canvas_w - geo["elbow_x"]

    # Feet (optional). foot_bbox_l / foot_bbox_r are [x0,y0,x1,y1] on the canvas.
    geo["foot_bbox_l"] = cfg.get("foot_bbox_l")
    geo["foot_bbox_r"] = cfg.get("foot_bbox_r")

    ty = pick("torso_y")
    if ty is None:
        ty = _derive_torso_y(source_rgb, geo["shoulder_x"], geo["shoulder_x_right"],
                             geo["arm_y"], derived.get("torso_y_bottom"))
        geo["torso_y_derived"] = True
    geo["torso_y"] = [int(ty[0]), int(ty[1])]
    return geo


# === per-race driver ====================================================

def _load_rgb(path: Path):
    return np.array(Image.open(path).convert("RGB"))


def process_race(race: str, cfg: dict) -> None:
    assets = BODY_PARTS / race
    src_path = assets / cfg["source"]
    if not src_path.exists():
        raise FileNotFoundError("source not found: %s" % src_path)
    source = _load_rgb(src_path)

    headless = None
    if cfg.get("headless"):
        hp = assets / cfg["headless"]
        headless = _load_rgb(hp) if hp.exists() else None
        if headless is None:
            print("  note: headless '%s' not found - using plain source" % cfg["headless"])

    cutlines = None
    head_outline = None
    if cfg.get("cutlines"):
        cp = assets / cfg["cutlines"]
        if cp.exists():
            cutlines = _load_rgb(cp)
            head_outline = detect_head_cut_mask(
                source, cutlines,
                cfg.get("annotation_detect", "diff"),
                int(cfg.get("annotation_diff_threshold", 18)))
        else:
            print("  note: cutlines '%s' not found - relying on explicit/derived values" % cfg["cutlines"])

    geo = resolve_geometry(cfg, source, cutlines)
    print("  geometry: shoulder_x=%d elbow_x=%d shoulder_x_right=%d head_bbox=%s arm_y=%s torso_y=%s%s" % (
        geo["shoulder_x"], geo["elbow_x"], geo["shoulder_x_right"], geo["head_bbox"],
        geo["arm_y"], geo["torso_y"], "  (torso_y derived)" if geo.get("torso_y_derived") else ""))

    torso_src = headless if headless is not None else source
    # No headless source? Subtract the head silhouette from the torso so it reads
    # as a clean shoulder block (the head sprite covers the gap at runtime).
    head_cut = None
    if headless is None and head_outline is not None:
        head_cut = head_interior_canvas(source, headless, head_outline, geo["head_bbox"])
        print("  (no headless - subtracting head outline from torso)")
    head_legacy, head_rig, head_j = extract_head(source, headless, head_outline, geo["head_bbox"], geo["pad"])
    torso_legacy, torso_rig, torso_j = extract_torso(
        torso_src, geo["shoulder_x"], geo["shoulder_x_right"], geo["torso_y"], geo["arm_y"], geo["pad"], head_cut)

    # --- Both arms cut natively from their own pixels (no mirroring) ---
    # LEFT arm:  upper = [elbow_x .. shoulder_x] (proximal = shoulder_x, inner);
    #            fore  = [0 .. elbow_x]           (proximal = elbow_x).
    # RIGHT arm: upper = [shoulder_x_right .. elbow_x_right] (proximal = shoulder_x_right);
    #            fore  = [elbow_x_right .. canvas_w]          (proximal = elbow_x_right).
    ay, pad = geo["arm_y"], geo["pad"]
    cw = geo["canvas_w"]
    lua_img, lua_j = extract_arm_segment(source, geo["elbow_x"], geo["shoulder_x"], geo["shoulder_x"], geo["elbow_x"], ay, pad)
    lfa_img, lfa_j = extract_arm_segment(source, 0, geo["elbow_x"], geo["elbow_x"], None, ay, pad)
    rua_img, rua_j = extract_arm_segment(source, geo["shoulder_x_right"], geo["elbow_x_right"], geo["shoulder_x_right"], geo["elbow_x_right"], ay, pad)
    rfa_img, rfa_j = extract_arm_segment(source, geo["elbow_x_right"], cw, geo["elbow_x_right"], None, ay, pad)

    outputs = {
        "head.png": head_legacy,
        "head_rig.png": head_rig,
        "torso.png": torso_legacy,
        "torso_rig.png": torso_rig,
        "upper_arm_l.png": lua_img,
        "forearm_l.png": lfa_img,
        "upper_arm_r.png": rua_img,
        "forearm_r.png": rfa_img,
        # legacy aliases (grimalkin/djargo still load these via BodyPartSprites)
        "upper_arm.png": lua_img,
        "forearm.png": lfa_img,
    }

    # --- Feet (optional) ---
    foot_parts = {}
    if geo.get("foot_bbox_l") and geo.get("foot_bbox_r"):
        lfoot_img, lfoot_j = extract_foot(source, [int(v) for v in geo["foot_bbox_l"]], pad)
        rfoot_img, rfoot_j = extract_foot(source, [int(v) for v in geo["foot_bbox_r"]], pad)
        outputs["leg_l.png"] = lfoot_img
        outputs["leg_r.png"] = rfoot_img
        foot_parts = {"l": (lfoot_img, lfoot_j), "r": (rfoot_img, rfoot_j)}

    for name, img in outputs.items():
        img.save(assets / name)
        print("  wrote %s  (%dx%d)" % (name, img.size[0], img.size[1]))

    def part(file, img, joints, pivot_key):
        return {"file": file, "size": [img.size[0], img.size[1]],
                "pivot": [round(joints[pivot_key][0], 1), round(joints[pivot_key][1], 1)],
                "joints": {k: [round(v[0], 1), round(v[1], 1)] for k, v in joints.items()}}

    parts = {
        "head": part("head_rig.png", head_rig, head_j, "neck"),
        "torso": part("torso_rig.png", torso_rig, torso_j, "neck"),
        "upper_arm_l": part("upper_arm_l.png", lua_img, {"shoulder": lua_j["proximal"], "elbow": lua_j["distal"]}, "shoulder"),
        "forearm_l":   part("forearm_l.png", lfa_img, {"elbow": lfa_j["proximal"], "wrist": lfa_j["distal"]}, "elbow"),
        "upper_arm_r": part("upper_arm_r.png", rua_img, {"shoulder": rua_j["proximal"], "elbow": rua_j["distal"]}, "shoulder"),
        "forearm_r":   part("forearm_r.png", rfa_img, {"elbow": rfa_j["proximal"], "wrist": rfa_j["distal"]}, "elbow"),
    }
    for side, (fimg, fj) in foot_parts.items():
        parts["leg_" + side] = part("leg_%s.png" % side, fimg, fj, "ankle")
    # tuning precedence: canonical defaults < config < hand-edits in an existing
    # manifest. MERGED (not replaced) so a hand-edited manifest that omits a key
    # never silently drops it, and re-running stays deterministic.
    tuning = dict(DEFAULT_TUNING)
    tuning.update(cfg.get("tuning", {}))
    mpath = assets / "body_manifest.json"
    if mpath.exists():
        try:
            prev_tuning = json.loads(mpath.read_text()).get("tuning")
            if isinstance(prev_tuning, dict):
                tuning.update(prev_tuning)
                print("  (kept existing tuning edits)")
        except Exception:
            pass
    attach = [
        ["torso", "neck", "head", "neck"],
        ["torso", "shoulder_l", "upper_arm_l", "shoulder"],
        ["upper_arm_l", "elbow", "forearm_l", "elbow"],
        ["torso", "shoulder_r", "upper_arm_r", "shoulder"],
        ["upper_arm_r", "elbow", "forearm_r", "elbow"],
    ]
    if foot_parts:
        attach += [
            ["torso", "hip_l", "leg_l", "ankle"],
            ["torso", "hip_r", "leg_r", "ankle"],
        ]
    manifest = {
        # schema 2: per-side arm parts (upper_arm_l/r, forearm_l/r) cut from their
        # own native pixels — no flip_h mirroring. Optional leg_l/leg_r foot parts.
        "schema": 2,
        "source": cfg["source"],
        "canvas": [geo["canvas_w"], geo["canvas_h"]],
        "unit_px": float(geo["shoulder_x_right"] - geo["shoulder_x"]),
        "tuning": tuning,
        "parts": parts,
        "attach": attach,
    }
    mpath.write_text(json.dumps(manifest, indent=2))
    print("  wrote body_manifest.json")
    for n, p in parts.items():
        print("    %-10s size=%s pivot=%s joints=%s" % (n, p["size"], p["pivot"], p["joints"]))


def load_config() -> dict:
    cfg = json.loads(CONFIG_PATH.read_text())
    cfg.pop("_README", None)
    return cfg


def main(argv) -> None:
    config = load_config()
    races = argv[1:] if len(argv) > 1 else list(config.keys())
    for race in races:
        if race not in config:
            print("[skip] '%s' has no entry in body_slice_config.json" % race)
            continue
        print("== %s ==" % race)
        try:
            process_race(race, config[race])
        except (FileNotFoundError, ValueError) as e:
            print("  [skip] %s" % e)


if __name__ == "__main__":
    main(sys.argv)
