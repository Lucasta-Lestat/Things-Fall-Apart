"""Proxy features for gen_plan's tilted guide: everything a race carries beyond the plain humanoid.

A race spec (tools/rigkit/races_td/<race>.json) lists them under "features":

    "features": {"horns": {"style": "ram", "len": 3.0}, "tail": {"curl": 200, "side": -1}}

The key is the feature's name; its preset is "kind" (default: the name). Every knob has a default in
PRESETS, so a feature can be as short as `"beard": {}`. Setting a feature to null in a spec that has
a "base" removes the base's feature.

Two coordinate spaces:

  head  x = image right, y = toward the character's FRONT (image bottom), z = up, origin at the
        centre of the cranium, 1.0 = the cranium's radius (skull_r). Head features are built before
        head_scale is applied, so they grow with the head.
  body  the proxy's world: half-span units, origin on the floor plan under the shoulder centre,
        shoulders at z = 1.56, floor at floor_z.

Every feature carries
  label   the derive.PALETTE label its pixels get (face, hair, body, over_garment, forearm ...).
          over_garment = anatomy that is drawn again ABOVE worn items (tails, folded wings, back fins).
  colour  a key of the spec's "colours" (falls back to hair for hair-labelled features, else skin).
  core    whether it counts as the humanoid figure for the depth / span and symmetry gates. Tails,
          wings, back fins, horns, upright ears, hats and hair that hangs past the head do not.
  guide   sentence for the prompt: what this form in the sculpt is.   (optional override)
  paint   phrase for the prompt: how to paint it.                     (optional override)

expand() turns features into generic shapes, ("ell", part, centre, radii) and
("rod", part, a, b, ra, rb, kz), which gen_plan.primitives adds to the proxy.
"""
import numpy as np

HEAD, BODY = "head", "body"

