"""Repaint a race at one shared steep overhead camera, by painting over a rendered guide.

    python -m tools.rigkit.gen_plan guide [--race orc] [--tilt 15]
    python -m tools.rigkit.gen_plan gen   [--race orc] [--n 4] [--tag final] [--guide tint|clay] [--no-swatch] [--tilt 15]
    python -m tools.rigkit.gen_plan check [--race orc] [--tag final | image.png ...]
    python -m tools.rigkit.gen_plan sheet [--race orc] [--tag final | image.png ...]
    python -m tools.rigkit.gen_plan dome  [--race orc] [--tag final | image.png ...]     (tilt 0 sets only)
    python -m tools.rigkit.gen_plan headsize [--race orc] [--legacy orc/default]

--tilt is the camera's angle off vertical in degrees, leaning toward the character's FRONT (default
DEFAULT_TILT = 15, or a race's own "tilt"). 0 is the strict plan view of pilot 3 and still renders
that guide (dome head, pec shelf, toe pegs, files guide_*.png). A tilted guide (files
guide_t<deg>_*.png) uses the anatomical proxy: a head with brow, nose, jaw and tusks, one chest mass
with pecs, a belly and real foot fronts, so the tilt reveals a face sliver and foot fronts by geometry.
The projection is exact (ray / ellipsoid z-buffer; clay, mask, labels and JSON share it), with ONE
deliberate cheat: the tilted proxy stands on a floor at z = floor_z (0.70), i.e. its legs are about a
quarter of their real length. A true 15 degree orthographic view of a figure with real legs is about
36 % deep on this proxy (the legs alone add 0.26 * leg length) and shows the legs, like the old orc
painting (38 %); the target of 22-30 % with the feet peeking out under the belly needs the short
stance. Set a race's floor_z to 0.0 to see the honest version.

guide   renders the race's proxy figure from RACES[race] with an orthographic camera
        straight above it and writes, to tools/rigkit/out/plan/<race>/:
            guide_clay.png    grey clay render (near-vertical light, crown highlight)
            guide_tint.png    the same render multiplied by the race's skin colour
            guide_mask.png    silhouette
            guide_labels.png  per-part label map in derive.PALETTE colours on black,
                              ready to be a pack's labels.png for `build_race`
            guide.json        measurements + the frames derive.py reads from the labels
            swatch.png        small upper-arm skin patch cut from the race's current painting
gen     asks Gemini (gemini-3-pro-image, 16:9) to paint over the guide, N times with the
        SAME prompt and inputs. Each candidate <tag>_<i>.png gets a <tag>_<i>.json
        (prompt, inputs, model); the prompt and a snapshot of the inputs are saved once
        per tag as <tag>.prompt.txt, <tag>.in1_guide.png, <tag>.in2_swatch.png.
check   per candidate: grey-keys the painting, then reports silhouette IoU against the
        guide mask, depth/span, a left-right symmetry score and how flat the grey ground
        is; writes <name>_iou.png overlays, <tag>_check.json and <tag>_heads.png, a zoomed
        head-crop contact sheet. IoU cannot see a painted-on face, so the gate also has a head
        test (head_metrics: dark strokes on the dome, dark / ivory in the band south of its rim,
        highlight offset). It is calibrated on about 20 orc images only: still LOOK at the head sheet.

dome    optional deterministic fix-up, writes <name>_dome.png and checks it: the south half of
        the skull circle is re-laid from the radial colour profile of its own north half, which
        the model always paints as clean scalp. Pixels outside the guide skull circle are kept.

The proxy is analytic primitives (ellipsoids, tapered capsules) in a world where
x = west-east, y = north-south (south = +, the figure faces south = image bottom),
z = height, and the fingertip-to-fingertip half span is 1.0. The image is the per-pixel
MAX height, so the same pass yields the silhouette and the label map.

A new race is a new RACES entry (proportions, colours, words), not new code.
Tilted-proxy knobs a race may set (all optional, the orc uses the defaults): foot_x_tilt, foot_w,
toe_y_tilt, tusk_x_tilt, head_z, head_fwd, jaw, brow, leg_r=(hip, ankle radius), nose_tilt=(extra
reach, radius factor), ear_tilt=(root radius, tip sweep back, tip rise), face_scale and face_fwd (size
and forward offset of the face forms, for a hair cap wider than the skull), and an "anat" dict of any
keys that should differ from the plan guide (see tilt_params). The approved look is the orc's
tilt15_final set; orc, human, halfling and goblin guides are tuned to that camera (depth / span
0.26-0.28), and only orc and goblin have been painted.

HEAD SIZE CONVENTION (tilted guides). A repainted race keeps the in-game head size of the pack it
replaces. install_plan scales a new pack so its fingertip span equals the legacy pack's, so the head
is preserved when (head frame radius / half span) is the same in the guide as in the legacy pack; the
head frame is derive.py's skull circle, the measure helmets are fitted to. A legacy three-quarter
painting has a much bigger head than true proportions seen from above (orc: x1.35), so every race
entry that replaces a legacy pack sets
    head_scale = <value printed by `gen_plan headsize --race R --legacy R/default`>
(head_scale_for() below; it is stored as a number so a guide never depends on pack files). head_scale
grows the WHOLE tilted head (cranium, brow, cheeks, jaw, nose, tusks, ears) about the skull base
(head_pivot_z, default 1.64), so the face stays the same share of the head: a strip on its bottom
edge. head_back (default 0; negative = south) then slides the scaled head north. A bigger head
overhangs the upper back and covers more chest: the orc raises the pivot (1.70) and slides the head a
little south so depth / span stays inside DEPTH_BAND_TILT. The printed value is a linear estimate;
set it, run headsize again and nudge until in_game_head_now_vs_legacy reads 1.00 (orc: 1.362).
Entries without head_scale render exactly as before.

What the recipe encodes (docs/rigging_rewrite.md, "Pilot 2"):
  (the items below are the tilt-0 recipe; for a tilted guide the face, chest and feet are modelled as
   anatomy instead and build_prompt_tilt names each at the size the guide has it)
  * the guide gives the camera; the prompt never has to ask for it;
  * the skull is a plain round dome centred on the shoulder axis with only tiny
    nose-tip / tusk-tip bumps on its south rim, and the prompt names no other part of
    the face, because the model paints a face wherever the guide leaves room for one;
    on the orc even a nose nub between the tusks was painted as a brow or muzzle (11 of 13
    images), while tusks alone gave a clean dome (8 of 8), so the orc has nose=(0, 0);
  * toes are shaped in the guide (short separate toe ends); the prompt only says what
    the nubs are, because naming a feature grows it;
  * the tinted guide + a small upper-arm swatch carry the house style without carrying
    the old painting's camera.
Prompts are phrased positively only. `gen` needs GEMINI_API_KEY.
"""
import argparse
import glob
import io
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

from .derive import PALETTE, LabelError, derive_frames

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(HERE, "out", "plan")
W, H = 1376, 768            # what gemini-3-pro-image returns at 16:9
SS = 2
BG = 128
DEFAULT_TILT = 15.0       # degrees off vertical, toward the character's front; 0 = strict plan view
FACE_DARK_MAX, MUZZLE_DARK_MAX, HL_OFFSET_MAX = 0.004, 0.06, 0.35   # head gate; see head_metrics
DEPTH_BAND_PLAN = (0.18, 0.26)      # depth / span the auto gate accepts at tilt 0 ...
DEPTH_BAND_TILT = (0.22, 0.30)      # ... and for a tilted guide (the old three-quarter orc was 0.38)
IOU_MIN_TILT = 0.90                 # a natural repaint of the anatomy outranks tracing the proxy

# part -> derive.PALETTE name. derive's _l/_r are IMAGE left/right.
PARTS = ["background", "body", "face", "upperarm_l", "upperarm_r", "forearm_l", "forearm_r",
         "hand_l", "hand_r", "foot_l", "foot_r", "leg_l", "leg_r"]
PART_RGB = [(0, 0, 0)] + [PALETTE[n] for n in PARTS[1:]]

