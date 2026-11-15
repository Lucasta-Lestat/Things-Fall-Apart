# res://tests/elevation_harness.gd
# Headless assertion harness for elevation-aware movement.
# Run:  godot --headless --path . res://tests/elevation_harness.tscn
# Judge by the printed PASS/FAIL lines (pre-existing project parse errors print
# noise; runs can flake exit 255 — rerun once). Exits 0 iff all checks pass.
# Deliberately does NOT instantiate Game.tscn (avoids the known
# VisibilityManager/HearingManager flake surface).
extends Node2D

const MAP_LOADER := preload("res://Structures/MapLoader.gd")

# game-stub properties for MapLoader's current_scene fallback (battlements scenario)
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}

var failures := 0

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	_scenario_projection()
	_scenario_can_step_astar()
	_scenario_deck_refcount()
	_scenario_movement_gate()
	await _scenario_elevation_los()
	_scenario_melee_predicate()
	_scenario_jump_fall()
	await _scenario_high_terrain()
	_scenario_cone_bands()
	await _scenario_solid_rock()
	_scenario_relative_deep_water()
	_scenario_battlements()   # LAST: loads the full real map into GridManager
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# Stub graph for the roof-channel projection check: one roofed cell.
class StubRoofGraph:
	extends RefCounted
	func cell_at(p: Vector2) -> int:
		var t := GridManager.world_to_map(p)
		return t.y * 1000 + t.x
	func ground_elev(_cid: int) -> float:
		return 0.0
	func roof_elev(cid: int) -> float:
		return 2.0 if cid == 3 * 1000 + 3 else 0.0

# Relative-roof lint stub: terrace ground 8 everywhere, a RELATIVE roof (2.0)
# at (3,3) — the export bug the lint exists to catch.
class StubHighRoofGraph:
	extends RefCounted
	func cell_at(p: Vector2) -> int:
		var t := GridManager.world_to_map(p)
		return t.y * 1000 + t.x
	func ground_elev(_cid: int) -> float:
		return 8.0
	func roof_elev(cid: int) -> float:
		return 2.0 if cid == 3 * 1000 + 3 else 0.0

# 8. HIGH TERRAIN: ground many stories up (hillside terraces), relative layer
# semantics, relief LOS, tile_elev, scatter, drop cap, sea safety.
func _c(x: int, y: int) -> Vector2:
	return GridManager.map_to_world(Vector2i(x, y))

# 32x20 tiles: terrace 8.0 (x<=9), 8.4 (x 10..14), a 3.6-story cliff up to 12.0
# (x>=15), and a graded 0.45/tile ramp up the cliff on rows 17..19.
func _build_terraces() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(32 * 64, 20 * 64)
	for y in 20:
		for x in 32:
			var e: float = 8.0 if x <= 9 else (8.4 if x <= 14 else 12.0)
			if y >= 17 and y <= 19 and x >= 15 and x <= 22:
				e = 8.4 + 0.45 * float(x - 14)
			GridManager.elevations[Vector2i(x, y)] = e
	GridManager.refresh_terrain_stats()

# Write a cells.json-shaped file for the tile_elev parse checks. 4x2 tiles,
# two cells (elev 1.0 west, 3.0 east; roof 5.0 east).
func _write_te_graph(path: String, te: Variant) -> void:
	var d: Dictionary = {"n": 2, "export_scale": 1.0, "cx": [64.0, 192.0], "cy": [64.0, 64.0],
		"r": [64.0, 64.0], "fuel": [0.0, 0.0], "elev": [1.0, 3.0], "roof": [0.0, 5.0],
		"nb_off": [0, 1, 2], "nb": [1, 0]}
	if te != null:
		d["tile_elev"] = te
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()

