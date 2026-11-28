class_name RigCharacter
extends Node2D
## A character assembled at runtime from a race pack plus whatever it wears.
##
## Nothing is baked per race: wear() builds the item's mesh on the spot by
## fitting the item's frames to this race's frames (RigFit). So any item pack
## fits any race pack, and a new item or a new race variant is only data.
##
## PHASE 1 (this file): bind pose. Body, overlays and worn items are built and
## layered correctly and the grip frames are exposed. Posing/animation lands in
## phase 2 (see docs/rigging_rewrite.md); until then the game keeps using
## RigCharacters/CharacterRig.gd.
##
## HANDS (docs/rigging_rewrite.md 3.6). Each hand has a pose: "open" is the hand
## in the race painting (a cut-out of the body), "grip" is the hand set's shared
## fist on the race's palm frame, coloured by the race's skin ramp. Wearing a held
## item closes its hand: the fist is drawn over the item and the part of the item
## behind the fist goes under the body. A glove is the showing hand drawn again
## through the glove's colour ramp, plus rigid cuff / back-of-hand pieces. A race
## pack built without the hand rig keeps the old behaviour.
##
## HEAD ENCLOSURE and TRUNK OVER FEET (tools/rigkit/core.py has the rules). An item
## pack with "encloses": true (great helm, deep hood) hides the whole head while it
## is worn: the "Head" overlay is hidden and the head's box of the body ("HeadBox")
## is swapped for "Bare", the same box with the head painted out. "TrunkOverFeet"
## is the trunk round the feet drawn again above feet items, so a boot never covers
## the belly.
##
## Node space is race-pack pixels with the torso origin at (0, 0); scale the
## node by `world_scale()` to get game units.

const RAMP_SHADER: Shader = preload("res://Characters/rig2/rig_ramp.gdshader")
const SIDES: Array[String] = ["l", "r"]

var race_id: String = ""
var variant: String = ""

var _race: Dictionary = {}
var _origin: Vector2 = Vector2.ZERO
var _worn: Dictionary = {}          # item id -> Array[Node]
var _body: Node2D = null
var _hand_set: Dictionary = {}
var _pose: Dictionary = {"l": "open", "r": "open"}      # what is shown
var _forced: Dictionary = {}                               # side -> pose set by set_hand_pose
var _open_hand: Dictionary = {}                            # side -> Polygon2D (cut-out of the body)
var _fist: Dictionary = {}                                 # side -> Polygon2D (built on first use)
var _head: Sprite2D = null                                 # the head overlay (above collars and capes)
var _head_box: Polygon2D = null                            # the head's box of the body painting
var _bare: Sprite2D = null                                 # the same box with the head painted out
var _enclosed: bool = false


## Build the bare body. Returns false (and builds nothing) if the pack is missing.
func setup(p_race: String, p_variant: String = "default") -> bool:
	clear()
	var data: Dictionary = RigLibrary.race(p_race, p_variant)
	if data.is_empty():
		push_warning("RigCharacter: no race pack %s/%s" % [p_race, p_variant])
		return false
	_race = data
	race_id = p_race
	variant = p_variant
	var frames: Dictionary = _race["frames"]
	var torso: Dictionary = frames["torso"]
	_origin = RigFit._v(torso["o"])
	_hand_set = RigLibrary.race_hand_set(_race)
	var layers: Dictionary = RigLibrary.skeleton()["body_layers"]
	_body = _build_body(int(layers["body"]))
	var overlays: Dictionary = _race.get("overlays", {})
	if overlays.has("head"):
		var head: Dictionary = overlays["head"]
		_head = _sprite("Head", str(head["file"]), RigFit._v(head["offset"]), int(layers["head"]))
	if overlays.has("trunk") and layers.has("trunk_over_feet"):
		var trunk: Dictionary = overlays["trunk"]
		_sprite("TrunkOverFeet", str(trunk["file"]), RigFit._v(trunk["offset"]), int(layers["trunk_over_feet"]))
	if overlays.has("over"):
		var over: Dictionary = overlays["over"]
		_sprite("OverGarment", str(over["file"]), RigFit._v(over["offset"]), int(layers["arms_over_garments"]))
	return _body != null