# ---------------------------------------------------------------- races
# Proportions in half-span units. "look" is the positive description of the character;
# "head_extras" says what sits on the skull's rim (only things that jut past the skull).
RACES = {
    "orc": dict(
        shoulder_half=0.30, delt_r=0.105,
        trunk_depth_n=0.165,            # upper back, north of the shoulder line
        chest_depth_s=0.212,            # pec shelf, south of the shoulder line
        belly_depth_s=0.190, belly_half=0.20, pec_half=0.128,
        skull_r=0.108, skull_y=0.004,   # round dome, centred on the shoulder axis
        nose=(0.0, 0.0), tusk=0.025, tusk_x=0.052, ear_len=0.062,
        upper_arm_r=(0.088, 0.072), forearm_r=(0.080, 0.053),
        elbow_x=0.585, wrist_x=0.805,
        palm_rx=0.070, palm_ry=0.064, finger_r=0.0145,
        foot_x=0.128, toe_y=0.238, toe_r=0.023,
        foot_x_tilt=0.150, foot_w=0.066, toe_y_tilt=0.188, tusk_x_tilt=0.046,   # tilted proxy only
        # in-game head size of orc/default: `gen_plan headsize --race orc --legacy orc/default`
        head_scale=1.362, head_back=-0.012, head_pivot_z=1.70,
        skin=(118, 136, 70), ivory=(236, 226, 196),
        swatch=dict(src="Rigs/races/orc/default/body.png", box=(630, 20, 810, 170)),
        look="an orc with olive-green skin, a bald scalp, pointed ears, heavy muscles and ivory tusk tips",
        head_extras="Two small ivory tusk points touch the outside of the dome's lower rim, set well apart, "
                    "each one a separate little cone lying on plain smooth chest skin. A pointed ear sticks "
                    "out sideways from each side of the dome.",
        skin_words="fresh saturated olive-green hue, its lighter yellow-green highlights",
        line_words="heavy, crisp, near-black green contour line",
        # tilted camera (see build_prompt_tilt): what the guide shows, then how to paint it
        face_tilt="a heavy brow ridge whose overhang shades the eye sockets into two dark slits, right "
                  "under it the broad tip of the nose, and just behind the nose the front of the jaw with "
                  "one small ivory tusk rising from each corner of the lower lip. Brow, nose tip and "
                  "tusks sit close together, squeezed by the steep view, and the tusks and lower lip "
                  "are the bottom edge of the head, with the chest starting directly below them. A "
                  "pointed ear sticks out sideways from each side of the head.",
        torso_tilt="first the top plane of the broad chest with its two pectoral muscles meeting at the "
                   "breastbone, then, tucked under the chest, a short glimpse of the upper belly.",
        face_paint="the head as a big bald scalp with, in the narrow strip along its bottom edge, a natural "
                   "orc face strongly foreshortened from above, a scowling brow over shadowed eye slits, a "
                   "broad nose tip and the front of a heavy jaw with its two small tusks",
        torso_paint="the torso as one broad chest with two full pectoral muscles and a firm upper belly "
                    "below them",
    ),
    # human and halfling: tilted guides tuned, never painted. "anat" holds what only the tilted proxy
    # uses (see tilt_params): for a haired race skull_r is there the HAIR CAP, and face_scale / face_fwd
    # size and place the face strip under its fringe.
    "human": dict(
        shoulder_half=0.25, delt_r=0.08, trunk_depth_n=0.125, chest_depth_s=0.13,
        belly_depth_s=0.120, belly_half=0.17, pec_half=0.11,
        skull_r=0.090, skull_y=0.004,
        nose=(0.011, 0.009), tusk=0.0, tusk_x=0.0, ear_len=0.0,
        upper_arm_r=(0.062, 0.052), forearm_r=(0.052, 0.036),
        elbow_x=0.57, wrist_x=0.83,
        palm_rx=0.055, palm_ry=0.048, finger_r=0.010,
        foot_x=0.085, toe_y=0.180, toe_r=0.012,
        anat=dict(skull_r=0.100, face_scale=0.90, face_fwd=0.012, chest_depth_s=0.165, belly_depth_s=0.150,
                  foot_x_tilt=0.112, foot_w=0.050, toe_y_tilt=0.168, leg_r=(0.070, 0.048)),
        skin=(214, 160, 120), ivory=(236, 226, 196), hair=(150, 78, 48),
        swatch=dict(src="Rigs/races/human/default/body.png", box=(715, 50, 845, 178)),
        look="a human man with light tan skin, short wavy auburn-brown hair and an athletic build",
        dome="cap of short wavy hair", dome_cover="hair", dome_cover_tilt="hair",
        head_extras="At the middle of the dome's lower rim a small rounded nose tip pokes out.",
        skin_words="warm skin hue, its lighter highlights",
        line_words="heavy, crisp, dark brown contour line",
        face_tilt="the fringe of the hair, right under it the brow shading the eye sockets into two dark "
                  "slits, then the bridge and tip of the nose, and just behind the nose the lips and the "
                  "front of the chin. Brow, nose tip and chin sit close together, squeezed by the steep "
                  "view, and the chin is the bottom edge of the head, with the chest starting directly "
                  "below it.",
        torso_tilt="first the top plane of the chest with its two pectoral muscles meeting at the "
                   "breastbone, then, tucked under the chest, a short glimpse of the flat upper belly.",
        face_paint="the head as a cap of short wavy hair seen from above with, in the narrow strip along "
                   "its bottom edge, a natural human face strongly foreshortened from above, calm brows "
                   "over shadowed eyes, a nose tip, closed lips and the front of the chin",
        torso_paint="the torso as one athletic chest with two pectoral muscles and a flat upper belly "
                    "below them",
    ),
    # Small and slim with a big head: the hair cap is wider than the trunk is deep, so it overhangs the
    # back, and the round belly juts further south than the chest.
    "halfling": dict(
        shoulder_half=0.27, delt_r=0.075, trunk_depth_n=0.115, chest_depth_s=0.170,
        belly_depth_s=0.215, belly_half=0.20, pec_half=0.115,
        skull_r=0.185, skull_y=0.006,
        nose=(0.012, 0.009), tusk=0.0, tusk_x=0.0, ear_len=0.0,
        upper_arm_r=(0.062, 0.050), forearm_r=(0.050, 0.036),
        elbow_x=0.56, wrist_x=0.82,
        palm_rx=0.058, palm_ry=0.052, finger_r=0.011,
        foot_x=0.105, toe_y=0.228, toe_r=0.020,
        anat=dict(skull_r=0.140, face_scale=1.05, face_fwd=0.030, head_z=1.76, chest_depth_s=0.150,
                  belly_depth_s=0.168, foot_x_tilt=0.142, foot_w=0.058, toe_y_tilt=0.176,
                  leg_r=(0.075, 0.052)),
        skin=(206, 152, 122), ivory=(236, 226, 196), hair=(150, 108, 62),
        swatch=dict(src="Rigs/races/halfling_male/default/body.png", box=(170, 150, 300, 260)),
        look="a halfling man with warm light skin, a soft slim build and a big head of thick wavy "
             "light-brown hair",
        dome="cap of thick wavy hair", dome_cover="hair", dome_cover_tilt="hair",
        head_extras="At the middle of the dome's lower rim a small rounded nose tip touches the rim, lying "
                    "on plain smooth chest skin.",
        skin_words="warm peach skin hue, its lighter highlights",
        line_words="heavy, crisp, dark red-brown contour line",
        face_tilt="the fringe of the thick hair, right under it the brow shading the eye sockets into two "
                  "dark slits, then the round tip of the nose, and just behind the nose the lips and the "
                  "front of a soft round chin. Brow, nose tip and chin sit close together, squeezed by the "
                  "steep view, and the chin is the bottom edge of the head, with the chest starting "
                  "directly below it.",
        torso_tilt="first the top plane of the soft chest, then, below the chest, the top of a small round "
                   "belly.",
        face_paint="the head as a big cap of thick wavy hair seen from above with, in the narrow strip "
                   "along its bottom edge, a natural halfling face strongly foreshortened from above, "
                   "friendly brows over shadowed eyes, a round nose tip, closed lips and a soft chin",
        torso_paint="the torso as one soft chest with a small round belly below it",
    ),
    # Male goblin: small and wiry with a big bald head, big pointed ears and a long pointed nose.
    "goblin": dict(
        shoulder_half=0.25, delt_r=0.064, trunk_depth_n=0.115, chest_depth_s=0.145,
        belly_depth_s=0.168, belly_half=0.170, pec_half=0.092,
        skull_r=0.140, skull_y=0.004,
        nose=(0.0, 0.0), tusk=0.012, tusk_x=0.060, ear_len=0.200,
        upper_arm_r=(0.052, 0.044), forearm_r=(0.046, 0.034),
        elbow_x=0.56, wrist_x=0.80,
        palm_rx=0.066, palm_ry=0.058, finger_r=0.0125,
        foot_x=0.120, toe_y=0.210, toe_r=0.020,
        foot_x_tilt=0.122, foot_w=0.056, toe_y_tilt=0.176, tusk_x_tilt=0.058,
        head_z=1.76, jaw=0.90, nose_tilt=(0.018, 0.74), ear_tilt=(0.046, 0.085, 0.075),
        leg_r=(0.070, 0.048),
        skin=(128, 136, 66), ivory=(236, 226, 196),
        swatch=dict(src="Rigs/races/goblin_male/default/body.png", box=(718, 150, 818, 228)),
        look="a male goblin with olive-green skin, a big bald head, very large pointed ears, a long pointed "
             "nose and a small wiry body with thin sinewy arms",
        head_extras="Two tiny ivory fang points touch the outside of the dome's lower rim, set well apart. "
                    "A very large pointed ear sticks out sideways from each side of the dome.",
        skin_words="muted olive-green hue, its lighter yellow-green highlights",
        line_words="heavy, crisp, near-black green contour line",
        face_tilt="a bony brow ridge whose overhang shades the eye sockets into two dark slits, right "
                  "under it a long pointed nose that juts forward to a narrow tip, and just behind the "
                  "nose the front of a narrow jaw with one tiny ivory fang rising from each corner of the "
                  "lower lip. Brow, nose and fangs sit close together, squeezed by the steep view, and "
                  "the nose tip and lower lip are the bottom edge of the head, with the chest starting "
                  "directly below them. A very large pointed ear, a long leaf shape, sweeps out sideways "
                  "and a little backward from each side of the head, lying over the shoulder.",
        torso_tilt="first the top plane of a narrow wiry chest with two small flat pectoral muscles meeting "
                   "at the breastbone, then, tucked under the chest, a short glimpse of a small round "
                   "belly.",
        face_paint="the head as a big bald scalp with, in the narrow strip along its bottom edge, a natural "
                   "goblin face strongly foreshortened from above, a sly scowling brow over shadowed eye "
                   "slits, a long pointed nose the same olive-green as the rest of the skin, and a narrow "
                   "jaw with its two tiny fangs; each big ear a thin leaf of skin with a shallow inner "
                   "hollow",
        torso_paint="the torso as one narrow wiry chest with two small flat pectoral muscles and a small "
                    "round belly below them",
    ),
}


