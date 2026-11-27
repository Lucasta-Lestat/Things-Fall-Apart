class_name RigFit
extends RefCounted
## The frame-to-frame fit: the engine-side mirror of tools/rigkit/core.py.
##
## A FRAME is {o, ax, lx, ly[, ly_neg]}: an origin, a unit axis, a scale along the
## axis and a scale across it. Races and items both describe themselves as named
## frames; fitting an item to a race maps each mesh vertex from the item's frame
## to the race's frame of the same name, blended across joints for skinned slots.
##
## Keep this file and core.py in step: tests/rig2_parity_test.tscn compares the
## vertices they produce.

const BLEND_FRAC: float = 0.22
const CHAINS: Dictionary = {
	"torso": [["upperarm_l", "forearm_l"], ["upperarm_r", "forearm_r"]],
	"legs": [["leg_l"], ["leg_r"]],
}


static func _v(a: Variant) -> Vector2:
	var arr: Array = a
	return Vector2(float(arr[0]), float(arr[1]))


static func _perp(f: Dictionary) -> Vector2:
	var ax: Vector2 = _v(f["ax"])
	return Vector2(-ax.y, ax.x)


static func _ly_neg(f: Dictionary) -> float:
	if f.has("ly_neg"):
		return float(f["ly_neg"])
	return float(f["ly"])


## Point -> normalised (U, V) in frame f.
static func frame_local(f: Dictionary, p: Vector2) -> Vector2:
	var d: Vector2 = p - _v(f["o"])
	var u: float = d.dot(_v(f["ax"]))
	var v: float = d.dot(_perp(f))
	var vn: float = v / float(f["ly"]) if v >= 0.0 else v / _ly_neg(f)
	return Vector2(u / float(f["lx"]), vn)


static func frame_world(f: Dictionary, uv: Vector2, ease_x: float, ease_y: float) -> Vector2:
	var u: float = uv.x * float(f["lx"]) * ease_x
	var v: float = (uv.y * float(f["ly"]) if uv.y >= 0.0 else uv.y * _ly_neg(f)) * ease_y
	return _v(f["o"]) + _v(f["ax"]) * u + _perp(f) * v


static func _smoothstep(e0: float, e1: float, x: float) -> float:
	var t: float = clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func slot_def(item: Dictionary, skel: Dictionary) -> Dictionary:
	var slots: Dictionary = skel["slots"]
	var slot: Dictionary = slots[item["slot"]]
	return slot


static func is_skinned(item: Dictionary, skel: Dictionary) -> bool:
	var fit: String = str(item.get("fit", slot_def(item, skel).get("fit", "rigid")))
	return fit == "skinned"


static func root_frame_name(item: Dictionary, skel: Dictionary) -> String:
	return str(item.get("root_frame", slot_def(item, skel)["frame"]))


static func ease_for(item: Dictionary, skel: Dictionary) -> float:
	return float(item.get("ease", slot_def(item, skel).get("ease", 1.0)))


static func scale_mode(item: Dictionary, skel: Dictionary) -> String:
	return str(item.get("scale", slot_def(item, skel).get("scale", "free")))


## The sides an item is drawn on: [""] for centre items, else ["l", "r"] or one side.
static func slot_sides(item: Dictionary, skel: Dictionary) -> Array[String]:
	var slot: Dictionary = slot_def(item, skel)
	var out: Array[String] = []
	if bool(slot.get("sided", false)):
		out.append("l")
		out.append("r")
	elif slot.has("side"):
		out.append(str(slot["side"]))
	else:
		out.append("")
	return out


static func is_mirrored(item: Dictionary, skel: Dictionary, side: String) -> bool:
	if not bool(slot_def(item, skel).get("sided", false)):
		return false
	return side != str(item.get("authored_side", "l"))


static func _target_name(item: Dictionary, skel: Dictionary, frame_name: String, side: String) -> String:
	if side != "" and frame_name == root_frame_name(item, skel):
		return frame_name + "_" + side
	return frame_name


