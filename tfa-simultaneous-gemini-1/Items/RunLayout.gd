# res://Items/RunLayout.gd
# RUN furniture: one item drawn as a continuous strip along its LOCAL x axis at
# any length -- a banquet table, a bar counter, a pew, a cloth runner -- from a
# 3-slice atlas row (Items.json "run" block, tools/make_run_atlas.py):
#   atlas  [pad|capL] gut [mid variant(s)] gut [capR|pad]   (+ pad rows)
#   strip  [capL | middle ............... | capR]
# Pure math (headless-testable, no textures). Terrain Generation's
# scripts/RunArt.gd is a 1:1 mirror; tests/run_parity_fixture.json pins both.
#
# Spawn contract (Maps.json item_spawns): "length" px (its presence = a run),
# "width" px (default meta.across), "caps" bitmask (1 = start/-x, 2 = end/+x;
# default 3; 0/1/2 butt-join L/T arrangements), "seed" int, "decor" list.
class_name RunLayout
extends RefCounted

# Built-in procedural decor (drawn, never items): base diameter px at scale 1.
const BUILTIN_DECOR := {"_plate": 16.0, "_cup": 6.0, "_candle": 5.0}


# Same integer hash in TG RunArt (variant picks, decor jitter seeds).
static func hash_i(seed: int, i: int) -> int:
	return ((seed * 73856093) ^ (i * 19349663)) & 0x7fffffff


# A spawn def / capture record -> the run dict Item.gd consumes ({} = no run).
# Values are coerced and typed here; the raw def is what persistence keeps.
static func run_from_spawn(def: Dictionary) -> Dictionary:
	if not def.has("length"):
		return {}
	var out: Dictionary = {
		"length": float(def["length"]),
		"width": float(def.get("width", -1.0)) if def.get("width") != null else -1.0,
		"caps": int(def.get("caps", 3)) if def.get("caps") != null else 3,
		"seed": int(def.get("seed", 0)) if def.get("seed") != null else 0,
		"decor": [],
	}
	var dv: Variant = def.get("decor")
	if dv is Array:
		out["decor"] = (dv as Array).duplicate(true)
	return out


# The strip's draw list: [{"dst": Rect2, "src": Rect2}] in local px, centred
# (x in [-L/2, L/2], y in [-W/2, W/2]; the transparent atlas pad grows the
# rects by pad*k so the opaque art keeps its exact size and the outer edges
# stay antialiased at any rotation).
static func tiles(length: float, width: float, meta: Dictionary, caps: int = 3, seed: int = 0) -> Array:
	var out: Array = []
	var aw: float = float(meta.get("w", 0.0))
	var ah: float = float(meta.get("h", 0.0))
	var pad: float = float(meta.get("pad", 0.0))
	var cap: float = float(meta.get("cap", 0.0))
	var opaque_h: float = ah - 2.0 * pad
	var mids: Array = meta.get("mid", [])
	if aw <= 0.0 or opaque_h <= 0.0 or length <= 0.0 or width <= 0.0 or mids.is_empty():
		return out
	var k: float = width / opaque_h
	var half_l: float = length * 0.5
	var y0: float = -width * 0.5 - pad * k
	var hh: float = ah * k
	var cl: float = cap * k if (caps & 1) != 0 else 0.0
	var cr: float = cap * k if (caps & 2) != 0 else 0.0
	var f: float = 1.0
	if cl + cr > 0.6 * length:
		# very short runs: squeeze both caps so a middle survives
		f = 0.6 * length / (cl + cr)
		cl *= f
		cr *= f
	var pk: float = pad * k * f
	if cl > 0.0:
		out.append({"dst": Rect2(-half_l - pk, y0, cl + pk, hh),
			"src": Rect2(0.0, 0.0, pad + cap, ah)})
	var x0: float = -half_l + cl
	var span: float = length - cl - cr
	var m0: Array = mids[0]
	if String(meta.get("mid_mode", "stretch")) == "tile":
		var mw: float = (float(m0[1]) - float(m0[0])) * k
		var n: int = maxi(1, roundi(span / maxf(mw, 0.001)))
		var tw: float = span / float(n)
		for i in n:
			var mv: Array = mids[hash_i(seed, i) % mids.size()]
			out.append({"dst": Rect2(x0 + tw * float(i), y0, tw, hh),
				"src": Rect2(float(mv[0]), 0.0, float(mv[1]) - float(mv[0]), ah)})
	else:
		out.append({"dst": Rect2(x0, y0, span, hh),
			"src": Rect2(float(m0[0]), 0.0, float(m0[1]) - float(m0[0]), ah)})
	if cr > 0.0:
		out.append({"dst": Rect2(half_l - cr, y0, cr + pk, hh),
			"src": Rect2(aw - pad - cap, 0.0, pad + cap, ah)})
	return out