def tilt_params(p, anat=True):
    """A race's proportions for the tilted (anatomical) proxy: its own entry with the optional
    "anat" dict laid over it, so a race can differ between the plan guide and the tilted guide
    (a hair cap that is not a skull, a belly the tilt would otherwise drop over the feet)."""
    return dict(p, **p["anat"]) if anat and "anat" in p else p


def primitives(p, anat=False):
    """List of (part, centre xyz, radii xyz): every primitive is an ellipsoid. part may carry a
    ':tag' suffix (tusk, skull). Tapered capsules are chains of ellipsoids (`cap`, `rod`).

    anat=False  the strict plan-view proxy: a plain dome head, a pec shelf, toe pegs.
    anat=True   the tilted-camera proxy: the parts a tilted camera can see are modelled as anatomy
                (a head with brow, nose, jaw and tusks; one chest mass with pecs; a belly; feet)."""
    p = tilt_params(p, anat)
    P = []
    sh = p["shoulder_half"]
    zs = 1.56  # shoulder / arm axis height

    def ell(part, c, r):
        P.append((part, tuple(float(v) for v in c), tuple(float(v) for v in r)))

    def rod(part, a, b, ra, rb, kz=1.0):
        """Tapered capsule between two 3D points, as a chain of ellipsoids (r, r, r * kz)."""
        a, b = np.array(a, float), np.array(b, float)
        n = int(np.ceil(np.linalg.norm(b - a) / (0.14 * max(min(ra, rb), 0.004)))) + 1
        for t in np.linspace(0, 1, min(max(n, 2), 90)):
            r = ra + (rb - ra) * t
            ell(part, a + (b - a) * t, (r, r, r * kz))

    def cap(part, a, b, ra, rb, z, kz=1.0):     # level capsule at height z
        rod(part, (a[0], a[1], z), (b[0], b[1], z), ra, rb, kz)

    n, cs, bs = p["trunk_depth_n"], p["chest_depth_s"], p["belly_depth_s"]
    r, hy = p["skull_r"], p["skull_y"]

    # ---- upper trunk, shared: a level shoulder band
    if not anat:
        ell("body", (0, 0.0, 1.32), (sh + 0.01, 0.15, 0.28))                  # rib cage
    ell("body", (0, -(n - 0.115), 1.40), (sh + 0.02, 0.115, 0.20))            # upper back / lats
    cap("body", (-sh, -0.01), (sh, -0.01), 0.10, 0.10, 1.465, 1.15)           # shoulder girdle
    ell("body", (0, -0.035, 1.52), (0.20, 0.11, 0.09))                        # traps / neck root, a low swell
    for s in (-1, 1):
        if anat:                                # a flatter cap that eases into the arm and the trapezius
            ell("body", (s * (sh + 0.035), 0.0, 1.535), (p["delt_r"] * 1.05, p["delt_r"], 0.095))
        else:
            ell("body", (s * (sh + 0.045), 0.0, 1.56), (p["delt_r"], p["delt_r"] + 0.005, 0.10))  # deltoid

    if not anat:
        for s in (-1, 1):
            # pec shelf: two lobes that meet at the sternum without crossing (crossing lobes read as a hunch)
            ell("body", (s * p["pec_half"], cs - 0.085, 1.36), (p["pec_half"], 0.085, 0.10))
        ell("body", (0, cs - 0.105, 1.35), (p["pec_half"] * 0.75, 0.085, 0.10))    # sternum: shallow cleft only
        ell("body", (0, bs - 0.13, 1.08), (p["belly_half"], 0.13, 0.25))      # belly, lower still

        # ---- head: a plain round dome on the shoulder axis; only tips jut past its south rim
        ell("face:skull", (0, hy, 1.86), (r, r, 0.15))
        nx, ny = p["nose"]
        if nx > 0:                              # (0, 0): the nose stays inside the skull's outline
            ell("face", (0, hy + r + ny * 0.45, 1.72), (nx, ny, 0.03))        # nose tip
        if p["tusk"] > 0:
            for s in (-1, 1):
                tx = p["tusk_x"]
                y0 = hy + (r * r - tx * tx) ** 0.5 - 0.008
                cap("face:tusk", (s * tx, y0), (s * (tx + 0.003), y0 + p["tusk"]), 0.011, 0.002, 1.70, 0.5)
        if p["ear_len"] > 0:
            for s in (-1, 1):
                cap("face", (s * r * 0.92, hy + 0.012), (s * (r + p["ear_len"]), hy - 0.030), 0.024, 0.004, 1.78, 0.6)
    else:
        # ---- trunk front: ONE chest mass; the pecs are low swells on it that overlap at the sternum,
        # the belly a slightly shallower mass below, the hips under that
        ph = p["pec_half"]
        ell("body", (0, cs - 0.175, 1.33), (sh + 0.005, 0.165, 0.26))         # rib cage, front at cs - 0.01
        for s in (-1, 1):
            ell("body", (s * ph * 0.93, cs - 0.105, 1.385), (ph * 1.22, 0.105, 0.115))   # pec
        ell("body", (0, bs - 0.135, 1.10), (p["belly_half"], 0.135, 0.22))    # belly
        z0 = p.get("floor_z", 0.70)             # the floor; see the note on the short stance in RACES
        ell("body", (0, bs - 0.155, 0.92), (p["belly_half"] * 0.95, 0.125, 0.14))   # hips

        # ---- head: cranium + the forms that make a face when seen from above and in front
        hf = p.get("head_fwd", 0.03)            # the head is carried a little forward of the shoulders
        zh = p.get("head_z", 1.80)
        yh = hy + hf
        ell("body", (0, yh * 0.5, 1.60), (0.085, 0.085, 0.14))                # neck
        head_from = len(P)                      # everything from here to the ears is the head
        ell("face:skull", (0, yh, zh), (r, r * 1.10, 0.135))                  # cranium (or the hair cap)
        f = p.get("face_scale", r / 0.108)      # face forms scale with the skull unless a race says otherwise
        yf = yh + p.get("face_fwd", 0.0)        # a hair cap wider than the skull: the face sits forward in it
        bw = p.get("brow", 1.0)
        for s in (-1, 1):                       # brow ridge: two lobes that meet in a notch above the nose
            ell("face", (s * 0.040 * f, yf + 0.076 * f, zh + 0.010), (0.052 * f, 0.040 * f * bw, 0.034))
        ell("face", (0, yf + 0.046 * f, zh - 0.080), (0.090 * f, 0.074 * f, 0.070))             # cheeks / mid face
        ell("face", (0, yf + 0.066 * f, zh - 0.125), (0.074 * f, 0.058 * f * p.get("jaw", 1.0), 0.045))   # jaw, chin
        nl, nr = p.get("nose_tilt", (0.0, 1.0))  # extra reach of the nose tip (in f units), radius factor
        rod("face", (0, yf + 0.104 * f, zh - 0.010), (0, yf + (0.124 + nl) * f, zh - 0.062 - nl * 0.6 * f),
            0.013 * f * nr, 0.021 * f * nr)                                   # nose
        if p["tusk"] > 0:
            for s in (-1, 1):
                tx = p.get("tusk_x_tilt", p["tusk_x"])
                rod("face:tusk", (s * tx, yf + 0.106 * f, zh - 0.140),
                    (s * (tx + 0.007), yf + 0.106 * f + p["tusk"] * 1.3, zh - 0.140 + p["tusk"] * 2.2), 0.0115, 0.003)
        el = p["ear_len"]
        if el > 0:
            er, eb, eu = p.get("ear_tilt", (0.024, 0.028, 0.005))   # root radius, tip sweep back, tip rise
            for s in (-1, 1):
                rod("face", (s * r * 0.90, yh + 0.010, zh - 0.035), (s * (r + el), yh - eb, zh + eu),
                    er, 0.004, 0.6)
        hs = p.get("head_scale", 1.0)           # see HEAD SIZE CONVENTION in the module docstring
        if hs != 1.0:
            for i in range(head_from, len(P)):
                part, c, q = P[i]
                P[i] = (part, head_point(p, c), tuple(v * hs for v in q))

    # ---- arms: dead-level bars at shoulder height; hands flat with spread fingers
    ex, wx = p["elbow_x"], p["wrist_x"]
    ua, fa = p["upper_arm_r"], p["forearm_r"]
    for s, side in ((-1, "l"), (1, "r")):                                     # image left / right
        cap("upperarm_" + side, (s * (sh + 0.05), 0), (s * ex, 0), ua[0], ua[1], zs)
        cap("forearm_" + side, (s * ex, 0), (s * wx, 0), fa[0], fa[1], zs - 0.01)
        hx = wx + p["palm_rx"] * 0.85
        hand = "hand_" + side
        ell(hand, (s * hx, 0, zs - 0.02), (p["palm_rx"], p["palm_ry"], 0.022))
        fr = p["finger_r"]
        tips = (0.962, 0.990, 1.0, 0.980)                                     # little .. index, north to south
        for i, tip in enumerate(tips):
            y0 = (i - 1.5) * fr * 2.25
            y1 = (i - 1.5) * fr * 3.1
            base = hx + p["palm_rx"] * 0.35
            cap(hand, (s * base, y0), (s * tip, y1), fr * 1.1, fr * 0.80, zs - 0.03, 0.8)
            ell(hand, (s * (base + 0.012), y0 * 1.05, zs - 0.012), (fr * 1.05, fr * 1.0, 0.012))   # knuckle
        cap(hand, (s * (hx - 0.03), p["palm_ry"] * 0.6), (s * (hx + 0.028), p["palm_ry"] + 0.036),
            fr * 1.25, fr * 0.95, zs - 0.035, 0.8)                            # thumb, toward south

        fx, tr = (p.get("foot_x_tilt", p["foot_x"]) if anat else p["foot_x"]), p["toe_r"]
        ty = p.get("toe_y_tilt", p["toe_y"] * 0.85) if anat else p["toe_y"]
        foot = "foot_" + side
        if not anat:
            # ---- feet: only short separate toe ends peek out south of the belly.
            # Each toe is a peg that starts hidden under the chest and ends in a short rounded tip, so
            # only the tips show, with grey ground between neighbours. Big toe is the inner one.
            for i, (k, back) in enumerate(((1.0, 0.30), (0.84, 0.15), (0.78, 0.15), (0.72, 0.35), (0.66, 0.70))):
                tx = fx - tr * 3.4 + i * tr * 1.7
                rad = tr * k * 0.64
                cap(foot, (s * tx, ty - 0.075), (s * tx, ty - back * tr - rad), rad, rad, 0.05, 0.6)
        else:
            # ---- legs and feet: a real foot (heel, instep, ball, five touching toes) on the floor
            fw = p.get("foot_w", tr * 2.6)      # half width of the ball of the foot
            fl = p.get("foot_len", 0.25)        # heel to big-toe tip
            tl = fw * 0.95                      # big-toe length
            heel = ty - fl
            ball = ty - tl - fw * 0.30
            lr = p.get("leg_r", (0.085, 0.055))
            rod("leg_" + side, (s * fx * 0.95, 0.02, 0.90), (s * fx, heel + 0.07, z0 + 0.10), lr[0], lr[1])   # leg, short
            rod(foot, (s * fx, heel + 0.045, z0 + 0.040), (s * fx, ball - 0.01, z0 + 0.034),
                fw * 0.72, fw * 0.98, 0.62)                                   # heel to ball
            ell(foot, (s * fx, heel + 0.10, z0 + 0.075), (fw * 0.70, 0.075, 0.055))           # instep rising to the ankle
            # toes: big toe inner; each overlaps its neighbour so the foot front is one scalloped edge
            widths = (1.0, 0.76, 0.70, 0.64, 0.58)
            reach = (1.0, 0.99, 0.93, 0.85, 0.75)
            tot = sum(widths)
            x = -fw * 1.04
            for k, rc in zip(widths, reach):
                half = fw * 1.04 * k / tot
                rad = half * 1.10
                cx = x + half
                x += 2 * half
                tip = ball + (tl + fw * 0.30) * rc - rad
                rod(foot, (s * (fx + cx * 0.92), ball, z0 + 0.024), (s * (fx + cx * 1.05), tip, z0 + 0.020),
                    rad, rad * 0.95, 0.78)
    return P