## The body. With the hand rig it is three polygons sharing body.png: "Body" (all
## but the hands) and "Hand_l" / "Hand_r" (the open hands, hidden while that hand
## grips). With a `bare` overlay the head's box is cut out of "Body" too and drawn
## as "HeadBox" (or "Bare" under enclosing headwear). With neither, one sprite.
func _build_body(z: int) -> Node2D:
	var path: String = RigLibrary.race_file(_race, str(_race["art"]))
	if path == "":
		push_warning("RigCharacter: %s/%s has no %s" % [race_id, variant, _race["art"]])
		return null
	var parts: Array[Dictionary] = []
	for side: String in SIDES:
		if RigFit.hand_rig_ok(_race, side) and not _hand_set.is_empty():
			var all_parts: Dictionary = _race["parts"]
			var p: Dictionary = all_parts["hand_" + side]
			parts.append(p)
	var hands_split: bool = parts.size() == 2 and not RigFit.rest_quads(_race_size(), parts).is_empty()
	if not hands_split:
		parts.clear()
	var rest: Array[Rect2] = RigFit.body_quads(_race, parts)
	if rest.is_empty():
		return _sprite("Body", str(_race["art"]), Vector2.ZERO, z)
	var tex: Texture2D = load(path)
	var body: Polygon2D = _quad_polygon("Body", tex, rest, z)
	var box: Rect2 = RigFit.head_box(_race)
	if box.has_area():
		var overlays: Dictionary = _race["overlays"]
		var bare: Dictionary = overlays["bare"]
		var box_quads: Array[Rect2] = [box.grow(RigFit.PART_OVERLAP)]
		_head_box = _quad_polygon("HeadBox", tex, box_quads, z)
		_bare = _sprite("Bare", str(bare["file"]), box.position, z)
		if _bare != null:
			_bare.visible = false
	if not hands_split:
		return body
	for side: String in SIDES:
		var all_parts2: Dictionary = _race["parts"]
		var part: Dictionary = all_parts2["hand_" + side]
		_open_hand[side] = _quad_polygon("Hand_" + side, tex, RigFit.part_quads(part), z)
	return body


## One Polygon2D drawing `quads` (pack px) of a texture laid 1:1 on the pack.
func _quad_polygon(node_name: String, tex: Texture2D, quads: Array[Rect2], z: int) -> Polygon2D:
	var pts: PackedVector2Array = PackedVector2Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var polys: Array = []
	for q: Rect2 in quads:
		var n: int = pts.size()
		for corner: Vector2 in [q.position, Vector2(q.end.x, q.position.y), q.end, Vector2(q.position.x, q.end.y)]:
			uvs.append(corner)
			pts.append(corner - _origin)
		polys.append(PackedInt32Array([n, n + 1, n + 2, n + 3]))
	var poly: Polygon2D = Polygon2D.new()
	poly.name = node_name
	poly.texture = tex
	poly.polygon = pts
	poly.uv = uvs
	poly.polygons = polys
	poly.z_index = z
	poly.z_as_relative = true
	add_child(poly)
	return poly


func _sprite(node_name: String, file_name: String, offset: Vector2, z: int) -> Sprite2D:
	var path: String = RigLibrary.race_file(_race, file_name)
	if path == "":
		push_warning("RigCharacter: %s/%s has no %s" % [race_id, variant, file_name])
		return null
	var s: Sprite2D = Sprite2D.new()
	s.name = node_name
	s.texture = load(path)
	s.centered = false
	s.position = offset - _origin
	s.z_index = z
	s.z_as_relative = true
	add_child(s)
	return s


func _race_size() -> Vector2:
	var size_arr: Array = _race["size"]
	return Vector2(float(size_arr[0]), float(size_arr[1]))


func clear() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_worn.clear()
	_race = {}
	_body = null
	_hand_set = {}
	_pose = {"l": "open", "r": "open"}
	_forced = {}
	_open_hand = {}
	_fist = {}
	_head = null
	_head_box = null
	_bare = null
	_enclosed = false


func world_scale() -> float:
	return float(_race.get("world_scale", 1.0))


## Why an item cannot be worn by this race ("" = it can).
func cannot_wear(item_id: String) -> String:
	var item: Dictionary = RigLibrary.item(item_id)
	if item.is_empty():
		return "no item pack '%s'" % item_id
	if _race.is_empty():
		return "no race set up"
	var missing: Array[String] = RigFit.missing_frames(item, RigLibrary.skeleton(), _race)
	if not missing.is_empty():
		return "race %s has no %s" % [race_id, ", ".join(missing)]
	return ""


