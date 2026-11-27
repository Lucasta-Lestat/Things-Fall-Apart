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
## Node space is race-pack pixels with the torso origin at (0, 0); scale the
## node by `world_scale()` to get game units.

var race_id: String = ""
var variant: String = ""

var _race: Dictionary = {}
var _origin: Vector2 = Vector2.ZERO
var _worn: Dictionary = {}          # item id -> Array[Node]
var _body: Sprite2D = null


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
	var layers: Dictionary = RigLibrary.skeleton()["body_layers"]
	_body = _sprite("Body", str(_race["art"]), Vector2.ZERO, int(layers["body"]))
	var overlays: Dictionary = _race.get("overlays", {})
	if overlays.has("head"):
		var head: Dictionary = overlays["head"]
		_sprite("Head", str(head["file"]), RigFit._v(head["offset"]), int(layers["head"]))
	if overlays.has("over"):
		var over: Dictionary = overlays["over"]
		_sprite("OverGarment", str(over["file"]), RigFit._v(over["offset"]), int(layers["arms_over_garments"]))
	return _body != null


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


func clear() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_worn.clear()
	_race = {}
	_body = null


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
	var skel: Dictionary = RigLibrary.skeleton()
	var item: Dictionary = RigLibrary.item(item_id)
	var tex_path: String = "%s/%s" % [item["_dir"], item["art"]]
	if not ResourceLoader.exists(tex_path):
		push_warning("RigCharacter: %s has no imported art (%s)" % [item_id, tex_path])
		return false
	var tex: Texture2D = load(tex_path)
	var mesh: Dictionary = RigFit.mesh_from_cells(item["mesh"])
	var verts: PackedVector2Array = mesh["verts"]
	var tris: PackedInt32Array = mesh["tris"]
	var polys: Array = []
	for t: int in range(0, tris.size(), 3):
		polys.append(PackedInt32Array([tris[t], tris[t + 1], tris[t + 2]]))
	var slot: Dictionary = RigFit.slot_def(item, skel)
	var z: int = int(slot["z"])
	if slot.has("layers"):
		z += int(item.get("layer", 1)) - 1
	var nodes: Array[Node] = []
	for side: String in RigFit.slot_sides(item, skel):
		var fitted: PackedVector2Array = RigFit.fit_points(item, skel, _race, verts, side)
		for i: int in fitted.size():
			fitted[i] -= _origin
		var poly: Polygon2D = Polygon2D.new()
		poly.name = "Item_%s%s" % [item_id, ("_" + side) if side != "" else ""]
		poly.texture = tex
		poly.polygon = fitted
		poly.uv = verts
		poly.polygons = polys
		poly.z_index = z
		poly.z_as_relative = true
		poly.set_meta("item", item_id)
		poly.set_meta("slot", str(item["slot"]))
		poly.set_meta("side", side)
		add_child(poly)
		nodes.append(poly)
	_worn[item_id] = nodes
	return true


func remove(item_id: String) -> void:
	if not _worn.has(item_id):
		return
	var nodes: Array = _worn[item_id]
	for n: Node in nodes:
		remove_child(n)
		n.queue_free()
	_worn.erase(item_id)


func worn() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for k: String in _worn.keys():
		out.append(k)
	return out


func item_nodes(item_id: String) -> Array:
	return _worn.get(item_id, [])


## Where a held item goes, in this node's space: {position, rotation, px_per_world}.
## The weapon's own art points -Y at rotation 0 and the grip axis is the blade
## direction, matching what ProceduralCharacter does with the old rig's grip_r/l.
func grip(side: String) -> Dictionary:
	var frames: Dictionary = _race.get("frames", {})
	var key: String = "grip_" + side
	if not frames.has(key):
		return {}
	var f: Dictionary = frames[key]
	var ax: Vector2 = RigFit._v(f["ax"])
	return {"position": RigFit._v(f["o"]) - _origin, "rotation": ax.angle(), "px_per_world": float(f["lx"])}
