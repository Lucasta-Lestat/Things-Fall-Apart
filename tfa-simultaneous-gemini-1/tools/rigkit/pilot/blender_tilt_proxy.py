"""Blender proxy for the TILTED base-body camera (pilot: blender_tilt).

    blender -b --python tools/rigkit/pilot/blender_tilt_proxy.py -- OUT_DIR [params.json]

Builds an anatomical T-posed heavy humanoid from overlapping organic primitives
(per rig part), fuses a copy into one smooth clay surface, and renders it with an
ORTHOGRAPHIC camera tilted `tilt_deg` off vertical toward the character's front
(0 = strict plan view; 15 = the camera sits a little south of overhead):
    guide_clay.png   skin-tinted clay render, transparent film
    guide_ids.png    flat colour per rig part, 1 sample (exact colours), alpha
    guide_meta.json  params, id palette, projected extents, px-per-unit
The figure faces -Y (image bottom); its LEFT side is +X (image right).
Every proportion is in PARAMS so another race is a params.json away.
"""
import json
import math
import os
import sys

import bpy
from mathutils import Vector

PARAMS = {
    "res": [1920, 1080],
    "tilt_deg": 15.0,
    "margin": 1.05,              # ortho width = fingertip span * margin
    "clay_rgb": [128, 146, 84],  # sRGB tint of the clay
    "voxel": 0.006, "smooth_iter": 22,
    # squat stance: everything above the hips is lowered by `drop` (the legs shorten to match)
    # and the legs stand `leg_y` behind the trunk line, so a tilted camera sees the feet and a
    # little shin under the belly while the thighs stay behind it
    "drop": 0.25, "leg_y": 0.075,
    # trunk: r = (x half-width, y half-depth, z half-height), centre y, centre z
    "shoulder_z": 1.56,
    "ribcage": {"r": [0.325, 0.20, 0.30], "y": -0.005, "z": 1.33},
    "belly":   {"r": [0.255, 0.195, 0.25], "y": -0.045, "z": 1.10},
    "pelvis":  {"r": [0.27, 0.185, 0.17], "y": 0.01, "z": 0.92},
    "traps":   {"r": [0.34, 0.14, 0.11], "y": 0.04, "z": 1.565},
    "pec":     {"r": [0.150, 0.080, 0.110], "x": 0.125, "y": -0.138, "z": 1.41},
    "sternum": {"r": [0.10, 0.075, 0.11], "y": -0.140, "z": 1.40},
    "neck_r": 0.115,
    # arms, all on the shoulder line
    "shoulder_x": 0.39, "deltoid_r": [0.150, 0.122, 0.105],
    "upper_len": 0.30, "upper_r": [0.092, 0.080],
    "fore_len": 0.29, "fore_r": [0.078, 0.052],
    "palm": [0.066, 0.058, 0.024], "finger_len": 0.088, "finger_r": 0.0135,
    # head (hunched a little forward of the shoulder line)
    "head_y": -0.065, "head_z": 1.795, "skull_r": [0.125, 0.148, 0.132],
    "jaw":   {"r": [0.098, 0.080, 0.080], "dy": -0.088, "dz": -0.095},
    "chin":  {"r": [0.066, 0.036, 0.038], "dy": -0.140, "dz": -0.135},
    "brow":  {"r": [0.096, 0.036, 0.024], "dy": -0.132, "dz": -0.022},
    "cheek": {"r": [0.028, 0.028, 0.028], "x": 0.066, "dy": -0.108, "dz": -0.070},
    "nose":  {"r": [0.022, 0.026, 0.050], "dy": -0.152, "dz": -0.045},
    "nostril": {"r": [0.034, 0.024, 0.018], "dy": -0.162, "dz": -0.082},
    "tusk":  {"x": 0.060, "dy": -0.160, "dz": -0.125, "len": 0.078, "r": 0.021, "lean": -0.016},
    "ear":   {"len": 0.085, "r": 0.032, "back": 0.03, "up": 0.03},
    # legs / feet (heels under the hips, so the feet stay under the trunk)
    "hip_x": 0.150, "thigh_r": 0.130, "shin_r": 0.082,
    "foot": {"r": [0.074, 0.125, 0.042], "y": -0.045, "toe_r": 0.0215},
}