# knob defaults per preset. "space", "label", "colour", "core" are common to all.
PRESETS = {
    # ---- head
    "horns": dict(space=HEAD, label="face", colour="horn", core=False, style="swept",
                  root=[0.55, -0.25, 0.95], len=1.8, r=[0.22, 0.03], count=1, gap=0.3,
                  guide="A horn rises from each side of the top of the head and sweeps backward.",
                  paint="the horns as smooth ridged horn"),
    "ears_up": dict(space=HEAD, label="face", colour="skin", core=False,
                    root=[0.62, -0.15, 0.85], dir=[0.62, -0.25, 0.75], len=1.3, r=[0.50, 0.05], flat=0.45,
                    guide="A large upright pointed ear stands on each side of the top of the head.",
                    paint="each ear as a thin upright ear with a paler inner hollow"),
    "snout": dict(space=HEAD, label="face", colour="skin", core=True,
                  root=[0.0, 0.75, -0.35], droop=0.35, len=1.0, r=[0.62, 0.42],
                  guide="", paint=""),
    "beak": dict(space=HEAD, label="face", colour="beak", core=True,
                 root=[0.0, 0.85, -0.30], droop=0.55, len=0.8, r=[0.36, 0.05],
                 guide="", paint=""),
    "crest": dict(space=HEAD, label="face", colour="skin", core=False,
                  start=[0.55, 1.15], end=[-1.0, 0.85], count=5, h=0.45, w=0.07,
                  guide="A low crest of short spines runs along the middle of the scalp from front to back.",
                  paint="the crest as a row of short spines"),
    "ring": dict(space=HEAD, label="face", colour="skin", core=True,
                 count=9, radius=1.02, size=0.30, z=-0.15, arc=[50, 310], flat=0.8,
                 guide="", paint=""),
    "hair_bushy": dict(space=HEAD, label="hair", colour="hair", core=True, kind_of="ring",
                       count=11, radius=1.0, size=0.40, z=0.10, arc=[45, 315], flat=0.8,
                       guide="", paint=""),
    "hair_long": dict(space=HEAD, label="hair", colour="hair", core=False,
                      width=1.7, depth=1.0, back=0.9, drop=1.9, thick=0.4,
                      guide="Behind the head the hair spreads over the tops of the shoulders and the upper back.",
                      paint="the hair on the shoulders as soft locks seen from above"),
    "locks": dict(space=HEAD, label="hair", colour="hair", core=False,
                  x=0.95, out=0.10, fwd=[0.6, 1.5], len=1.1, r=[0.26, 0.15],
                  guide="A lock of hair hangs forward over each collarbone beside the face.",
                  paint="each front lock as a soft strand lying on the chest"),
    "ponytail": dict(space=HEAD, label="hair", colour="hair", core=False,
                     root=[0.0, -0.85, 0.35], end=[0.0, -1.7, -1.9], r=[0.36, 0.14],
                     guide="A tail of gathered hair hangs from the back of the head down the upper back.",
                     paint="the gathered hair as one soft tail"),
    "bun": dict(space=HEAD, label="hair", colour="hair", core=False,
                at=[0.0, -0.55, 1.2], size=0.5,
                guide="A round knot of gathered hair sits on the back of the crown.",
                paint="the knot of hair as a small round bun"),
    "beard": dict(space=HEAD, label="hair", colour="hair", core=True,
                  at=[0.0, 0.95, -1.55], width=0.85, depth=0.55, len=1.0,
                  guide="Below the chin a beard hangs over the top of the chest.",
                  paint="the beard as thick combed hair"),
    "hat_cone": dict(space=HEAD, label="hair", colour="hat", core=False,
                     root=[0.0, -0.1, 0.9], lean=0.8, len=3.0, r=[1.1, 0.06],
                     guide="A tall pointed cap covers the scalp and tapers to a tip that leans backward.",
                     paint="the cap as soft felt"),
    # ---- body
    "tail": dict(space=BODY, label="over_garment", colour="skin", core=False,
                 root_y=-0.10, len=0.9, r=[0.07, 0.012], curl=120, side=1, tip=0.0, tip_curl=0.0, taper=1.0,
                 guide="Behind the character a tail lies on the floor, coming out past the back and curving "
                       "toward the {side} of the picture.",
                 paint="the tail as a smooth tapering tail in the same skin as the body"),
    "wings": dict(space=BODY, label="over_garment", colour="wing", core=False,
                  x=0.17, y=-0.17, z=1.47, r=[0.14, 0.13, 0.20], fan=0.10,
                  guide="On the upper back two folded wings lie side by side behind the head.",
                  paint="the folded wings as layered feathers"),
    "dorsal_fin": dict(space=BODY, label="over_garment", colour="skin", core=False,
                       y=[-0.02, -0.20], z=1.60, h=0.14, w=0.014, count=4,
                       guide="A thin upright fin runs down the middle of the upper back behind the head.",
                       paint="the back fin as a thin ribbed membrane"),
    "arm_fins": dict(space=BODY, label="forearm", colour="skin", core=True,
                     at=0.5, size=0.07,
                     guide="A small flat fin stands out from the back edge of each forearm.",
                     paint="each forearm fin as a thin ribbed membrane"),
    "bust": dict(space=BODY, label="body", colour="skin", core=True, size=1.0, guide="", paint=""),
    # ---- generic, either space: {"kind": "blob", "space": "head", "at": [...], "r": [...], "mirror": true}
    "blob": dict(space=HEAD, label="face", colour="skin", core=True, at=[0, 0, 0], r=[0.3, 0.3, 0.3],
                 mirror=False, guide="", paint=""),
    "rod": dict(space=HEAD, label="face", colour="skin", core=True, a=[0, 0, 0], b=[0, 1, 0], r=[0.2, 0.1],
                kz=1.0, mirror=False, guide="", paint=""),
}

HORN_STYLES = {     # dir, curl-toward, curl degrees (overridable per feature: "dir", "toward", "curl")
    "swept": ([0.35, -0.85, 0.40], [0.3, 0.0, 0.9], 35),
    "up": ([0.35, -0.30, 0.90], [0.2, -0.9, 0.0], 40),
    "ram": ([0.60, -0.70, 0.40], [0.3, 0.9, -0.4], 250),
    "wide": ([0.95, -0.15, 0.30], [0.0, -0.5, 0.85], 80),
}


