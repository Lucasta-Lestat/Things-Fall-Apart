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


# ---------------------------------------------------------------- hands (docs 3.6)
#
# A hand has a POSE. "open" is the hand in the race painting; "grip" is the shared
# fist of the race's hand set, fitted to the race's palm frame and coloured through
# the race's skin ramp. Mirrors the "hands" block at the end of core.py.

const TAIL_BACK: float = 2.0
const PART_OVERLAP: float = 0.5


## True when this race side can show hand poses (built with the hand rig).
static func hand_rig_ok(race: Dictionary, side: String) -> bool:
	var frames: Dictionary = race.get("frames", {})
	var parts: Dictionary = race.get("parts", {})
	return frames.has("palm_" + side) and frames.has("wrist_" + side) and parts.has("hand_" + side) and race.has("skin")


## Map points from frame fi onto frame fr. `uniform` = "lx" or "ly" uses ONE scale,
## read off that axis; "" scales the two axes independently.
static func fit_frame(fi: Dictionary, fr: Dictionary, pts: PackedVector2Array, ease: float, flip: bool, uniform: String) -> PackedVector2Array:
	var g: Dictionary = fr.duplicate()
	if uniform == "lx":
		var k: float = float(fr["lx"]) / float(fi["lx"])
		g["ly"] = float(fi["ly"]) * k
		g["ly_neg"] = _ly_neg(fi) * k
	elif uniform == "ly":
		var k2: float = float(fr["ly"]) / float(fi["ly"])
		g["lx"] = float(fi["lx"]) * k2
		g["ly_neg"] = _ly_neg(fi) * k2
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(pts.size())
	for i: int in pts.size():
		var uv: Vector2 = frame_local(fi, pts[i])
		if flip:
			uv.y = -uv.y
		out[i] = frame_world(g, uv, ease, ease)
	return out


## The palm frame a pose shows on this race side. Open: the race's own. Grip: the
## same origin, axis and half-width, with the knuckle line where the fist's is.
static func pose_palm(race: Dictionary, hs: Dictionary, side: String, pose: String) -> Dictionary:
	var frames: Dictionary = race["frames"]
	var src: Dictionary = frames["palm_" + side]
	var f: Dictionary = src.duplicate()
	if pose == "grip" and not hs.is_empty():
		var fp: Dictionary = _grip_pose(hs)["frames"]["palm"]
		f["lx"] = float(fp["lx"]) * float(f["ly"]) / float(fp["ly"])
	return f


static func _grip_pose(hs: Dictionary) -> Dictionary:
	var poses: Dictionary = hs["poses"]
	var g: Dictionary = poses["grip"]
	return g


## The hand set's fist vertices on this race side (uniform, by the half-width).
static func fist_points(race: Dictionary, hs: Dictionary, side: String, pts: PackedVector2Array) -> PackedVector2Array:
	var fp: Dictionary = _grip_pose(hs)["frames"]["palm"]
	var frames: Dictionary = race["frames"]
	var fr: Dictionary = frames["palm_" + side]
	return fit_frame(fp, fr, pts, 1.0, side != str(hs.get("authored_side", "r")), "ly")


## A glove piece's vertices on this race side in this pose: the cuff rides the wrist
## frame at one scale; the back of the hand maps wrist to wrist, knuckles to
## knuckles and edge to edge on the pose's palm frame.
static func glove_piece_points(piece: Dictionary, skel: Dictionary, race: Dictionary, hs: Dictionary, side: String,
		pose: String, pts: PackedVector2Array, authored_side: String) -> PackedVector2Array:
	var spec: Dictionary = skel["slots"]["hands"]["pieces"][piece["name"]]
	var pframes: Dictionary = piece["frames"]
	var fi: Dictionary = pframes[piece["frame"]]
	var flip: bool = side != authored_side
	var ease: float = float(spec.get("ease", 1.0))
	if str(piece["frame"]) == "wrist":
		var frames: Dictionary = race["frames"]
		var fw: Dictionary = frames["wrist_" + side]
		return fit_frame(fi, fw, pts, ease, flip, "lx")
	return fit_frame(fi, pose_palm(race, hs, side, pose), pts, ease, flip, "")