## Race frames this item needs and the race does not have (empty = wearable).
static func missing_frames(item: Dictionary, skel: Dictionary, race: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var rframes: Dictionary = race["frames"]
	var iframes: Dictionary = item["frames"]
	for side: String in slot_sides(item, skel):
		for frame_name: String in iframes.keys():
			var t: String = _target_name(item, skel, frame_name, side)
			if not rframes.has(t):
				out.append(t)
	return out


## The names of the frames a skinned item blends between, root first, in the
## fixed order core.skin_weights uses.
static func weight_names(item: Dictionary, skel: Dictionary) -> Array[String]:
	var names: Array[String] = [root_frame_name(item, skel)]
	if is_skinned(item, skel):
		var iframes: Dictionary = item["frames"]
		var chains: Array = CHAINS.get(item["slot"], [])
		for chain: Array in chains:
			for link: String in chain:
				if not iframes.has(link):
					break
				names.append(link)
	return names


## Per-vertex weights over weight_names(). Returns one PackedFloat32Array per frame.
static func skin_weights(item: Dictionary, skel: Dictionary, pts: PackedVector2Array) -> Array[PackedFloat32Array]:
	var iframes: Dictionary = item["frames"]
	var n: int = pts.size()
	var root_w: PackedFloat32Array = PackedFloat32Array()
	root_w.resize(n)
	root_w.fill(1.0)
	var out: Array[PackedFloat32Array] = [root_w]
	if not is_skinned(item, skel):
		return out
	var fr: Dictionary = iframes[root_frame_name(item, skel)]
	var beta: float = BLEND_FRAC * float(fr["lx"])
	var chains: Array = CHAINS.get(item["slot"], [])
	for chain: Array in chains:
		var prev: int = 0
		for link: String in chain:
			if not iframes.has(link):
				break
			var f: Dictionary = iframes[link]
			var fo: Vector2 = _v(f["o"])
			var fax: Vector2 = _v(f["ax"])
			var side: float = (fo - _v(fr["o"])).dot(_v(fr["ax"]))
			var w: PackedFloat32Array = PackedFloat32Array()
			w.resize(n)
			for i: int in n:
				var take: float = _smoothstep(-beta, beta, (pts[i] - fo).dot(fax))
				if prev == 0 and frame_local(fr, pts[i]).x * side <= 0.0:
					take = 0.0
				var wi: float = out[prev][i] * take
				out[prev][i] -= wi
				w[i] = wi
			out.append(w)
			prev = out.size() - 1
	return out


## The race frame an item frame lands on, with the item's scale mode applied.
## Returns {frame, ease_x, ease_y}.
static func target_frame(item: Dictionary, skel: Dictionary, race: Dictionary, frame_name: String, side: String) -> Dictionary:
	var iframes: Dictionary = item["frames"]
	var rframes: Dictionary = race["frames"]
	var fi: Dictionary = iframes[frame_name]
	var src: Dictionary = rframes[_target_name(item, skel, frame_name, side)]
	var fr: Dictionary = src.duplicate()
	var ease: float = ease_for(item, skel)
	var mode: String = scale_mode(item, skel)
	if mode == "uniform" or mode == "world":
		var k: float = float(fr["lx"]) / float(fi["lx"])
		fr["ly"] = float(fi["ly"]) * k
		fr["ly_neg"] = _ly_neg(fi) * k
		if mode == "world":
			return {"frame": fr, "ease_x": 1.0, "ease_y": 1.0}
		return {"frame": fr, "ease_x": ease, "ease_y": ease}
	if is_skinned(item, skel):
		return {"frame": fr, "ease_x": 1.0, "ease_y": ease}
	return {"frame": fr, "ease_x": ease, "ease_y": ease}


## Map item-space points onto the race (race pack pixels).
static func fit_points(item: Dictionary, skel: Dictionary, race: Dictionary, pts: PackedVector2Array, side: String) -> PackedVector2Array:
	var names: Array[String] = weight_names(item, skel)
	var weights: Array[PackedFloat32Array] = skin_weights(item, skel, pts)
	var iframes: Dictionary = item["frames"]
	var flip: bool = is_mirrored(item, skel, side)
	var n: int = pts.size()
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(n)
	out.fill(Vector2.ZERO)
	for j: int in names.size():
		var t: Dictionary = target_frame(item, skel, race, names[j], side)
		var fr: Dictionary = t["frame"]
		var ex: float = t["ease_x"]
		var ey: float = t["ease_y"]
		var fi: Dictionary = iframes[names[j]]
		var w: PackedFloat32Array = weights[j]
		for i: int in n:
			if w[i] == 0.0:
				continue
			var uv: Vector2 = frame_local(fi, pts[i])
			if flip:
				uv.y = -uv.y
			out[i] += frame_world(fr, uv, ex, ey) * w[i]
	return out


## Vertices (item pixels) and triangle indices from an item's stored cell list.
## Same numbering as core.mesh_from_cells: first use, corners clockwise from
## top-left, two triangles per cell (a,b,c) and (a,c,d).
static func mesh_from_cells(mesh: Dictionary) -> Dictionary:
	var x0: float = float(mesh["x0"])
	var y0: float = float(mesh["y0"])
	var step: float = float(mesh["step"])
	var index: Dictionary = {}
	var verts: PackedVector2Array = PackedVector2Array()
	var tris: PackedInt32Array = PackedInt32Array()
	var cells: Array = mesh["cells"]
	for cell: Array in cells:
		var ci: int = int(cell[0])
		var cj: int = int(cell[1])
		var ids: Array[int] = []
		for corner: Vector2i in [Vector2i(ci, cj), Vector2i(ci + 1, cj), Vector2i(ci + 1, cj + 1), Vector2i(ci, cj + 1)]:
			if not index.has(corner):
				index[corner] = verts.size()
				verts.append(Vector2(x0 + corner.x * step, y0 + corner.y * step))
			var id: int = index[corner]
			ids.append(id)
		tris.append_array(PackedInt32Array([ids[0], ids[1], ids[2], ids[0], ids[2], ids[3]]))
	return {"verts": verts, "tris": tris}