def resolved(features):
    """{name: knobs} with preset defaults filled in, in spec order. Features set to false are skipped."""
    out = {}
    for name, f in (features or {}).items():
        if f is None or f is False:
            continue
        f = dict(f)
        kind = f.get("kind", name)
        if kind not in PRESETS:
            raise KeyError("feature %r: unknown kind %r (known: %s)" % (name, kind, ", ".join(sorted(PRESETS))))
        out[name] = dict(PRESETS[kind], kind=kind, **{k: v for k, v in f.items() if k != "kind"})
    return out


def _unit(v):
    v = np.array(v, float)
    return v / max(float(np.linalg.norm(v)), 1e-9)


def arc(root, d, toward, length, curl_deg, n=14):
    """Points of an arc of the given length that leaves `root` along `d` and bends toward `toward`
    through curl_deg degrees in all."""
    d = _unit(d)
    b = np.array(toward, float)
    b = _unit(b - d * float(b @ d))
    th = max(np.radians(float(curl_deg)), 1e-3)
    R = float(length) / th
    t = np.linspace(0.0, th, n)
    return [np.array(root, float) + R * (np.sin(a) * d + (1 - np.cos(a)) * b) for a in t]


def _chain(out, part, pts, r0, r1, kz=1.0):
    n = len(pts) - 1
    for i in range(n):
        ra = r0 + (r1 - r0) * i / float(n)
        rb = r0 + (r1 - r0) * (i + 1) / float(n)
        out.append(("rod", part, tuple(pts[i]), tuple(pts[i + 1]), ra, rb, kz))


def part_name(f, side=None):
    """gen_plan part string: label[:c.<colour>][:x]   (x = not part of the core figure)."""
    lab = f["label"]
    if lab in ("forearm", "upperarm", "hand", "foot"):
        lab += "_" + side
    return lab + ":c." + f["colour"] + ("" if f["core"] else ":x")


