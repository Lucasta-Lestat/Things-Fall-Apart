extends Node2D
# P3-D, the roadmap's Phase 3 exit criterion (5): a test layout with an E-W
# deep river and deck bridges passes the walk, elevation and fluid tests. The
# map is TG's layouts/test_prim_river.json exported under contract 3 (TG
# p3-rivers): its Maps.json row and cells.json are TEXT fixtures in
# tests/fixtures/p3d_river/ (no art: the row's images point at the icon), loaded
# the way Game does (CellGraph, set_elevation_data, MapLoader). The river runs
# west -> east across the whole map, its surface 1.8 stories over ground 2.0
# with its bed at 0.8 -- above sea level, so only the relative deep-water rule
# (GridManager.is_deep_water against tile_water) calls it deep. Two bridges
# cross it: mill_bridge (wood, walk_elev 2.0 = the banks) and weir_bridge
# (stone, 2.3: a 0.3-story step at each end).
#   walk: every open-water tile off the decks is deep, every deck tile is not;
#     the default spawn (north bank) reaches the 'south' spawn and the guard
#     over the bridges, each bridge alone carries the walk, and with the decks
#     gone nothing crosses; the deck tiles walk on planks / stone, not wading;
#   elevation: can_step at both ends of each bridge, never deck -> water or
#     bank -> water; effective_elev on a deck is its walk_elev over the bed;
#     relief LOS on; without the water layer the absolute rule calls none of
#     the river deep (the L8 hole the layer closes); the jump planner never
#     lands in the river, can_jump_to refuses it, knockback stops at the bank
#     and at the deck's edge (the deep-water veto itself) and runs along the deck;
#   view layer: a walker on either bridge over the river is the ground layer
#     (height measured from the bridge's banks, GridManager.ground_ref, never
#     the bed), a deck 1.3 over plain water is the high layer; in a RAVINE (the
#     same map with the river's surface 0.9, a story under its banks, and its
#     bed 0.3: TG's export of the layout at surface 0.9, depth 0.6) both
#     bridges are still the ground layer and a deck 1.4 over its banks is high,
#     measured from the banks;
#   bridge art and damage: no loose item rows on the decks (the deck art is
#     baked into the structures overlay); every deck row is indestructible
#     and its Structure neither burns nor breaks (no walker stranded in deep
#     water before P4-B);
#   fluid (water_sim 'sink'): every river cell off the decks is a sink, no
#     deck cell is, each deck cell stands at its own walk_elev head; a deposit
#     anywhere on a deck lands on the deck (never drained on landing); one on
#     the river drains at once; no shore cell lying below a deck beside it sits
#     below the waterline (the clamp saw the deck as the water under it); a
#     0.6 spill on the bridge sheds down to its puddle floor, into the river,
#     and one on such a shore cell runs under the deck; no sink ever holds
#     fluid and the mass ledger closes; 'visual' builds no sinks;
#   flat LOS (the row's relief_los false): neither bank-level bridge's
#     occluder shadows the cone of a walker on it; a deck a story up keeps
#     its GROUND mask;
#   fire: oil on each bridge's span lights, burns the walker in it and burns
#     away, the decks stand; a grass fire at a bridge end never lights a dry
#     deck tile or crosses the river;
#   fluid art: each bridge deck's Art draws the fluid field (deck_fluid
#     .gdshader on CellFluidFX's fields) and a slick on it turns that on.
# Headless:  godot --headless --path . res://tests/river_bridge_check.tscn
# Exit 0 when every check passes.
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const FIX := "res://tests/fixtures/p3d_river/"
const ROW_PATH := FIX + "tg_test_prim_river_row.json"
const CELLS_PATH := FIX + "tg_test_prim_river_cells.json"
const NOLAYER_PATH := "user://river_bridge_check_nolayer_cells.json"
const RAVINE_PATH := "user://river_bridge_check_ravine_cells.json"

# MapLoader's game stub (it reads these off its parent) + FluidManager's, and
# SurfaceManager's for the fire checks (it finds its game by load_map)
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null
var characters_in_scene: Array = []
var items_in_scene: Array = []
var fluid_manager: FluidManager = null
var surface_manager: SurfaceManager = null
var fog_manager: FogManager = null

var fails := 0
var checks := 0
var row: Dictionary = {}
var cols := 0
var rows := 0
var decks: Array = []          # [{tiles: Array[Vector2i], elev, id, a, b}] from the row's walk_elev rows


func load_map(_a = null, _b = "", _c = "") -> void:
	pass


func _check(cname: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", cname, detail])


func _ready() -> void:
	await get_tree().process_frame
	var f := FileAccess.open(ROW_PATH, FileAccess.READ)
	if f == null:
		_check("fixture.row", false, ROW_PATH)
		_done()
		return
	row = JSON.parse_string(f.get_as_text())
	f.close()
	var ws: Array = row["world_size"]
	cols = int(ws[0]) / 64
	rows = int(ws[1]) / 64
	var g := await _load(CELLS_PATH)
	_check("fixture.loaded", g != null and GridManager.has_water_layer() and decks.size() == 2,
		"%dx%d tiles, layer %s, %d decks" % [cols, rows, str(GridManager.has_water_layer()), decks.size()])
	if g == null or decks.size() != 2:
		_done()
		return
	_walk_checks()
	_elevation_checks()
	_view_layer_checks()
	_bridge_art_and_damage_checks()
	await _fluid_checks(g)
	await _flat_occluder_checks()
	await _fire_checks()
	await _deck_fluid_art_checks()
	await _ravine_view_checks()
	# --- the fallback: the same map without the water layer (contract 2's reading).
	# The river's tiles are taken while the layer is loaded: without it,
	# water_body_at IS is_deep_water, so a list taken after the strip is empty
	var river := _river_tiles()
	_strip_layer()
	g = await _load(NOLAYER_PATH)
	var deep := 0
	for t in river:
		if GridManager.is_deep_water(t):
			deep += 1
	_check("fallback.absolute-rule-misses-the-river", not GridManager.has_water_layer() and GridManager.relief_los
		and river.size() > 0 and deep == 0,
		"%d of %d river tiles deep without the layer (bed 0.8 > -0.5)" % [deep, river.size()])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(NOLAYER_PATH))
	_done()