# Opaque footprint half-extents (no pad): the strip's real size.
static func half_extents(length: float, width: float) -> Vector2:
	return Vector2(length * 0.5, width * 0.5)


# ---- built-in procedural decor -------------------------------------------
# One painter for both repos (TG RunArt.draw_builtin is a copy): pewter /
# trencher plates, ale cups, candles with a painted glow (no Light2D).
# world_rot = the run's on-screen rotation: the drop shadow and the glint stay
# world-fixed (light from the upper left, like the art) whatever the table's angle.
static func draw_builtin(ci: CanvasItem, id: String, at: Vector2, rot: float, scale: float, v: int, world_rot: float = 0.0) -> void:
	var d: float = float(BUILTIN_DECOR.get(id, 0.0)) * scale
	if d <= 0.0:
		return
	var r: float = d * 0.5
	var sh: Vector2 = Vector2(0.6, 0.8).rotated(-world_rot)     # shadow falls down-right
	var gl: Vector2 = Vector2(-0.68, -0.72).rotated(-world_rot) # glint up-left
	match id:
		"_plate":
			var base: Color = Color(0.60, 0.60, 0.57) if v % 3 != 1 else Color(0.55, 0.38, 0.22)
			if v % 3 == 2:
				base = Color(0.70, 0.52, 0.36)   # glazed earthenware
			_disc(ci, at + sh * r * 0.16, r, Color(0.0, 0.0, 0.0, 0.18))
			_disc(ci, at, r, base.darkened(0.28))
			_disc(ci, at, r * 0.86, base)
			_disc(ci, at, r * 0.58, base.lightened(0.07))
			ci.draw_arc(at, r * 0.58, 0.0, TAU, 24, base.darkened(0.12), maxf(0.35, r * 0.06), true)
			_disc(ci, at + gl * r * 0.48, r * 0.16, Color(1.0, 1.0, 0.95, 0.35))
		"_cup":
			var rim: Color = Color(0.47, 0.47, 0.44) if v % 2 == 0 else Color(0.42, 0.29, 0.17)
			var hdir := Vector2.from_angle(rot)
			ci.draw_line(at + hdir * r * 0.7, at + hdir * r * 1.45, rim.darkened(0.2), maxf(0.6, r * 0.42), true)
			_disc(ci, at + sh * r * 0.22, r, Color(0.0, 0.0, 0.0, 0.2))
			_disc(ci, at, r, rim)
			_disc(ci, at, r * 0.70, Color(0.30, 0.18, 0.07) if v % 2 == 0 else Color(0.36, 0.08, 0.10))
			_disc(ci, at + gl * r * 0.38, r * 0.22, Color(1.0, 0.95, 0.85, 0.30))
		"_candle":
			# painted glow first (soft warm pool on the board), then holder/wax/flame
			for gi in 6:
				var gr: float = r * (6.0 - float(gi) * 0.85)
				_disc(ci, at, gr, Color(1.0, 0.74, 0.38, 0.035 + 0.012 * float(gi)))
			_disc(ci, at, r * 1.25, Color(0.58, 0.43, 0.20))
			_disc(ci, at, r * 1.0, Color(0.42, 0.30, 0.13))
			_disc(ci, at, r * 0.72, Color(0.93, 0.89, 0.78))
			_disc(ci, at, r * 0.36, Color(1.0, 0.86, 0.45))
			_disc(ci, at, r * 0.16, Color(1.0, 0.98, 0.85))


static func _disc(ci: CanvasItem, p: Vector2, r: float, c: Color) -> void:
	ci.draw_circle(p, r, c, true, -1.0, true)