## Put an item on. Items sharing a slot are NOT removed here: slot exclusivity
## belongs to the inventory, and torso layers legitimately stack.
func wear(item_id: String) -> bool:
	if _worn.has(item_id):
		return true
	var why: String = cannot_wear(item_id)
	if why != "":
		push_warning("RigCharacter: %s not shown: %s" % [item_id, why])
		return false
	var item: Dictionary = RigLibrary.item(item_id)
	var tex_path: String = "%s/%s" % [item["_dir"], item["art"]]
	if not ResourceLoader.exists(tex_path):
		push_warning("RigCharacter: %s has no imported art (%s)" % [item_id, tex_path])
		return false
	_worn[item_id] = [] as Array[Node]
	if _is_held(item):
		_refresh_hands()                # closes the hand; rebuilds gloves in the new pose
	_worn[item_id] = _build_item(item_id)
	_refresh_enclosed()
	return true


func remove(item_id: String) -> void:
	if not _worn.has(item_id):
		return
	var item: Dictionary = RigLibrary.item(item_id)
	_free_nodes(item_id)
	_worn.erase(item_id)
	if _is_held(item):
		_refresh_hands()
	_refresh_enclosed()


## True while something worn encloses the head (item.json "encloses"): the head is
## then not drawn, so nothing of it can stick out of a great helm or a deep hood.
func head_enclosed() -> bool:
	return _enclosed


func _refresh_enclosed() -> void:
	var enc: bool = false
	for item_id: String in _worn.keys():
		var item: Dictionary = RigLibrary.item(item_id)
		if bool(item.get("encloses", false)):
			enc = true
	_enclosed = enc
	if _head != null:
		_head.visible = not enc
	# without a `bare` overlay the body keeps its head pixels: the helm still covers the skull
	if _head_box != null and _bare != null:
		_head_box.visible = not enc
		_bare.visible = enc


func _free_nodes(item_id: String) -> void:
	var nodes: Array = _worn[item_id]
	for n: Node in nodes:
		remove_child(n)
		n.queue_free()


func worn() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for k: String in _worn.keys():
		out.append(k)
	return out


func item_nodes(item_id: String) -> Array:
	return _worn.get(item_id, [])


static func _is_held(item: Dictionary) -> bool:
	var slot: String = str(item.get("slot", ""))
	return slot == "main_hand" or slot == "off_hand"


# ---------------------------------------------------------------- hands

## The pose a hand is showing: "open" or "grip".
func hand_pose(side: String) -> String:
	return str(_pose.get(side, "open"))


## Force a hand's pose ("grip" = an empty fist), or pass "" to hand it back to the
## rule: a hand grips while a held item occupies it or needs it as a second hand.
func set_hand_pose(side: String, pose: String) -> void:
	if pose == "":
		_forced.erase(side)
	else:
		_forced[side] = pose
	_refresh_hands()


## Why this race cannot close its hand on a held item ("" = it can).
func cannot_grip(side: String) -> String:
	if _hand_set.is_empty():
		return "no hand set installed (Rigs/hands)"
	if not RigFit.hand_rig_ok(_race, side) or not _open_hand.has(side):
		return "race %s/%s was built without the hand rig (run tools.rigkit.build_race)" % [race_id, variant]
	return ""


func _wanted_poses() -> Dictionary:
	var want: Dictionary = {"l": "open", "r": "open"}
	var skel: Dictionary = RigLibrary.skeleton()
	for item_id: String in _worn.keys():
		var item: Dictionary = RigLibrary.item(item_id)
		if not _is_held(item):
			continue
		var side: String = str(RigFit.slot_def(item, skel)["side"])
		want[side] = RigFit.held_pose(item)
		if RigFit.held_two_handed(item):
			want["l" if side == "r" else "r"] = "grip"
	for side: String in _forced.keys():
		want[side] = _forced[side]
	for side: String in SIDES:
		if cannot_grip(side) != "":
			want[side] = "open"
	return want


func _refresh_hands() -> void:
	var want: Dictionary = _wanted_poses()
	var changed: bool = false
	for side: String in SIDES:
		if str(want[side]) == str(_pose[side]):
			continue
		changed = true
		_pose[side] = want[side]
		var grip: bool = str(want[side]) == "grip"
		if _open_hand.has(side):
			var open_hand: Polygon2D = _open_hand[side]
			open_hand.visible = not grip
		if grip and not _fist.has(side):
			var hands: Dictionary = RigLibrary.skeleton()["hands"]
			var skin: Dictionary = _race["skin"]
			_fist[side] = _fist_polygon("Fist_" + side, side, int(hands["z_fist"]), skin["ramp"], false)
		if _fist.has(side):
			var fist: Polygon2D = _fist[side]
			fist.visible = grip
	if not changed:
		return
	# gloves follow the hand: rebuild them in the new pose
	for item_id: String in _worn.keys():
		var item: Dictionary = RigLibrary.item(item_id)
		if str(item.get("slot", "")) == "hands":
			_free_nodes(item_id)
			_worn[item_id] = _build_item(item_id)