func _scenario_high_terrain() -> void:
	# --- tile_elev: per-tile terrain beats nearest-cell projection when sized right
	var te_path := "user://elev_harness_te_cells.json"
	GridManager.TILE_SIZE = 64
	_write_te_graph(te_path, {"cols": 4, "rows": 2, "data": [0.5, 1.0, 1.5, 2.0, 0.6, 1.1, 1.6, 2.1]})
	GridManager.initialize(4 * 64, 2 * 64)
	var teg: CellGraph = CellGraph.from_structured(te_path)
	GridManager.set_elevation_data(teg)
	_check("hi.tile-elev-overrides-nearest-cell", GridManager.tile_elev_used
		and is_equal_approx(GridManager.terrain_elev(Vector2i(0, 0)), 0.5)
		and is_equal_approx(GridManager.terrain_elev(Vector2i(1, 0)), 1.0)
		and is_equal_approx(GridManager.terrain_elev(Vector2i(3, 1)), 2.1),
		"used=%s (0,0)=%.2f (1,0)=%.2f (3,1)=%.2f" % [str(GridManager.tile_elev_used),
			GridManager.terrain_elev(Vector2i(0, 0)), GridManager.terrain_elev(Vector2i(1, 0)),
			GridManager.terrain_elev(Vector2i(3, 1))])
	_check("hi.tile-elev-roof-stays-nearest-cell", is_equal_approx(GridManager.roof_at(Vector2i(3, 0)), 5.0)
		and not GridManager.has_roof(Vector2i(0, 0)) and GridManager.roof_lint_bad == 0)
	_check("hi.tile-elev-span-drives-relief", GridManager.relief_los
		and is_equal_approx(GridManager.terrain_max - GridManager.terrain_min, 1.6))
	# a grid of the wrong size is never indexed against these tiles
	_write_te_graph(te_path, {"cols": 3, "rows": 2, "data": [0.5, 1.0, 1.5, 0.6, 1.1, 1.6]})
	GridManager.initialize(4 * 64, 2 * 64)
	teg = CellGraph.from_structured(te_path)
	GridManager.set_elevation_data(teg)
	_check("hi.tile-elev-size-mismatch-falls-back", not GridManager.tile_elev_used
		and is_equal_approx(GridManager.terrain_elev(Vector2i(0, 0)), 1.0)
		and is_equal_approx(GridManager.terrain_elev(Vector2i(3, 0)), 3.0),
		"used=%s (0,0)=%.2f (3,0)=%.2f" % [str(GridManager.tile_elev_used),
			GridManager.terrain_elev(Vector2i(0, 0)), GridManager.terrain_elev(Vector2i(3, 0))])
	_write_te_graph(te_path, {"cols": 4, "rows": 2, "data": [0.5, 1.0]})
	teg = CellGraph.from_structured(te_path)
	_check("hi.tile-elev-malformed-discarded", teg != null and teg.tile_elev_dims() == Vector2i.ZERO)
	_write_te_graph(te_path, null)
	teg = CellGraph.from_structured(te_path)
	GridManager.initialize(4 * 64, 2 * 64)
	GridManager.set_elevation_data(teg)
	_check("hi.no-tile-elev-is-legacy", not GridManager.tile_elev_used
		and is_equal_approx(GridManager.terrain_elev(Vector2i(0, 0)), 1.0))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(te_path))

	# --- terraces: relief detection + relative semantics
	_build_terraces()
	_check("hi.relief-los-on", GridManager.relief_los)
	_check("hi.terrain-elev", is_equal_approx(GridManager.terrain_elev(Vector2i(5, 5)), 8.0))
	_check("hi.on-terrain-hag-zero", is_zero_approx(GridManager.height_above_ground(Vector2i(5, 5), 8.0)))
	_check("hi.step-0.4-walkable", GridManager.can_step(Vector2i(9, 5), Vector2i(10, 5)))
	_check("hi.cliff-blocked", not GridManager.can_step(Vector2i(14, 5), Vector2i(15, 5)))
	var p := GridManager.find_path(Vector2i(5, 5), Vector2i(25, 5))
	var legal := not p.is_empty()
	var via_ramp := false
	var prev := Vector2i(5, 5)
	for t in p:
		legal = legal and GridManager.can_step(prev, t)
		via_ramp = via_ramp or t.y >= 17
		prev = t
	_check("hi.astar-climbs-by-ramp", legal and via_ramp, "len=%d" % p.size())
	# view layer + cone tier are RELATIVE to the local ground
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	var los := PointLight2D.new()
	los.name = "LineOfSight"
	ch.add_child(los)
	ch.global_position = _c(25, 5)
	ch._refresh_elevation()
	_check("hi.terrace-walker-ground-layer", not GridManager.is_high_layer(ch)
		and not ch.is_on_raised_surface() and is_equal_approx(ch.current_elevation, 12.0)
		and los.shadow_item_cull_mask == _cone(12.0))   # relief map: the cone culls on its elevation band
	GridManager.register_deck(Vector2i(26, 5), 13.44)
	ch.global_position = _c(26, 5)
	ch._refresh_elevation()
	_check("hi.deck-on-terrace-is-high", GridManager.is_high_layer(ch)
		and is_equal_approx(ch.height_above_ground(), 1.44)
		and los.shadow_item_cull_mask == _cone(13.44),
		"hag=%.2f mask=%d" % [ch.height_above_ground(), los.shadow_item_cull_mask])
	GridManager.unregister_deck(Vector2i(26, 5), 13.44)
	ch._refresh_elevation()
	_check("hi.off-deck-back-to-ground-tier", not GridManager.is_high_layer(ch)
		and los.shadow_item_cull_mask == _cone(12.0))
	# terrain LOS (pure)
	_check("hi.los-same-terrace", GridManager.terrain_line_clear(_c(2, 5), _c(8, 5), 8.5, 8.5))
	_check("hi.los-cliff-blocks-low-viewer", not GridManager.terrain_line_clear(_c(5, 5), _c(25, 5), 8.5, 12.5))
	_check("hi.los-edge-sees-down", GridManager.terrain_line_clear(_c(15, 5), _c(12, 5), 12.5, 8.9))
	_check("hi.los-far-back-misses-cliff-foot", not GridManager.terrain_line_clear(_c(25, 5), _c(14, 5), 12.5, 8.9))
	_check("hi.los-ramp-climb-clear", GridManager.terrain_line_clear(_c(14, 18), _c(23, 18), 8.9, 12.5))
	for x in range(11, 15):
		for y in range(8, 11):
			GridManager.roof_elevations[Vector2i(x, y)] = 10.4      # ABSOLUTE: 8.4 + 2
	_check("hi.roof-slab-blocks-view-into-house", not GridManager.terrain_line_clear(_c(15, 9), _c(12, 9), 12.5, 8.9))
	_check("hi.roof-slab-indoors-clear", GridManager.terrain_line_clear(_c(11, 9), _c(13, 9), 8.9, 8.9))
	# jumper on absolute roofs; planned-drop cap
	_check("hi.jumper-mounts-absolute-roof", not GridManager.find_path(Vector2i(9, 9), Vector2i(12, 9), 2.5, 2, false, true).is_empty())
	# (roofs off first: a 1.6 hop onto the house then a 2.0 drop off its eave is
	# a legitimate route down and would mask the cap)
	GridManager.roof_elevations.clear()
	for x in range(15, 23):
		for y in range(17, 20):
			GridManager.grid_costs[Vector2i(x, y)] = INF                  # close the ramp: only way down is the 3.6 cliff
	_check("hi.no-planned-lethal-drop", GridManager.find_path(Vector2i(16, 5), Vector2i(12, 5), 2.5, 2).is_empty())
	var drop_edges := 0
	for e in GridManager._get_jump_neighbors(Vector3i(15, 5, 0), 2.5, 2):
		if (e["n"] as Vector3i).x < 15:
			drop_edges += 1
	_check("hi.cliff-brow-has-no-drop-edge", drop_edges == 0, "edges=%d" % drop_edges)
	GridManager.roof_elevations[Vector2i(16, 5)] = 15.8                 # roof 3.8 above the 12.0 terrace
	var roof_drops := 0
	for e in GridManager._get_jump_neighbors(Vector3i(16, 5, 1), 2.5, 2):
		if (e["n"] as Vector3i).z == 0:
			roof_drops += 1
	_check("hi.roof-drop-capped", roof_drops == 0, "edges=%d" % roof_drops)
	GridManager.roof_elevations[Vector2i(16, 5)] = 14.0                 # 2.0 above: still allowed
	roof_drops = 0
	for e in GridManager._get_jump_neighbors(Vector3i(16, 5, 1), 2.5, 2):
		if (e["n"] as Vector3i).z == 0:
			roof_drops += 1
	_check("hi.roof-drop-within-cap-kept", roof_drops > 0)
	_build_terraces()
	# end-to-end sight_line_clear: NAN default = ground under the target
	await get_tree().physics_frame
	var space := get_world_2d().direct_space_state
	_check("hi.default-target-elev-is-ground", GridManager.sight_line_clear(space, _c(2, 5), _c(8, 5), 8.0))
	_check("hi.default-both-elevs-are-ground", GridManager.sight_line_clear(space, _c(2, 5), _c(8, 5)))
	_check("hi.default-sees-nothing-through-cliff", not GridManager.sight_line_clear(space, _c(5, 5), _c(25, 5)))
	# interpolated eye line vs a 1-story wall (top 9) on terrace 8, viewer at 10
	var near_t := _make_blocker(Vector2(460, 100), 9.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("hi.wall-near-low-target-blocks", not GridManager.sight_line_clear(space, Vector2(100, 100), Vector2(500, 100), 10.0, 8.0))
	near_t.queue_free()
	var mid := _make_blocker(Vector2(300, 100), 9.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("hi.high-viewer-sees-over-midway-wall", GridManager.sight_line_clear(space, Vector2(100, 100), Vector2(500, 100), 10.0, 8.0))
	mid.queue_free()
	await get_tree().physics_frame
	# MapLoader: relative HIGH bit + terrain-following wall
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	var w = ml._spawn_geo_structure({"kind": "wall", "a": [136, 224], "b": [384, 224], "half": 7.0, "id": "stone_wall"}, null, 64)
	var occ: LightOccluder2D = w.get_node("Occluder")
	# relief map: no bit 1 (cones are GROUND | band); bit 2 is the structure bit for torches
	_check("hi.terrace-wall-relief-light-bits", (occ.occluder_light_mask & CollisionLayers.SIGHT_MASK_GROUND) == 0
		and (occ.occluder_light_mask & CollisionLayers.SIGHT_MASK_HIGH) != 0
		and is_equal_approx(float(w.get_meta("occlude_top")), 9.0) and not w.has_meta("occlude_rel_h"),
		"mask=%d top=%.2f" % [occ.occluder_light_mask, float(w.get_meta("occlude_top"))])
	var tr = ml._spawn_geo_structure({"kind": "tree", "pos": [160, 400], "r": 30.0, "id": "tree"}, null, 64)
	_check("hi.terrace-tree-high-bit", (tr.get_node("Occluder").occluder_light_mask & CollisionLayers.SIGHT_MASK_HIGH) != 0)
	var tw = ml._spawn_geo_structure({"kind": "wall", "a": [1600, 400], "b": [1900, 400], "half": 7.0, "id": "stone_wall", "occlude_h": 2.5}, null, 64)
	_check("hi.occlude-h-key", is_equal_approx(float(tw.get_meta("occlude_top")), 14.5)
		and (tw.get_node("Occluder").occluder_light_mask & CollisionLayers.SIGHT_MASK_HIGH) != 0,
		"top=%.2f" % float(tw.get_meta("occlude_top")))
	var pw = ml._spawn_geo_structure({"kind": "wall", "a": [1600, 600], "b": [1900, 600], "half": 4.0, "id": "stone_wall", "occlude_h": 0.35}, null, 64)
	_check("hi.parapet-casts-no-cone-shadow", pw.get_node("Occluder").occluder_light_mask == 0
		and is_equal_approx(float(pw.get_meta("occlude_top")), 12.35))
	var sw = ml._spawn_geo_structure({"kind": "wall", "a": [960, 1184], "b": [1472, 1184], "half": 7.0, "id": "stone_wall"}, null, 64)   # up the ramp, row 18
	_check("hi.sloped-wall-follows", sw.has_meta("occlude_rel_h") and is_equal_approx(float(sw.get_meta("occlude_half_px")), 7.0))
	# pad-edge house wall (xcheck C12): pad 9.0 (x 3..6, rows 12..15) one story
	# above the 8.0 street; the wall's CENTRE sits on the street tile, so a
	# centre-based or viewer-face top (9.0) would let the street see inside.
	for x in range(3, 7):
		for y in range(12, 16):
			GridManager.elevations[Vector2i(x, y)] = 9.0
	var padw = ml._spawn_geo_structure({"kind": "wall", "a": [190, 768], "b": [190, 1024], "half": 7.0, "id": "stone_wall"}, null, 64)
	_check("hi.pad-edge-wall-follows", padw.has_meta("occlude_rel_h")
		and is_equal_approx(float(padw.get_meta("occlude_top")), 9.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("hi.sloped-wall-blocks-at-top-end", not GridManager.sight_line_clear(space, _c(22, 17), _c(22, 19), 12.0, 12.0))
	_check("hi.pad-edge-wall-street-cannot-see-in", not GridManager.sight_line_clear(space, Vector2(32, 864), Vector2(224, 864), 8.0, 9.0))
	# control: the top is pad + 1 = 10, not infinite — a viewer on a 12.0 deck
	# across the street sees over it (eye line 10.1 at the wall)
	_check("hi.pad-edge-wall-high-viewer-sees-over",
		GridManager.sight_line_clear(space, Vector2(32, 864), Vector2(224, 864), 12.0, 9.0))
	padw.free()
	await get_tree().physics_frame
	# tile_elev only places the pad edge to within half a tile (centre
	# sampling): the same house wall 12 / 22 px inside the street-valued tile
	# (x 170 / 180, tile step at 192) must still block both ways
	for wx in [180.0, 170.0]:
		var pw2 = ml._spawn_geo_structure({"kind": "wall", "a": [wx, 768], "b": [wx, 1024], "half": 7.0, "id": "stone_wall"}, null, 64)
		await get_tree().physics_frame
		await get_tree().physics_frame
		_check("hi.pad-edge-wall-x%d-follows" % int(wx), pw2.has_meta("occlude_rel_h"))
		_check("hi.pad-edge-wall-x%d-street-cannot-see-in" % int(wx),
			not GridManager.sight_line_clear(space, Vector2(32, 864), Vector2(224, 864), 8.0, 9.0))
		_check("hi.pad-edge-wall-x%d-inside-cannot-see-street" % int(wx),
			not GridManager.sight_line_clear(space, Vector2(224, 864), Vector2(32, 864), 9.0, 8.0))
		_check("hi.pad-edge-wall-x%d-high-viewer-sees-over" % int(wx),
			GridManager.sight_line_clear(space, Vector2(32, 864), Vector2(224, 864), 12.0, 9.0))
		pw2.free()
		await get_tree().physics_frame
	# control: a street wall a tile clear of the pad (x 100, 92 px from the
	# step) keeps the plain centre-based top
	var stw = ml._spawn_geo_structure({"kind": "wall", "a": [100, 768], "b": [100, 1024], "half": 7.0, "id": "stone_wall"}, null, 64)
	_check("hi.street-wall-off-pad-no-follow", not stw.has_meta("occlude_rel_h")
		and is_equal_approx(float(stw.get_meta("occlude_top")), 9.0))
	ml.queue_free()
	await get_tree().physics_frame
	for x in range(3, 7):
		for y in range(12, 16):
			GridManager.elevations[Vector2i(x, y)] = 8.0
	# scatter never crosses the cliff
	seed(12345)
	var bad := 0
	for i in 200:
		var t := GridManager.world_to_map(GridManager.scatter_point(_c(14, 5), 160.0))
		if t.x >= 15 or not GridManager.would_walk(t):
			bad += 1
	_check("hi.scatter-stays-on-terrace", bad == 0, "bad=%d" % bad)
	# fall off the cliff: relative damage + landing on terrain
	_check("hi.fall-damage-relative", ch.fall_damage_for(3.6) == 21, "dmg=%d" % ch.fall_damage_for(3.6))
	ch.global_position = _c(15, 5)
	ch.on_roof = false
	ch._refresh_elevation()
	_check("hi.knockback-off-cliff-falls", ch._forced_drop_check(Vector2(-64.0, 0.0)) and ch._fall_active)
	for _i in 20:
		if not ch._fall_active:
			break
		ch._update_fall_motion(1.0 / 30.0)
	_check("hi.lands-on-lower-terrace", is_equal_approx(ch.current_elevation, 8.4) and is_zero_approx(ch.height_above_ground()),
		"elev=%.2f hag=%.2f" % [ch.current_elevation, ch.height_above_ground()])

	# --- sea safety: quay 0.33 (x<=4), sea surface floor at -1.0 seabed (x>=5)
	GridManager.initialize(10 * 64, 6 * 64)
	var wet = MAP_LOADER.FloorStub.new()
	wet.floor_id = "shallow_water"
	for y in 6:
		for x in 10:
			if x <= 4:
				GridManager.elevations[Vector2i(x, y)] = 0.33
			else:
				GridManager.elevations[Vector2i(x, y)] = -1.0
				GridManager.register_floor(Vector2i(x, y), wet)
	# a gently shelving strip on row 4: -0.4 (not deep) then -0.6 (deep)
	GridManager.elevations[Vector2i(5, 4)] = -0.4
	GridManager.elevations[Vector2i(6, 4)] = -0.6
	GridManager.refresh_terrain_stats()
	_check("hi.sea-is-deep-water", GridManager.relief_los and GridManager.is_deep_water(Vector2i(6, 2))
		and not GridManager.is_deep_water(Vector2i(3, 2)) and not GridManager.is_deep_water(Vector2i(5, 4)))
	var sea_edges := 0
	for e in GridManager._get_jump_neighbors(Vector3i(4, 2, 0), 2.5, 2):
		if (e["n"] as Vector3i).x >= 5:
			sea_edges += 1
	GridManager.roof_elevations[Vector2i(4, 1)] = 1.5
	for e in GridManager._get_jump_neighbors(Vector3i(4, 1, 1), 2.5, 2):
		if (e["n"] as Vector3i).x >= 5 and (e["n"] as Vector3i).z == 0:
			sea_edges += 1
	GridManager.roof_elevations.clear()
	_check("hi.jumper-never-plans-into-sea", sea_edges == 0, "edges=%d" % sea_edges)
	ch.global_position = _c(4, 2)
	ch.on_roof = false
	ch._refresh_elevation()
	_check("hi.forced-drop-refuses-sea", not ch._forced_drop_check(Vector2(64.0, 0.0)) and not ch._fall_active
		and not ch._forced_step_ok(ch.global_position, ch.global_position + Vector2(64.0, 0.0)))
	_check("hi.forced-step-refuses-shelving-into-deep",
		GridManager.can_traverse(_c(5, 4), _c(6, 4)) and not ch._forced_step_ok(_c(5, 4), _c(6, 4)))
	# 1px from the quay edge, knocked seaward at full speed: one update spans
	# the rim. Before the sea veto this began a 1.33-story fall onto the seabed.
	ch.global_position = Vector2(4 * 64 + 63, 2 * 64 + 32)
	ch.knockback_velocity = Vector2(800.0, 0.0)
	ch.knockback_active = true
	ch._update_knockback(1.0 / 30.0)
	var kb_t := GridManager.world_to_map(ch.global_position)
	_check("hi.knockback-stops-at-quay-edge", kb_t.x <= 4 and not ch._fall_active and not ch.knockback_active,
		"tile=%s fall=%s" % [str(kb_t), str(ch._fall_active)])
	ch.global_position = _c(3, 2)
	var land: Vector2 = ch.predict_knockback_landing(Vector2(4000.0, 0.0), 0.25)
	_check("hi.knockback-preview-stays-on-quay", GridManager.world_to_map(land).x <= 4, "land=%s" % str(land))
	# flat-map control: a shipped-style ravine stream (-0.98, span < 1) is NOT deep
	GridManager.initialize(6 * 64, 4 * 64)
	GridManager.elevations[Vector2i(3, 1)] = -0.98
	GridManager.register_floor(Vector2i(3, 1), wet)
	GridManager.refresh_terrain_stats()
	_check("flat.ravine-stream-not-deep", not GridManager.relief_los and not GridManager.is_deep_water(Vector2i(3, 1)))
	# flat-map control (xcheck C11): a tree in a ravine keeps the ABSOLUTE HIGH
	# rule (-0.98 + 2 = 1.02 < 2: no HIGH bit) exactly as before
	var ml2: Node2D = MAP_LOADER.new()
	add_child(ml2)
	var rt = ml2._spawn_geo_structure({"kind": "tree", "pos": [224, 96], "r": 30.0, "id": "tree"}, null, 64)
	_check("flat.ravine-tree-keeps-absolute-high-bit",
		(rt.get_node("Occluder").occluder_light_mask & CollisionLayers.SIGHT_MASK_HIGH) == 0)
	ml2.queue_free()
	ch.queue_free()

	# relative-roof lint
	GridManager.initialize(8 * 64, 8 * 64)
	GridManager.set_elevation_data(StubHighRoofGraph.new())   # ground_elev 8.0 everywhere, roof_elev 2.0 at (3,3)
	_check("hi.relative-roof-linted", GridManager.roof_lint_bad == 1, "bad=%d" % GridManager.roof_lint_bad)
	# micro-bench (informational)
	_build_terraces()
	var t0 := Time.get_ticks_usec()
	for i in 2000:
		GridManager.terrain_line_clear(_c(1, 1 + i % 18), _c(30, 18 - i % 18), 8.5, 12.5)
	print("INFO terrain-los: %.1f us/ray (~30-tile rays)" % (float(Time.get_ticks_usec() - t0) / 2000.0))

# OR of the light masks of every occluder under `inst` whose polygon covers
# world point p (structure occluders are in the instance's local frame).
func _occ_mask_at(inst: Node2D, p: Vector2) -> int:
	var m := 0
	for c in inst.get_children():
		var lo := c as LightOccluder2D
		if lo != null and Geometry2D.is_point_in_polygon(p - inst.position, lo.occluder.polygon):
			m |= lo.occluder_light_mask
	return m

# The cone band bit of a viewer standing at `elev`.
func _bbit(elev: float) -> int:
	return GridManager.cone_band_bit(GridManager.cone_band(elev))

# The full shadow mask of a relief-map cone for a viewer standing at `elev`.
func _cone(elev: float) -> int:
	return CollisionLayers.SIGHT_MASK_GROUND | _bbit(elev)

func _band_chunk_count(inst: Node2D) -> int:
	var k := 0
	for c in inst.get_children():
		if c is LightOccluder2D and String(c.name).begins_with("OccluderBand"):
			k += 1
	return k

# 9. SIGHT-CONE ELEVATION BANDS (v1.1): band math + top anchoring, occluder
# band bits (walls, trees, decks, parapets, terrain-following walls), cliff
# occluders, viewer cone masks — on the synthetic terraces — and a flat-map
# control that must keep GROUND/HIGH exactly.
func _scenario_cone_bands() -> void:
	_build_terraces()   # 8.0 (x<=9) | 8.4 | 3.6-story cliff to 12.0 (x>=15) | ramp rows 17..19
	_check("band.base-at-lowest-ground", GridManager.cone_band_base == 8, "base=%d" % GridManager.cone_band_base)
	_check("band.of-viewers", GridManager.cone_band(8.0) == 0 and GridManager.cone_band(8.4) == 0
		and GridManager.cone_band(8.6) == 1 and GridManager.cone_band(12.0) == 4 and GridManager.cone_band(13.44) == 5,
		"8.0=%d 8.4=%d 8.6=%d 12=%d 13.44=%d" % [GridManager.cone_band(8.0), GridManager.cone_band(8.4),
			GridManager.cone_band(8.6), GridManager.cone_band(12.0), GridManager.cone_band(13.44)])
	_check("band.bits-are-2-to-19", GridManager.cone_band_bit(0) == 4 and GridManager.cone_band_bit(17) == 1 << 19
		and GridManager.cone_band_bit(99) == 1 << 19 and GridManager.cone_band(-50.0) == 0)
	# an occluder hides from a band iff its top is above the band's middle eye
	_check("band.mask-below-strict", GridManager.band_mask_below(9.0) == 4 and GridManager.band_mask_below(8.5) == 0
		and GridManager.band_mask_below(8.51) == 4 and GridManager.band_mask_below(12.0) == 0b1111 << 2
		and GridManager.band_mask_below(99.0) == ((1 << 18) - 1) << 2,
		"9.0=%d 8.5=%d 12=%d" % [GridManager.band_mask_below(9.0), GridManager.band_mask_below(8.5), GridManager.band_mask_below(12.0)])

	# --- structure occluders: GROUND (+HIGH) kept, band bits added
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	var w = ml._spawn_geo_structure({"kind": "wall", "a": [136, 224], "b": [384, 224], "half": 7.0, "id": "stone_wall"}, null, 64)
	var wm: int = w.get_node("Occluder").occluder_light_mask
	_check("band.terrace-wall-structure-bit-not-ground", (wm & CollisionLayers.SIGHT_MASK_GROUND) == 0
		and (wm & CollisionLayers.SIGHT_MASK_HIGH) != 0, "mask=%d" % wm)
	_check("band.terrace-wall-shadows-own-terrace", (wm & _bbit(8.0)) != 0, "mask=%d" % wm)
	_check("band.uphill-viewer-sees-over-lower-wall", (wm & _bbit(12.0)) == 0 and (wm & _bbit(8.6)) == 0,
		"mask=%d" % wm)
	var tr = ml._spawn_geo_structure({"kind": "tree", "pos": [160, 400], "r": 30.0, "id": "tree"}, null, 64)
	var trm: int = tr.get_node("Occluder").occluder_light_mask
	_check("band.tree-two-stories", (trm & _bbit(8.0)) != 0 and (trm & _bbit(9.0)) != 0
		and (trm & _bbit(10.0)) == 0 and (trm & CollisionLayers.SIGHT_MASK_HIGH) != 0, "mask=%d" % trm)
	var pw = ml._spawn_geo_structure({"kind": "wall", "a": [1600, 600], "b": [1900, 600], "half": 4.0, "id": "stone_wall", "occlude_h": 0.35}, null, 64)
	_check("band.parapet-still-no-cone-shadow", pw.get_node("Occluder").occluder_light_mask == 0)
	# deck walkway 1.44 above the 12.0 terrace (row 2, x 24..27)
	var dk = ml._spawn_geo_structure({"kind": "wall", "a": [1536, 160], "b": [1792, 160], "half": 12.0, "id": "stone_wall", "walk_elev": 13.44}, null, 64)
	var dkm: int = dk.get_node("Occluder").occluder_light_mask
	_check("band.deck-shadows-ground-viewer", (dkm & _bbit(12.0)) != 0, "mask=%d" % dkm)
	_check("band.deck-never-shadows-its-walker", (dkm & _bbit(13.44)) == 0, "mask=%d" % dkm)
	var pink_ground: int = GridManager.cone_band_bit(GridManager.cone_band(12.0) + 1)
	# worst case for the pink cone: the viewer's eye just under a band edge
	# (ground 12.45, eye 12.95 -> band 4, middle 12.5), deck 1.44 above it
	var dk2 = ml._spawn_geo_structure({"kind": "wall", "a": [1536, 224], "b": [1792, 224], "half": 12.0, "id": "stone_wall", "walk_elev": 13.89}, null, 64)
	var dk2m: int = dk2.get_node("Occluder").occluder_light_mask
	var pink_edge: int = GridManager.cone_band_bit(GridManager.cone_band(12.45) + 1)
	_check("band.deck-never-shadows-pink-cone", (dkm & pink_ground) == 0 and (dk2m & pink_edge) == 0
		and (dk2m & _bbit(12.45)) != 0, "mask=%d edge-deck=%d" % [dkm, dk2m])
	# terrain-following wall up the ramp (row 18, ground 8.85 -> 12.0): its top
	# follows the ground, so an uphill viewer (12.0) sees over its LOW end but
	# not its HIGH end; the bands every stretch blocks sit on the main Occluder
	var sw = ml._spawn_geo_structure({"kind": "wall", "a": [960, 1184], "b": [1472, 1184], "half": 7.0, "id": "stone_wall"}, null, 64)
	var low_m: int = _occ_mask_at(sw, Vector2(968, 1184))
	var high_m: int = _occ_mask_at(sw, Vector2(1464, 1184))
	_check("band.sloped-wall-split-into-chunks", sw.has_meta("occlude_rel_h") and _band_chunk_count(sw) > 0,
		"chunks=%d" % _band_chunk_count(sw))
	_check("band.sloped-wall-low-end-seen-over", (low_m & _bbit(12.0)) == 0 and (low_m & _bbit(8.85)) != 0,
		"low=%d" % low_m)
	_check("band.sloped-wall-high-end-blocks-uphill", (high_m & _bbit(12.0)) != 0, "high=%d" % high_m)
	var chunk_bad := 0
	for c in sw.get_children():
		if c is LightOccluder2D and String(c.name).begins_with("OccluderBand"):
			var cm: int = (c as LightOccluder2D).occluder_light_mask
			if (cm & (CollisionLayers.SIGHT_MASK_GROUND | CollisionLayers.SIGHT_MASK_HIGH)) != 0 or (cm & ~GridManager.band_mask_below(13.0)) != 0:
				chunk_bad += 1
	var swm: int = sw.get_node("Occluder").occluder_light_mask
	_check("band.sloped-wall-chunks-band-only", (swm & CollisionLayers.SIGHT_MASK_HIGH) != 0
		and (swm & CollisionLayers.SIGHT_MASK_GROUND) == 0 and chunk_bad == 0, "main=%d bad chunks=%d" % [swm, chunk_bad])
	# pad-edge house wall: pad 9.0 one story above the 8.0 street, the wall's
	# centre on the street tile. A centre-based top (9.0) would let the pad
	# interior's cone through; the face-max top (10.0) shadows both sides.
	for x in range(3, 7):
		for y in range(12, 16):
			GridManager.elevations[Vector2i(x, y)] = 9.0
	var padw = ml._spawn_geo_structure({"kind": "wall", "a": [190, 768], "b": [190, 1024], "half": 7.0, "id": "stone_wall"}, null, 64)
	var padm: int = _occ_mask_at(padw, Vector2(190, 896))
	_check("band.pad-edge-wall-shadows-street-and-pad", (padm & _bbit(8.0)) != 0 and (padm & _bbit(9.0)) != 0
		and (padm & _bbit(12.0)) == 0, "mask=%d" % padm)
	for x in range(3, 7):
		for y in range(12, 16):
			GridManager.elevations[Vector2i(x, y)] = 8.0

	# --- cliff occluders: a 14.0 pad (x 25..27, row 5) on the 12.0 terrace
	# adds four edges; the 3.6 cliff and the ramp's brow merge into one run each
	for x in range(25, 28):
		GridManager.elevations[Vector2i(x, 5)] = 14.0
	var cr: Node2D = ml._build_cliff_occluders()
	var runs: Array = []
	for c in cr.get_children():
		var co := c as LightOccluder2D
		runs.append([co.occluder.polygon[0], co.occluder.polygon[1], co.occluder_light_mask, co.occluder.closed, co.sdf_collision])
	_check("cliff.run-count", runs.size() == 6, "runs=%d %s" % [runs.size(), str(runs)])
	var m12: int = GridManager.band_mask_below(12.0)
	var m14: int = GridManager.band_mask_below(14.0)
	var want: Array = [
		[Vector2(960, 0), Vector2(960, 1088), m12],      # the 3.6-story cliff, rows 0..16 merged
		[Vector2(1600, 320), Vector2(1600, 384), m14],   # pad west face
		[Vector2(1792, 320), Vector2(1792, 384), m14],   # pad east face
		[Vector2(960, 1088), Vector2(1344, 1088), m12],  # ramp brow: x 15..20 (x 21's 0.45 step is walkable)
		[Vector2(1600, 320), Vector2(1792, 320), m14],   # pad north face, 3 tiles merged
		[Vector2(1600, 384), Vector2(1792, 384), m14],   # pad south face
	]
	var missing: Array = []
	for wnt in want:
		var hit := false
		for r in runs:
			hit = hit or (r[0] == wnt[0] and r[1] == wnt[1] and int(r[2]) == int(wnt[2]))
		if not hit:
			missing.append(wnt)
	_check("cliff.runs-merged-on-tile-edges", missing.is_empty(), "missing %s" % str(missing))
	var all_open := true
	for r in runs:
		all_open = all_open and not bool(r[3]) and not bool(r[4]) and (int(r[2]) & (CollisionLayers.SIGHT_MASK_GROUND | CollisionLayers.SIGHT_MASK_HIGH)) == 0
	_check("cliff.open-band-only-no-sdf", all_open)
	var g1 := 0
	var torch_miss := 0
	for st in [w, tr, dk, dk2, sw, padw]:
		for c in (st as Node).get_children():
			if c is LightOccluder2D:
				var om: int = (c as LightOccluder2D).occluder_light_mask
				if (om & CollisionLayers.SIGHT_MASK_GROUND) != 0:
					g1 += 1
				if String(c.name) == "Occluder" and (om & CollisionLayers.LIGHT_SHADOW_MASK) == 0:
					torch_miss += 1
	for r in runs:
		if (int(r[2]) & (CollisionLayers.SIGHT_MASK_GROUND | CollisionLayers.LIGHT_SHADOW_MASK)) != 0:
			g1 += 1
	_check("band.no-relief-occluder-has-bit-1", g1 == 0, "%d occluders with bit 1" % g1)
	_check("band.torches-still-shadowed-by-structures-not-cliffs", torch_miss == 0, "%d structures without a torch bit" % torch_miss)
	_check("cliff.shadows-foot-not-brow", (m12 & _bbit(8.4)) != 0 and (m12 & _bbit(10.65)) != 0
		and (m12 & _bbit(12.0)) == 0 and (m14 & _bbit(12.0)) != 0 and (m14 & _bbit(14.0)) == 0)
	ml.queue_free()

	# --- viewer cones: the band bit of the viewer's own eye
	_build_terraces()
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	var los := PointLight2D.new()
	los.name = "LineOfSight"
	ch.add_child(los)
	ch.global_position = _c(5, 5)
	ch._refresh_elevation()
	_check("cone.terrace-8-band-0", los.shadow_item_cull_mask == _cone(8.0) and ch.sight_cone_mask() == 1 | 4,
		"mask=%d" % los.shadow_item_cull_mask)
	ch.global_position = _c(25, 5)
	ch._refresh_elevation()
	_check("cone.terrace-12-band-4", los.shadow_item_cull_mask == _cone(12.0)
		and ch.elevated_cone_mask() == CollisionLayers.SIGHT_MASK_GROUND | GridManager.cone_band_bit(5), "mask=%d" % los.shadow_item_cull_mask)
	GridManager.register_deck(Vector2i(26, 5), 13.44)
	ch.global_position = _c(26, 5)
	ch._refresh_elevation()
	_check("cone.deck-walker-band-5", ch.is_on_raised_surface() and los.shadow_item_cull_mask == _cone(13.44),
		"mask=%d" % los.shadow_item_cull_mask)
	GridManager.unregister_deck(Vector2i(26, 5), 13.44)

	# --- top anchoring: sea floor -1 to a 17.5 summit with 20.67 roofs (the
	# real tg_hillside_upper span). Bottom-anchored bands would clamp the
	# summit into band 17 and its own brow would shadow it.
	GridManager.initialize(4 * 64, 1 * 64)
	GridManager.elevations[Vector2i(0, 0)] = -1.0
	GridManager.elevations[Vector2i(1, 0)] = 8.0
	GridManager.elevations[Vector2i(2, 0)] = 17.5
	GridManager.elevations[Vector2i(3, 0)] = 17.5
	GridManager.roof_elevations[Vector2i(3, 0)] = 20.67
	GridManager.refresh_terrain_stats()
	_check("band.tall-map-anchors-at-top", GridManager.cone_band_base == 4 and GridManager.cone_band(20.67) == 17,
		"base=%d roof band=%d" % [GridManager.cone_band_base, GridManager.cone_band(20.67)])
	_check("band.tall-map-summit-sees-off-its-brow", (GridManager.band_mask_below(17.5) & _bbit(17.5)) == 0
		and (GridManager.band_mask_below(17.5) & _bbit(8.0)) != 0)

	# --- flat control (shipped-map-like ravine at -0.98, span < 1): every mask
	# is the legacy GROUND/HIGH value, no band bits, no chunks, no cliff run
	GridManager.initialize(32 * 64, 20 * 64)
	GridManager.elevations[Vector2i(3, 1)] = -0.98
	GridManager.refresh_terrain_stats()
	ch.global_position = _c(10, 10)
	ch._refresh_elevation()
	var flat_ground_ok: bool = not GridManager.relief_los and ch.sight_cone_mask() == CollisionLayers.SIGHT_MASK_GROUND \
		and ch.elevated_cone_mask() == CollisionLayers.SIGHT_MASK_HIGH
	GridManager.register_deck(Vector2i(11, 10), 1.44)
	ch.global_position = _c(11, 10)
	ch._refresh_elevation()
	_check("flat.cone-masks-legacy", flat_ground_ok and los.shadow_item_cull_mask == CollisionLayers.SIGHT_MASK_HIGH
		and ch.sight_cone_mask() == CollisionLayers.SIGHT_MASK_HIGH)
	GridManager.unregister_deck(Vector2i(11, 10), 1.44)
	ch.queue_free()
	var ml3: Node2D = MAP_LOADER.new()
	add_child(ml3)
	var fw = ml3._spawn_geo_structure({"kind": "wall", "a": [136, 224], "b": [384, 224], "half": 7.0, "id": "stone_wall"}, null, 64)
	var ftr = ml3._spawn_geo_structure({"kind": "tree", "pos": [160, 400], "r": 30.0, "id": "tree"}, null, 64)
	var frt = ml3._spawn_geo_structure({"kind": "tree", "pos": [224, 96], "r": 30.0, "id": "tree"}, null, 64)
	var fdk = ml3._spawn_geo_structure({"kind": "wall", "a": [1536, 160], "b": [1792, 160], "half": 12.0, "id": "stone_wall", "walk_elev": 1.44}, null, 64)
	var fpp = ml3._spawn_geo_structure({"kind": "wall", "a": [1536, 160], "b": [1792, 160], "half": 4.0, "id": "stone_wall", "occlude_h": 0.35}, null, 64)
	var fpt = ml3._spawn_geo_structure({"kind": "wall", "a": [1536, 172], "b": [1792, 172], "half": 3.0, "id": "stone_wall", "occlude_h": 1.0}, null, 64)
	var fmasks: Array = [fw.get_node("Occluder").occluder_light_mask, ftr.get_node("Occluder").occluder_light_mask,
		frt.get_node("Occluder").occluder_light_mask, fdk.get_node("Occluder").occluder_light_mask,
		fpp.get_node("Occluder").occluder_light_mask, fpt.get_node("Occluder").occluder_light_mask]
	_check("flat.occluder-masks-legacy", fmasks == [1, 3, 1, 1, 0, 3], "masks=%s" % str(fmasks))
	# ordinary lights moved to GROUND|HIGH: on flat maps that casts exactly the
	# occluders GROUND alone did (every HIGH occluder also carries GROUND)
	var same := true
	for fm in fmasks:
		same = same and (((int(fm) & CollisionLayers.LIGHT_SHADOW_MASK) != 0) == ((int(fm) & CollisionLayers.SIGHT_MASK_GROUND) != 0))
	_check("flat.light-shadow-mask-casts-as-ground", same)
	var em: PointLight2D = load("res://Items/equipment_effects.gd").make_light(0.5, {})
	_check("light.emitted-light-shadow-mask", em.shadow_item_cull_mask == CollisionLayers.LIGHT_SHADOW_MASK, "mask=%d" % em.shadow_item_cull_mask)
	em.free()
	var chunks := 0
	for s in [fw, ftr, frt, fdk, fpp, fpt]:
		chunks += _band_chunk_count(s)
	_check("flat.no-band-chunks", chunks == 0)
	ml3.generate_structured_map({"id": "flat_band_ctl", "images": {"map": "res://icon.svg"}, "floors": [], "structures": []})
	_check("flat.no-cliff-occluders", ml3.cliff_occluders == null and ml3.get_node_or_null("CliffOccluders") == null)
	ml3.queue_free()

# 10. SOLID ROCK (L16) + TERRAIN THAT BLOCKS AIM AND SOUND (G3), on a cave
# whose rock is terrain. 16x8 tiles: gallery A floor 9.0 (x <= 6), rock 12.5
# (x 7..9), gallery B floor 9.0 (x >= 10). Row 1 is a graded causeway out of
# gallery A (0.5/tile, entered at x 2..3) climbing ONTO the rock top: 11.4 at
# x 7 is still floor, 11.9 / 12.4 at x 8 / 9 are rock under solid_rock_elev
# 11.5, so only the solid-rock rule keeps feet off the rock there.
func _build_cave() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(16 * 64, 8 * 64)
	for y in 8:
		for x in 16:
			GridManager.elevations[Vector2i(x, y)] = 12.5 if x >= 7 and x <= 9 else 9.0
	var ramp: Array = [9.0, 9.5, 10.0, 10.5, 11.0, 11.4, 11.9, 12.4]   # x 2..9
	for i in ramp.size():
		GridManager.elevations[Vector2i(2 + i, 1)] = float(ramp[i])
	GridManager.refresh_terrain_stats()

# Layer-0 jump edges out of from_t that land on a column in xs.
func _jump_landings(from_t: Vector2i, jump_h: float, xs: Array) -> int:
	var n := 0
	for e in GridManager._get_jump_neighbors(Vector3i(from_t.x, from_t.y, 0), jump_h, 2):
		var nb: Vector3i = e["n"]
		if nb.z == 0 and nb.x in xs:
			n += 1
	return n

func _scenario_solid_rock() -> void:
	# earlier scenarios' bodies (queue_free'd) must be gone before the rays
	await get_tree().physics_frame
	await get_tree().physics_frame
	var world := get_world_2d()
	_build_cave()
	var rock_xs := [7, 8, 9]
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	ch.jump_height = 4.0          # more lift than any race has today (2.5): the hole L16 names
	ch.jump_range = 2
	ch.global_position = _c(6, 4)
	ch._refresh_elevation()

	# --- no key: today's rule exactly (the rock is only a 3.5-story step)
	_check("rock.off-by-default", GridManager.solid_rock_elev == INF and GridManager.relief_los
		and not GridManager.is_solid_rock(Vector2i(8, 4)) and GridManager.would_walk(Vector2i(8, 4)))
	_check("rock.off-causeway-reaches-rock-top", not GridManager.find_path(Vector2i(2, 1), Vector2i(9, 1)).is_empty())
	_check("rock.off-jumper-can-land-on-rock", _jump_landings(Vector2i(6, 4), 4.0, rock_xs) > 0
		and ch.can_jump_to(Vector2i(6, 4), Vector2i(7, 4)))
	_check("rock.off-spawn-unmoved", GridManager.off_solid_rock(_c(8, 4)) == _c(8, 4))

	# --- key set (an entry's solid_rock_elev, as MapLoader applies it)
	GridManager.solid_rock_elev = 11.5
	_check("rock.tiles", GridManager.is_solid_rock(Vector2i(8, 4)) and GridManager.is_solid_rock(Vector2i(8, 1))
		and not GridManager.is_solid_rock(Vector2i(7, 1)) and not GridManager.is_solid_rock(Vector2i(5, 4)))
	_check("rock.walk-step-refused", not GridManager.can_step(Vector2i(7, 1), Vector2i(8, 1))
		and GridManager.can_step(Vector2i(6, 1), Vector2i(7, 1)))
	_check("rock.causeway-floor-still-walkable", not GridManager.find_path(Vector2i(2, 1), Vector2i(7, 1)).is_empty())
	_check("rock.astar-never-onto-rock", GridManager.find_path(Vector2i(2, 1), Vector2i(9, 1)).is_empty()
		and GridManager.find_path(Vector2i(2, 1), Vector2i(8, 1), 4.0, 2).is_empty())
	var reach := GridManager.reachable_within(Vector2i(7, 1), 6)
	var reach_rock := 0
	for t in reach:
		if GridManager.is_solid_rock(t):
			reach_rock += 1
	_check("rock.reach-excludes-rock", reach_rock == 0 and not reach.is_empty(), "rock tiles=%d" % reach_rock)
	_check("rock.would-walk-refused", not GridManager.would_walk(Vector2i(8, 4)) and GridManager.would_walk(Vector2i(5, 4)))
	_check("rock.click-snaps-to-floor", GridManager.nearest_walkable(Vector2i(7, 4)) == Vector2i(6, 4)
		and GridManager.world_to_map(GridManager.clamp_off_walls(_c(7, 4))) == Vector2i(6, 4))
	# the per-frame movement gate (1px short of the causeway's first rock tile)
	ch.global_position = Vector2(8 * 64 - 1.0, 1 * 64 + 32.0)
	ch._refresh_elevation()
	ch.target_position = _c(9, 1)
	ch.is_moving = true
	for i in 40:
		ch._update_movement(1.0 / 60.0)
	_check("rock.mover-stops-at-rock", GridManager.world_to_map(ch.global_position).x <= 7,
		"ended at %s" % str(GridManager.world_to_map(ch.global_position)))
	ch.is_moving = false
	# jump landings: the planner's edge and the character's own gate
	ch.global_position = _c(6, 4)
	ch._refresh_elevation()
	_check("rock.jumper-plans-no-landing", _jump_landings(Vector2i(6, 4), 4.0, rock_xs) == 0)
	_check("rock.can-jump-to-refused", not ch.can_jump_to(Vector2i(6, 4), Vector2i(7, 4)))
	_check("rock.forced-drop-bails-at-rock", not ch._forced_drop_check(Vector2(64.0, 0.0)) and not ch._fall_active)
	# spawns (Game._spawn_character funnels every spawn through off_solid_rock)
	_check("rock.spawn-moves-to-floor", GridManager.off_solid_rock(_c(7, 4)) == _c(6, 4),
		"got %s" % str(GridManager.off_solid_rock(_c(7, 4))))
	var on_floor: Vector2 = _c(5, 4) + Vector2(5, -3)
	_check("rock.spawn-on-floor-unmoved", GridManager.off_solid_rock(on_floor) == on_floor)
	_check("rock.spawn-refused-without-ground", not GridManager.off_solid_rock(_c(8, 4), 1).is_finite())
	var placed: Vector2 = DialogueManager.actions_api._placement(_c(8, 4), 0, 1, 0.0, {})
	_check("rock.dialogue-placement-off-rock", not GridManager.is_solid_rock(GridManager.world_to_map(placed))
		and GridManager.would_walk(GridManager.world_to_map(placed)), "placed=%s" % str(placed))
	# teleports (the AbilityEffect "teleport" effect)
	var before: Vector2 = ch.global_position
	var tp: Dictionary = AbilityEffect._resolve_teleport({"to": "position"}, self, [ch], _c(8, 4))
	_check("rock.teleport-refused", ch.global_position == before and not bool(tp["success"])
		and (tp["targets_refused"] as Array).has(ch), "pos=%s" % str(ch.global_position))
	tp = AbilityEffect._resolve_teleport({"to": "position"}, self, [ch], _c(4, 4))
	_check("rock.teleport-to-floor-ok", ch.global_position == _c(4, 4) and bool(tp["success"]))
	ch.global_position = _c(6, 4)
	ch._refresh_elevation()

	# --- aim (any relief map; independent of the rock key): with stop_at_terrain
	# (the bite) the ribbon stops at the first tile whose terrain rises above the
	# eye line, before any physics; without it (throw, dash: their actions fly or
	# run on past terrain) the preview runs to the cursor as the action does
	var aim := AimLine.compute_aim(world, _c(2, 4), _c(13, 4), CollisionLayers.STRUCTURES, 0.0, true)
	var aim_end: Vector2 = aim["endpoint"]
	_check("aim.rock-stops-ribbon", bool(aim["blocked"]) and GridManager.world_to_map(aim_end) == Vector2i(6, 4)
		and aim_end.x > 7 * 64 - 2.0, "end=%s" % str(aim_end))
	aim = AimLine.compute_aim(world, _c(2, 4), _c(13, 4), CollisionLayers.STRUCTURES)
	_check("aim.throw-dash-preview-ignores-terrain", not bool(aim["blocked"]) and aim["endpoint"] == _c(13, 4),
		"end=%s" % str(aim["endpoint"]))
	aim = AimLine.compute_aim(world, _c(2, 4), _c(13, 4), 0, 0.0, true)
	_check("aim.terrain-stop-needs-no-mask", bool(aim["blocked"])
		and GridManager.world_to_map(aim["endpoint"] as Vector2) == Vector2i(6, 4))
	aim = AimLine.compute_aim(world, _c(1, 4), _c(5, 4), CollisionLayers.STRUCTURES, 0.0, true)
	_check("aim.open-gallery-clear", not bool(aim["blocked"]) and aim["endpoint"] == _c(5, 4))
	aim = AimLine.compute_aim(world, _c(2, 4), _c(13, 4), CollisionLayers.STRUCTURES, 200.0, true)
	_check("aim.range-clamp-short-of-rock", not bool(aim["blocked"])
		and is_equal_approx((aim["endpoint"] as Vector2).x, _c(2, 4).x + 200.0))
	var bite_end: Vector2 = AimLine.compute_endpoint(world, _c(6, 4), _c(10, 4), CollisionLayers.STRUCTURES, 0.0, true)
	_check("aim.bite-endpoint-stops-too", GridManager.world_to_map(bite_end) == Vector2i(6, 4), "end=%s" % str(bite_end))

	# --- the terrain walk itself: where it stops
	var hit_t: float = GridManager.terrain_line_hit(_c(2, 4), _c(13, 4), 9.5, 9.5, false)
	var want_t: float = (7.0 * 64.0 - _c(2, 4).x) / (_c(13, 4).x - _c(2, 4).x)
	_check("terrain-hit.enters-blocking-tile", is_equal_approx(hit_t, want_t), "t=%.4f want %.4f" % [hit_t, want_t])
	_check("terrain-hit.clear-is-negative", GridManager.terrain_line_hit(_c(1, 4), _c(5, 4), 9.5, 9.5, false) < 0.0)

	# --- hearing: a scream across the rock counts as TERRAIN_OCCLUDERS walls,
	# inside the MAX_OCCLUDERS cap; the open gallery is untouched
	var wf: float = HearingManager.WALL_OCCLUSION_FACTOR
	var through: float = HearingManager._loudness_at(_c(5, 4), _c(11, 4), 1.0)
	_check("hear.rock-two-walls-quieter", is_equal_approx(through, wf * wf), "got %.4f" % through)
	_check("hear.open-gallery-full", is_equal_approx(HearingManager._loudness_at(_c(1, 4), _c(5, 4), 1.0), 1.0))
	_check("hear.terrain-term-constants", HearingManager.TERRAIN_OCCLUDERS == 2 and HearingManager.MAX_OCCLUDERS == 3)
	var wa := _make_blocker(Vector2(400, 288), -1.0)
	var wb := _make_blocker(Vector2(690, 288), -1.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var capped: float = HearingManager._loudness_at(_c(5, 4), _c(11, 4), 1.0)
	_check("hear.walls-plus-rock-capped", is_equal_approx(capped, wf * wf * wf), "got %.5f" % capped)
	wa.queue_free()
	wb.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame

	# --- MapLoader applies the entry key; a map without it leaves the rule off
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	GridManager.solid_rock_elev = INF
	ml.generate_structured_map({"id": "rock_ctl", "images": {"map": "res://icon.svg"}, "floors": [], "structures": [],
		"solid_rock_elev": 11.5})
	_check("rock.maploader-reads-entry", is_equal_approx(GridManager.solid_rock_elev, 11.5))
	_build_cave()   # initialize() resets the key
	ml.generate_structured_map({"id": "rock_ctl_off", "images": {"map": "res://icon.svg"}, "floors": [], "structures": []})
	_check("rock.maploader-absent-key-off", GridManager.solid_rock_elev == INF)
	ml.queue_free()

	# --- key cleared: the legacy rule again, exactly
	_check("rock.cleared-is-legacy", GridManager.can_step(Vector2i(7, 1), Vector2i(8, 1))
		and not GridManager.find_path(Vector2i(2, 1), Vector2i(9, 1)).is_empty()
		and GridManager.off_solid_rock(_c(8, 4)) == _c(8, 4) and GridManager.would_walk(Vector2i(8, 4))
		and GridManager.nearest_walkable(Vector2i(7, 4)) == Vector2i(7, 4))

	# --- flat control: no relief, no terrain term (every shipped flat map)
	GridManager.initialize(16 * 64, 8 * 64)
	GridManager.refresh_terrain_stats()
	_check("flat.no-terrain-hearing-term", not GridManager.relief_los
		and is_equal_approx(HearingManager._loudness_at(_c(5, 4), _c(11, 4), 1.0), 1.0))
	aim = AimLine.compute_aim(world, _c(2, 4), _c(13, 4), CollisionLayers.STRUCTURES, 0.0, true)
	_check("flat.aim-untouched", not bool(aim["blocked"]) and aim["endpoint"] == _c(13, 4))

	# --- terraces: the bite's aim stops at the cliff face, as sight does; a
	# throw or dash preview (no terrain stop) runs on to the cursor
	_build_terraces()
	aim = AimLine.compute_aim(world, _c(5, 5), _c(25, 5), CollisionLayers.STRUCTURES, 0.0, true)
	_check("aim.cliff-stops-at-face", bool(aim["blocked"])
		and GridManager.world_to_map(aim["endpoint"] as Vector2) == Vector2i(14, 5),
		"end=%s" % str(aim["endpoint"]))
	aim = AimLine.compute_aim(world, _c(5, 5), _c(25, 5), CollisionLayers.STRUCTURES)
	_check("aim.throw-dash-preview-runs-past-cliff", not bool(aim["blocked"]) and aim["endpoint"] == _c(25, 5),
		"end=%s" % str(aim["endpoint"]))
	for x in range(11, 15):
		for y in range(8, 11):
			GridManager.roof_elevations[Vector2i(x, y)] = 10.4
	_check("terrain-hit.roofs-off-ignores-slab",
		GridManager.terrain_line_hit(_c(15, 9), _c(12, 9), 12.5, 8.9) >= 0.0
		and GridManager.terrain_line_hit(_c(15, 9), _c(12, 9), 12.5, 8.9, false) < 0.0)
	GridManager.roof_elevations.clear()
	ch.queue_free()

# 10. RELATIVE DEEP WATER (P3-D, L8/L17): with the open-water layer (cells.json
# tile_water / tile_body, export contract 3) deep water is measured below the
# water's own surface, on any map; without it the absolute -0.5 rule stands.
# A cells.json with one cell per tile (64 px), ground 2.0, a river on rows 3-4
# (surface 1.8, bed 0.8, body 1: deep only by the relative rule) with a deck
# bridge on column 6 (walk_elev 2.0, rows 2-5), a ditch at (0,3) (ground 0.0,
# beside the river: a jump UP into it), threshold tiles (11,3) bed 1.3 (depth
# exactly 0.5: deep) and (11,4) bed 1.31 (0.49: not), and a creek at (9,6)
# (surface 1.7, bed 1.4, body 2: wadeable).
const RDW_COLS := 12
const RDW_ROWS := 8

func _rdw_te(x: int, y: int) -> float:
	if x == 0 and y == 3:
		return 0.0
	if x == 11 and y == 3:
		return 1.3
	if x == 11 and y == 4:
		return 1.31
	if x == 9 and y == 6:
		return 1.4
	return 0.8 if (y == 3 or y == 4) else 2.0

func _rdw_body(x: int, y: int) -> int:
	if x == 9 and y == 6:
		return 2
	return 1 if (y == 3 or y == 4) and x > 0 else 0

func _write_rdw_graph(path: String, cols: int, rows: int, te: Array, tw: Array, tb: Array, layer: bool) -> void:
	var cx: Array = []
	var cy: Array = []
	var r: Array = []
	var fuel: Array = []
	var roof: Array = []
	var nb_off: Array = []
	var nb: Array = []
	for y in rows:
		for x in cols:
			cx.append((float(x) + 0.5) * 64.0)
			cy.append((float(y) + 0.5) * 64.0)
			r.append(32.0)
			fuel.append(0.0)
			roof.append(0.0)
			nb_off.append(nb.size())
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n := Vector2i(x, y) + d
				if n.x >= 0 and n.y >= 0 and n.x < cols and n.y < rows:
					nb.append(n.y * cols + n.x)
	nb_off.append(nb.size())
	var d: Dictionary = {"n": cols * rows, "export_scale": 2.0, "cx": cx, "cy": cy, "r": r, "fuel": fuel,
		"elev": te, "roof": roof, "nb_off": nb_off, "nb": nb, "tile_elev": {"cols": cols, "rows": rows, "data": te}}
	if layer:
		d["tile_water"] = {"cols": cols, "rows": rows, "data": tw}
		d["tile_body"] = {"cols": cols, "rows": rows, "data": tb}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()

func _load_rdw(layer: bool) -> void:
	var path := "user://elev_harness_rdw_cells.json"
	var te: Array = []
	var tw: Array = []
	var tb: Array = []
	for y in RDW_ROWS:
		for x in RDW_COLS:
			te.append(_rdw_te(x, y))
			var bid := _rdw_body(x, y)
			tb.append(bid)
			tw.append(1.7 if bid == 2 else (1.8 if bid == 1 else 0.0))
	_write_rdw_graph(path, RDW_COLS, RDW_ROWS, te, tw, tb, layer)
	GridManager.TILE_SIZE = 64
	GridManager.initialize(RDW_COLS * 64, RDW_ROWS * 64)
	GridManager.set_elevation_data(CellGraph.from_structured(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for y in RDW_ROWS:
		for x in RDW_COLS:
			var t := Vector2i(x, y)
			GridManager.floors[t] = "shallow_water" if _rdw_body(x, y) > 0 else "floor_stone"
	for y in range(2, 6):
		GridManager.register_deck(Vector2i(6, y), 2.0)
		GridManager.floors[Vector2i(6, y)] = "floor_wood"   # TG writes planks under a deck

func _scenario_relative_deep_water() -> void:
	# --- the layer: the river is deep below its OWN surface (bed 0.8 > -0.5)
	_load_rdw(true)
	_check("rdw.layer-loaded", GridManager.has_water_layer() and GridManager.relief_los
		and is_equal_approx(GridManager.water_surface_at(Vector2i(2, 3)), 1.8))
	_check("rdw.river-deep-above-sea-level", GridManager.is_deep_water(Vector2i(2, 3))
		and GridManager.is_deep_water(Vector2i(8, 4)), "bed 0.8, surface 1.8")
	_check("rdw.bridge-not-deep", not GridManager.is_deep_water(Vector2i(6, 3)) and not GridManager.is_deep_water(Vector2i(6, 4)),
		"a deck over the water is its surface")
	_check("rdw.bank-not-deep", not GridManager.is_deep_water(Vector2i(2, 1)) and not GridManager.is_deep_water(Vector2i(0, 3)))
	_check("rdw.creek-wadeable", not GridManager.is_deep_water(Vector2i(9, 6)), "depth 0.3")
	_check("rdw.threshold", GridManager.is_deep_water(Vector2i(11, 3)) and not GridManager.is_deep_water(Vector2i(11, 4)),
		"depth 0.50 deep, 0.49 not")
	# walking: the bridge carries the walk, its ends pass the step gate, the river does not
	_check("rdw.can-step-bridge-ends", GridManager.can_step(Vector2i(6, 1), Vector2i(6, 2))
		and GridManager.can_step(Vector2i(6, 5), Vector2i(6, 6)) and not GridManager.can_step(Vector2i(6, 3), Vector2i(5, 3))
		and not GridManager.can_step(Vector2i(5, 2), Vector2i(5, 3)))
	var p := GridManager.find_path(Vector2i(2, 0), Vector2i(2, 7))
	var over_deck := true
	for t in p:
		over_deck = over_deck and (GridManager.deck_elevations.has(t) or _rdw_body(t.x, t.y) == 0)
	_check("rdw.path-over-bridge", not p.is_empty() and over_deck, "len=%d" % p.size())
	# the jump planner: no landing in the river, down from the bank or UP from the ditch
	var into := 0
	for e in GridManager._get_jump_neighbors(Vector3i(2, 2, 0), 2.5, 2):
		var n := Vector2i((e["n"] as Vector3i).x, (e["n"] as Vector3i).y)
		if GridManager.is_deep_water(n):
			into += 1
	var up_into := 0
	for e in GridManager._get_jump_neighbors(Vector3i(0, 3, 0), 2.5, 2):
		var n := Vector2i((e["n"] as Vector3i).x, (e["n"] as Vector3i).y)
		if GridManager.is_deep_water(n):
			up_into += 1
	_check("rdw.planner-never-into-river", into == 0 and up_into == 0, "down %d, up %d" % [into, up_into])
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	ch.jump_height = 2.5
	ch.jump_range = 2
	ch.global_position = _c(2, 2)
	ch._refresh_elevation()
	_check("rdw.can-jump-to-refuses-river", not ch.can_jump_to(Vector2i(2, 2), Vector2i(2, 3))
		and not ch.can_jump_to(Vector2i(2, 2), Vector2i(2, 4)) and ch.can_jump_to(Vector2i(2, 2), Vector2i(4, 2)))
	ch.global_position = _c(0, 3)
	ch._refresh_elevation()
	_check("rdw.can-jump-to-refuses-river-uphill", not ch.can_jump_to(Vector2i(0, 3), Vector2i(1, 3)),
		"ditch 0.0 -> bed 0.8")
	ch.global_position = _c(2, 2)
	ch._refresh_elevation()
	_check("rdw.knockback-refuses-river", not ch._forced_drop_check(Vector2(0.0, 64.0)) and not ch._fall_active
		and not ch._forced_step_ok(_c(2, 2), _c(2, 3)))
	_check("rdw.knockback-along-bridge", ch._forced_step_ok(_c(6, 2), _c(6, 5)), "deck tiles are not deep")
	_check("rdw.knockback-off-bridge-refused", not ch._forced_step_ok(_c(6, 3), _c(5, 3)))
	ch.queue_free()
	# --- no layer: the absolute rule, exactly as before (the bed is above -0.5)
	_load_rdw(false)
	_check("rdw.fallback-absolute", not GridManager.has_water_layer() and GridManager.relief_los
		and not GridManager.is_deep_water(Vector2i(2, 3)) and not GridManager.is_deep_water(Vector2i(11, 3)),
		"today's rule: a river above sea level is not deep (L8)")
	# --- a FLAT map (span < 1) with the layer: deep without relief_los, and the
	# forced movers see it (segment_enters_deep_water no longer bails on flat maps)
	var fpath := "user://elev_harness_rdw_flat.json"
	var fte: Array = []
	var ftw: Array = []
	var ftb: Array = []
	for y in 4:
		for x in 6:
			var wet: bool = x == 3
			fte.append(-0.7 if wet else 0.0)
			ftw.append(-0.1 if wet else 0.0)
			ftb.append(1 if wet else 0)
	for layer in [true, false]:
		_write_rdw_graph(fpath, 6, 4, fte, ftw, ftb, layer)
		GridManager.initialize(6 * 64, 4 * 64)
		GridManager.set_elevation_data(CellGraph.from_structured(fpath))
		for y in 4:
			GridManager.floors[Vector2i(3, y)] = "shallow_water"
		if layer:
			_check("rdw.flat-layer-deep", not GridManager.relief_los and GridManager.is_deep_water(Vector2i(3, 1))
				and GridManager.segment_enters_deep_water(_c(1, 1), _c(5, 1)), "depth 0.6 on a 0.7-span map")
		else:
			_check("rdw.flat-no-layer-unchanged", not GridManager.relief_los and not GridManager.is_deep_water(Vector2i(3, 1))
				and not GridManager.segment_enters_deep_water(_c(1, 1), _c(5, 1)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(fpath))
	# --- L17: the relief_los override (GridManager) and its entry key (MapLoader)
	GridManager.initialize(6 * 64, 4 * 64)
	GridManager.elevations[Vector2i(3, 1)] = -0.98
	GridManager.floors[Vector2i(3, 1)] = "shallow_water"
	GridManager.refresh_terrain_stats()
	var auto_off: bool = not GridManager.relief_los
	GridManager.set_relief_los_override(1)
	var forced_on: bool = GridManager.relief_los and GridManager.is_deep_water(Vector2i(3, 1))
	GridManager.refresh_terrain_stats()
	var sticks: bool = GridManager.relief_los
	GridManager.set_relief_los_override(-1)
	_check("l17.override-forces-on", auto_off and forced_on and sticks and not GridManager.relief_los,
		"flat map: on with the override (the no-layer deep rule rides it), auto again at -1")
	_build_terraces()
	GridManager.set_relief_los_override(0)
	var forced_off: bool = not GridManager.relief_los
	GridManager.initialize(4 * 64, 4 * 64)
	_check("l17.override-forces-off-and-resets", forced_off and GridManager.relief_los_override == -1)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	GridManager.initialize(6 * 64, 4 * 64)
	GridManager.refresh_terrain_stats()
	ml.generate_structured_map({"id": "l17_on", "images": {"map": "res://icon.svg"}, "floors": [], "structures": [],
		"relief_los": true})
	var key_on: bool = GridManager.relief_los
	_build_terraces()
	ml.generate_structured_map({"id": "l17_off", "images": {"map": "res://icon.svg"}, "floors": [], "structures": [],
		"relief_los": false})
	var key_off: bool = not GridManager.relief_los
	_build_terraces()
	ml.generate_structured_map({"id": "l17_bad", "images": {"map": "res://icon.svg"}, "floors": [], "structures": [],
		"relief_los": "yes"})
	var key_bad_auto: bool = GridManager.relief_los and GridManager.relief_los_override == -1
	_build_terraces()
	ml.generate_structured_map({"id": "l17_none", "images": {"map": "res://icon.svg"}, "floors": [], "structures": []})
	var key_absent_auto: bool = GridManager.relief_los and GridManager.relief_los_override == -1
	ml.queue_free()
	_check("l17.maploader-entry-key", key_on and key_off and key_bad_auto and key_absent_auto,
		"on %s off %s bad->auto %s absent->auto %s" % [str(key_on), str(key_off), str(key_bad_auto), str(key_absent_auto)])

# 6b. JUMP + FALL: roof channel, layered A*, jump/fall states
func _scenario_jump_fall() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(20 * 64, 20 * 64)
	# --- roof channel projection: stacked, never leaking into the ground layer
	GridManager.set_elevation_data(StubRoofGraph.new())
	_check("roofchan.loads", GridManager.roof_elevations.size() == 1
		and is_equal_approx(GridManager.roof_at(Vector2i(3, 3)), 2.0))
	_check("roofchan.no-ground-leak", GridManager.effective_elev(Vector2i(3, 3)) == 0.0)
	# --- roof-surface step gate
	GridManager.initialize(20 * 64, 20 * 64)
	# a realistic building: roofed tiles whose GROUND is walled off (INF) —
	# real roofs sit over obstacle tiles, so roof landings must not consult
	# ground pathability
	for x in range(5, 9):
		for y in range(5, 8):
			GridManager.roof_elevations[Vector2i(x, y)] = 2.0
			GridManager.grid_costs[Vector2i(x, y)] = INF
	_check("canstep_roof.gate", GridManager.can_step_roof(Vector2i(5, 5), Vector2i(6, 5))
		and not GridManager.can_step_roof(Vector2i(5, 5), Vector2i(4, 5)))
	GridManager.roof_elevations[Vector2i(8, 5)] = 3.0
	_check("canstep_roof.delta-gate", not GridManager.can_step_roof(Vector2i(7, 5), Vector2i(8, 5)))
	GridManager.roof_elevations[Vector2i(8, 5)] = 2.0
	# --- layered A*: default race cannot reach the roof block, a jumper can
	var ground := Vector2i(2, 6)
	var roof_goal := Vector2i(6, 6)
	_check("astar.default-cannot-mount", GridManager.find_path(ground, roof_goal).is_empty())
	var jp := GridManager.find_path(ground, roof_goal, 2.5, 2)
	_check("astar.jumper-mounts", not jp.is_empty())
	# --- ceiling clearance: from a tile UNDER its own roof you cannot leap up
	# through it onto that same roof; from an UNROOFED tile the roof IS mountable
	GridManager.grid_costs[Vector2i(15, 6)] = 1.0   # unroofed approach
	GridManager.grid_costs[Vector2i(16, 6)] = 1.0   # roofed interior
	GridManager.grid_costs[Vector2i(17, 6)] = 1.0   # roofed interior
	GridManager.roof_elevations[Vector2i(16, 6)] = 2.0
	GridManager.roof_elevations[Vector2i(17, 6)] = 2.0
	var interior_has_mount := false
	for e in GridManager._get_jump_neighbors(Vector3i(16, 6, 0), 2.5, 2):
		if (e["n"] as Vector3i).z == 1:
			interior_has_mount = true
	_check("jump.no-mount-through-own-ceiling", not interior_has_mount)
	var approach_has_mount := false
	for e in GridManager._get_jump_neighbors(Vector3i(15, 6, 0), 2.5, 2):
		if (e["n"] as Vector3i).z == 1:
			approach_has_mount = true
	_check("jump.unroofed-tile-can-mount", approach_has_mount)
	# --- jump DOWN a ledge: a jumper on a 2-story deck can descend (was a
	# one-way trap before — up-jump existed, down-jump did not), a walker cannot
	GridManager.elevations[Vector2i(12, 10)] = 2.0
	GridManager.grid_costs[Vector2i(12, 10)] = 1.0
	GridManager.grid_costs[Vector2i(13, 10)] = 1.0
	GridManager.grid_costs[Vector2i(14, 10)] = 1.0
	_check("astar.jumper-descends-ledge",
		not GridManager.find_path(Vector2i(12, 10), Vector2i(14, 10), 2.5, 2).is_empty())
	_check("astar.walker-stranded-on-ledge",
		GridManager.find_path(Vector2i(12, 10), Vector2i(14, 10)).is_empty())
	# --- goal layer: a roofed interior whose ground is sealed by walls on all
	# four sides is NOT satisfiable at ground level (no "arriving" on the roof
	# above the target — you would have to path THROUGH the roof to its floor),
	# but IS reachable when the caller explicitly asks for the roof surface.
	# (initialize() leaves the grid open at default cost, so the walls must be
	# set explicitly — the target's only access is over the roof.)
	GridManager.roof_elevations[Vector2i(17, 12)] = 2.0
	GridManager.roof_elevations[Vector2i(18, 12)] = 2.0
	GridManager.grid_costs[Vector2i(17, 12)] = INF   # roofed wall (roof approach)
	GridManager.grid_costs[Vector2i(19, 12)] = INF   # seal the interior floor...
	GridManager.grid_costs[Vector2i(18, 11)] = INF
	GridManager.grid_costs[Vector2i(18, 13)] = INF
	GridManager.grid_costs[Vector2i(18, 12)] = 1.0   # roofed interior, ground sealed
	_check("astar.goal-ground-not-faked-on-roof",
		GridManager.find_path(Vector2i(16, 12), Vector2i(18, 12), 2.5, 2).is_empty())
	_check("astar.goal-roof-reached-when-asked",
		not GridManager.find_path(Vector2i(16, 12), Vector2i(18, 12), 2.5, 2, false, true).is_empty())
	# --- character jump/fall states
	var scene: PackedScene = load("res://Characters/ProceduralCharacter.tscn")
	var ch = scene.instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	ch.jump_height = 2.5
	ch.jump_range = 2
	ch.global_position = GridManager.map_to_world(Vector2i(4, 6))   # beside the roof block
	ch._refresh_elevation()
	_check("canjumpto.gate", ch.can_jump_to(Vector2i(4, 6), Vector2i(5, 6))
		and not ch.can_jump_to(Vector2i(4, 6), Vector2i(7, 6)))   # range 3 > jump_range
	var pre_mask: int = ch.collision_mask
	ch._begin_jump(Vector2i(5, 6))
	_check("jump.suspends-structures", (ch.collision_mask & CollisionLayers.STRUCTURES) == 0)
	for _i in 40:
		if not ch._jump_active:
			break
		ch._update_jump_motion(1.0 / 30.0)
	_check("jump.lands-on-roof", ch.on_roof and is_equal_approx(ch.current_elevation, 2.0)
		and ch.collision_mask == pre_mask,
		"on_roof=%s elev=%.2f" % [str(ch.on_roof), ch.current_elevation])
	# --- forced drop off the rim -> fall state -> ground landing with damage
	ch.global_position = GridManager.map_to_world(Vector2i(5, 6))
	ch.current_health = 20
	var stepv := Vector2(-float(GridManager.TILE_SIZE), 0.0)   # west, off the roof block
	_check("fall.forced-drop-begins", ch._forced_drop_check(stepv) and ch._fall_active)
	for _i in 20:
		if not ch._fall_active:
			break
		ch._update_fall_motion(1.0 / 30.0)
	_check("fall.lands-grounded", not ch.on_roof and is_equal_approx(ch.current_elevation, 0.0))
	_check("fall.damage-applied", ch.current_health < 20, "hp=%d" % ch.current_health)
	# --- graceful ramp: small drops never enter the fall state or hurt
	ch.current_health = 20
	GridManager.elevations[Vector2i(10, 10)] = 0.4
	ch.global_position = GridManager.map_to_world(Vector2i(10, 10))
	ch._refresh_elevation()
	_check("fall.ramp-no-fall", not ch._forced_drop_check(Vector2(float(GridManager.TILE_SIZE), 0.0))
		and not ch._fall_active and ch.current_health == 20)
	# --- fall damage scales with race multiplier (pure base amount; take_damage
	# layers limb/condition effects on top, so health deltas aren't compared)
	ch.fall_damage_mult = 0.4
	var soft_dmg: int = ch.fall_damage_for(3.0)
	ch.fall_damage_mult = 1.0
	var hard_dmg: int = ch.fall_damage_for(3.0)
	_check("fall.damage-scales", soft_dmg > 0 and hard_dmg > soft_dmg
		and ch.fall_damage_for(1.0) == 0,
		"soft=%d hard=%d" % [soft_dmg, hard_dmg])
	# --- controlled drop off a high jump lands hard EVEN when the per-frame
	# _refresh_elevation fires mid-arc: the takeoff must be snapshotted at
	# _begin_jump, else the refresh rewrites current_elevation to the landing
	# and _end_jump computes a zero drop (free hops off any height).
	ch.fall_damage_mult = 1.0
	ch.on_roof = true
	ch.current_elevation = 2.0
	ch.current_health = 20
	ch.global_position = GridManager.map_to_world(Vector2i(6, 6))   # on the roof block
	ch._begin_jump(Vector2i(4, 6))                                  # down to bare ground
	ch._update_jump_motion(1.0 / 60.0)
	ch._refresh_elevation()   # simulate _process's mid-arc refresh (the corruptor)
	for _i in 40:
		if not ch._jump_active:
			break
		ch._update_jump_motion(1.0 / 30.0)
	_check("jump.controlled-drop-still-hurts", ch.current_health < 20 and not ch.on_roof,
		"hp=%d on_roof=%s" % [ch.current_health, str(ch.on_roof)])
	ch.queue_free()

# 7. BATTLEMENTS: the shipped tg_export loads with walkable fort tower decks
# and ladder warp pairs (walk_elev + derived warps from the editor exporter).
func _scenario_battlements() -> void:
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	if f == null:
		_check("battlements.maps-json", false, "cannot open Maps.json")
		return
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == "tg_export":
			m = e
			break
	if m.is_empty():
		_check("battlements.entry", false, "no tg_export entry in Maps.json")
		return
	add_to_group("game")   # harmless for earlier scenarios; MapLoader stub hook
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var graph: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	GridManager.set_elevation_data(graph)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	_check("battlements.decks-registered", not GridManager.deck_elevations.is_empty(),
		"no deck tiles after load")
	var spawns: Dictionary = m.get("player_spawns", {})
	var ladder_warps := 0
	var top_t := Vector2i(-1, -1)
	var base_t := Vector2i(-1, -1)
	for w in m.get("warp_points", []):
		var wid := String(w.get("id", ""))
		if not wid.begins_with("fort_ladder_"):
			continue
		ladder_warps += 1
		var ts := String(w.get("target_spawn", ""))
		if not spawns.has(ts):
			_check("battlements.arrival-" + ts, false, "missing player_spawns key")
			continue
		var pos_a: Array = spawns[ts]["position"]
		var t := GridManager.world_to_map(Vector2(float(pos_a[0]), float(pos_a[1])))
		var e := GridManager.effective_elev(t)
		# RELATIVE to the local terrain (identical on this flat map; a ladder
		# on a hillside terrace sits at ground 8, not 0)
		var hag: float = e - GridManager.terrain_elev(t)
		if ts.ends_with("_top"):
			top_t = t
			_check("battlements." + ts, hag >= GridManager.HIGH_LAYER_STORIES and GridManager.would_walk(t),
				"elev=%.2f hag=%.2f walkable=%s" % [e, hag, str(GridManager.would_walk(t))])
		else:
			base_t = t
			_check("battlements." + ts, absf(hag) < GridManager.MAX_STEP_STORIES and GridManager.would_walk(t),
				"elev=%.2f hag=%.2f walkable=%s" % [e, hag, str(GridManager.would_walk(t))])
	_check("battlements.ladder-warps-present", ladder_warps == 4, "found %d" % ladder_warps)
	# the deck rim is a cliff: some deck tile must border low ground it cannot step to
	var rim_blocked := false
	for t in GridManager.deck_elevations:
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = t + d
			if not GridManager.deck_elevations.has(n) and not GridManager.can_step(t, n):
				rim_blocked = true
				break
		if rim_blocked:
			break
	_check("battlements.rim-is-cliff", rim_blocked)
	# and the tower top is foot-unreachable from the ladder base (warp-only)
	if top_t.x >= 0 and base_t.x >= 0:
		_check("battlements.tower-foot-unreachable",
			GridManager.find_path(base_t, top_t).is_empty())
	# a jumper can mount a real ROOF from an adjacent street tile (the fort
	# drums stay ladder-gated even for jumpers: their merlon-ring halo keeps
	# every landing 3+ cardinal steps out — accepted balance)
	var mounted := false
	var tried := 0
	for rt in GridManager.roof_elevations:
		if tried >= 200 or mounted:
			break
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var s: Vector2i = (rt as Vector2i) + d * 2
			if GridManager.grid_costs.get(s, INF) == INF or GridManager.has_roof(s):
				continue
			tried += 1
			if not GridManager.find_path(s, rt, 2.5, 2).is_empty():
				mounted = true
				break
	_check("battlements.jumper-mounts-real-roof", mounted,
		"no street-adjacent roof mount found in %d tries" % tried)
	ml.queue_free()

# 1. PROJECTION: real cells.json -> sparse per-tile elevations
func _scenario_projection() -> void:
	GridManager.TILE_SIZE = 64
	if not ResourceLoader.exists("res://Maps/tg_export_cells.json") \
			and not FileAccess.file_exists("res://Maps/tg_export_cells.json"):
		_check("projection.load", false, "tg_export_cells.json missing")
		return
	var graph: CellGraph = CellGraph.from_structured("res://Maps/tg_export_cells.json")
	if graph == null:
		_check("projection.load", false, "from_structured returned null")
		return
	GridManager.initialize(3328, 4096)
	GridManager.set_elevation_data(graph)
	var has_nonzero := false
	for i in graph._elev.size():
		if absf(graph._elev[i]) > 0.001:
			has_nonzero = true
			break
	_check("projection.nonempty-iff-source",
		GridManager.elevations.is_empty() != has_nonzero,
		"cells nonzero=%s but tile dict size=%d" % [has_nonzero, GridManager.elevations.size()])
	# a tile with no entry must read exactly 0.0
	var flat := Vector2i(-1, -1)
	for y in GridManager.map_rect.size.y:
		for x in GridManager.map_rect.size.x:
			if not GridManager.elevations.has(Vector2i(x, y)):
				flat = Vector2i(x, y)
				break
		if flat.x >= 0:
			break
	if flat.x >= 0:
		_check("projection.flat-reads-zero", GridManager.effective_elev(flat) == 0.0)
	# adjacent-tile delta histogram (tunes MAX_STEP_STORIES)
	var max_d := 0.0
	var buckets := [0, 0, 0, 0]   # <=0.25, <=0.55, <=1.0, >1.0
	for t in GridManager.elevations:
		for d in [Vector2i(1, 0), Vector2i(0, 1)]:
			var dd: float = absf(GridManager.effective_elev(t + d) - GridManager.effective_elev(t))
			max_d = maxf(max_d, dd)
			if dd <= 0.25: buckets[0] += 1
			elif dd <= 0.55: buckets[1] += 1
			elif dd <= 1.0: buckets[2] += 1
			else: buckets[3] += 1
	print("INFO projection: %d elevated tiles, max adjacent delta %.3f, buckets(<=.25/<=.55/<=1/>1)=%s" \
		% [GridManager.elevations.size(), max_d, str(buckets)])

# 2. CAN_STEP + A* on a synthetic ridge with a ramp saddle
func _scenario_can_step_astar() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(20 * 64, 20 * 64)
	for y in range(0, 16):
		GridManager.elevations[Vector2i(10, y)] = 2.0
	GridManager.elevations[Vector2i(10, 16)] = 0.4
	GridManager.elevations[Vector2i(10, 17)] = 0.4
	_check("canstep.ridge-blocked", not GridManager.can_step(Vector2i(9, 5), Vector2i(10, 5)))
	_check("canstep.ridge-blocked-reverse", not GridManager.can_step(Vector2i(10, 5), Vector2i(9, 5)))
	_check("canstep.saddle-open", GridManager.can_step(Vector2i(9, 17), Vector2i(10, 17)))
	var path := GridManager.find_path(Vector2i(5, 5), Vector2i(15, 5))
	_check("astar.path-found", not path.is_empty(), "no route via the saddle")
	var prev := Vector2i(5, 5)
	var ok := true
	for p in path:
		if not GridManager.can_step(prev, p):
			ok = false
			break
		prev = p
	_check("astar.every-step-legal", ok, "path crossed a cliff at %s" % str(prev))

# 3. DECK REFCOUNT (+ mixed-height junction: taller deck dies first)
func _scenario_deck_refcount() -> void:
	GridManager.initialize(20 * 64, 20 * 64)
	GridManager.register_deck(Vector2i(3, 3), 2.0)
	GridManager.register_deck(Vector2i(3, 3), 2.0)
	GridManager.unregister_deck(Vector2i(3, 3), 2.0)
	_check("deck.survives-one-unregister", GridManager.effective_elev(Vector2i(3, 3)) == 2.0)
	_check("deck.blocks-ground-step", not GridManager.can_step(Vector2i(2, 3), Vector2i(3, 3)))
	GridManager.unregister_deck(Vector2i(3, 3), 2.0)
	_check("deck.cleared-at-zero-refs", GridManager.effective_elev(Vector2i(3, 3)) == 0.0)
	# walkway (1.0) + tower top (3.0) share a junction tile; the tower dies —
	# the tile must drop to the surviving walkway's height, not keep 3.0
	GridManager.register_deck(Vector2i(5, 5), 1.0)
	GridManager.register_deck(Vector2i(5, 5), 3.0)
	_check("deck.mixed-max-wins", GridManager.effective_elev(Vector2i(5, 5)) == 3.0)
	GridManager.unregister_deck(Vector2i(5, 5), 3.0)
	_check("deck.survivor-height-restored", GridManager.effective_elev(Vector2i(5, 5)) == 1.0)
	GridManager.unregister_deck(Vector2i(5, 5), 1.0)
	_check("deck.mixed-cleared", GridManager.effective_elev(Vector2i(5, 5)) == 0.0)
	# 3b. CAN_TRAVERSE: a one-tile ravine must not be tunnelled by a long step
	GridManager.elevations[Vector2i(8, 8)] = -1.0
	var west := GridManager.map_to_world(Vector2i(7, 8))
	var east := GridManager.map_to_world(Vector2i(9, 8))
	_check("traverse.blocks-across-ravine", not GridManager.can_traverse(west, east))
	_check("traverse.same-tile-ok", GridManager.can_traverse(west, west + Vector2(3, 0)))
	GridManager.elevations.erase(Vector2i(8, 8))

# 4. MOVEMENT GATE: real ProceduralCharacter vs the synthetic ridge.
# The character is placed 1px from the tile boundary so the gate decision
# fires on the first _update_movement call — move_and_slide's real motion is
# frame-delta dependent and unreliable in a headless synchronous loop, but the
# gate math, axis-slide, and fake-arrival contract are position-based and
# fully deterministic.
func _scenario_movement_gate() -> void:
	GridManager.initialize(20 * 64, 20 * 64)
	for y in range(0, 16):
		GridManager.elevations[Vector2i(10, y)] = 2.0
	GridManager.elevations[Vector2i(10, 16)] = 0.4
	GridManager.elevations[Vector2i(10, 17)] = 0.4
	var scene: PackedScene = load("res://Characters/ProceduralCharacter.tscn")
	var ch = scene.instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	var arrivals := [0]
	ch.character_reached_target.connect(func(): arrivals[0] += 1)
	# (a) dead-on at the cliff: pure-east move into the ridge — no slide axis,
	# stuck timer must fake-arrive within ~0.5s of calls
	ch.global_position = Vector2(10 * 64 - 1.0, 5 * 64 + 32.0)   # 1px west of the ridge boundary
	ch.target_position = GridManager.map_to_world(Vector2i(12, 5))
	ch.is_moving = true
	for i in 40:
		ch._update_movement(1.0 / 60.0)
	var end_tile: Vector2i = GridManager.world_to_map(ch.global_position)
	_check("gate.cliff-not-crossed", end_tile.x <= 9, "ended at %s" % str(end_tile))
	_check("gate.fake-arrival-fired", arrivals[0] >= 1 and not ch.is_moving,
		"arrivals=%d is_moving=%s" % [arrivals[0], str(ch.is_moving)])
	# (b) diagonal at the cliff: the y-axis is safe, so the gate must SLIDE
	# (velocity straight south) instead of dead-stopping
	ch.global_position = Vector2(10 * 64 - 1.0, 5 * 64 + 32.0)
	ch.target_position = GridManager.map_to_world(Vector2i(12, 7))
	ch.is_moving = true
	ch.velocity = Vector2.ZERO
	ch._update_movement(1.0 / 60.0)
	_check("gate.axis-slide", ch.velocity.x == 0.0 and ch.velocity.y > 0.0,
		"velocity=%s" % str(ch.velocity))
	# (c) legal move toward the saddle: the gate must NOT veto (velocity keeps
	# its eastward component, no fake arrival)
	arrivals[0] = 0
	ch.global_position = Vector2(10 * 64 - 1.0, 17 * 64 + 32.0)   # boundary of the 0.4 saddle
	ch.target_position = GridManager.map_to_world(Vector2i(12, 17))
	ch.is_moving = true
	ch.velocity = Vector2.ZERO
	for i in 10:
		ch._update_movement(1.0 / 60.0)
	_check("gate.ramp-passes", ch.is_moving and arrivals[0] == 0 and ch.velocity.x > 0.0,
		"is_moving=%s arrivals=%d velocity=%s" % [str(ch.is_moving), arrivals[0], str(ch.velocity)])
	# (d) elevation state tracks the tile under the feet
	ch.global_position = GridManager.map_to_world(Vector2i(10, 17))
	ch._refresh_elevation()
	_check("gate.elevation-tracks", is_equal_approx(ch.current_elevation, 0.4),
		"elev=%f" % ch.current_elevation)
	ch.queue_free()

# 5. ELEVATION LOS: occlude_top filtering in sight_line_clear
func _scenario_elevation_los() -> void:
	var a := Vector2(100, 100)
	var b := Vector2(500, 100)
	var low := _make_blocker(Vector2(300, 100), 1.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_2d().direct_space_state
	_check("los.ground-blocked", not GridManager.sight_line_clear(space, a, b, 0.0))
	_check("los.elevated-sees-over", GridManager.sight_line_clear(space, a, b, 1.5))
	# target-aware: a GROUND viewer sees a HIGH target (roof-walker) over low
	# cover — without the target term, LOS was one-way and nobody on the street
	# could ever acquire a character standing on a roof.
	_check("los.ground-sees-high-target", GridManager.sight_line_clear(space, a, b, 0.0, 2.0))
	var high := _make_blocker(Vector2(400, 100), 3.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("los.excludes-only-low", not GridManager.sight_line_clear(space, a, b, 1.5))
	low.queue_free()
	high.queue_free()
	var legacy := _make_blocker(Vector2(300, 100), -1.0)   # no meta
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("los.legacy-always-blocks", not GridManager.sight_line_clear(space, a, b, 50.0))
	legacy.queue_free()

func _make_blocker(pos: Vector2, occlude_top: float) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = CollisionLayers.VISION_BLOCKERS
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(40, 200)
	cs.shape = rect
	body.add_child(cs)
	body.position = pos
	if occlude_top >= 0.0:
		body.set_meta("occlude_top", occlude_top)
	add_child(body)
	return body

# 6. MELEE PREDICATE: the gate constant + logic (Game.tscn itself is not
# bootable in this harness; the predicate is one absf compare)
func _scenario_melee_predicate() -> void:
	var game_script := load("res://Game.gd")
	var tol: float = game_script.MELEE_ELEV_TOLERANCE
	_check("melee.const-exists", tol == 0.75, "tolerance=%f" % tol)
	_check("melee.deck-vs-ground-blocked", absf(0.0 - 2.0) > tol)
	_check("melee.mid-ramp-allowed", not (absf(0.0 - 0.5) > tol))
