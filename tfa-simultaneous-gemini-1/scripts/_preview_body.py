"""THROWAWAY race-parameterized rig preview. Mirrors SkeletalBodyRig math to
composite head+torso+arms+legs from a race's body_manifest.json so slice quality
is visible without the game. Usage: python _preview_body.py "Male Orc" [overlap]
Delete this + _preview_*.png (+ .import) when done."""
import json, math, sys
from pathlib import Path
from PIL import Image

RACE = sys.argv[1] if len(sys.argv) > 1 else "Male Orc"
A = Path(__file__).resolve().parent.parent / "Characters/Assets/Body Parts" / RACE
M = json.loads((A / "body_manifest.json").read_text())
parts = M["parts"]
OV = float(sys.argv[2]) if len(sys.argv) > 2 else M["tuning"].get("head_overlap_px", 0.0)
ZOOM = 4.0; W = 820; H = 620; CENTER = (W / 2, H / 2)
body_width = 60.0; shoulder_y = 12.0
render_scale = body_width / M["unit_px"]
arm_seg = [16.0, 13.0, 8.0]; arm_len = sum(arm_seg)
leg_length = 18.0; leg_spacing = 10.0
ARM_FLIP = {"l": M["tuning"].get("arm_flip_left", False), "r": not M["tuning"].get("arm_flip_left", False)}
FRONT = (0, -1); BACK = (0, 1)


def bkey(k):
    if k.startswith("upper_arm"): return "upper_arm"
    if k.startswith("forearm"): return "forearm"
    if k.startswith("leg"): return "leg"
    return k
def pivot(k): return tuple(parts[bkey(k)]["pivot"])
def joint(k, j):
    js = parts[bkey(k)]["joints"]; return tuple(js[j]) if j in js else pivot(k)
def size(k): return tuple(parts[bkey(k)]["size"])
def sub(a, b): return (a[0]-b[0], a[1]-b[1])
def add(a, b): return (a[0]+b[0], a[1]+b[1])
def mul(a, s): return (a[0]*s, a[1]*s)
def length(a): return math.hypot(*a)
def ang(a): return math.atan2(a[1], a[0])
def rot(a, r): return (a[0]*math.cos(r)-a[1]*math.sin(r), a[0]*math.sin(r)+a[1]*math.cos(r))
def oriented(k, p, flip): return (size(k)[0]-p[0], p[1]) if flip else p
def align(aim, prox, world, extra):
    loc = sub(aim, prox)
    if length(loc) < 1e-6 or length(world) < 1e-6: return extra
    return ang(world)-ang(loc)+extra
def joint_world(k, j, pos, r, flip):
    loc = mul(sub(oriented(k, joint(k, j), flip), oriented(k, pivot(k), flip)), render_scale)
    return add(pos, rot(loc, r))
def solve(side, sign):
    shoulder = (sign*body_width/2, shoulder_y)
    L0 = arm_seg[0]; L1 = arm_seg[1]+arm_seg[2]
    target = add(shoulder, (sign*arm_len*0.55, arm_len*0.35))   # arms out & down
    d = sub(target, shoulder); dist = max(min(length(d), L0+L1-0.01), 1e-3)
    a0 = math.acos(max(-1, min(1, (dist*dist+L0*L0-L1*L1)/(2*dist*L0))))
    ea = ang(d)+sign*a0
    elbow = add(shoulder, (math.cos(ea)*L0, math.sin(ea)*L0))
    return shoulder, elbow, target

pl = []
tn = oriented("torso", pivot("torso"), False)
hipmid = mul(add(oriented("torso", joint("torso", "hip_l"), False), oriented("torso", joint("torso", "hip_r"), False)), 0.5)
trot = align(hipmid, tn, BACK, 0.0)
smid = mul(add(oriented("torso", joint("torso", "shoulder_l"), False), oriented("torso", joint("torso", "shoulder_r"), False)), 0.5)
tpos = sub((0.0, shoulder_y), rot(mul(sub(smid, tn), render_scale), trot))
pl.append(("torso", "torso_rig.png", tpos, trot, False, -1))
hpos = add(tpos, mul(rot(BACK, trot), OV*render_scale))
hrot = align(oriented("head", joint("head", "crown"), False), oriented("head", pivot("head"), False), FRONT, 0.0)
pl.append(("head", "head_rig.png", hpos, hrot, False, 1))
for side, sign in (("l", -1), ("r", 1)):
    flip = ARM_FLIP[side]
    sh, elbow, hand = solve(side, sign)
    uapos = joint_world("torso", "shoulder_"+side, tpos, trot, False)
    uarot = align(oriented("upper_arm_"+side, joint("upper_arm_"+side, "elbow"), flip),
                  oriented("upper_arm_"+side, joint("upper_arm_"+side, "shoulder"), flip), sub(elbow, sh), 0.0)
    pl.append(("upper_arm_"+side, "upper_arm.png", uapos, uarot, flip, -2))
    elpos = joint_world("upper_arm_"+side, "elbow", uapos, uarot, flip)
    farot = align(oriented("forearm_"+side, joint("forearm_"+side, "wrist"), flip),
                  oriented("forearm_"+side, joint("forearm_"+side, "elbow"), flip), sub(hand, elbow), 0.0)
    pl.append(("forearm_"+side, "forearm.png", elpos, farot, flip, -2))
hip_y = shoulder_y+3
for side, sgn in (("l", -1), ("r", 1)):
    hip = (sgn*leg_spacing, hip_y); foot = (sgn*leg_spacing, hip_y-leg_length)
    mid = mul(add(hip, foot), 0.5); d = sub(foot, hip)
    lr = (ang(d)-math.pi/2) if length(d) > 1e-3 else 0.0
    pl.append(("leg_"+side, "leg.png", mid, lr, False, -3, True))

canvas = Image.new("RGBA", (W, H), (46, 64, 46, 255))
for p in sorted(pl, key=lambda x: x[5]):
    key, fname, pos_u, r, flip = p[0], p[1], p[2], p[3], p[4]
    centered = len(p) > 6 and p[6]
    fp = A / fname
    if not fp.exists(): continue
    img = Image.open(fp).convert("RGBA")
    if flip: img = img.transpose(Image.FLIP_LEFT_RIGHT)
    piv = (img.size[0]/2.0, img.size[1]/2.0) if centered else (oriented(key, pivot(key), False) if not flip else (img.size[0]-pivot(key)[0], pivot(key)[1]))
    s = render_scale*ZOOM; T = add(CENTER, mul(pos_u, ZOOM))
    cosr, sinr = math.cos(r), math.sin(r)
    a = cosr/s; b = sinr/s; c = piv[0]-(cosr*T[0]+sinr*T[1])/s
    dd = -sinr/s; e = cosr/s; f = piv[1]-(-sinr*T[0]+cosr*T[1])/s
    canvas.alpha_composite(img.transform((W, H), Image.AFFINE, (a, b, c, dd, e, f), resample=Image.BILINEAR))
# Write OUTSIDE the assets tree so Godot never imports the preview as a game asset.
out = Path(__file__).resolve().parent / ("_preview_%s.png" % RACE.replace(" ", "_"))
canvas.convert("RGB").save(out)
print("wrote", out, "ov=%g" % OV)
