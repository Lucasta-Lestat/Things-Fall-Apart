"""Blender proxy for the true top-down base-body camera (pilot: blender_guide).

    blender -b --python tools/rigkit/pilot/blender_guide_proxy.py -- OUT_DIR [params.json]

Builds a T-posed humanoid from primitives (per rig part), fuses a copy into one
clay surface, and renders with an ORTHOGRAPHIC camera looking straight down -Z:
    guide_clay.png   clay render, transparent film (composited on grey later)
    guide_ids.png    flat colour per rig part, 1 sample (exact colours), alpha
    guide_meta.json  params, id palette, world extents, px-per-unit
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
    "margin": 1.05,              # ortho width = fingertip span * margin
    # trunk: r = (x half-width, y half-depth, z half-height), centre y, centre z
    "shoulder_z": 1.60,
    "ribcage": {"r": [0.30, 0.185, 0.30], "y": -0.02, "z": 1.36},
    "belly":   {"r": [0.24, 0.19, 0.22], "y": -0.05, "z": 1.10},
    "pelvis":  {"r": [0.25, 0.17, 0.16], "y": 0.00, "z": 0.94},
    "traps":   {"r": [0.33, 0.14, 0.10], "y": 0.035, "z": 1.60},
    "pec":     {"r": [0.19, 0.10, 0.13], "x": 0.17, "y": -0.13, "z": 1.44},
    "neck_r": 0.105,
    # arms, all on the shoulder line
    "shoulder_x": 0.37, "deltoid_r": [0.135, 0.12, 0.115],
    "upper_len": 0.30, "upper_r": [0.088, 0.076],
    "fore_len": 0.28, "fore_r": [0.074, 0.05],
    "palm": [0.065, 0.058, 0.024], "finger_len": 0.085, "finger_r": 0.0125,
    # head
    "head_y": -0.04, "head_z": 1.82, "skull_r": [0.128, 0.148, 0.135],
    "jaw": {"r": [0.105, 0.105, 0.085], "y": -0.085, "z": 1.72},
    "brow": {"r": [0.10, 0.034, 0.028], "y": -0.160, "z": 1.815},
    "nose": {"r": [0.032, 0.034, 0.03], "y": -0.196, "z": 1.765},
    "tusk": {"x": 0.062, "y": -0.188, "z": 1.725, "len": 0.06, "r": 0.016, "lean": -0.03},
    "ear": {"len": 0.075, "r": 0.03, "back": 0.035, "up": 0.02},
    # legs / feet
    "hip_x": 0.135, "thigh_r": 0.115, "shin_r": 0.075,
    "foot": {"r": [0.058, 0.14, 0.04], "y": -0.118, "toe_r": 0.017},
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
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    parts = {k: [] for k in IDS}

    def ell(part, loc, r):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=1.0, location=loc)
        o = bpy.context.active_object
        o.scale = r if not isinstance(r, (int, float)) else (r, r, r)
        parts[part].append(o)
        return o

    def limb(part, p0, p1, r0, r1):
        p0, p1 = Vector(p0), Vector(p1)
        d = p1 - p0
        bpy.ops.mesh.primitive_cone_add(vertices=32, radius1=r0, radius2=r1, depth=d.length,
                                        location=(p0 + p1) / 2)
        o = bpy.context.active_object
        o.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
        parts[part].append(o)
        ell(part, p0, r0)
        ell(part, p1, max(r1, 0.002))
        return o

    sz = P["shoulder_z"]
    # ---- trunk
    for k in ("ribcage", "belly", "pelvis", "traps"):
        ell("body", (0, P[k]["y"], P[k]["z"]), P[k]["r"])
    pc = P["pec"]
    for s in (-1, 1):
        ell("body", (s * pc["x"], pc["y"], pc["z"]), pc["r"])
        ell("body", (s * P["shoulder_x"], 0, sz), P["deltoid_r"])
        hx = s * P["hip_x"]   # legs live under the trunk
        limb("body", (hx, 0, 0.90), (hx, -0.02, 0.50), P["thigh_r"], P["shin_r"] * 1.15)
        limb("body", (hx, -0.02, 0.50), (hx, -0.01, 0.09), P["shin_r"], P["shin_r"] * 0.7)
    limb("body", (0, 0.0, sz - 0.05), (0, P["head_y"] + 0.02, P["head_z"] - 0.08),
         P["neck_r"], P["neck_r"] * 0.95)

    # ---- head
    hy, hz = P["head_y"], P["head_z"]
    ell("head", (0, hy, hz), P["skull_r"])
    for k in ("jaw", "brow", "nose"):
        ell("head", (0, P[k]["y"], P[k]["z"]), P[k]["r"])
    t, e = P["tusk"], P["ear"]
    for s in (-1, 1):
        if t["len"] > 0:
            limb("head", (s * t["x"], t["y"], t["z"]),
                 (s * (t["x"] + 0.008), t["y"] + t["lean"], t["z"] + t["len"]), t["r"], 0.003)
        x0 = s * (P["skull_r"][0] - 0.015)
        limb("head", (x0, hy + 0.005, hz - 0.02),
             (x0 + s * e["len"], hy + e["back"], hz - 0.02 + e["up"]), e["r"], 0.004)

    # ---- arms and feet (L = +X)
    for s, sfx in ((1, "L"), (-1, "R")):
        x0 = P["shoulder_x"]
        x1 = x0 + P["upper_len"]
        x2 = x1 + P["fore_len"]
        limb("upper_arm_" + sfx, (s * (x0 + 0.03), 0, sz), (s * (x1 - 0.012), 0, sz), *P["upper_r"])
        limb("forearm_" + sfx, (s * x1, 0, sz), (s * x2, 0, sz), *P["fore_r"])
        pr = P["palm"]
        px = x2 + pr[0] * 0.85
        ell("hand_" + sfx, (s * px, 0, sz), pr)
        fr, fl = P["finger_r"], P["finger_len"]
        for i, fy in enumerate((-0.6, -0.2, 0.2, 0.6)):
            ln = fl * (0.86, 1.0, 0.95, 0.78)[i]
            y = fy * pr[1] * 1.05
            limb("hand_" + sfx, (s * (px + pr[0] * 0.75), y, sz),
                 (s * (px + pr[0] * 0.75 + ln), y * 1.25, sz), fr, fr * 0.8)
        limb("hand_" + sfx, (s * (px - pr[0] * 0.35), -pr[1] * 0.7, sz),
             (s * (px + pr[0] * 0.35), -pr[1] * 1.75, sz), fr * 1.25, fr * 0.95)
        f = P["foot"]
        fx = s * P["hip_x"]
        ell("foot_" + sfx, (fx, f["y"], f["r"][2]), f["r"])
        ell("foot_" + sfx, (fx, f["y"] - f["r"][1] * 0.70, f["r"][2] * 0.8),
            (f["r"][0] * 1.12, f["r"][1] * 0.33, f["r"][2] * 0.8))   # ball of the foot
        for i in range(5):
            big = (i == (0 if s > 0 else 4))   # big toe on the inside
            tx = fx + (i - 2) * f["r"][0] * 0.47
            inner = (4 - i) if s < 0 else i     # 0 = big toe
            ty = f["y"] - f["r"][1] * (1.0 - 0.04 * inner)
            ell("foot_" + sfx, (tx, ty, f["toe_r"]), f["toe_r"] * (1.25 if big else 1.0))

    all_objs = [o for v in parts.values() for o in v]
    bpy.context.view_layer.update()
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for o in all_objs:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))

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
    rm.voxel_size = 0.007
    sm = clay.modifiers.new("smooth", "SMOOTH")
    sm.factor = 0.8
    sm.iterations = 30
    bpy.ops.object.modifier_apply(modifier="remesh")
    bpy.ops.object.modifier_apply(modifier="smooth")
    bpy.ops.object.shade_smooth()
    clay.data.materials.clear()
    cm = bpy.data.materials.new("clay")
    cm.use_nodes = True
    b = cm.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0.55, 0.47, 0.38, 1)
    b.inputs["Roughness"].default_value = 0.85
    clay.data.materials.append(cm)

    # ---- camera: orthographic, straight down
    span = hi.x - lo.x
    cam_d = bpy.data.cameras.new("cam")
    cam_d.type = "ORTHO"
    cam_d.ortho_scale = span * P["margin"]
    cam_d.clip_end = 100
    cam = bpy.data.objects.new("cam", cam_d)
    cam.location = (0, (lo.y + hi.y) / 2, 10)
    cam.rotation_euler = (0, 0, 0)   # looks down -Z, +Y is image up
    scn.collection.objects.link(cam)
    scn.camera = cam

    def sun(rot, energy):
        d = bpy.data.lights.new("sun", "SUN")
        d.energy = energy
        d.angle = math.radians(25)
        o = bpy.data.objects.new("sun", d)
        o.rotation_euler = rot
        scn.collection.objects.link(o)

    sun((math.radians(32), math.radians(-12), 0), 3.2)   # above, leaning to the front (south)
    sun((math.radians(-25), math.radians(20), 0), 0.8)
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.5, 0.5, 1)
    w.node_tree.nodes["Background"].inputs[1].default_value = 0.55
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
    scn.cycles.samples = 64
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

    meta = {"params": P, "ids": IDS, "lo": list(lo), "hi": list(hi), "span": span,
            "depth": hi.y - lo.y, "depth_over_span": (hi.y - lo.y) / span,
            "ortho_scale": cam_d.ortho_scale, "px_per_unit": P["res"][0] / cam_d.ortho_scale,
            "facing": "-Y = image bottom; character left = +X = image right"}
    with open(os.path.join(out, "guide_meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("GUIDE_OK depth/span=%.3f" % meta["depth_over_span"])


main()