def head_point(p, c):
    """Where head_scale / head_back put a point of the tilted proxy's unscaled head: scaled about the
    skull base (on the cranium's axis, at head_pivot_z), then slid north by head_back."""
    hs = p.get("head_scale", 1.0)
    if hs == 1.0:
        return tuple(c)
    py = p["skull_y"] + p.get("head_fwd", 0.03)
    pz = p.get("head_pivot_z", 1.64)
    return (c[0] * hs, py + (c[1] - py) * hs - p.get("head_back", 0.0), pz + (c[2] - pz) * hs)


def head_scale_for(race, legacy=None, tilt=None):
    """The head_scale that gives `race`'s tilted guide the same head-frame radius per half span as the
    pack `legacy` ("race/variant", default "<race>/default"), i.e. the same in-game head size once
    install_plan has span-matched the new pack to it. Returns (head_scale, info)."""
    from . import core
    from .install_plan import measures
    mr, mv = ((legacy or race + "/default").split("/") + ["default"])[:2]
    ref = core.load_race(mr, mv)
    want = ref["frames"]["head"]["lx"] / (measures(ref["frames"])["span"] / 2.0)

    def ratio(over):
        _, _, _, lab, st = render(race, tilt=tilt, over=over)
        fr, _ = derive_frames(np.array(PART_RGB, np.uint8)[lab], 1.0)
        return fr["head"]["lx"] / (st["span_px"] / 2.0)
    base = ratio(dict(head_scale=1.0))
    now = ratio(None)
    return want / base, dict(legacy="%s/%s" % (mr, mv), legacy_ratio=round(want, 4), guide_ratio_unscaled=round(base, 4),
                             guide_ratio_now=round(now, 4), head_scale_now=RACES[race].get("head_scale", 1.0),
                             in_game_head_now_vs_legacy=round(now / want, 3))


def guide_prefix(tilt):
    """Guide files of the strict plan view keep their old names; tilted guides get their own."""
    return "guide" if tilt == 0 else "guide_t%g" % tilt


def race_tilt(race, tilt=None):
    return float(RACES[race].get("tilt", DEFAULT_TILT) if tilt is None else tilt)