func _ramp_material(stops: Array, ramp: Array, cut: float) -> ShaderMaterial:
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = RAMP_SHADER
	m.set_shader_parameter("src_stops", Vector4(float(stops[0]), float(stops[1]), float(stops[2]), float(stops[3])))
	for i: int in 4:
		var c: Array = ramp[i]
		m.set_shader_parameter("ramp%d" % i, Vector3(float(c[0]), float(c[1]), float(c[2])))
	m.set_shader_parameter("cut", cut)
	return m


## The hand set's fist on one side, drawn through a colour ramp.
func _fist_polygon(node_name: String, side: String, z: int, ramp: Array, gloved: bool) -> Polygon2D:
	var poses: Dictionary = _hand_set["poses"]
	var g: Dictionary = poses["grip"]
	var tex: Texture2D = load("%s/%s" % [_hand_set["_dir"], g["art"]])
	var mesh: Dictionary = RigFit.mesh_from_cells(g["mesh"])
	var verts: PackedVector2Array = mesh["verts"]
	var fitted: PackedVector2Array = RigFit.fist_points(_race, _hand_set, side, verts)
	var size: Array = g["size"]
	var cut: float = RigFit.glove_cut(_hand_set) / float(size[0]) if gloved else -1.0
	var poly: Polygon2D = _mesh_polygon(node_name, tex, verts, fitted, mesh["tris"], z)
	poly.material = _ramp_material(g["stops"], ramp, cut)
	return poly


func _mesh_polygon(node_name: String, tex: Texture2D, verts: PackedVector2Array, fitted: PackedVector2Array,
		tris: PackedInt32Array, z: int, keep: PackedByteArray = PackedByteArray(), keep_value: int = 0) -> Polygon2D:
	var polys: Array = []
	for t: int in range(0, tris.size(), 3):
		@warning_ignore("integer_division")
		var cell: int = t / 6
		if not keep.is_empty() and int(keep[cell]) != keep_value:
			continue
		polys.append(PackedInt32Array([tris[t], tris[t + 1], tris[t + 2]]))
	var pts: PackedVector2Array = fitted.duplicate()
	for i: int in pts.size():
		pts[i] -= _origin
	var poly: Polygon2D = Polygon2D.new()
	poly.name = node_name
	poly.texture = tex
	poly.polygon = pts
	poly.uv = verts
	poly.polygons = polys
	poly.z_index = z
	poly.z_as_relative = true
	add_child(poly)
	return poly


func _tag(node: Node, item_id: String, slot: String, side: String, part: String) -> void:
	node.set_meta("item", item_id)
	node.set_meta("slot", slot)
	node.set_meta("side", side)
	node.set_meta("part", part)


func _build_item(item_id: String) -> Array[Node]:
	var skel: Dictionary = RigLibrary.skeleton()
	var item: Dictionary = RigLibrary.item(item_id)
	var tex: Texture2D = load("%s/%s" % [item["_dir"], item["art"]])
	var mesh: Dictionary = RigFit.mesh_from_cells(item["mesh"])
	var verts: PackedVector2Array = mesh["verts"]
	var tris: PackedInt32Array = mesh["tris"]
	var slot: Dictionary = RigFit.slot_def(item, skel)
	var slot_name: String = str(item["slot"])
	var z: int = int(slot["z"])
	if slot.has("layers"):
		z += int(item.get("layer", 1)) - 1
	var nodes: Array[Node] = []
	for side: String in RigFit.slot_sides(item, skel):
		var suffix: String = ("_" + side) if side != "" else ""
		if slot_name == "hands" and RigFit.glove_ok(item, _race, side) and cannot_grip(side) == "":
			nodes.append_array(_build_glove(item_id, item, tex, side))
			continue
		var fitted: PackedVector2Array = RigFit.fit_points(item, skel, _race, verts, side)
		if _is_held(item):
			var zz: Vector2i = RigFit.held_layers(item, skel, _race, side)
			if cannot_grip(side) != "":
				zz = Vector2i(z, z)
			if zz.x != zz.y:
				var tail: PackedByteArray = RigFit.held_tail(item, item["mesh"])
				var front: Polygon2D = _mesh_polygon("Item_%s%s" % [item_id, suffix], tex, verts, fitted, tris, zz.x, tail, 0)
				_tag(front, item_id, slot_name, side, "front")
				nodes.append(front)
				if tail.has(1):
					var back: Polygon2D = _mesh_polygon("Item_%s%s_tail" % [item_id, suffix], tex, verts, fitted, tris, zz.y, tail, 1)
					_tag(back, item_id, slot_name, side, "tail")
					nodes.append(back)
				continue
			z = zz.x
		var poly: Polygon2D = _mesh_polygon("Item_%s%s" % [item_id, suffix], tex, verts, fitted, tris, z)
		_tag(poly, item_id, slot_name, side, "")
		nodes.append(poly)
	return nodes


