extends Node2D
# Rig2 (anchor-based rig) gate, headless-safe (reads data and node state, not pixels).
#  1. PARITY  RigFit (GDScript) must place every mesh vertex where
#             tools/rigkit/core.py placed it (tests/fixtures/rig2_parity.json,
#             regenerate with `python -m tools.rigkit.export_parity`).
#  2. PACKS   every race pack has the skeleton's required frames and its art.
#  3. BUILD   RigCharacter assembles a dressed character for every race: one
#             node per item side, right z order, variant inheritance, grips.
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
				if child is Polygon2D:
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