def render(race="orc", w=W, h=H, ss=SS, margin=0.035, tilt=None, over=None):
    """Returns (clay, tint, mask, label_idx, stats).

    Orthographic camera `tilt` degrees off vertical, leaning toward the character's front (south):
    a world point (x, y, z) lands at screen (x, y cos t - z sin t), so higher parts move north and
    the front surfaces come into view. Every pixel's ray is intersected with every ellipsoid and the
    hit nearest the camera wins; clay, mask and labels all come from that one z-buffer."""
    tilt = race_tilt(race, tilt)
    anat = tilt > 0
    p = tilt_params(RACES[race], anat)
    if over:                                    # trial values, e.g. head_scale_for's unscaled head
        p = dict(p, **over)
        p.pop("anat", None)                     # already laid over by tilt_params; keep `over` on top
    ct, st = float(np.cos(np.radians(tilt))), float(np.sin(np.radians(tilt)))
    ww, hh = w * ss, h * ss
    scale = ww * (0.5 - margin)                 # px per unit; fingertips land `margin` from each edge
    prims = primitives(p, anat)
    cen = np.array([c for _, c, _ in prims])
    rad = np.array([q for _, _, q in prims])
    if anat:                                    # centre the projected north-south extent on the canvas
        syc = cen[:, 1] * ct - cen[:, 2] * st
        ext = np.sqrt((rad[:, 1] * ct) ** 2 + (rad[:, 2] * st) ** 2)
        y_n, y_s = float((syc - ext).min()), float((syc + ext).max())
    else:
        y_n = -(p["trunk_depth_n"]) - 0.01
        y_s = max(p["toe_y"], p["belly_depth_s"])
    yc = (y_n + y_s) / 2
    xs = ((np.arange(ww) + 0.5 - ww / 2) / scale).astype(np.float32)
    ys = ((np.arange(hh) + 0.5 - hh / 2) / scale + yc).astype(np.float32)
    dep = np.full((hh, ww), -1e9, np.float32)   # distance toward the camera along the view direction
    nrm = np.zeros((hh, ww, 3), np.float32)
    nrm[..., 2] = 1
    label = np.zeros((hh, ww), np.uint8)
    tusk = np.zeros((hh, ww), bool)
    skull = np.zeros((hh, ww), bool)
    for name, (cx, cy, cz), (rx, ry, rz) in prims:
        sy0 = cy * ct - cz * st
        ey = float(np.sqrt((ry * ct) ** 2 + (rz * st) ** 2))
        i0 = max(int(np.floor((cx - rx) * scale + ww / 2)) - 1, 0)
        i1 = min(int(np.ceil((cx + rx) * scale + ww / 2)) + 1, ww)
        j0 = max(int(np.floor((sy0 - ey - yc) * scale + hh / 2)) - 1, 0)
        j1 = min(int(np.ceil((sy0 + ey - yc) * scale + hh / 2)) + 1, hh)
        if i1 <= i0 or j1 <= j0:
            continue
        sx, sy = np.meshgrid(xs[i0:i1], ys[j0:j1])
        # the ray  (sx, sy ct, -sy st) + lam (0, st, ct)  in the ellipsoid's unit-sphere space
        ox, oy, oz = (sx - cx) / rx, (sy * ct - cy) / ry, (-sy * st - cz) / rz
        dy, dz = st / ry, ct / rz
        a = dy * dy + dz * dz
        b = oy * dy + oz * dz
        disc = b * b - a * (ox * ox + oy * oy + oz * oz - 1)
        hit = disc > 0
        lam = (-b + np.sqrt(np.clip(disc, 0, None))) / a
        sub = dep[j0:j1, i0:i1]
        win = hit & (lam > sub)
        if not win.any():
            continue
        sub[win] = lam[win]
        n3 = np.stack([ox / rx, (oy + lam * dy) / ry, (oz + lam * dz) / rz], -1)[win]
        nrm[j0:j1, i0:i1][win] = n3 / np.linalg.norm(n3, axis=-1, keepdims=True)
        label[j0:j1, i0:i1][win] = PARTS.index(name.split(":")[0])
        tusk[j0:j1, i0:i1][win] = name.endswith(":tusk")
        skull[j0:j1, i0:i1][win] = name.endswith(":skull")
    mask = dep > -1e8
    X, Y = np.meshgrid(xs, ys)
    r, hy = p["skull_r"], p["skull_y"]
    hs = np.where(mask, dep, 0).astype(np.float32)
    if not anat:
        # clay shading from the height-map normal, light almost straight down
        hsm = ndi.gaussian_filter(hs, 1.5 * ss)
        gy, gx = np.gradient(hsm * scale * 0.55)    # 0.55: flatten relief a little so cliffs do not go black
        nh = np.stack([-gx, -gy, np.ones_like(gx)], -1)
        nh /= np.linalg.norm(nh, axis=-1, keepdims=True)
        L = np.array([-0.04, -0.08, 0.995]); L /= np.linalg.norm(L)
        lam = np.clip(nh @ L, 0, 1)
        ao = np.clip((ndi.gaussian_filter(hs, 14 * ss) - hs) * 1.6, 0, 0.45)       # pits and low parts darker
        rho = np.hypot(X, Y - hy) / r
        near = np.clip((rho - 1.0) / 0.9, 0, 1)     # 0 at the skull rim .. 1 from 1.9 r out
        ao *= near                                   # no dark crescent under the dome: it gets painted as a muzzle
        depth = 0.80 + 0.20 * np.clip(hs / 1.9, 0, 1)
        shade = (0.30 + 0.70 * lam) * depth * (1 - ao)
        # the block-out head recipe: explicit sphere shading on the skull, crown highlight dead centre
        sphere = np.sqrt(np.clip(1 - (rho * 0.93) ** 2, 0, 1))
        crown = np.exp(-(rho / 0.22) ** 2)          # tight bright spot at the dead centre
        shade = np.where(skull, (0.34 + 0.66 * sphere) * 0.95 + 0.26 * crown, shade)
        clay = 205 * shade
        # crease lines where one part overlaps another (depth discontinuity)
        edge = np.hypot(*np.gradient(ndi.gaussian_filter(hs, 0.8 * ss))) * scale
        crease = np.clip((edge - 1.6) / 3.0, 0, 1) * 0.35
        crease *= np.where(skull, 1.0, 0.35 + 0.65 * np.clip((rho - 1.0) / 0.45, 0, 1))   # nose / tusk tips: soft, fused to the rim
        clay *= (1 - crease)
        rim = np.exp(-(((rho - 1.0) * r * scale) / (1.6 * ss)) ** 2) * mask             # the skull's rim: one hard, strict circle
        clay = clay * (1 - 0.8 * rim) + 40 * 0.8 * rim
    else:
        # clay shading from the TRUE surface normal (lightly smoothed so unions blend), key light from
        # above and a little in front, so the face and chest fronts the camera sees are lit, not black
        mf = mask.astype(np.float32)
        sig = p.get("normal_blur", 2.2) * ss
        wsum = np.maximum(ndi.gaussian_filter(mf, sig), 1e-4)
        ns = np.stack([ndi.gaussian_filter(nrm[..., i] * mf, sig) / wsum for i in range(3)], -1)
        ns /= np.maximum(np.linalg.norm(ns, axis=-1, keepdims=True), 1e-6)
        L = np.array([-0.05, 0.30, 0.95]); L /= np.linalg.norm(L)
        lam = np.clip(ns @ L, 0, 1)
        ao = np.clip((ndi.gaussian_filter(hs, 12 * ss) - hs) * 0.7, 0, 0.28)        # parts tucked under others
        shade = (0.36 + 0.64 * lam) * (1 - ao)
        clay = 205 * shade
        edge = np.hypot(*np.gradient(ndi.gaussian_filter(hs, 0.8 * ss))) * scale    # one part in front of another
        clay *= 1 - np.clip((edge - 1.4) / 3.0, 0, 1) * 0.50
    dist_in = ndi.distance_transform_edt(mask)
    outline = np.clip(1.25 - dist_in / (2.4 * ss), 0, 1)   # a bold contour: the painting keeps its weight
    clay = clay * (1 - 0.75 * outline) + 45 * 0.75 * outline
    grey = np.clip(np.where(mask, clay, BG), 0, 255)
    clay_im = Image.fromarray(np.repeat(grey[..., None], 3, -1).astype(np.uint8)).resize((w, h), Image.LANCZOS)
    skin = np.array(p["skin"], np.float32) / 205.0
    ivory = np.array(p["ivory"], np.float32) / 205.0
    base = np.where(skull[..., None], np.array(p.get("hair", p["skin"]), np.float32) / 205.0, skin)
    col = np.where(tusk[..., None], ivory * 205 * 0.8 + 0.2 * clay[..., None], base * (clay[..., None] * 1.25))
    tinted = np.where(mask[..., None], np.clip(col, 0, 255), BG).astype(np.uint8)
    tint_im = Image.fromarray(tinted).resize((w, h), Image.LANCZOS)

    m = Image.fromarray((mask * 255).astype(np.uint8)).resize((w, h), Image.LANCZOS).point(lambda v: 255 if v >= 128 else 0)
    mnp = np.array(m) > 0
    lab = np.array(Image.fromarray(label).resize((w, h), Image.NEAREST)) * mnp
    holes = mnp & (lab == 0)                    # make labels and mask agree exactly after resampling
    if holes.any():
        idx = ndi.distance_transform_edt(lab == 0, return_distances=False, return_indices=True)
        lab = lab[tuple(idx)] * mnp
    ys_, xs_ = np.nonzero(mnp)
    px = scale / ss
    if anat:
        _, hyw, hzw = head_point(p, (0.0, hy + p.get("head_fwd", 0.03), p.get("head_z", 1.80)))
        r = r * p.get("head_scale", 1.0)
    else:
        hyw, hzw = hy, 0.0
    stats = dict(race=race, canvas=[w, h], tilt_deg=tilt, px_per_unit=round(px, 3),
                 bbox=[int(xs_.min()), int(ys_.min()), int(xs_.max()), int(ys_.max())],
                 span_px=int(xs_.max() - xs_.min() + 1), depth_px=int(ys_.max() - ys_.min() + 1),
                 shoulder_line_y=round(h / 2 + ((-1.56 * st if anat else 0.0) - yc) * px, 2),
                 skull_centre=[round(w / 2, 2), round(h / 2 + (hyw * ct - hzw * st - yc) * px, 2)],
                 skull_r_px=round(r * px, 2))
    stats["depth_over_span"] = round(stats["depth_px"] / stats["span_px"], 4)
    stats["label_colours"] = {n: list(c) for n, c in zip(PARTS, PART_RGB)}
    stats["note"] = "figure faces south (image bottom); _l/_r are IMAGE left/right, as derive.py expects"
    return clay_im, tint_im, m, lab.astype(np.uint8), stats


def race_out(race):
    d = os.path.join(OUT, race)
    os.makedirs(d, exist_ok=True)
    return d


def make_swatch(race, out):
    """A tight patch of the current painting's upper arm: colour and line only, no camera cue."""
    sw = RACES[race]["swatch"]
    im = Image.open(os.path.join(ROOT, sw["src"])).convert("RGBA")
    bg = Image.new("RGBA", im.size, (BG, BG, BG, 255))
    bg.alpha_composite(im)
    c = bg.convert("RGB").crop(sw["box"])
    c = c.resize((c.width * 3, c.height * 3), Image.LANCZOS)
    p = os.path.join(out, "swatch.png")
    c.save(p)
    return p