## A glove on one side: the showing hand in the glove's material, then its pieces.
func _build_glove(item_id: String, item: Dictionary, tex: Texture2D, side: String) -> Array[Node]:
	var skel: Dictionary = RigLibrary.skeleton()
	var hz: Dictionary = skel["hands"]
	var hand: Dictionary = item["hand"]
	var pose: String = hand_pose(side)
	var nodes: Array[Node] = []
	if str(hand.get("fingers", "tint")) != "none":
		var skin: Polygon2D = null
		if pose == "grip":
			skin = _fist_polygon("Item_%s_%s_hand" % [item_id, side], side, int(hz["z_glove"]), hand["ramp"], true)
		else:
			var src: Polygon2D = _open_hand[side]
			skin = src.duplicate() as Polygon2D
			skin.name = "Item_%s_%s_hand" % [item_id, side]
			skin.visible = true
			skin.z_index = int(hz["z_glove"])
			var race_skin: Dictionary = _race["skin"]
			skin.material = _ramp_material(race_skin["stops"], hand["ramp"], -1.0)
			add_child(skin)
		_tag(skin, item_id, "hands", side, "hand")
		nodes.append(skin)
	var pieces: Array = hand["pieces"]
	for piece: Dictionary in pieces:
		var mesh: Dictionary = RigFit.mesh_from_cells(piece["mesh"])
		var verts: PackedVector2Array = mesh["verts"]
		var fitted: PackedVector2Array = RigFit.glove_piece_points(piece, skel, _race, _hand_set, side, pose, verts,
			str(item.get("authored_side", "r")))
		var pz: int = int(hz["z_cuff"]) if str(piece["name"]) == "cuff" else int(hz["z_back"])
		var poly: Polygon2D = _mesh_polygon("Item_%s_%s_%s" % [item_id, side, piece["name"]], tex, verts, fitted, mesh["tris"], pz)
		_tag(poly, item_id, "hands", side, str(piece["name"]))
		nodes.append(poly)
	return nodes


## Where a held item goes, in this node's space: {position, rotation, px_per_world}.
## The weapon's own art points -Y at rotation 0 and the grip axis is the blade
## direction, matching what ProceduralCharacter does with the old rig's grip_r/l.
## With the hand rig the position is the FRONT of the closed fist, where the item's
## hold point goes (item.json "hold": `offset` world px behind its gameplay grip point).
func grip(side: String) -> Dictionary:
	var frames: Dictionary = _race.get("frames", {})
	var key: String = "grip_" + side
	if not frames.has(key):
		return {}
	var f: Dictionary = frames[key]
	var ax: Vector2 = RigFit._v(f["ax"])
	return {"position": RigFit._v(f["o"]) - _origin, "rotation": ax.angle(), "px_per_world": float(f["lx"]),
		"pose": hand_pose(side)}


## Where the SECOND hand closes on a two-handed item held in `side`'s hand, in this
## node's space ({} when the item has no grip2 frame). Phase 2's arm IK reaches the
## other hand's grip frame to it; nothing moves in bind pose.
func grip_target(item_id: String, side: String) -> Dictionary:
	var item: Dictionary = RigLibrary.item(item_id)
	var iframes: Dictionary = item.get("frames", {})
	if not iframes.has("grip2") or not _race.get("frames", {}).has("grip_" + side):
		return {}
	var pts: PackedVector2Array = PackedVector2Array([RigFit._v(iframes["grip2"]["o"])])
	var fitted: PackedVector2Array = RigFit.fit_points(item, RigLibrary.skeleton(), _race, pts, side)
	return {"position": fitted[0] - _origin}