IDS = {  # sRGB bytes
    "body": (128, 128, 0), "head": (255, 0, 0),
    "upper_arm_L": (0, 255, 0), "upper_arm_R": (0, 128, 0),
    "forearm_L": (0, 0, 255), "forearm_R": (0, 0, 128),
    "hand_L": (255, 255, 0), "hand_R": (255, 0, 255),
    "foot_L": (0, 255, 255), "foot_R": (255, 128, 0),
}


def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    out = os.path.abspath(argv[0])
    P = json.loads(json.dumps(PARAMS))
    if len(argv) > 1:
        with open(argv[1]) as f:
            for k, v in json.load(f).items():
                if isinstance(v, dict) and isinstance(P.get(k), dict):
                    P[k].update(v)
                else:
                    P[k] = v
    os.makedirs(out, exist_ok=True)
    drop, ly = P["drop"], P["leg_y"]
    for k in ("ribcage", "belly", "pelvis", "traps", "pec", "sternum"):
        P[k]["z"] -= drop
    P["shoulder_z"] -= drop
    P["head_z"] -= drop
    lk = (0.86 - drop) / 0.86          # leg z scale
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    parts = {k: [] for k in IDS}

    def ell(part, loc, r, rot=None):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=1.0, location=loc)
        o = bpy.context.active_object
        o.scale = r if not isinstance(r, (int, float)) else (r, r, r)
        if rot:
            o.rotation_euler = rot
        parts[part].append(o)
        return o

    def limb(part, p0, p1, r0, r1):
        p0, p1 = Vector(p0), Vector(p1)
        d = p1 - p0
        bpy.ops.mesh.primitive_cone_add(vertices=64, radius1=r0, radius2=r1, depth=d.length,
                                        location=(p0 + p1) / 2)
        o = bpy.context.active_object
        o.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
        parts[part].append(o)
        ell(part, p0, r0)
        ell(part, p1, max(r1, 0.002))
        return o

    sz = P["shoulder_z"]
    # ---- trunk: one chest mass (ribcage + two overlapping pecs + sternum filler), belly, pelvis
    for k in ("ribcage", "belly", "pelvis", "traps"):
        ell("body", (0, P[k]["y"], P[k]["z"]), P[k]["r"])
    st = P["sternum"]
    ell("body", (0, st["y"], st["z"]), st["r"])
    pc = P["pec"]
    hx0 = P["hip_x"]
    for s in (-1, 1):
        ell("body", (s * pc["x"], pc["y"], pc["z"]), pc["r"])
        ell("body", (s * P["shoulder_x"], 0, sz), P["deltoid_r"])
        ell("body", (s * 0.27, 0.06, sz - 0.20), (0.13, 0.13, 0.20))        # lats / shoulder blade
        hx = s * hx0
        knee = (hx, ly - 0.035, 0.50 * lk)
        limb("body", (hx * 0.95, ly * 0.5, 0.86 * lk), knee, P["thigh_r"], P["shin_r"] * 1.12)
        ell("body", (hx, ly - 0.075, 0.50 * lk), (0.062, 0.05, 0.065))  # kneecap
        limb("body", knee, (hx, ly + 0.035, 0.10), P["shin_r"], P["shin_r"] * 0.68)
        ell("body", (hx, ly + 0.055, 0.34 * lk), (0.07, 0.065, 0.11))   # calf
    limb("body", (0, 0.02, sz - 0.06), (0, P["head_y"] + 0.045, P["head_z"] - 0.07),
         P["neck_r"] * 1.15, P["neck_r"])

    # ---- head: skull, brow ridge, cheekbones, nose, jaw/muzzle, chin, tusks, ears
    hy, hz = P["head_y"], P["head_z"]
    ell("head", (0, hy, hz), P["skull_r"])
    for k in ("jaw", "chin", "brow", "nose", "nostril"):
        ell("head", (0, hy + P[k]["dy"], hz + P[k]["dz"]), P[k]["r"])
    ck, t, e = P["cheek"], P["tusk"], P["ear"]
    for s in (-1, 1):
        ell("head", (s * ck["x"], hy + ck["dy"], hz + ck["dz"]), ck["r"])
        if t["len"] > 0:
            limb("head", (s * t["x"], hy + t["dy"], hz + t["dz"]),
                 (s * (t["x"] + 0.030), hy + t["dy"] + t["lean"], hz + t["dz"] + t["len"]),
                 t["r"], 0.004)
        x0 = s * (P["skull_r"][0] - 0.02)
        limb("head", (x0, hy + 0.01, hz - 0.03),
             (x0 + s * e["len"], hy + 0.01 + e["back"], hz - 0.03 + e["up"]), e["r"], 0.005)

    # ---- arms and feet (L = +X)
    for s, sfx in ((1, "L"), (-1, "R")):
        x0 = P["shoulder_x"]
        x1 = x0 + P["upper_len"]
        x2 = x1 + P["fore_len"]
        ua, fa = "upper_arm_" + sfx, "forearm_" + sfx
        limb(ua, (s * (x0 + 0.03), 0, sz), (s * (x1 - 0.012), 0, sz), *P["upper_r"])
        ell(ua, (s * (x0 + 0.15), -0.035, sz - 0.01), (0.105, 0.070, 0.078))   # biceps (front)
        ell(ua, (s * (x0 + 0.14), 0.040, sz - 0.005), (0.110, 0.062, 0.074))   # triceps (back)
        limb(fa, (s * x1, 0, sz), (s * x2, 0, sz), *P["fore_r"])
        ell(fa, (s * (x1 + 0.085), -0.012, sz), (0.095, 0.078, 0.070))         # forearm belly
        pr = P["palm"]
        px = x2 + pr[0] * 0.85
        hd = "hand_" + sfx
        ell(hd, (s * px, 0, sz), pr)
        fr, fl = P["finger_r"], P["finger_len"]
        for i, fy in enumerate((-0.62, -0.21, 0.21, 0.62)):
            ln = fl * (0.88, 1.0, 0.95, 0.78)[i]
            y = fy * pr[1] * 1.02
            limb(hd, (s * (px + pr[0] * 0.72), y, sz),
                 (s * (px + pr[0] * 0.72 + ln), y * 1.28, sz - 0.004), fr, fr * 0.82)
        limb(hd, (s * (px - pr[0] * 0.45), -pr[1] * 0.65, sz),
             (s * (px + pr[0] * 0.30), -pr[1] * 1.80, sz - 0.004), fr * 1.35, fr * 1.0)

        # foot: heel + instep wedge + ball + five short toes fused into the ball
        f = P["foot"]
        fx = s * P["hip_x"]
        ft = "foot_" + sfx
        fy0 = f["y"] + ly
        ell(ft, (fx, fy0, f["r"][2]), f["r"])
        ell(ft, (fx, fy0 + 0.02, 0.075), (0.052, 0.085, 0.055))               # instep toward the ankle
        ball_y = fy0 - f["r"][1] * 0.72
        ell(ft, (fx, ball_y, f["r"][2] * 0.78), (f["r"][0] * 1.14, 0.052, f["r"][2] * 0.78))
        for inner in range(5):                       # 0 = big toe (inside of the foot)
            tr = f["toe_r"] * (1.30, 1.04, 1.0, 0.95, 0.88)[inner]
            off = (-0.058, -0.024, 0.006, 0.034, 0.060)[inner]
            tx = fx + s * off
            ty = ball_y - 0.052 + 0.0030 * inner * inner
            ell(ft, (tx, ty, tr * 0.95), (tr * 0.92, tr * 1.6, tr * 0.95))

    all_objs = [o for v in parts.values() for o in v]
    bpy.context.view_layer.update()

    # ---- camera frame: orthographic, tilted toward the character's front
    th = math.radians(P["tilt_deg"])
    up = Vector((0, math.cos(th), math.sin(th)))        # image up
    fwd = Vector((0, math.sin(th), -math.cos(th)))      # view direction
    xs, us = [], []
    for o in all_objs:
        mw = o.matrix_world
        for v in o.data.vertices:
            w = mw @ v.co
            xs.append(w.x)
            us.append(w.dot(up))
    span = max(xs) - min(xs)
    u_lo, u_hi = min(us), max(us)

    def emit(name, rgb):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        em = nt.nodes.new("ShaderNodeEmission")
        em.inputs[0].default_value = (lin(rgb[0]), lin(rgb[1]), lin(rgb[2]), 1)
        o = nt.nodes.new("ShaderNodeOutputMaterial")
        nt.links.new(em.outputs[0], o.inputs[0])
        return m

    for k, objs in parts.items():
        m = emit("id_" + k, IDS[k])
        for o in objs:
            o.data.materials.append(m)

    # ---- fused clay copy
    bpy.ops.object.select_all(action="DESELECT")
    for o in all_objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = all_objs[0]
    bpy.ops.object.duplicate()
    bpy.ops.object.join()
    clay = bpy.context.active_object
    clay.name = "clay"
    rm = clay.modifiers.new("remesh", "REMESH")
    rm.mode = "VOXEL"
    rm.voxel_size = P["voxel"]
    sm = clay.modifiers.new("smooth", "SMOOTH")
    sm.factor = 0.8
    sm.iterations = int(P["smooth_iter"])
    bpy.ops.object.modifier_apply(modifier="remesh")
    bpy.ops.object.modifier_apply(modifier="smooth")
    bpy.ops.object.shade_smooth()
    clay.data.materials.clear()
    cm = bpy.data.materials.new("clay")
    cm.use_nodes = True
    b = cm.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = tuple(lin(c) for c in P["clay_rgb"]) + (1,)
    b.inputs["Roughness"].default_value = 0.9
    clay.data.materials.append(cm)

    cam_d = bpy.data.cameras.new("cam")
    cam_d.type = "ORTHO"
    cam_d.ortho_scale = span * P["margin"]
    cam_d.clip_end = 100
    cam = bpy.data.objects.new("cam", cam_d)
    cam.location = up * ((u_lo + u_hi) / 2) - fwd * 20
    cam.rotation_euler = (th, 0, 0)   # 0 = straight down -Z with +Y image-up
    scn.collection.objects.link(cam)
    scn.camera = cam

    def sun(rot, energy, angle=30):
        d = bpy.data.lights.new("sun", "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        o = bpy.data.objects.new("sun", d)
        o.rotation_euler = rot
        scn.collection.objects.link(o)

    sun((math.radians(38), math.radians(-14), 0), 2.6)   # key: above, leaning to the front (south)
    sun((math.radians(-20), math.radians(25), 0), 0.7)   # fill from behind-left
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.5, 0.5, 1)
    w.node_tree.nodes["Background"].inputs[1].default_value = 0.9
    scn.world = w

    scn.render.engine = "CYCLES"
    scn.cycles.device = "CPU"
    scn.render.resolution_x, scn.render.resolution_y = P["res"]
    scn.render.resolution_percentage = 100
    scn.render.film_transparent = True
    scn.render.image_settings.file_format = "PNG"
    scn.render.image_settings.color_mode = "RGBA"
    scn.view_settings.view_transform = "Standard"
    scn.view_settings.look = "None"

    for o in all_objs:
        o.hide_render = True
    scn.cycles.samples = 48
    scn.render.filepath = os.path.join(out, "guide_clay.png")
    bpy.ops.render.render(write_still=True)

    # ids: 1 sample + tiny box filter -> exact flat colours, hard edges
    clay.hide_render = True
    for o in all_objs:
        o.hide_render = False
    scn.cycles.samples = 1
    scn.cycles.use_denoising = False
    scn.cycles.pixel_filter_type = "BOX"
    scn.cycles.filter_width = 0.01
    scn.render.filepath = os.path.join(out, "guide_ids.png")
    bpy.ops.render.render(write_still=True)

    depth = u_hi - u_lo
    meta = {"params": P, "ids": IDS, "tilt_deg": P["tilt_deg"], "span": span,
            "proj_depth": depth, "depth_over_span": depth / span,
            "ortho_scale": cam_d.ortho_scale, "px_per_unit": P["res"][0] / cam_d.ortho_scale,
            "facing": "-Y = image bottom; character left = +X = image right"}
    with open(os.path.join(out, "guide_meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("GUIDE_OK tilt=%.1f depth/span=%.3f" % (P["tilt_deg"], meta["depth_over_span"]))


main()