def save_guide(race, tilt=None):
    out = race_out(race)
    tilt = race_tilt(race, tilt)
    g = os.path.join(out, guide_prefix(tilt))
    clay, tint, m, lab, stats = render(race, tilt=tilt)
    clay.save(g + "_clay.png")
    tint.save(g + "_tint.png")
    m.save(g + "_mask.png")
    lab_rgb = np.array(PART_RGB, np.uint8)[lab]
    Image.fromarray(lab_rgb).save(g + "_labels.png")
    make_swatch(race, out)
    try:                                        # prove the label map feeds derive.py as it stands
        frames, notes = derive_frames(lab_rgb, 1.0)
        stats["derive"] = dict(ok=True, frames=sorted(frames), notes=notes,
                               head=frames["head"], torso=frames["torso"])
    except LabelError as e:
        stats["derive"] = dict(ok=False, error=str(e))
    with open(g + ".json", "w") as f:
        json.dump(stats, f, indent=1)
    print(json.dumps({k: stats[k] for k in ("tilt_deg", "bbox", "span_px", "depth_px", "depth_over_span",
                                             "shoulder_line_y", "skull_centre", "skull_r_px")}))
    print("derive:", "ok, %d frames; %s" % (len(stats["derive"]["frames"]), stats["derive"]["notes"])
          if stats["derive"]["ok"] else "FAIL " + stats["derive"]["error"])
    return stats


# ---------------------------------------------------------------- prompt

def build_prompt(race, guide="tint", swatch=True, tilt=None):
    if race_tilt(race, tilt) > 0:
        return build_prompt_tilt(race, guide, swatch, race_tilt(race, tilt))
    p = RACES[race]
    what = "a flat-colour 3D sculpt" if guide == "tint" else "a grey clay sculpt"
    dome = p.get("dome", "smooth scalp")        # what the top of the head is covered with; last word = its noun
    cover = p.get("dome_cover", "skin")
    t = (
        "Image 1 is %s of a game character, rendered by an orthographic camera hovering directly above "
        "the top of its head and looking straight down at the floor: a plan view, like a miniature seen "
        "from above on a tabletop battle map. The figure stands bolt upright with both arms stretched "
        "straight out to the sides. "
        "The round dome in the centre is the top of its skull, like a smooth ball seen from above: the "
        "whole circle, rim to rim, is one unbroken %s shaded as a sphere, with the crown and a "
        "single soft highlight at the dead centre of the circle, equally far from every rim. The dark "
        "rim line of the circle all the way round is the widest part of the skull, and its lower half is "
        "exactly as round, smooth and plain as its upper half, a mirror image of it. %s "
        "The wide horizontal band running through the dome is the tops of the shoulders, the trapezius "
        "and the upper back. The level bars to the left and right are the arms seen from above, ending "
        "in flat hands with the backs of the hands, the knuckles and the spread fingers facing the "
        "camera. The rounded shelf below the shoulder band is the top surface of the chest seen from "
        "above, and the ten separate short rounded pegs at the very bottom, five on each side, are the "
        "tips of the toes on the floor far below, peeking out from under the chest. "
        "Paint this exact sculpt as a finished game character: %s. Keep the identical outline, pose, "
        "proportions, position, scale and straight-down viewpoint, tracing the silhouette precisely and "
        "keeping every shape exactly where and how large the sculpt has it. Paint the dome as a %s "
        "filling the entire perfect circle, one even curve of %s from the top rim to the bottom "
        "rim: the %s inside the circle is the same unmarked %s everywhere, and the circle's dark rim "
        "line stays a true circle. Paint the shoulder band as trapezius, deltoid and "
        "shoulder-blade muscles seen from above, the arms as level bars of biceps and forearm muscle, "
        "and each hand with five well-formed fingers, knuckles and fingernails. Paint each short peg at "
        "the bottom as one separate small toe tip, ten in all, each with grey background on both sides of "
        "it and a short dull nail plate on its top a little lighter than the skin. Bare unclothed "
        "base body, left-right symmetric, lit evenly from directly above, on a perfectly flat uniform "
        "mid-grey background, RGB 128 128 128, that fills the rest of the picture."
    ) % (what, dome, p["head_extras"], p["look"], dome, cover, cover, dome.split()[-1])
    if swatch:
        t += (
            " Image 2 is a small close-up swatch of this character's painted skin, for colour and finish "
            "only: match its %s, its smooth cel-like painted shading with a few broad soft-edged "
            "highlights per muscle, mirrored left and right, every highlight a lighter tint of the skin hue, "
            "and its %s of varying thickness around the whole silhouette and around the dome, as thick as "
            "the sculpt's own outline and crisp everywhere, with thinner dark lines separating the muscles, "
            "across the whole figure."
        ) % (p["skin_words"], p["line_words"])
    return t


TILT_WORDS = {5: "five", 10: "ten", 15: "fifteen", 20: "twenty", 25: "twenty-five", 30: "thirty"}


def build_prompt_tilt(race, guide, swatch, tilt):
    """The tilted camera: the guide's own face, chest and feet are anatomy, so the prompt names each
    one at the size the guide has it and asks for a living creature, positively phrased."""
    p = RACES[race]
    what = "a flat-colour 3D sculpt" if guide == "tint" else "a grey clay sculpt"
    deg = TILT_WORDS.get(int(round(tilt)), "%g" % tilt)
    t = (
        "Image 1 is %s of a game character, a simple block-out rendered by an orthographic camera high "
        "above the character, looking steeply down at it from just in front of directly overhead, leaning "
        "%s degrees toward the character's front: the view of a miniature on a tabletop battle map. The "
        "character stands upright, facing the bottom of the picture, with both arms stretched straight "
        "out to the sides at shoulder height, palms down. "
        "The rounded form at the centre is the head seen from steeply above. Most of it is the %s: the "
        "top of the skull, with the crown a little above the middle of the head. Along the head's bottom "
        "edge sits a narrow, strongly foreshortened strip of face seen from above: %s "
        "The wide band across the picture is the tops of the shoulders, the trapezius and the upper "
        "back. The level bars to the left and right are the arms seen from above, ending in flat hands "
        "with the backs of the hands, the knuckles and the spread fingers toward the camera. Below the "
        "shoulder band is the front of the torso seen from steeply above and strongly foreshortened: %s "
        "At the very bottom the front halves of the two bare feet stand on the floor far below, toes "
        "pointing at the bottom of the picture, each a natural foot front with its instep and five toes "
        "side by side, the big toe on the inner side. "
        "Paint over this exact sculpt to make a finished game character: %s. Keep the identical outline, "
        "pose, proportions, position, scale and steep overhead viewpoint, tracing the silhouette "
        "precisely and keeping every form where and how large the sculpt has it. Turn the sculpt's "
        "simple forms into the natural anatomy of a believable living creature: %s; trapezius, deltoid "
        "and shoulder-blade muscles across the shoulder band; level arms of biceps, triceps and forearm "
        "muscle; each hand with five well-formed fingers, knuckles and short fingernails; %s; and each "
        "foot front with five natural toes with short dull toenails. Bare unclothed base body, left-right "
        "symmetric, chalky matte skin, lit softly and evenly from above, on a perfectly flat uniform mid-grey "
        "background, RGB 128 128 128, that fills the rest of the picture."
    ) % (what, deg, p.get("dome", "smooth bald scalp"),
         p.get("face_tilt", "the brow, under it the bridge and tip of the nose, and the chin behind them."),
         p.get("torso_tilt", "first the top plane of the chest, then, tucked under it, a short glimpse of "
                             "the upper belly."),
         p["look"],
         p.get("face_paint", "the head with, in the strip along its bottom edge, a natural face seen from "
                             "above, brow, nose and chin"),
         p.get("torso_paint", "the torso as one natural chest with a flat upper belly below it"))
    if swatch:
        t += (
            " Image 2 is a small close-up swatch of this character's painted skin, for colour and finish "
            "only: match its %s, its smooth cel-like painted matte shading with a few broad, soft-edged, "
            "low-contrast highlights per muscle and one on the %s, mirrored left and right, every highlight a lighter tint of the skin hue, "
            "and its %s, about four pixels thick around the whole silhouette and around the head, crisp "
            "everywhere, with thinner dark lines separating the muscles and the features, across the whole "
            "figure."
        ) % (p["skin_words"], p.get("dome_cover_tilt", "scalp"), p["line_words"])
    return t