## Art x (px) left of which a GLOVED fist is not drawn: just behind the wrist line.
static func glove_cut(hs: Dictionary) -> float:
	var fp: Dictionary = _grip_pose(hs)["frames"]["palm"]
	var o: Array = fp["o"]
	return float(o[0]) - 0.12 * float(fp["ly"])


## True when a hands item can use the hand rig on this side (else the legacy
## one-image fit to the hand frame is used).
static func glove_ok(item: Dictionary, race: Dictionary, side: String) -> bool:
	return item.has("hand") and hand_rig_ok(race, side)


## A stored cut-out (race.json "parts") as quads: Rect2 per run, in pack px.
static func part_quads(part: Dictionary, overlap: float = PART_OVERLAP) -> Array[Rect2]:
	var s: float = float(part["step"])
	var out: Array[Rect2] = []
	var runs: Array = part["runs"]
	for run: Array in runs:
		var j: float = float(run[0])
		var i0: float = float(run[1])
		var i1: float = float(run[2])
		out.append(_quad(i0 * s, j * s, i1 * s, (j + 1.0) * s, overlap))
	return out


static func _quad(x0: float, y0: float, x1: float, y1: float, overlap: float) -> Rect2:
	return Rect2(x0 - overlap, y0 - overlap, x1 - x0 + 2.0 * overlap, y1 - y0 + 2.0 * overlap)


static func _part_bbox(part: Dictionary) -> Rect2:
	var s: float = float(part["step"])
	var runs: Array = part["runs"]
	var x0: float = INF
	var y0: float = INF
	var x1: float = -INF
	var y1: float = -INF
	for run: Array in runs:
		x0 = minf(x0, float(run[1]) * s)
		x1 = maxf(x1, float(run[2]) * s)
		y0 = minf(y0, float(run[0]) * s)
		y1 = maxf(y1, (float(run[0]) + 1.0) * s)
	return Rect2(x0, y0, x1 - x0, y1 - y0)


## The body with the given cut-outs removed, as quads (same construction and order
## as core.rest_quads). Empty when two cut-outs share columns: the body is then
## drawn whole and no hand can be hidden.
static func rest_quads(size: Vector2, parts: Array[Dictionary], overlap: float = PART_OVERLAP) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var order: Array[Dictionary] = parts.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _part_bbox(a).position.x < _part_bbox(b).position.x)
	var x: float = 0.0
	for p: Dictionary in order:
		var box: Rect2 = _part_bbox(p)
		var bx0: float = box.position.x
		var by0: float = box.position.y
		var bx1: float = minf(box.end.x, size.x)
		var by1: float = box.end.y
		if bx0 < x:
			return []
		if bx0 > x:
			out.append(_quad(x, 0.0, bx0, size.y, overlap))
		if by0 > 0.0:
			out.append(_quad(bx0, 0.0, bx1, by0, overlap))
		if by1 < size.y:
			out.append(_quad(bx0, by1, bx1, size.y, overlap))
		var s: float = float(p["step"])
		var rows: Dictionary = {}
		var runs: Array = p["runs"]
		for run: Array in runs:
			var key: int = int(run[0])
			if not rows.has(key):
				rows[key] = []
			var row: Array = rows[key]
			row.append(Vector2(float(run[1]), float(run[2])))
		var j: int = roundi(by0 / s)
		while float(j) * s < by1:
			var cur: float = bx0
			var spans: Array = rows.get(j, [])
			spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
			for span: Vector2 in spans:
				if span.x * s > cur:
					out.append(_quad(cur, float(j) * s, span.x * s, (float(j) + 1.0) * s, overlap))
				cur = span.y * s
			if cur < bx1:
				out.append(_quad(cur, float(j) * s, bx1, (float(j) + 1.0) * s, overlap))
			j += 1
		x = bx1
	if x < size.x:
		out.append(_quad(x, 0.0, size.x, size.y, overlap))
	return out


## (x0, y0, x1, y1) of the race's `bare` overlay as a Rect2 in pack px; no area when
## the pack has none. See core.py, "head enclosure".
static func head_box(race: Dictionary) -> Rect2:
	var overlays: Dictionary = race.get("overlays", {})
	if not overlays.has("bare"):
		return Rect2()
	var b: Dictionary = overlays["bare"]
	return Rect2(_v(b["offset"]), _v(b["size"]))


