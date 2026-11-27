extends Node2D
# Rig2 (anchor-based rig) gate, headless-safe (reads data and node state, not pixels).
#  1. PARITY  RigFit (GDScript) must place every mesh vertex where
#             tools/rigkit/core.py placed it (tests/fixtures/rig2_parity.json,
#             regenerate with `python -m tools.rigkit.export_parity`).
#  2. PACKS   every race pack has the skeleton's required frames and its art.
#  3. BUILD   RigCharacter assembles a dressed character for every race: one
#             node per item side, right z order, variant inheritance, grips.
#  4. HANDS   the hand rig (docs 3.6): body cut-outs, fist and glove-piece
#             vertices against core.py, and the pose rule on a built character
#             (holding closes the hand, the fist is above the weapon, the glove
#             above the fist, the weapon's tail under the body, removing reopens).
# Run:  godot --headless --path . res://tests/rig2_parity_test.tscn
const FIXTURE := "res://tests/fixtures/rig2_parity.json"
const TOLERANCE := 0.05
const OUTFIT: Array[String] = ["peasants_stained_shirt", "breastplate", "kettle_helm", "leather_boot",
	"leather_glove", "red_cape"]
const MIN_CHECKS := 400

var fails := 0
var checks := 0


func _check(what: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL %s %s" % [what, detail])


func _ready() -> void:
	_parity()
	_packs()
	_build()
	_hands()
	# a GDScript runtime error aborts only the function it happens in, so a
	# crashed section would otherwise pass silently: assert the check count
	_check("check count", checks >= MIN_CHECKS, "only %d checks ran" % checks)
	print("rig2_parity_test: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)


func _parity() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var root: Dictionary = parsed
	var cases: Array = root["cases"]
	var skel: Dictionary = RigLibrary.skeleton()
	var worst: float = 0.0
	for c: Dictionary in cases:
		var tag: String = "%s x %s%s" % [c["race"], c["item"], c["side"]]
		var race: Dictionary = RigLibrary.race(str(c["race"]))
		var item: Dictionary = RigLibrary.item(str(c["item"]))
		var mesh: Dictionary = RigFit.mesh_from_cells(item["mesh"])
		var verts: PackedVector2Array = mesh["verts"]
		var tris: PackedInt32Array = mesh["tris"]
		@warning_ignore("integer_division")
		var tri_count: int = tris.size() / 3
		_check("mesh size " + tag, verts.size() == int(c["n_verts"]) and tri_count == int(c["n_tris"]),
			"%d verts / %d tris" % [verts.size(), tri_count])
		var names: Array[String] = RigFit.weight_names(item, skel)
		var want_names: Array = c["frames"]
		_check("frames " + tag, str(names) == str(want_names), "%s vs %s" % [names, want_names])
		var fitted: PackedVector2Array = RigFit.fit_points(item, skel, race, verts, str(c["side"]))
		var sample: Array = c["sample"]
		var step: int = int(c["sample_step"])
		var err: float = 0.0
		for k: int in sample.size():
			var want: Array = sample[k]
			err = maxf(err, fitted[k * step].distance_to(Vector2(float(want[0]), float(want[1]))))
		worst = maxf(worst, err)
		_check("parity " + tag, err <= TOLERANCE, "off by %.3f px" % err)
	print("parity: %d cases, worst error %.4f px" % [cases.size(), worst])


func _race_ids() -> PackedStringArray:
	var d: DirAccess = DirAccess.open(RigLibrary.ROOT + "/races")
	if d == null:
		return PackedStringArray()
	return d.get_directories()


func _packs() -> void:
	var skel: Dictionary = RigLibrary.skeleton()
	var required: Array = skel["required_frames"]
	var ids: PackedStringArray = _race_ids()
	_check("race packs present", ids.size() >= 50, "%d found" % ids.size())
	for id: String in ids:
		for v: String in RigLibrary.variants(id):
			var race: Dictionary = RigLibrary.race(id, v)
			var frames: Dictionary = race.get("frames", {})
			var missing: Array[String] = []
			for f: Variant in required:
				if not frames.has(str(f)):
					missing.append(str(f))
			_check("frames %s/%s" % [id, v], missing.is_empty(), "missing %s" % [missing])
			_check("art %s/%s" % [id, v], RigLibrary.race_file(race, str(race.get("art", ""))) != "")


func _build() -> void:
	for id: String in _race_ids():
		for v: String in RigLibrary.variants(id):
			var rc: RigCharacter = RigCharacter.new()
			add_child(rc)
			var tag: String = "%s/%s" % [id, v]
			_check("setup " + tag, rc.setup(id, v))
			_check("body " + tag, rc.get_node_or_null("Body") != null and rc.get_node_or_null("Head") != null)
			var expect: int = 0
			for item_id: String in OUTFIT:
				if rc.cannot_wear(item_id) != "":
					continue
				_check("wear %s %s" % [tag, item_id], rc.wear(item_id))
				expect += rc.item_nodes(item_id).size()
			var polys: int = 0
			for child: Node in rc.get_children():
				if child is Polygon2D and child.has_meta("item"):
					polys += 1
			_check("item nodes " + tag, polys == expect and expect >= 5, "%d built, %d expected" % [polys, expect])
			var shirt: Array = rc.item_nodes("peasants_stained_shirt")
			var plate: Array = rc.item_nodes("breastplate")
			var cape: Array = rc.item_nodes("red_cape")
			var helm: Array = rc.item_nodes("kettle_helm")
			if shirt.size() == 1 and plate.size() == 1 and cape.size() == 1 and helm.size() == 1:
				var zs: int = (shirt[0] as Polygon2D).z_index
				var zp: int = (plate[0] as Polygon2D).z_index
				var zc: int = (cape[0] as Polygon2D).z_index
				var zh: int = (helm[0] as Polygon2D).z_index
				var head: Sprite2D = rc.get_node("Head")
				_check("z order " + tag, zc < 0 and zs < zp and zp < head.z_index and head.z_index < zh,
					"cape %d shirt %d plate %d head %d helm %d" % [zc, zs, zp, head.z_index, zh])
			else:
				_check("core outfit worn " + tag, false)
			var g: Dictionary = rc.grip("r")
			_check("grip " + tag, g.has("position") and float(g.get("px_per_world", 0.0)) > 1.0)
			rc.remove("breastplate")
			_check("remove " + tag, rc.item_nodes("breastplate").is_empty() and not ("breastplate" in rc.worn()))
			rc.queue_free()
	_check("game id alias", RigLibrary.item_for_game_id("peasant's_stained_shirt") == "peasants_stained_shirt")
	_check("unknown item", RigLibrary.item_for_game_id("no_such_item") == "")


func _sample_err(fitted: PackedVector2Array, sample: Array, step: int) -> float:
	var err: float = 0.0
	for k: int in sample.size():
		var want: Array = sample[k]
		err = maxf(err, fitted[k * step].distance_to(Vector2(float(want[0]), float(want[1]))))
	return err


func _quad_sum(quads: Array[Rect2]) -> float:
	var total: float = 0.0
	for q: Rect2 in quads:
		total += q.position.x + q.position.y + q.end.x + q.end.y
	return total


func _hands() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var root: Dictionary = parsed
	var hands: Dictionary = root["hands"]
	var skel: Dictionary = RigLibrary.skeleton()
	var races: Array = hands["races"]
	_check("hand fixture", races.size() >= 4, "%d races" % races.size())
	var worst: float = 0.0
	for row: Dictionary in races:
		var tag: String = "%s/%s" % [row["race"], row["variant"]]
		var race: Dictionary = RigLibrary.race(str(row["race"]), str(row["variant"]))
		var hs: Dictionary = RigLibrary.race_hand_set(race)
		_check("hand set " + tag, not hs.is_empty())
		_check("hand rig " + tag, RigFit.hand_rig_ok(race, "l") and RigFit.hand_rig_ok(race, "r"))
		var parts: Dictionary = race["parts"]
		var both: Array[Dictionary] = [parts["hand_l"], parts["hand_r"]]
		var size_arr: Array = race["size"]
		var rest: Array[Rect2] = RigFit.rest_quads(Vector2(float(size_arr[0]), float(size_arr[1])), both)
		var want_rest: Dictionary = row["rest"]
		_check("rest quads " + tag, rest.size() == int(want_rest["n"]) and absf(_quad_sum(rest) - float(want_rest["sum"])) < 0.5,
			"%d quads, sum %.2f vs %s" % [rest.size(), _quad_sum(rest), want_rest])
		var poses: Dictionary = hs["poses"]
		var g: Dictionary = poses["grip"]
		var fist_mesh: Dictionary = RigFit.mesh_from_cells(g["mesh"])
		var fist_verts: PackedVector2Array = fist_mesh["verts"]
		var sides: Dictionary = row["sides"]
		for side: String in ["l", "r"]:
			var s: Dictionary = sides[side]
			var pq: Array[Rect2] = RigFit.part_quads(parts["hand_" + side])
			var want_part: Dictionary = s["part"]
			_check("hand quads %s %s" % [tag, side], pq.size() == int(want_part["n"]) and absf(_quad_sum(pq) - float(want_part["sum"])) < 0.5)
			var err: float = _sample_err(RigFit.fist_points(race, hs, side, fist_verts), s["fist"], int(s["fist_step"]))
			worst = maxf(worst, err)
			_check("fist %s %s" % [tag, side], err <= TOLERANCE, "off by %.3f px" % err)
			var pieces: Array = s["pieces"]
			for pc: Dictionary in pieces:
				var item: Dictionary = RigLibrary.item(str(pc["item"]))
				var hand: Dictionary = item["hand"]
				var piece: Dictionary = {}
				var item_pieces: Array = hand["pieces"]
				for cand: Dictionary in item_pieces:
					if str(cand["name"]) == str(pc["piece"]):
						piece = cand
				var pm: Dictionary = RigFit.mesh_from_cells(piece["mesh"])
				var fitted: PackedVector2Array = RigFit.glove_piece_points(piece, skel, race, hs, side, str(pc["pose"]),
					pm["verts"], str(item.get("authored_side", "r")))
				var perr: float = _sample_err(fitted, pc["sample"], int(pc["step"]))
				worst = maxf(worst, perr)
				_check("glove %s %s %s %s %s" % [tag, side, pc["item"], pc["piece"], pc["pose"]], perr <= TOLERANCE, "off by %.3f px" % perr)
	var held: Array = hands["held"]
	for h: Dictionary in held:
		var item: Dictionary = RigLibrary.item(str(h["item"]))
		var tail: PackedByteArray = RigFit.held_tail(item, item["mesh"])
		_check("tail cells " + str(h["item"]), tail.size() == int(h["cells"]) and tail.count(1) == int(h["tail"]),
			"%d of %d" % [tail.count(1), tail.size()])
	print("hands: worst error %.4f px" % worst)
	_hand_poses()


func _z(nodes: Array, part: String) -> int:
	for n: Node in nodes:
		if str(n.get_meta("part", "")) == part:
			return (n as Node2D).z_index
	return -999


func _hand_poses() -> void:
	for pack: Array in [["orc", "tilt15_head"], ["human", "default"], ["goblin_male", "default"], ["orc", "ashen"]]:
		var tag: String = "%s/%s" % [pack[0], pack[1]]
		var rc: RigCharacter = RigCharacter.new()
		add_child(rc)
		_check("hands setup " + tag, rc.setup(str(pack[0]), str(pack[1])))
		var body: Node = rc.get_node_or_null("Body")
		var open_r: Polygon2D = rc.get_node_or_null("Hand_r")
		var open_l: Polygon2D = rc.get_node_or_null("Hand_l")
		_check("body split " + tag, body is Polygon2D and open_r != null and open_l != null)
		_check("can grip " + tag, rc.cannot_grip("r") == "" and rc.cannot_grip("l") == "")
		_check("starts open " + tag, rc.hand_pose("r") == "open" and open_r.visible and rc.get_node_or_null("Fist_r") == null)
		_check("glove open " + tag, rc.wear("plate_gauntlet"))
		var glove: Array = rc.item_nodes("plate_gauntlet")
		_check("glove parts open " + tag, glove.size() == 6 and _z(glove, "hand") < _z(glove, "back") and _z(glove, "back") < _z(glove, "cuff"),
			"%d nodes" % glove.size())
		_check("hold " + tag, rc.wear("longsword"))
		var fist: Polygon2D = rc.get_node_or_null("Fist_r")
		_check("holding closes the hand " + tag, rc.hand_pose("r") == "grip" and rc.hand_pose("l") == "open"
			and not open_r.visible and open_l.visible and fist != null and fist.visible)
		var sword: Array = rc.item_nodes("longsword")
		glove = rc.item_nodes("plate_gauntlet")
		_check("sword split " + tag, sword.size() == 2, "%d nodes" % sword.size())
		if fist != null and sword.size() == 2:
			var zb: int = (body as Node2D).z_index
			_check("layering " + tag, _z(sword, "tail") < zb and zb < _z(sword, "front") and _z(sword, "front") < fist.z_index
				and fist.z_index < _z(glove, "hand") and _z(glove, "hand") < _z(glove, "cuff")
				and _z(glove, "cuff") < (rc.get_node("Head") as Node2D).z_index,
				"tail %d body %d front %d fist %d glove %d cuff %d" % [_z(sword, "tail"), zb, _z(sword, "front"), fist.z_index,
				_z(glove, "hand"), _z(glove, "cuff")])
			var mat: ShaderMaterial = fist.material as ShaderMaterial
			_check("fist skin ramp " + tag, mat != null and mat.get_shader_parameter("ramp2") is Vector3)
		_check("glove rebuilt for the grip " + tag, glove.size() == 6 and (glove[0] as Node).is_inside_tree())
		var g: Dictionary = rc.grip("r")
		_check("grip pose " + tag, str(g.get("pose", "")) == "grip")
		rc.remove("longsword")
		_check("release reopens " + tag, rc.hand_pose("r") == "open" and open_r.visible and fist != null and not fist.visible)
		rc.set_hand_pose("l", "grip")
		_check("forced fist " + tag, rc.hand_pose("l") == "grip" and not open_l.visible)
		rc.set_hand_pose("l", "")
		_check("forced fist released " + tag, rc.hand_pose("l") == "open" and open_l.visible)
		rc.queue_free()
