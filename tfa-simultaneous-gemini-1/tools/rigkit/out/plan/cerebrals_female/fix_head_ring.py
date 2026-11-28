"""Workaround for install_plan.snap_head on cerebrals_female/tilt15 (run after install_plan, before build_race).

snap_head hands the head's dark contour line to the trunk, which on this race leaves a 2-4 px ring of
`body` label round the top of the cranium (the head reaches north of the trunk). derive then reads the
torso as reaching the top of the head. This gives the thin ring back to the face label.
    python tools/rigkit/out/plan/cerebrals_female/fix_head_ring.py
"""
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

P = "Rigs/races/cerebrals_female/tilt15/labels.png"
BODY, FACE = (60, 180, 75), (230, 25, 75)
lab = np.array(Image.open(P).convert("RGB"))
body = (lab == BODY).all(2)
face = (lab == FACE).all(2)
solid = ndi.binary_opening(body, structure=np.ones((9, 9), bool))      # the trunk proper
thin = body & ~ndi.binary_dilation(solid, iterations=2)
near_face = ndi.binary_dilation(face, iterations=6)
ys = np.where(face.any(1))[0]
above_eyes = np.zeros_like(body)
above_eyes[: int(ys[0] + 0.62 * (ys[-1] - ys[0]))] = True               # the cranium, not the chin and chest
ring = thin & near_face & above_eyes
lab[ring] = FACE
Image.fromarray(lab).save(P)
print("ring px relabelled to face:", int(ring.sum()))