## Quads with the rectangle `box` removed (same construction and order as
## core.cut_rect): a quad that overlaps it is split into above, below, left, right.
static func cut_rect(quads: Array[Rect2], box: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for q: Rect2 in quads:
		if q.end.x <= box.position.x or q.position.x >= box.end.x or q.end.y <= box.position.y or q.position.y >= box.end.y:
			out.append(q)
			continue
		if q.position.y < box.position.y:
			out.append(Rect2(q.position.x, q.position.y, q.size.x, box.position.y - q.position.y))
		if q.end.y > box.end.y:
			out.append(Rect2(q.position.x, box.end.y, q.size.x, q.end.y - box.end.y))
		var ya: float = maxf(q.position.y, box.position.y)
		var yb: float = minf(q.end.y, box.end.y)
		if q.position.x < box.position.x:
			out.append(Rect2(q.position.x, ya, box.position.x - q.position.x, yb - ya))
		if q.end.x > box.end.x:
			out.append(Rect2(box.end.x, ya, q.end.x - box.end.x, yb - ya))
	return out


## The quads the body polygon is drawn with (core.body_quads): the painting minus the
## open hands (`hand_parts`: both hands, or empty when the hand rig is off) and minus
## the head box. Empty = nothing to cut, the body is one sprite.
static func body_quads(race: Dictionary, hand_parts: Array[Dictionary]) -> Array[Rect2]:
	var size_arr: Array = race["size"]
	var size: Vector2 = Vector2(float(size_arr[0]), float(size_arr[1]))
	var rest: Array[Rect2] = []
	if hand_parts.size() == 2:
		rest = rest_quads(size, hand_parts)
	var box: Rect2 = head_box(race)
	if rest.is_empty() and not box.has_area():
		return rest
	if rest.is_empty():
		rest.append(Rect2(Vector2.ZERO, size))
	if box.has_area():
		rest = cut_rect(rest, box)
	return rest


## Per mesh cell: 1 when the cell lies well behind the item's hold point (its grip
## frame origin, which sits at the front of the fist). Those cells are drawn under
## the body when the item's hold says tail "under".
static func held_tail(item: Dictionary, mesh: Dictionary) -> PackedByteArray:
	var iframes: Dictionary = item["frames"]
	var f: Dictionary = iframes["grip"]
	var o: Vector2 = _v(f["o"])
	var ax: Vector2 = _v(f["ax"])
	var x0: float = float(mesh["x0"])
	var y0: float = float(mesh["y0"])
	var step: float = float(mesh["step"])
	var cells: Array = mesh["cells"]
	var out: PackedByteArray = PackedByteArray()
	out.resize(cells.size())
	var limit: float = -TAIL_BACK * float(f["lx"])
	for k: int in cells.size():
		var cell: Array = cells[k]
		var c: Vector2 = Vector2(x0 + (float(cell[0]) + 0.5) * step, y0 + (float(cell[1]) + 0.5) * step)
		out[k] = 1 if (c - o).dot(ax) < limit else 0
	return out


## How a held item is layered on this race side: Vector2i(front z, tail z); tail z
## equal to front z means the item is drawn in one piece.
static func held_layers(item: Dictionary, skel: Dictionary, race: Dictionary, side: String) -> Vector2i:
	var slot: Dictionary = slot_def(item, skel)
	var z: int = int(slot["z"])
	if not hand_rig_ok(race, side):
		return Vector2i(z, z)
	var hold: Dictionary = item.get("hold", {})
	if str(hold.get("layer", "")) == "over":
		var oz: int = int(slot.get("over_z", z))
		return Vector2i(oz, oz)
	if item.has("hold") and str(hold.get("tail", "under")) == "under":
		return Vector2i(z, int(slot.get("tail_z", z)))
	return Vector2i(z, z)


## The pose a held item asks of the hand in its slot, and whether it needs both hands.
static func held_pose(item: Dictionary) -> String:
	var hold: Dictionary = item.get("hold", {})
	return str(hold.get("pose", "grip"))


static func held_two_handed(item: Dictionary) -> bool:
	var hold: Dictionary = item.get("hold", {})
	return int(hold.get("hands", 1)) == 2