func _done() -> void:
	print("RIVER BRIDGE CHECK DONE: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 or checks == 0 else 0)


# Game.load_map's order: graph -> set_elevation_data -> MapLoader (floors, decks).
# `over`: row keys replaced for this load (the relief_los key, edited structures).
func _load(cells_path: String, over: Dictionary = {}) -> CellGraph:
	if map_loader != null and is_instance_valid(map_loader):
		map_loader.queue_free()
		map_loader = null
		await get_tree().process_frame
	GridManager.TILE_SIZE = 64
	GridManager.initialize(cols * 64, rows * 64)
	var g: CellGraph = CellGraph.from_structured(cells_path)
	if g == null:
		_check("fixture.cells", false, cells_path)
		return null
	GridManager.set_elevation_data(g)
	var m: Dictionary = row.duplicate(true)
	m["images"] = {"map": "res://icon.svg"}
	m["cell_graph"] = cells_path
	for k in over:
		m[k] = over[k]
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	map_loader = ml
	ml.generate_structured_map(m)
	ml.set("structured_ground", null)   # no water renderer in a headless check
	decks = []
	for s_v in row.get("structures", []):
		var s: Dictionary = s_v
		if s.get("walk_elev") == null:
			continue
		var a := Vector2(float(s["a"][0]), float(s["a"][1]))
		var b := Vector2(float(s["b"][0]), float(s["b"][1]))
		var tiles: Array[Vector2i] = ml._tiles_near_segment(a, b, float(s["half"]), 64)
		decks.append({"tiles": tiles, "elev": float(s["walk_elev"]), "id": String(s["id"]), "a": a, "b": b})
	return g


func _water(t: Vector2i) -> bool:
	return GridManager.water_body_at(t) > 0


func _on_deck(t: Vector2i) -> bool:
	return GridManager.deck_elevations.has(t)


func _river_tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in rows:
		for x in cols:
			var t := Vector2i(x, y)
			if _water(t) and not _on_deck(t):
				out.append(t)
	return out


func _spawn_tile(key: String) -> Vector2i:
	var p: Array = ((row["player_spawns"] as Dictionary)[key] as Dictionary)["position"]
	return GridManager.world_to_map(Vector2(float(p[0]), float(p[1])))


func _walk_checks() -> void:
	var river := _river_tiles()
	var deep := 0
	for t in river:
		if GridManager.is_deep_water(t):
			deep += 1
	var deck_deep := 0
	var land_deep := 0
	var deck_wading := 0
	for y in rows:
		for x in cols:
			var t := Vector2i(x, y)
			if _on_deck(t):
				if GridManager.is_deep_water(t):
					deck_deep += 1
				if _water(t) and String(GridManager.floors.get(t, "")) == "shallow_water":
					deck_wading += 1
			elif not _water(t) and GridManager.is_deep_water(t):
				land_deep += 1
	_check("walk.river-is-deep", river.size() > 0 and deep == river.size(), "%d of %d open-water tiles off the decks" % [deep, river.size()])
	_check("walk.decks-and-banks-not-deep", deck_deep == 0 and land_deep == 0, "deck %d, land %d" % [deck_deep, land_deep])
	_check("walk.deck-floors-not-wading", deck_wading == 0, "%d deck tiles over the water read shallow_water" % deck_wading)
	var t0 := _spawn_tile("default")
	var t1 := _spawn_tile("south")
	var p := GridManager.find_path(t0, t1)
	var dry := true
	for t in p:
		dry = dry and (_on_deck(t) or not _water(t))
	_check("walk.north-to-south-over-a-bridge", not p.is_empty() and dry, "path of %d tiles" % p.size())
	var guard_ok := true
	for n_v in row.get("npc_spawns", []):
		var np: Array = (n_v as Dictionary)["position"]
		guard_ok = guard_ok and not GridManager.find_path(t0, GridManager.world_to_map(Vector2(float(np[0]), float(np[1])))).is_empty()
	_check("walk.guard-reachable", guard_ok, "")
	# each bridge alone carries the walk; with no deck nothing crosses (removing
	# a deck drops its bank ground too: restored with the decks)
	var saved_ground: Dictionary = GridManager.deck_ground_refs.duplicate()
	for k in decks.size():
		var other: Dictionary = decks[1 - k]
		for t in other["tiles"]:
			GridManager.unregister_deck(t, float(other["elev"]))
		_check("walk.%s-alone-carries" % String((decks[k] as Dictionary)["id"]), not GridManager.find_path(t0, t1).is_empty(), "")
		for t in other["tiles"]:
			GridManager.register_deck(t, float(other["elev"]))
	for d in decks:
		for t in (d as Dictionary)["tiles"]:
			GridManager.unregister_deck(t, float((d as Dictionary)["elev"]))
	_check("walk.no-crossing-without-decks", GridManager.find_path(t0, t1).is_empty(), "")
	_check("walk.removed-decks-drop-their-bank-ground", not saved_ground.is_empty() and GridManager.deck_ground_refs.is_empty(),
		"%d bank-ground tiles registered, %d left with every deck removed" % [saved_ground.size(), GridManager.deck_ground_refs.size()])
	for d in decks:
		for t in (d as Dictionary)["tiles"]:
			GridManager.register_deck(t, float((d as Dictionary)["elev"]))
	GridManager.deck_ground_refs = saved_ground


func _elevation_checks() -> void:
	_check("elev.relief-los", GridManager.relief_los, "span %.2f" % (GridManager.terrain_max - GridManager.terrain_min))
	for d_v in decks:
		var d: Dictionary = d_v
		var tiles: Array = d["tiles"]
		var ends_ok := 0
		var ends_bad := 0
		var off_bad := 0
		var off_ok := 0
		var elev_ok := true
		for t_v in tiles:
			var t: Vector2i = t_v
			elev_ok = elev_ok and is_equal_approx(GridManager.effective_elev(t), float(d["elev"]))
			if _water(t):
				elev_ok = elev_ok and GridManager.terrain_elev(t) < 1.0
			for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = t + dd
				if not GridManager.map_rect.has_point(n) or _on_deck(n):
					continue
				if _water(n):
					if GridManager.can_step(t, n):
						off_bad += 1
					else:
						off_ok += 1
				elif GridManager.can_step(t, n) and GridManager.can_step(n, t):
					ends_ok += 1
				else:
					ends_bad += 1
		_check("elev.%s-deck-at-walk-elev" % String(d["id"]), elev_ok, "walk_elev %.2f over the bed" % float(d["elev"]))
		_check("elev.%s-can-step-at-ends" % String(d["id"]), ends_ok > 0 and ends_bad == 0, "%d bank steps pass, %d fail" % [ends_ok, ends_bad])
		_check("elev.%s-no-step-into-water" % String(d["id"]), off_ok > 0 and off_bad == 0, "%d deck -> water steps refused, %d allowed" % [off_ok, off_bad])
	var bank_river := 0
	for t in _river_tiles():
		for dd: Vector2i in [Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = t + dd
			if GridManager.map_rect.has_point(n) and not _water(n) and GridManager.can_step(n, t):
				bank_river += 1
	_check("elev.bank-never-steps-into-river", bank_river == 0, "%d" % bank_river)
	# jumps and knockback: never into the river
	var river := _river_tiles()
	var landings := 0
	for t in river:
		for dd: Vector2i in [Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = t + dd
			if not GridManager.map_rect.has_point(n) or _water(n):
				continue
			for e in GridManager._get_jump_neighbors(Vector3i(n.x, n.y, 0), 2.5, 2):
				var en := Vector2i((e["n"] as Vector3i).x, (e["n"] as Vector3i).y)
				if GridManager.is_deep_water(en):
					landings += 1
	_check("elev.planner-never-lands-in-river", landings == 0, "%d jump edges into deep water" % landings)
	var bank := Vector2i(-1, -1)
	var below := Vector2i(-1, -1)
	for t in river:
		var n := t + Vector2i(0, -1)
		if GridManager.map_rect.has_point(n) and not _water(n) and not _on_deck(n):
			bank = n
			below = t
			break
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	ch.jump_height = 2.5
	ch.jump_range = 2
	ch.global_position = GridManager.map_to_world(bank)
	ch._refresh_elevation()
	_check("elev.can-jump-to-refuses-river", bank.x >= 0 and not ch.can_jump_to(bank, below), "%s -> %s" % [str(bank), str(below)])
	# the forced-mover veto itself: on this fixture the bank and the deck stand
	# 1.2 over the bed, so can_traverse alone already refuses those steps
	_check("elev.knockback-veto-at-bank", GridManager.segment_enters_deep_water(
		GridManager.map_to_world(bank), GridManager.map_to_world(below)), "%s -> %s" % [str(bank), str(below)])
	_check("elev.knockback-stops-at-bank", not ch._forced_step_ok(GridManager.map_to_world(bank), GridManager.map_to_world(below))
		and not ch._forced_drop_check(Vector2(0.0, 64.0)) and not ch._fall_active)
	var mill: Dictionary = decks[0]
	var a: Vector2 = mill["a"]
	var b: Vector2 = mill["b"]
	var mid := (a + b) * 0.5
	var side := mid + (b - a).normalized().orthogonal() * 160.0
	_check("elev.knockback-runs-along-deck", ch._forced_step_ok(a.lerp(b, 0.15), a.lerp(b, 0.85)), "")
	_check("elev.knockback-veto-at-deck-edge", GridManager.segment_enters_deep_water(mid, side), "")
	_check("elev.knockback-stops-at-deck-edge", not ch._forced_step_ok(mid, side), "")
	_check("elev.knockback-along-deck-no-veto", not GridManager.segment_enters_deep_water(a.lerp(b, 0.15), a.lerp(b, 0.85)), "")
	ch.queue_free()


# The view layer / sight tier on a bridge (GridManager.ground_ref): a walker on
# a deck over the river is measured from the deck's own banks (2.0, above the
# surface at 1.8), not the bed a story further down, so neither bridge (0.0 /
# 0.3 over its banks) is the HIGH layer (was: 1.2 / 1.5 over the bed: hidden
# in ground view, the leader's view flipped to the roof slice, crowns always
# blocking them). A deck 1.3 over plain water (no banks: measured from the
# surface) still is.
func _view_layer_checks() -> void:
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	for d_v in decks:
		var d: Dictionary = d_v
		var n := 0
		var high := 0
		var hag_max := -INF
		for t_v in d["tiles"]:
			var t: Vector2i = t_v
			if not _water(t):
				continue
			n += 1
			ch.global_position = GridManager.map_to_world(t)
			ch._refresh_elevation()
			hag_max = maxf(hag_max, ch.height_above_ground())
			if GridManager.is_high_layer(ch) or ch.is_on_raised_surface() \
					or GridManager.height_above_ground(t, ch.get_elevation()) >= GridManager.HIGH_LAYER_STORIES:
				high += 1
		_check("view.%s-walker-is-ground-layer" % String(d["id"]), n > 0 and high == 0
			and absf(hag_max - (float(d["elev"]) - 2.0)) < 1e-4,
			"%d deck tiles over the water, %d on the high layer, height above ground up to %.2f (over its 2.0 banks)" % [n, high, hag_max])
	var bank := _spawn_tile("default")
	ch.global_position = GridManager.map_to_world(bank)
	ch._refresh_elevation()
	_check("view.bank-walker-is-ground-layer", not GridManager.is_high_layer(ch) and is_zero_approx(ch.height_above_ground()), "")
	var rt: Vector2i = _river_tiles()[0]
	var hi_e: float = GridManager.water_surface_at(rt) + 1.3
	GridManager.register_deck(rt, hi_e)
	ch.global_position = GridManager.map_to_world(rt)
	ch._refresh_elevation()
	_check("view.high-deck-over-water-is-high", GridManager.is_high_layer(ch) and absf(ch.height_above_ground() - 1.3) < 1e-4,
		"deck %.2f over the water at %.2f: hag %.2f" % [hi_e, GridManager.water_surface_at(rt), ch.height_above_ground()])
	GridManager.unregister_deck(rt, hi_e)
	ch.queue_free()


# The same view-layer contract in a RAVINE: the fixture with the river's surface
# lowered 0.9 (to 0.9, 1.1 stories under its 2.0 banks) and its bed 0.5 (to
# 0.3), which is TG's export of the same layout at water surface 0.9, depth
# 0.6 (no depth or low-bank warning). Measured from the water, the bank-level
# mill bridge stood 1.1 over it and the weir 1.4: both HIGH (hidden in ground
# view, the leader's view flipped to the roof slice). Measured from their banks
# they are the ground layer, and the weir raised to 3.4 (1.4 over its banks,
# 2.5 over the water) is high at 1.4. The river off the decks stays deep.
func _ravine_view_checks() -> void:
	var f := FileAccess.open(CELLS_PATH, FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var tw: Array = (d["tile_water"] as Dictionary)["data"]
	var te: Array = (d["tile_elev"] as Dictionary)["data"]
	var tb: Array = (d["tile_body"] as Dictionary)["data"]
	for i in tb.size():
		if int(tb[i]) > 0:
			tw[i] = float(tw[i]) - 0.9
			te[i] = float(te[i]) - 0.5
	var ce: Array = d["elev"]
	for i in ce.size():
		if absf(float(ce[i]) - 0.8) < 1e-4:
			ce[i] = 0.3
	var w := FileAccess.open(RAVINE_PATH, FileAccess.WRITE)
	w.store_string(JSON.stringify(d))
	w.close()
	var g := await _load(RAVINE_PATH)
	var river := _river_tiles()
	var surf: float = GridManager.water_surface_at(river[0]) if not river.is_empty() else NAN
	var bed: float = GridManager.terrain_elev(river[0]) if not river.is_empty() else NAN
	var deep := 0
	for t in river:
		if GridManager.is_deep_water(t):
			deep += 1
	_check("ravine.loaded", g != null and GridManager.has_water_layer() and absf(surf - 0.9) < 1e-4
		and absf(bed - 0.3) < 1e-4 and deep == river.size() and not river.is_empty(),
		"surface %.2f, bed %.2f, %d of %d river tiles deep" % [surf, bed, deep, river.size()])
	if g == null or river.is_empty():
		return
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	for d_v in decks:
		var dk: Dictionary = d_v
		var n := 0
		var high := 0
		var hag_max := -INF
		for t_v in dk["tiles"]:
			var t: Vector2i = t_v
			if not _water(t):
				continue
			n += 1
			ch.global_position = GridManager.map_to_world(t)
			ch._refresh_elevation()
			hag_max = maxf(hag_max, ch.height_above_ground())
			if GridManager.is_high_layer(ch) or ch.is_on_raised_surface() \
					or GridManager.height_above_ground(t, ch.get_elevation()) >= GridManager.HIGH_LAYER_STORIES:
				high += 1
		_check("ravine.%s-walker-is-ground-layer" % String(dk["id"]), n > 0 and high == 0,
			"walk_elev %.2f: %d deck tiles over the water, %d on the high layer, height above ground up to %.2f (%.2f over the water)"
			% [float(dk["elev"]), n, high, hag_max, float(dk["elev"]) - surf])
	var bank := _spawn_tile("default")
	ch.global_position = GridManager.map_to_world(bank)
	ch._refresh_elevation()
	_check("ravine.bank-walker-is-ground-layer", not GridManager.is_high_layer(ch) and is_zero_approx(ch.height_above_ground()), "")
	ch.queue_free()
	# the weir a story over its banks
	var structs: Array = (row["structures"] as Array).duplicate(true)
	for s_v in structs:
		if String((s_v as Dictionary).get("id", "")) == "stone_wall" and (s_v as Dictionary).get("walk_elev") != null:
			(s_v as Dictionary)["walk_elev"] = 3.4
	g = await _load(RAVINE_PATH, {"structures": structs})
	ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	var n_hi := 0
	var hi := 0
	var hag_lo := INF
	var hag_hi := -INF
	for st in structures_in_scene:
		if not (is_instance_valid(st) and (st as Structure).is_deck and is_equal_approx((st as Structure).deck_elevation, 3.4)):
			continue
		for t in (st as Structure).deck_tiles:
			if not _water(t):
				continue
			n_hi += 1
			ch.global_position = GridManager.map_to_world(t)
			ch._refresh_elevation()
			hag_lo = minf(hag_lo, ch.height_above_ground())
			hag_hi = maxf(hag_hi, ch.height_above_ground())
			if GridManager.is_high_layer(ch) and ch.is_on_raised_surface():
				hi += 1
	_check("ravine.deck-a-story-over-its-banks-is-high", g != null and n_hi > 0 and hi == n_hi
		and absf(hag_lo - 1.4) < 1e-4 and absf(hag_hi - 1.4) < 1e-4,
		"%d of %d deck tiles over the water high, height above ground %.2f..%.2f (1.4 over the banks)" % [hi, n_hi, hag_lo, hag_hi])
	ch.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RAVINE_PATH))


# Bridge art is baked (TG draws the deck into the structures overlay, which the
# deck's own Art slices): no loose plank items to loot or knock away. And a
# bridge deck is indestructible until P4-B: fire or a big hit never drops its
# walkers into deep water.
func _bridge_art_and_damage_checks() -> void:
	var loose := 0
	for it_v in row.get("item_spawns", []):
		var it: Dictionary = it_v
		var ip: Array = it.get("position", [0, 0])
		if _on_deck(GridManager.world_to_map(Vector2(float(ip[0]), float(ip[1])))) or String(it.get("id", "")) == "plank_bridge":
			loose += 1
	_check("art.no-loose-items-on-the-decks", loose == 0, "%d item rows on a deck or plank_bridge" % loose)
	var rows_ok := 0
	for s_v in row.get("structures", []):
		var s: Dictionary = s_v
		if s.get("walk_elev") != null and s.get("indestructible", false) == true:
			rows_ok += 1
	_check("damage.deck-rows-indestructible", rows_ok == decks.size(), "%d of %d deck rows" % [rows_ok, decks.size()])
	var insts: Array = []
	for st in structures_in_scene:
		if is_instance_valid(st) and (st as Structure).is_deck:
			insts.append(st)
	var flags_ok := insts.size() == decks.size()
	for st in insts:
		flags_ok = flags_ok and (st as Structure).indestructible and not (st as Structure).flammable
	_check("damage.decks-indestructible-not-flammable", flags_ok, "%d deck structures" % insts.size())
	var tiles_before := 0
	for d in decks:
		tiles_before += ((d as Dictionary)["tiles"] as Array).size()
	for st in insts:
		(st as Structure).take_damage({"fire": 100000, "bludgeoning": 100000})
	var alive := 0
	var hp_ok := true
	for st in insts:
		if is_instance_valid(st) and not (st as Structure).is_queued_for_deletion():
			alive += 1
			hp_ok = hp_ok and (st as Structure).current_health == (st as Structure).max_health
	var still := 0
	for d in decks:
		for t in (d as Dictionary)["tiles"]:
			if is_equal_approx(GridManager.effective_elev(t), float((d as Dictionary)["elev"])):
				still += 1
	_check("damage.decks-survive-fire-and-blows", alive == insts.size() and hp_ok and still == tiles_before,
		"%d of %d decks stand, %d of %d deck tiles registered" % [alive, insts.size(), still, tiles_before])


func _fluid_checks(g: CellGraph) -> void:
	var fm := FluidManager.new()
	fm.name = "FluidManager"
	add_child(fm)
	await get_tree().process_frame
	# 'visual': no sinks, as before P3-A
	map_loader.set("water_sim", "visual")
	fm.setup_cell_graph(g)
	_check("fluid.visual-no-sinks", fm.cell_fluid.sink_count == 0, "")
	map_loader.set("water_sim", "sink")
	fm.setup_cell_graph(g)
	var cf: CellFluid = fm.cell_fluid
	var river_cells := 0
	var river_sinks := 0
	var deck_cells: Array[int] = []
	var deck_sinks := 0
	var head_bad := 0
	for cid in g.cell_count:
		var t := GridManager.world_to_map(g.centroid(cid))
		if _on_deck(t):
			if _water(t):
				deck_cells.append(cid)
				if cf.is_sink(cid):
					deck_sinks += 1
				var want: float = maxf(float(GridManager.deck_elevations[t]), GridManager.water_surface_at(t)) * CellFluid.HEAD_PER_STORY
				if absf(cf._ground_head(cid) - want) > 1e-4:
					head_bad += 1
		elif _water(t):
			river_cells += 1
			if cf.is_sink(cid):
				river_sinks += 1
	_check("fluid.river-cells-are-sinks", river_cells > 0 and river_sinks == river_cells, "%d of %d" % [river_sinks, river_cells])
	_check("fluid.no-deck-is-a-sink", deck_cells.size() > 0 and deck_sinks == 0, "%d deck cells over the water" % deck_cells.size())
	_check("fluid.decks-stand-at-their-own-head", head_bad == 0 and cf.deck_head_count == deck_cells.size(),
		"%d heads off, deck_head_count %d" % [head_bad, cf.deck_head_count])
	# a deposit on every deck tile, and at its edges, lands on the deck
	var landed_bad := 0
	var n_dep := 0
	for d_v in decks:
		var d: Dictionary = d_v
		for t_v in d["tiles"]:
			var t: Vector2i = t_v
			if not _water(t):
				continue
			for off in [Vector2(0, 0), Vector2(-28, 0), Vector2(28, 0), Vector2(0, -28), Vector2(0, 28)]:
				var wp: Vector2 = GridManager.map_to_world(t) + off
				var dr0: float = cf.drained_total()
				cf.deposit(wp, "water", 0.05)
				n_dep += 1
				if cf.drained_total() != dr0:
					landed_bad += 1
	_check("fluid.deposit-on-deck-lands-on-deck", n_dep > 0 and landed_bad == 0, "%d of %d deposits drained on landing" % [landed_bad, n_dep])
	var deck_mass0 := 0.0
	for cid in deck_cells:
		deck_mass0 += cf.amount_at(cid)
	var rt: Vector2i = _river_tiles()[0]
	var dr1: float = cf.drained_mass("water")
	cf.deposit(GridManager.map_to_world(rt), "water", 0.3)
	_check("fluid.river-deposit-drains", is_equal_approx(cf.drained_mass("water") - dr1, 0.3), "")
	# the shore beside a bridge: a non-deck cell lying below a deck over the
	# water drains UNDER it (the clamp saw the deck as the water): none sits
	# below the waterline
	var beside: Array[int] = []
	var low_beside := 0
	for cid in deck_cells:
		for nb in g.neighbors(cid):
			var nbi: int = nb
			if cf.is_sink(nbi) or deck_cells.has(nbi) or beside.has(nbi):
				continue
			if cf._ground_head(nbi) < cf._ground_head(cid) - CellFluid.HEAD_EPS:
				beside.append(nbi)
				if cf._ground_head(nbi) < 1.8 * CellFluid.HEAD_PER_STORY - CellFluid.HEAD_EPS:
					low_beside += 1
	_check("fluid.shore-beside-a-deck-at-the-waterline", low_beside == 0,
		"%d cells below a deck beside it, %d below the waterline" % [beside.size(), low_beside])
	# a spill on the bridge: the deck holds its puddle floor and sheds the
	# rest off its edges into the river; a spill on such a shore cell runs
	# under the deck into the river
	var mid_t: Vector2i = GridManager.world_to_map(((decks[0] as Dictionary)["a"] as Vector2).lerp((decks[0] as Dictionary)["b"], 0.5))
	var spill_cid: int = cf._deck_cell_at(GridManager.map_to_world(mid_t), g.cell_at(GridManager.map_to_world(mid_t)))
	var dr2: float = cf.drained_mass("water")
	cf.deposit(GridManager.map_to_world(mid_t), "water", 0.6)
	var shore_cid := -1
	if not beside.is_empty():
		shore_cid = beside[0]
		cf.deposit(g.centroid(shore_cid), "water", 0.6)
	var leaks := 0
	for i in 600:   # 10 s
		cf.tick(1.0 / 60.0)
		if i % 15 == 0:
			for cid in g.cell_count:
				if cf.is_sink(cid) and (cf.amount[cid] != 0.0 or cf.active.has(cid)):
					leaks += 1
	_check("fluid.no-sink-holds-fluid", leaks == 0, "%d" % leaks)
	var floor_w: float = cf._puddle_of(cf._ti_of("water")) + CellFluid.EPSILON + 0.01
	_check("fluid.bridge-spill-sheds-to-its-floor", deck_cells.has(spill_cid) and cf.amount_at(spill_cid) <= floor_w
		and cf.amount_at(spill_cid) > 0.0 and cf.drained_mass("water") > dr2 + 0.05,
		"deck cell %d: 0.6 -> %.3f (floor %.2f), drained +%.3f" % [spill_cid, cf.amount_at(spill_cid), floor_w, cf.drained_mass("water") - dr2])
	_check("fluid.shore-spill-runs-under-the-deck", shore_cid >= 0 and cf.amount_at(shore_cid) <= floor_w,
		"shore cell %d: 0.6 -> %.3f" % [shore_cid, cf.amount_at(shore_cid) if shore_cid >= 0 else -1.0])
	var deck_mass1 := 0.0
	for cid in deck_cells:
		deck_mass1 += cf.amount_at(cid)
	_check("fluid.decks-keep-what-landed", deck_mass1 > 0.0, "deck water %.3f -> %.3f (+0.6 spilled)" % [deck_mass0, deck_mass1])
	var led: Dictionary = cf.mass_ledger()
	var in_cells := 0.0
	for i in cf.amount.size():
		in_cells += cf.amount[i]
	var res: float = float(led["poured"]) - in_cells - float(led["drained"]) - float(led["evaporated"]) - float(led["lost"])
	_check("fluid.mass-closes", absf(res) < 1e-4, "residual %.6f" % res)
	fm.queue_free()
	await get_tree().process_frame


# A FLAT-LOS map (the row's relief_los key false, L17): there a deck's light
# occluder carries the GROUND sight mask, and a walker on a bank-level bridge
# is the GROUND tier (measured from the water, ground_ref), so the deck's own
# polygon -- the walker's light inside it -- would black out the walker's cone
# beyond the deck edges. A deck under one story over its ground on any tile
# casts no cone shadow; a deck a story or more over every tile keeps the
# GROUND mask (it still hides what is under it) and its walkers are HIGH.
func _flat_occluder_checks() -> void:
	var g := await _load(CELLS_PATH, {"relief_los": false})
	_check("flat.relief-off", g != null and not GridManager.relief_los, "")
	if g == null:
		return
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	for st in structures_in_scene:
		if not is_instance_valid(st) or not (st as Structure).is_deck:
			continue
		var s: Structure = st
		var occ: LightOccluder2D = s.get_node_or_null("Occluder")
		var om: int = occ.occluder_light_mask if occ != null else -1
		var overlap := 0
		var n := 0
		for t in s.deck_tiles:
			ch.global_position = GridManager.map_to_world(t)
			ch._refresh_elevation()
			n += 1
			if (int(ch.sight_cone_mask()) & om) != 0:
				overlap += 1
		_check("flat.%s-occluder-spares-its-walkers" % String(s.structure_id), occ != null and n > 0 and overlap == 0,
			"occluder mask %d, %d of %d deck tiles shadow the walker's own cone" % [om, overlap, n])
	# the control: the stone deck raised to 3.4 (1.4 over the banks, 1.6 over the water)
	var structs: Array = (row["structures"] as Array).duplicate(true)
	for s_v in structs:
		if String((s_v as Dictionary).get("id", "")) == "stone_wall" and (s_v as Dictionary).get("walk_elev") != null:
			(s_v as Dictionary)["walk_elev"] = 3.4
	ch.queue_free()
	g = await _load(CELLS_PATH, {"relief_los": false, "structures": structs})
	ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	var hi_ok := false
	var hi_detail := "no raised deck"
	for st in structures_in_scene:
		if is_instance_valid(st) and (st as Structure).is_deck and is_equal_approx((st as Structure).deck_elevation, 3.4):
			var s: Structure = st
			var occ: LightOccluder2D = s.get_node_or_null("Occluder")
			var om: int = occ.occluder_light_mask if occ != null else -1
			var overlap := 0
			for t in s.deck_tiles:
				ch.global_position = GridManager.map_to_world(t)
				ch._refresh_elevation()
				if (int(ch.sight_cone_mask()) & om) != 0:
					overlap += 1
			hi_ok = om == CollisionLayers.SIGHT_MASK_GROUND and overlap == 0
			hi_detail = "occluder mask %d, %d deck tiles shadow the walker's cone" % [om, overlap]
	_check("flat.high-deck-keeps-ground-mask", hi_ok, hi_detail)
	ch.queue_free()


# Fire on a bridge (CellFire.FUEL_DECK). An oil slick on each deck's span
# lights, burns whoever stands in it and burns away, and the deck neither
# burns nor breaks. With no oil, a grass fire on the north bank at a bridge's
# end never lights a deck tile and never crosses the river.
func _fire_checks() -> void:
	var g := await _fire_setup()
	if g == null:
		return
	var cf: CellFire = surface_manager.cell_fire
	var spans: Array = []   # per deck: the span tiles across its middle row
	for d_v in decks:
		var d: Dictionary = d_v
		var mid_y: int = GridManager.world_to_map(((d["a"] as Vector2) + (d["b"] as Vector2)) * 0.5).y
		var st: Array[Vector2i] = []
		for t_v in d["tiles"]:
			var t: Vector2i = t_v
			if t.y == mid_y and _water(t):
				st.append(t)
		spans.append(st)
		for t in st:
			fluid_manager.register_fluid(t, "oil", 1.0)
	for _i in 30:
		fluid_manager.update_fluid_tick(1.0 / 60.0)
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	ch.global_position = GridManager.map_to_world((spans[0] as Array)[0])
	ch._refresh_elevation()
	var oil0: Array = []
	var fuel_ok: Array = []
	var lit: Array = []
	for k in decks.size():
		var o := 0.0
		var fok := true
		for t in spans[k]:
			o += fluid_manager.get_fluid_amount(t, "oil")
			fok = fok and cf._fuel(g.cell_at(GridManager.map_to_world(t))) > 0.0
		oil0.append(o)
		fuel_ok.append(fok)
		var n0 := cf.burning.size()
		surface_manager.try_ignite_area(GridManager.map_to_world((spans[k] as Array)[0]), 48.0)
		lit.append(cf.burning.size() - n0)
	var burned_walker := false
	for _i in 600:   # 10 s
		surface_manager.update_surfaces(1.0 / 60.0, [ch], self)
		fluid_manager.update_fluid_tick(1.0 / 60.0)
		burned_walker = burned_walker or (ch.get_node("ConditionManager") as ConditionManager).has_condition("burning")
	for k in decks.size():
		var d: Dictionary = decks[k]
		var o1 := 0.0
		for t in spans[k]:
			o1 += fluid_manager.get_fluid_amount(t, "oil")
		_check("fire.oil-on-%s-burns" % String(d["id"]), (spans[k] as Array).size() > 0 and fuel_ok[k] and lit[k] > 0
			and o1 < 0.2,   # burned away: unlit, the slick sheds only to its ~0.5 floor
			"%d span tiles, lit %d at ignition, oil %.2f -> %.2f" % [(spans[k] as Array).size(), lit[k], oil0[k], o1])
	_check("fire.burns-the-walker-on-the-deck", burned_walker, "")
	_check("fire.decks-stand-after-burning-oil", _decks_whole(), "")
	ch.queue_free()
	# a grass fire beside the mill bridge's north end, no oil anywhere
	g = await _fire_setup()
	cf = surface_manager.cell_fire
	var mill: Dictionary = decks[0]
	var river_south := 0
	for t in _river_tiles():
		river_south = maxi(river_south, t.y)
	var a_t: Vector2i = GridManager.world_to_map(mill["a"])
	surface_manager.try_ignite_area(GridManager.map_to_world(a_t + Vector2i(0, -2)), 64.0)
	var lit0 := cf.burning.size()
	var on_deck := 0
	var south := 0
	var near_deck := 0
	for i in 1200:   # 20 s
		surface_manager.update_surfaces(1.0 / 60.0, [], self)
		if i % 30 == 0:
			for cid in cf.burning:
				var t := GridManager.world_to_map(g.centroid(cid))
				if _on_deck(t):
					on_deck += 1
				elif t.y > river_south:
					south += 1
				elif _on_deck(t + Vector2i(0, 1)) or _on_deck(t + Vector2i(1, 0)) or _on_deck(t + Vector2i(-1, 0)):
					near_deck += 1
	_check("fire.grass-fire-reaches-the-bridge-end", lit0 > 0 and near_deck > 0, "lit %d, %d samples beside the deck" % [lit0, near_deck])
	_check("fire.dry-deck-and-river-are-a-firebreak", on_deck == 0 and south == 0,
		"%d samples on a deck tile, %d south of the river" % [on_deck, south])
	_check("fire.decks-stand-after-grass-fire", _decks_whole(), "")
	surface_manager.queue_free()
	fluid_manager.queue_free()
	fog_manager.queue_free()
	surface_manager = null
	fluid_manager = null
	fog_manager = null
	await get_tree().process_frame


# A fluid on a bridge deck is drawn OVER the deck's art (z -3, opaque), not
# by the ground's water pass under it (z -6): each bridge deck's Art carries
# deck_fluid.gdshader on CellFluidFX's own blob and flow fields, mapped onto
# the ground texture's frame, and turns its fluid pass on with the ground's.
# Headless renders nothing: this checks the wiring; the look was checked in
# an off-screen capture.
func _deck_fluid_art_checks() -> void:
	var g := await _load(CELLS_PATH, {"images": {"map": "res://icon.svg", "structures": "res://icon.svg"}})
	if g == null:
		return
	map_loader.set("water_sim", "sink")
	# the ground at the map's own size, as an exported ground PNG is
	var img := Image.create(cols * 64, rows * 64, false, Image.FORMAT_RGBA8)
	var ground := Sprite2D.new()
	ground.texture = ImageTexture.create_from_image(img)
	ground.centered = false
	map_loader.add_child(ground)
	map_loader.set("structured_ground", ground)
	var fm := FluidManager.new()
	fm.name = "FluidManager"
	add_child(fm)
	await get_tree().process_frame
	fm.setup_cell_graph(g)
	var fx: CellFluidFX = fm.cell_fluid_fx
	var arts: Array = map_loader.get("bridge_deck_arts")
	var gm := ground.material as ShaderMaterial
	var wired := 0
	for art_v in arts:
		var dm := (art_v as Polygon2D).material as ShaderMaterial
		if dm != null and dm.shader == CellFluidFX.DECK_SHADER and gm != null \
				and dm.get_shader_parameter("fluid_mask") == gm.get_shader_parameter("fluid_mask") \
				and dm.get_shader_parameter("flow_mask") == gm.get_shader_parameter("flow_mask") \
				and dm.get_shader_parameter("field_size") == ground.texture.get_size() \
				and is_equal_approx(float(dm.get_shader_parameter("wave_scale")), float(gm.get_shader_parameter("wave_scale"))):
			wired += 1
	_check("fluid-art.bridge-decks-draw-the-fluid-field", fx != null and arts.size() == decks.size() and wired == arts.size(),
		"%d bridge deck arts, %d on the deck fluid pass" % [arts.size(), wired])
	# a slick on each deck turns the deck pass on and is drawn into the field
	var cf: CellFluid = fm.cell_fluid
	var dep_cells: Array[int] = []
	for d_v in decks:
		var d: Dictionary = d_v
		var wp: Vector2 = ((d["a"] as Vector2) + (d["b"] as Vector2)) * 0.5
		cf.deposit(wp, "oil", 0.5)
		dep_cells.append(cf._deck_cell_at(wp, g.cell_at(wp)))
	for _i in 4:
		await get_tree().process_frame
	var on := 0
	for art_v in arts:
		var dm := (art_v as Polygon2D).material as ShaderMaterial
		if dm != null and float(dm.get_shader_parameter("fluid_on")) > 0.5:
			on += 1
	var drawn := 0
	for cid in dep_cells:
		if fx != null and fx._disp.has(cid):
			drawn += 1
	_check("fluid-art.deck-slick-turns-the-deck-pass-on", on == arts.size() and arts.size() > 0 and drawn == dep_cells.size(),
		"%d of %d deck passes on, %d of %d deck slicks in the field" % [on, arts.size(), drawn, dep_cells.size()])
	fm.queue_free()
	await get_tree().process_frame


# A fresh load with FluidManager ('sink') and SurfaceManager (CellFire) on it.
func _fire_setup() -> CellGraph:
	if surface_manager != null and is_instance_valid(surface_manager):
		surface_manager.queue_free()
		fluid_manager.queue_free()
		fog_manager.queue_free()
	var g := await _load(CELLS_PATH)
	if g == null:
		return null
	map_loader.set("water_sim", "sink")
	fog_manager = FogManager.new()
	add_child(fog_manager)
	fluid_manager = FluidManager.new()
	fluid_manager.name = "FluidManager"
	add_child(fluid_manager)
	surface_manager = SurfaceManager.new()
	add_child(surface_manager)
	await get_tree().process_frame
	fluid_manager.setup_cell_graph(g)
	surface_manager.setup_cell_graph(g)
	surface_manager.cell_fire._rng.seed = 1
	return g


# Every deck stands at full health with every tile registered.
func _decks_whole() -> bool:
	var n := 0
	for st in structures_in_scene:
		if is_instance_valid(st) and (st as Structure).is_deck and not (st as Structure).is_queued_for_deletion():
			n += 1
			if (st as Structure).current_health != (st as Structure).max_health:
				return false
	if n != decks.size():
		return false
	for d in decks:
		for t in (d as Dictionary)["tiles"]:
			if not is_equal_approx(GridManager.effective_elev(t), float((d as Dictionary)["elev"])):
				return false
	return true


# The fixture's cells.json without tile_water / tile_body (the contract-2 reading).
func _strip_layer() -> void:
	var f := FileAccess.open(CELLS_PATH, FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	d.erase("tile_water")
	d.erase("tile_body")
	var w := FileAccess.open(NOLAYER_PATH, FileAccess.WRITE)
	w.store_string(JSON.stringify(d))
	w.close()