def gen(race, n, tag, guide="tint", swatch=True, text=None, tilt=None):
    from .gen_overhead import generate, _part
    out = race_out(race)
    tilt = race_tilt(race, tilt)
    gp = os.path.join(out, guide_prefix(tilt))
    gsrc = "%s_%s.png" % (gp, guide)
    save_guide(race, tilt)                      # always fresh: the proxy is what is being tuned
    prompt = text or build_prompt(race, guide, swatch, tilt)
    with open(os.path.join(out, "%s.prompt.txt" % tag), "w", encoding="utf-8") as f:
        f.write(prompt)
    # snapshot the inputs: the guide changes between rounds, the candidates must keep theirs
    in1 = os.path.join(out, "%s.in1_guide.png" % tag)
    shutil.copyfile(gsrc, in1)
    shutil.copyfile(gp + "_mask.png", os.path.join(out, "%s.guide_mask.png" % tag))
    shutil.copyfile(gp + "_labels.png", os.path.join(out, "%s.guide_labels.png" % tag))
    shutil.copyfile(gp + ".json", os.path.join(out, "%s.guide.json" % tag))
    inputs = [in1]
    parts = [{"text": prompt}, _part(in1, max_side=1376)]
    if swatch:
        in2 = os.path.join(out, "%s.in2_swatch.png" % tag)
        shutil.copyfile(make_swatch(race, out), in2)
        parts.append(_part(in2))
        inputs.append(in2)
    log_p = os.path.join(out, "calls.json")
    log = json.load(open(log_p)) if os.path.exists(log_p) else []
    made = []
    for i in range(1, n + 1):
        name = "%s_%d" % (tag, i)
        try:
            raw, model = generate(parts)
        except RuntimeError as e:               # a refused / empty answer still spent a call
            raw = None
            print("[FAIL] %s: %s" % (name, e))
        log.append(name if raw else name + " FAILED")
        with open(log_p, "w") as f:
            json.dump(log, f)
        if raw is None:
            continue
        p = os.path.join(out, name + ".png")
        with open(p, "wb") as f:
            f.write(raw)
        with open(os.path.join(out, name + ".json"), "w") as f:
            json.dump(dict(prompt=prompt, inputs=[os.path.basename(x) for x in inputs], model=model,
                           race=race, guide=guide, swatch=swatch, tilt_deg=tilt), f, indent=1)
        print("[ok ] %s via %s %s  (Gemini calls so far: %d)" % (p, model, Image.open(io.BytesIO(raw)).size, len(log)))
        made.append(p)
    if made:
        check(race, made, tag)
    return made


# ---------------------------------------------------------------- check

def key_mask(a):
    """Foreground of a painting on flat grey. a: HxWx3 float. Returns (mask, ground colour)."""
    k = 24
    corners = np.concatenate([a[:k, :k].reshape(-1, 3), a[:k, -k:].reshape(-1, 3),
                              a[-k:, :k].reshape(-1, 3), a[-k:, -k:].reshape(-1, 3)])
    bg = np.median(corners, 0)
    d = np.abs(a - bg).max(-1)
    chroma = a.max(-1) - a.min(-1)
    fg = (chroma > 14) | (d > 45)       # coloured skin, or the dark outline / bright tusks
    fg = ndi.binary_opening(fg, iterations=1)
    lab, n = ndi.label(fg)
    if n:
        sizes = ndi.sum(fg, lab, range(1, n + 1))
        fg = lab == (1 + int(np.argmax(sizes)))
    fg = ndi.binary_fill_holes(ndi.binary_closing(fg, iterations=2))
    return fg, bg


def measure(path, gmask, write_overlay=True, stats=None, face_lab=None):
    a = np.asarray(Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS)).astype(np.float32)
    f, bg = key_mask(a)
    g = gmask
    ys, xs = np.nonzero(f)
    span, depth = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
    # symmetry about the painting's own centre column: silhouette overlap and colour agreement
    cx = int(round((xs.min() + xs.max() + 1) / 2.0))
    half = min(cx, W - cx)
    lf, rf = f[:, cx - half:cx][:, ::-1], f[:, cx:cx + half]
    la, ra = a[:, cx - half:cx][:, ::-1], a[:, cx:cx + half]
    both = lf & rf
    sym_shape = float(both.sum()) / max(float((lf | rf).sum()), 1.0)
    sym_colour = 1.0 - float(np.abs(la - ra).mean(-1)[both].mean()) / 255.0
    ground = a[~ndi.binary_dilation(f, iterations=6)]
    res = dict(image=os.path.basename(path),
               iou=round(float((g & f).sum()) / float((g | f).sum()), 4),
               span_px=int(span), depth_px=int(depth), depth_over_span=round(float(depth) / span, 4),
               outside_guide=round(float((f & ~g).sum()) / f.sum(), 4),
               guide_uncovered=round(float((g & ~f).sum()) / g.sum(), 4),
               symmetry_shape=round(sym_shape, 4), symmetry_colour=round(sym_colour, 4),
               centre_x_offset_px=int(cx - W // 2),
               ground_rgb=[int(round(v)) for v in ground.mean(0)],
               ground_std=round(float(ground.std(0).max()), 2))
    tilt = float((stats or {}).get("tilt_deg", 0.0))
    lo, hi, iou_min = DEPTH_BAND_TILT + (IOU_MIN_TILT,) if tilt > 0 else DEPTH_BAND_PLAN + (0.93,)
    res["tilt_deg"] = tilt
    res["depth_band"] = [lo, hi]
    res["auto_pass"] = bool(res["iou"] >= iou_min and lo <= res["depth_over_span"] <= hi
                            and res["symmetry_shape"] >= 0.93
                            and max(abs(v - BG) for v in res["ground_rgb"]) <= 10)
    if stats is not None and face_lab is not None and tilt > 0:
        # a tilted camera SHOWS a face sliver, so the plan view's "plain dome" head gate does not apply;
        # what can be measured is roughly how much of the head the face takes (see face_share)
        res.update(face_share(a, stats, face_lab))
    elif stats is not None and face_lab is not None:
        res.update(head_metrics(a, stats, face_lab))
        res["head_pass"] = bool(res["face_dark"] <= FACE_DARK_MAX and res["muzzle_dark"] <= MUZZLE_DARK_MAX
                                and np.hypot(res["hl_dx"], res["hl_dy"]) <= HL_OFFSET_MAX * stats["skull_r_px"])
        res["auto_pass"] = bool(res["auto_pass"] and res["head_pass"])
    if write_overlay:   # green = both, red = painting outside the guide, blue = guide left empty
        ov = np.full(g.shape + (3,), 128, np.uint8)
        ov[g & f] = (90, 170, 90); ov[f & ~g] = (220, 60, 60); ov[g & ~f] = (60, 90, 220)
        Image.fromarray(ov).save(os.path.splitext(path)[0] + "_iou.png")
    return res


def face_share(a, stats, face_lab):
    """Tilted guides only, a rough number for the eye check: the share of the guide head's height
    that lies south of the northernmost dark stroke near the head's centre line, i.e. roughly how
    much of the head is face. The guide's own value sits near 0.3; a clean scalp with no face is 0."""
    cx, _ = stats["skull_centre"]
    r = stats["skull_r_px"]
    cols = slice(int(cx - 0.55 * r), int(cx + 0.55 * r))
    rows = np.nonzero(face_lab[:, cols].any(1))[0]
    top, bot = int(rows.min()), int(rows.max())
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    dark = (lum - ndi.gaussian_filter(lum, 6)) < -12
    inset = int(0.18 * (bot - top))             # skip the head's own top outline
    strip = dark[top + inset:bot + 1, cols].mean(1) > 0.25
    first = int(np.argmax(strip)) + inset if strip.any() else bot - top + 1
    return dict(face_share=round(1.0 - first / float(bot - top + 1), 3))


def head_metrics(a, stats, face_lab):
    """What IoU cannot see. a: HxWx3 float painting; face_lab: bool map of the guide's head label.
    face_dark   share of the dome inside 0.82 r that is a dark stroke against its surroundings:
                brows, eye sockets, a mouth line (a plain scalp scores about 0)
    muzzle_dark share of the band just south of the rim (outside the guide's own nose / tusk pixels)
                that is dark line or ivory: a lip band, a jaw, extra teeth
    hl_dx/dy    offset in px of the dome's highlight from the skull centre (+y = south)"""
    cx, cy = stats["skull_centre"]
    r = stats["skull_r_px"]
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    dx, dy = xx - cx + 0.5, yy - cy + 0.5
    rho = np.hypot(dx, dy) / r
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    lines = (lum - ndi.gaussian_filter(lum, 6)) < -9          # dark strokes against their surroundings
    face_dark = float(lines[rho < 0.82].mean())
    inner = rho < 0.8
    thr = np.percentile(lum[inner], 92)
    hot = inner & (lum >= thr)
    band = (rho > 1.07) & (rho < 1.5) & (dy > 0) & (np.abs(dx) < dy * 1.2)
    band &= ~ndi.binary_dilation(face_lab, iterations=5)
    ref = np.median(lum[band])
    ivory = (a.min(-1) > 150) & ((a.max(-1) - a.min(-1)) < 70)
    muzzle = float(((lum < 0.62 * ref) | ivory)[band].mean())
    return dict(face_dark=round(face_dark, 4), muzzle_dark=round(muzzle, 4),
                hl_dx=round(float(dx[hot].mean()), 1), hl_dy=round(float(dy[hot].mean()), 1))


def _tag_of(path):
    b = os.path.splitext(os.path.basename(path))[0]
    if b.endswith("_dome"):
        b = b[:-5]
    return b.rsplit("_", 1)[0]


def heal_dome(path, stats, dst=None):
    """Deterministic head fix-up: make the south half of the skull circle as plain as its north half.

    From straight above, under vertical light, a skull is radially symmetric, and the model always
    paints the NORTH half of the dome as clean scalp. So the radial colour profile is read from the
    north half (median over angle, the ear sectors left out) and laid over the south half, blending
    in just below the equator. Everything outside the guide skull circle (nose tip, tusk tips, ears,
    chest) is left as painted."""
    a = np.asarray(Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS)).astype(np.float32)
    cx, cy = stats["skull_centre"]
    r = stats["skull_r_px"]
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    dx, dy = xx - cx + 0.5, yy - cy + 0.5
    rho = np.hypot(dx, dy)
    ang = np.degrees(np.arctan2(-dy, dx))                   # 90 = north
    rmax = r * 1.05
    nb = 64
    prof = np.zeros((nb + 1, 3), np.float32)
    north = (ang > 25) & (ang < 155)
    for i in range(nb + 1):
        lo, hi = (i - 0.6) * rmax / nb, max((i + 0.6) * rmax / nb, 2.0)
        sel = north & (rho >= lo) & (rho < hi)
        if not sel.any():
            sel = (rho >= lo) & (rho < hi) & (dy < 0)
        prof[i] = np.median(a[sel], 0)
    t = np.clip(rho / rmax * nb, 0, nb)
    i0 = np.floor(t).astype(int)
    i1 = np.minimum(i0 + 1, nb)
    radial = prof[i0] * (1 - (t - i0))[..., None] + prof[i1] * (t - i0)[..., None]
    south = np.clip((dy / r - 0.02) / 0.45, 0, 1)           # 0 at the equator, 1 from 0.47 r south
    south = south * south * (3 - 2 * south)
    inside = np.clip((r * 1.035 - rho) / 2.0, 0, 1)         # stop just past the painted rim line
    wgt = (south * inside)[..., None]
    out = a * (1 - wgt) + radial * wgt
    dst = dst or os.path.splitext(path)[0] + "_dome.png"
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(dst)
    return dst