def expand(features, space, p):
    """Generic shapes of every feature living in `space`. p: the race's (tilt) params."""
    out = []
    for name, f in resolved(features).items():
        if f["space"] != space:
            continue
        kind = f.get("kind_of", f["kind"])
        pn = part_name(f) if f["label"] not in ("forearm", "upperarm", "hand", "foot") else None
        if kind == "horns":
            d, tw, curl = HORN_STYLES[f["style"]]
            d, tw, curl = f.get("dir", d), f.get("toward", tw), f.get("curl", curl)
            for k in range(int(f["count"])):
                for s in (-1, 1):
                    root = np.array(f["root"], float) + np.array([0, -f["gap"] * k, -0.1 * k])
                    m = np.array([s, 1, 1], float)
                    pts = arc(root * m, np.array(d) * m, np.array(tw) * m, f["len"] * (0.8 ** k), curl)
                    _chain(out, pn, pts, f["r"][0] * (0.85 ** k), f["r"][1])
        elif kind == "ears_up":
            for s in (-1, 1):
                m = np.array([s, 1, 1], float)
                a = np.array(f["root"], float) * m
                b = a + _unit(np.array(f["dir"], float) * m) * f["len"]
                out.append(("rod", pn, tuple(a), tuple(b), f["r"][0], f["r"][1], f["flat"]))
        elif kind in ("snout", "beak"):
            a = np.array(f["root"], float)
            b = a + np.array([0.0, 1.0, -f["droop"]]) * f["len"]
            out.append(("rod", pn, tuple(a), tuple(b), f["r"][0], f["r"][1], 0.8))
        elif kind == "crest":
            (y0, z0), (y1, z1), n = f["start"], f["end"], int(f["count"])
            seg = abs(y1 - y0) / max(n, 1)
            for i in range(n):
                t = (i + 0.5) / n
                out.append(("ell", pn, (0.0, y0 + (y1 - y0) * t, z0 + (z1 - z0) * t + f["h"] * 0.4),
                            (f["w"], seg * 0.75, f["h"])))
        elif kind == "ring":
            a0, a1 = f["arc"]
            n = int(f["count"])
            for i in range(n):
                a = np.radians(a0 + (a1 - a0) * (i / float(max(n - 1, 1))))
                sz = f["size"] * (1.0 + 0.18 * ((i * 7) % 3 - 1))        # uneven, but the same every run
                out.append(("ell", pn, (f["radius"] * np.sin(a), f["radius"] * np.cos(a) * 1.05, f["z"]),
                            (sz, sz, sz * f["flat"])))
        elif kind == "hair_long":
            out.append(("ell", pn, (0.0, -f["back"], -f["drop"]), (f["width"], f["depth"], f["thick"])))
        elif kind == "locks":
            for s in (-1, 1):
                a = (s * f["x"], f["fwd"][0], -0.3)
                b = (s * (f["x"] + f["out"]), f["fwd"][1], -f["len"])
                out.append(("rod", pn, a, b, f["r"][0], f["r"][1], 1.0))
        elif kind == "ponytail":
            out.append(("rod", pn, tuple(f["root"]), tuple(f["end"]), f["r"][0], f["r"][1], 1.0))
        elif kind == "bun":
            out.append(("ell", pn, tuple(f["at"]), (f["size"], f["size"], f["size"] * 0.9)))
        elif kind == "beard":
            out.append(("ell", pn, tuple(f["at"]), (f["width"], f["depth"], f["len"])))
        elif kind == "hat_cone":
            a = np.array(f["root"], float)
            b = a + np.array([0.0, -f["lean"], f["len"]])
            out.append(("rod", pn, tuple(a), tuple(b), f["r"][0], f["r"][1], 1.0))
        elif kind == "tail":
            z0 = p.get("floor_z", 0.70)
            r0, r1 = f["r"]
            s = 1.0 if f["side"] >= 0 else -1.0
            a = np.array([0.0, f["root_y"], 0.95])
            b = np.array([0.0, f["root_y"] - 0.10 - r0, z0 + r0 * 0.9])
            pts = [a] + arc(b, [0, -1, 0], [s, 0, 0], f["len"], f["curl"], n=22)
            if f["tip"] > 0:                    # a straight run after the curl (a tail that comes round to the front)
                d = _unit(pts[-1] - pts[-2])     # tip_curl: degrees it bends, + = away from the body, - = toward it
                out_dir = np.array([s, 0.0, 0.0]) if f["tip_curl"] >= 0 else np.array([-s, 0.0, 0.0])
                if abs(float(out_dir @ d)) > 0.95:
                    out_dir = np.array([0.0, 1.0, 0.0])
                pts += arc(pts[-1], d, out_dir, f["tip"], max(abs(f["tip_curl"]), 0.1), n=12)[1:]
            zt = np.linspace(z0 + r0 * 0.9, z0 + r1 * 0.9, len(pts) - 1)      # the tail rests on the floor
            for q, z in zip(pts[1:], zt):
                q[2] = z
            if f["taper"] == 1.0:
                _chain(out, pn, pts, r0, r1)
            else:                               # taper > 1 keeps the tail thick for longer and thins it near the tip
                n = len(pts) - 1
                rad = [r0 + (r1 - r0) * (i / float(n)) ** f["taper"] for i in range(n + 1)]
                for i in range(n):
                    out.append(("rod", pn, tuple(pts[i]), tuple(pts[i + 1]), rad[i], rad[i + 1], 1.0))
        elif kind == "wings":
            rx, ry, rz = f["r"]
            for s in (-1, 1):
                out.append(("ell", pn, (s * f["x"], f["y"], f["z"]), (rx, ry, rz)))
            if f["fan"] > 0:
                out.append(("ell", pn, (0.0, f["y"] - ry * 0.7, f["z"] - rz * 0.9), (f["fan"], f["fan"], 0.08)))
        elif kind == "dorsal_fin":
            (y0, y1), n = f["y"], int(f["count"])
            seg = abs(y1 - y0) / max(n, 1)
            for i in range(n):
                t = (i + 0.5) / n
                k = 1.0 - 0.5 * abs(t - 0.45) * 2
                out.append(("ell", pn, (0.0, y0 + (y1 - y0) * t, f["z"]), (f["w"], seg * 0.8, f["h"] * k)))
        elif kind == "arm_fins":
            ex, wx = p["elbow_x"], p["wrist_x"]
            fr = p["forearm_r"]
            rr = fr[0] + (fr[1] - fr[0]) * f["at"]
            for s, side in ((-1, "l"), (1, "r")):
                x = s * (ex + (wx - ex) * f["at"])
                out.append(("ell", part_name(f, side), (x, -(rr * 0.5 + f["size"] * 0.6), 1.55),
                            (f["size"] * 1.5, f["size"], 0.012)))
        elif kind == "bust":
            ph, cs, k = p["pec_half"], p["chest_depth_s"], f["size"]
            for s in (-1, 1):
                out.append(("ell", pn, (s * ph * 0.95, cs - 0.075, 1.30), (ph * 0.92, 0.075 * (0.9 + 0.25 * k), 0.085)))
        elif kind == "blob":
            for s in ((-1, 1) if f["mirror"] else (1,)):
                at = np.array(f["at"], float) * np.array([s, 1, 1])
                out.append(("ell", pn, tuple(at), tuple(f["r"])))
        elif kind == "rod":
            for s in ((-1, 1) if f["mirror"] else (1,)):
                m = np.array([s, 1, 1], float)
                out.append(("rod", pn, tuple(np.array(f["a"], float) * m), tuple(np.array(f["b"], float) * m),
                            f["r"][0], f["r"][1], f["kz"]))
    return out