def dome(race, paths):
    out = race_out(race)
    made = []
    for p in paths:
        sj = os.path.join(os.path.dirname(p), _tag_of(p) + ".guide.json")
        stats = json.load(open(sj if os.path.exists(sj) else os.path.join(out, "guide.json")))
        made.append(heal_dome(p, stats))
        print("[ok ]", made[-1])
    return made


def head_sheet(paths, stats, guide_path, dst, zoom=3):
    """Guide + every candidate, cropped to the head and zoomed, with the shoulder line
    and the guide's skull circle drawn on a second row for the eye check."""
    cx, cy = stats["skull_centre"]
    r = stats["skull_r_px"]
    half_w, up, down = int(r * 2.3), int(r * 1.6), int(r * 2.3)
    box = (int(cx - half_w), int(cy - up), int(cx + half_w), int(cy + down))
    cw, ch = (box[2] - box[0]) * zoom, (box[3] - box[1]) * zoom
    items = [("guide", guide_path)] + [(os.path.splitext(os.path.basename(p))[0], p) for p in paths]
    sheet = Image.new("RGB", (cw * len(items), ch * 2 + 22), (40, 40, 40))
    d = ImageDraw.Draw(sheet)
    for i, (name, p) in enumerate(items):
        c = Image.open(p).convert("RGB").resize((W, H), Image.LANCZOS).crop(box).resize((cw, ch), Image.LANCZOS)
        sheet.paste(c, (i * cw, 22))
        c2 = c.copy()
        d2 = ImageDraw.Draw(c2)
        sy = (stats["shoulder_line_y"] - box[1]) * zoom
        d2.line([0, sy, cw, sy], fill=(255, 60, 60), width=1)
        ox, oy = (cx - box[0]) * zoom, (cy - box[1]) * zoom
        d2.ellipse([ox - r * zoom, oy - r * zoom, ox + r * zoom, oy + r * zoom], outline=(255, 255, 0))
        sheet.paste(c2, (i * cw, 22 + ch))
        d.text((i * cw + 4, 4), name, fill=(255, 255, 255))
    sheet.save(dst)
    return dst


def contact_sheet(race, paths, tag=None, pad=14):
    """<tag>_sheet.jpg: the candidates stacked, each cropped to the guide figure's box."""
    out = race_out(race)
    tag = tag or _tag_of(paths[0])
    sj = os.path.join(out, tag + ".guide.json")
    x0, y0, x1, y1 = json.load(open(sj))["bbox"] if os.path.exists(sj) else (0, 0, W - 1, H - 1)
    box = (max(x0 - pad * 2, 0), max(y0 - pad, 0), min(x1 + pad * 2, W), min(y1 + pad, H))
    crops = [Image.open(q).convert("RGB").resize((W, H), Image.LANCZOS).crop(box) for q in paths]
    sheet = Image.new("RGB", (crops[0].width, sum(c.height for c in crops)), (BG, BG, BG))
    y = 0
    for c in crops:
        sheet.paste(c, (0, y))
        y += c.height
    dst = os.path.join(out, tag + "_sheet.jpg")
    sheet.save(dst, quality=92)
    print("contact sheet:", dst)
    return dst


def check(race, paths, tag=None):
    out = race_out(race)
    res = []
    for p in paths:
        pre = os.path.join(os.path.dirname(p), _tag_of(p))
        snap = pre + ".guide_mask.png"          # the guide this candidate was painted on
        gm = snap if os.path.exists(snap) else os.path.join(out, "guide_mask.png")
        gl = pre + ".guide_labels.png" if os.path.exists(pre + ".guide_labels.png") else os.path.join(out, "guide_labels.png")
        gj = pre + ".guide.json" if os.path.exists(pre + ".guide.json") else os.path.join(out, "guide.json")
        face = (np.asarray(Image.open(gl).convert("RGB")) == np.array(PALETTE["face"], np.uint8)).all(-1)
        r = measure(p, np.asarray(Image.open(gm).convert("L")) > 0, stats=json.load(open(gj)), face_lab=face)
        res.append(r)
        print(json.dumps(r))
    name = (tag or _tag_of(paths[0])) + ("_dome" if paths[0].endswith("_dome.png") else "")
    tag = tag or _tag_of(paths[0])
    sj = os.path.join(out, tag + ".guide.json")
    stats = json.load(open(sj if os.path.exists(sj) else os.path.join(out, "guide.json")))
    gp = os.path.join(out, tag + ".in1_guide.png")
    sheet = head_sheet(paths, stats, gp if os.path.exists(gp) else os.path.join(out, "guide_tint.png"),
                       os.path.join(out, name + "_heads.png"))
    with open(os.path.join(out, name + "_check.json"), "w") as f:
        json.dump(res, f, indent=1)
    print("head sheet:", sheet)
    print("auto gate passed %d of %d (the head still needs the eye check)" % (sum(r["auto_pass"] for r in res), len(res)))
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    th = ("camera tilt in degrees off vertical, toward the character's front "
          "(default: the race's, else %g; 0 = strict plan view)" % DEFAULT_TILT)
    g = sub.add_parser("guide"); g.add_argument("--race", default="orc")
    g.add_argument("--tilt", type=float, default=None, help=th)
    n = sub.add_parser("gen")
    n.add_argument("--race", default="orc"); n.add_argument("--n", type=int, default=4)
    n.add_argument("--tag", default="final"); n.add_argument("--guide", default="tint", choices=["tint", "clay"])
    n.add_argument("--no-swatch", action="store_true"); n.add_argument("--tilt", type=float, default=None, help=th)
    n.add_argument("--text-file", default="", help="use this prompt instead of the built one")
    c = sub.add_parser("check")
    c.add_argument("images", nargs="*"); c.add_argument("--race", default="orc"); c.add_argument("--tag", default="")
    d = sub.add_parser("dome")
    d.add_argument("images", nargs="*"); d.add_argument("--race", default="orc"); d.add_argument("--tag", default="")
    z = sub.add_parser("headsize"); z.add_argument("--race", default="orc")
    z.add_argument("--legacy", default=None, help="pack to keep the head size of (default <race>/default)")
    z.add_argument("--tilt", type=float, default=None, help=th)
    h = sub.add_parser("sheet")
    h.add_argument("images", nargs="*"); h.add_argument("--race", default="orc"); h.add_argument("--tag", default="")
    a = ap.parse_args(argv)
    if a.cmd in ("check", "dome", "sheet") and not a.images:
        if not a.tag:
            ap.error("%s needs --tag or image paths" % a.cmd)
        a.images = sorted(q for q in glob.glob(os.path.join(race_out(a.race), a.tag + "_*.png"))
                          if os.path.basename(q)[len(a.tag) + 1:-4].isdigit())
    if a.cmd == "headsize":
        hs, info = head_scale_for(a.race, a.legacy, a.tilt)
        print(json.dumps(info))
        print("first estimate: head_scale=%.3f in RACES[%r]; nudge until in_game_head_now_vs_legacy is 1.00"
              % (hs, a.race))
    elif a.cmd == "dome":
        check(a.race, dome(a.race, a.images), a.tag or None)
    elif a.cmd == "sheet":
        contact_sheet(a.race, a.images, a.tag or None)
    elif a.cmd == "guide":
        save_guide(a.race, a.tilt)
    elif a.cmd == "gen":
        text = open(a.text_file, encoding="utf-8").read().strip() if a.text_file else None
        gen(a.race, a.n, a.tag, a.guide, not a.no_swatch, text, a.tilt)
    else:
        check(a.race, a.images, a.tag or None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