def foot_shapes(p, s, side, fx, ty, z0):
    """A non-human foot front (spec "foot": {"kind": "claw" | "hoof" | "paw", ...}) as generic shapes.
    fx: foot centre x, ty: toe-tip y, z0: floor. Same heel / instep as the human foot."""
    ft = dict(dict(kind="claw", toes=3, toe_len=1.25, spread=0.34, claw=0.5), **p.get("foot", {}))
    tr = p["toe_r"]
    fw = p.get("foot_w", tr * 2.6)
    fl = p.get("foot_len", 0.25)
    tl = fw * 0.95
    heel = ty - fl
    ball = ty - tl - fw * 0.30
    part = "foot_" + side
    out = [("rod", part, (s * fx, heel + 0.045, z0 + 0.040), (s * fx, ball - 0.01, z0 + 0.034), fw * 0.72, fw * 0.98, 0.62),
           ("ell", part, (s * fx, heel + 0.10, z0 + 0.075), (fw * 0.70, 0.075, 0.055))]
    n = int(ft["toes"])
    reach = (tl + fw * 0.30)
    if ft["kind"] == "hoof":                    # two blunt lobes side by side
        for k in (-1, 1):
            out.append(("rod", part, (s * (fx + k * fw * 0.42), ball - 0.01, z0 + 0.03),
                        (s * (fx + k * fw * 0.46), ball + reach - fw * 0.5, z0 + 0.028), fw * 0.50, fw * 0.44, 0.8))
    elif ft["kind"] == "paw":                   # short round toes in a shallow arc
        for i in range(n):
            u = (i - (n - 1) / 2.0) / max((n - 1) / 2.0, 1.0)
            rad = fw * 1.9 / (2 * n) * 1.15
            out.append(("ell", part, (s * (fx + u * fw * 0.82), ball + reach * (0.78 - 0.20 * u * u) - rad, z0 + 0.024),
                        (rad, rad * 1.25, rad * 0.8)))
    else:                                       # claw: long tapering toes that fan out
        for i in range(n):
            u = (i - (n - 1) / 2.0) / max((n - 1) / 2.0, 1.0)
            rad = fw * 1.9 / (2 * n) * 1.05
            ang = u * ft["spread"]
            ln = reach * ft["toe_len"] * (1.0 - 0.12 * abs(u))
            a = (s * (fx + u * fw * 0.62), ball - 0.005, z0 + 0.024)
            b = (s * (fx + u * fw * 0.62 + np.sin(ang) * ln), ball + np.cos(ang) * ln, z0 + 0.016)
            out.append(("rod", part, a, b, rad, rad * (1.0 - 0.75 * ft["claw"]), 0.8))
    return out


def sentences(features, space, key):
    """The prompt text the features of one space contribute: key = "guide" or "paint"."""
    out = []
    for name, f in resolved(features).items():
        if f["space"] != space or not f.get(key):
            continue
        t = f[key]
        if "{side}" in t:
            t = t.replace("{side}", "right" if f.get("side", 1) >= 0 else "left")
        out.append(t)
    return out
