# res://tests/sight_heights_check.gd
# Headless assertion harness for TG export contract 2's sight heights (P2-A,
# TG docs/export_contract.md): building walls that occlude by their stories,
# see-over "hedge" rows that still block walking, curtain pieces at their drawn
# height, and tree rows carrying "stories". The rows are INJECTED through
# MapLoader._spawn_geo_structure exactly as an export would write them, so this
# runs before Perrow train 2 re-exports anything; every contract-2 row has a
# contract-1 twin that must keep today's behaviour.
#   flat  : the legacy rule (an occluder clears when max(viewer, target) + eye
#           tops it) and the GROUND / HIGH cone bits
#   relief: synthetic terraces (8.0 | 8.4 | 12.0 stories): interpolated eye
#           line and the elevation-band cone bits
# Run:  godot --headless --path . res://tests/sight_heights_check.tscn
# Prints PASS/FAIL lines and "SIGHT HEIGHTS DONE failures=N"; exits 0 iff all pass.
extends Node2D

const MAP_LOADER := preload("res://Structures/MapLoader.gd")

# game-stub properties for MapLoader's current_scene fallback
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
	_scenario_hedge_def()
	await _scenario_flat()
	await _scenario_relief()
	print("SIGHT HEIGHTS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)


func _mask(inst: Node) -> int:
	return (inst.get_node("Occluder") as LightOccluder2D).occluder_light_mask


func _top(inst: Node) -> float:
	return float(inst.get_meta("occlude_top"))


func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


# Exported rows, as MapExporter writes them (px). A horizontal wall run
# centred on (x, y), 240 px long.
func _wall_row(x: float, y: float, half: float, extra: Dictionary = {}) -> Dictionary:
	var r := {"kind": "wall", "a": [x - 120.0, y], "b": [x + 120.0, y], "half": half,
		"id": "stone_wall", "hp": 80}
	r.merge(extra, true)
	return r


func _vwall_row(x: float, y0: float, y1: float, extra: Dictionary = {}) -> Dictionary:
	var r := {"kind": "wall", "a": [x, y0], "b": [x, y1], "half": 7.0, "id": "stone_wall", "hp": 80}
	r.merge(extra, true)
	return r


func _hedge_row(x: float, y: float) -> Dictionary:
	return {"kind": "tree", "pos": [x, y], "r": 24.0, "id": "hedge", "hp": 40,
		"occlude_h": 0.45, "stories": 0.5}


# 1. The structure definition the hedge id resolves to.
func _scenario_hedge_def() -> void:
	var d = StructureDatabase.get_structure_data(&"hedge")
	_check("def.hedge-exists", d != null)
	if d == null:
		return
	_check("def.hedge-flammable", bool(d.flammable))
	_check("def.hedge-label", StructureDatabase.get_structure_label(&"hedge") == "Hedge",
		StructureDatabase.get_structure_label(&"hedge"))
	_check("def.tree-unchanged", StructureDatabase.get_structure_data(&"tree") != null
		and int(StructureDatabase.get_structure_data(&"tree").max_health) == 80)


# 2. FLAT MAP (relief_los off). One structure per column x (tile centres); the
# viewer stands at (x, 352), the target at (x, 992), the structure across y = 672.
func _scenario_flat() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(48 * 64, 20 * 64)
	GridManager.refresh_terrain_stats()
	_check("flat.no-relief", not GridManager.relief_los)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	var cols := {
		"c1_wall": 224.0, "c2_wall1": 544.0, "c2_wall2": 864.0, "c2_wall3": 1184.0,
		"c2_hedge": 1504.0, "c1_hedge": 1824.0, "c2_tree": 2144.0,
		"c1_curtain": 2464.0, "c2_curtain": 2784.0,
	}
	var st: Dictionary = {}
	st["c1_wall"] = ml._spawn_geo_structure(_wall_row(cols["c1_wall"], 672.0, 7.0), null, 64)
	st["c2_wall1"] = ml._spawn_geo_structure(_wall_row(cols["c2_wall1"], 672.0, 7.0, {"occlude_h": 1.0}), null, 64)
	st["c2_wall2"] = ml._spawn_geo_structure(_wall_row(cols["c2_wall2"], 672.0, 7.0, {"occlude_h": 2.0}), null, 64)
	st["c2_wall3"] = ml._spawn_geo_structure(_wall_row(cols["c2_wall3"], 672.0, 7.0, {"occlude_h": 3.0}), null, 64)
	st["c2_hedge"] = ml._spawn_geo_structure(_hedge_row(cols["c2_hedge"], 672.0), null, 64)
	# contract 1: the same plan hedge exported as a bare tree circle
	st["c1_hedge"] = ml._spawn_geo_structure({"kind": "tree", "pos": [cols["c1_hedge"], 672.0], "r": 24.0,
		"id": "tree", "hp": 40}, null, 64)
	st["c2_tree"] = ml._spawn_geo_structure({"kind": "tree", "pos": [cols["c2_tree"], 672.0], "r": 60.0,
		"id": "tree", "hp": 80, "stories": 1.3}, null, 64)
	st["c1_curtain"] = ml._spawn_geo_structure(_wall_row(cols["c1_curtain"], 672.0, 35.2, {"occlude_h": 1.6}), null, 64)
	st["c2_curtain"] = ml._spawn_geo_structure(_wall_row(cols["c2_curtain"], 672.0, 35.2, {"occlude_h": 2.17}), null, 64)
	await _settle()
	var space := get_world_2d().direct_space_state
	var los := func(key: String, viewer_elev: float) -> bool:
		var x: float = cols[key]
		return GridManager.sight_line_clear(space, Vector2(x, 352.0), Vector2(x, 992.0), viewer_elev, 0.0)
	var ground := CollisionLayers.SIGHT_MASK_GROUND
	var high := CollisionLayers.SIGHT_MASK_HIGH

	# --- building walls (G4): a 1-story wall is exactly today's default wall
	_check("flat.c1-wall-default", is_equal_approx(_top(st["c1_wall"]), 1.0)
		and _mask(st["c1_wall"]) == ground, "top=%.2f mask=%d" % [_top(st["c1_wall"]), _mask(st["c1_wall"])])
	_check("flat.c2-1story-wall-equals-c1", is_equal_approx(_top(st["c2_wall1"]), _top(st["c1_wall"]))
		and _mask(st["c2_wall1"]) == _mask(st["c1_wall"]))
	_check("flat.c2-2story-wall-high-bit", is_equal_approx(_top(st["c2_wall2"]), 2.0)
		and _mask(st["c2_wall2"]) == (ground | high), "top=%.2f mask=%d" % [_top(st["c2_wall2"]), _mask(st["c2_wall2"])])
	_check("flat.ground-viewer-blocked-by-1story", not los.call("c2_wall1", 0.0))
	_check("flat.deck-viewer-sees-over-1story", los.call("c2_wall1", 1.44) and los.call("c1_wall", 1.44))
	_check("flat.deck-viewer-blocked-by-2story", not los.call("c2_wall2", 1.44))
	_check("flat.roof-viewer-sees-over-2story", los.call("c2_wall2", 2.0))
	_check("flat.roof-viewer-blocked-by-3story", not los.call("c2_wall3", 2.0))

	# --- hedges (G5): see-over, cone-transparent, still an obstacle
	var hg: Structure = st["c2_hedge"]
	var hx: float = cols["c2_hedge"]
	var hedge_tile := GridManager.world_to_map(Vector2(hx, 672.0))
	_check("flat.hedge-id", hg.structure_id == &"hedge" and hg.max_health == 40 and hg.flammable,
		"id=%s hp=%d flammable=%s" % [String(hg.structure_id), hg.max_health, str(hg.flammable)])
	_check("flat.hedge-no-cone-shadow", _mask(hg) == 0, "mask=%d" % _mask(hg))
	_check("flat.hedge-top-below-eye", is_equal_approx(_top(hg), 0.45))
	_check("flat.hedge-ground-viewer-sees-over", los.call("c2_hedge", 0.0))
	_check("flat.hedge-blocks-walking", not GridManager.would_walk(hedge_tile)
		and hg.occupied_tiles.has(hedge_tile), "tile %s" % str(hedge_tile))
	_check("flat.hedge-solid-body", (hg.collision_layer & CollisionLayers.STRUCTURES) != 0
		and not hg.is_deck)
	var c1h: Structure = st["c1_hedge"]
	_check("flat.c1-hedge-is-a-tree", c1h.structure_id == &"tree" and is_equal_approx(_top(c1h), 2.0)
		and _mask(c1h) == (ground | high) and not los.call("c1_hedge", 0.0))
	# same tree collider and obstacle tiles under both contracts: movement is unchanged
	var c1_cs := (c1h.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	var c2_cs := (hg.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	_check("flat.hedge-collider-unchanged", c1_cs != null and c2_cs != null
		and is_equal_approx(c1_cs.radius, c2_cs.radius) and c1h.occupied_tiles.size() == hg.occupied_tiles.size())

	# --- tree rows: "stories" is carried for P3-F; the trunk keeps its 2 stories
	var tree_c2: Structure = st["c2_tree"]
	_check("flat.c2-tree-keeps-trunk-default", is_equal_approx(_top(tree_c2), 2.0) and _mask(tree_c2) == (ground | high),
		"top=%.2f mask=%d" % [_top(tree_c2), _mask(tree_c2)])

	# --- curtains (L31): the drawn merlon top 2.17 vs contract 1's 1.6
	_check("flat.c1-curtain-no-high-bit", _mask(st["c1_curtain"]) == ground)
	_check("flat.c2-curtain-high-bit", is_equal_approx(_top(st["c2_curtain"]), 2.17)
		and _mask(st["c2_curtain"]) == (ground | high))
	_check("flat.deck-viewer-sees-over-c1-curtain", los.call("c1_curtain", 1.44))
	_check("flat.deck-viewer-blocked-by-c2-curtain", not los.call("c2_curtain", 1.44))
	_check("flat.tower-viewer-sees-over-c2-curtain", los.call("c2_curtain", 2.0))
	ml.queue_free()
	await _settle()


# Synthetic terraces (the elevation harness's): 8.0 (x <= 9), 8.4 (x 10..14),
# a 3.6-story cliff up to 12.0 (x >= 15).
func _build_terraces() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(32 * 64, 20 * 64)
	for y in 20:
		for x in 32:
			GridManager.elevations[Vector2i(x, y)] = 8.0 if x <= 9 else (8.4 if x <= 14 else 12.0)
	GridManager.refresh_terrain_stats()


func _bbit(elev: float) -> int:
	return GridManager.cone_band_bit(GridManager.cone_band(elev))


# 3. RELIEF MAP. Everything stands across x = 520 on the 8.0 terrace (tile 8,
# both faces flat, so no terrain-following); the target is at tile (2, 5).
func _scenario_relief() -> void:
	_build_terraces()
	_check("relief.on", GridManager.relief_los)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	var space := get_world_2d().direct_space_state
	var target := Vector2(160.0, 352.0)
	var hill := Vector2(1056.0, 352.0)    # tile (16, 5) on the 12.0 terrace
	var street := Vector2(800.0, 352.0)   # tile (12, 5) on the 8.4 terrace
	var high := CollisionLayers.SIGHT_MASK_HIGH

	# --- a 1-story building wall: the hill viewer sees over it, the street does not
	var w1: Structure = ml._spawn_geo_structure(_vwall_row(520.0, 200.0, 500.0, {"occlude_h": 1.0}), null, 64)
	await _settle()
	_check("relief.1story-top", is_equal_approx(_top(w1), 9.0) and not w1.has_meta("occlude_rel_h"),
		"top=%.2f" % _top(w1))
	_check("relief.1story-mask", _mask(w1) == (high | GridManager.band_mask_below(9.0)), "mask=%d" % _mask(w1))
	_check("relief.1story-shadows-street-cone", (_mask(w1) & _bbit(8.4)) != 0)
	_check("relief.1story-hill-cone-sees-over", (_mask(w1) & _bbit(12.0)) == 0)
	_check("relief.street-blocked-by-1story", not GridManager.sight_line_clear(space, street, target, 8.4, 8.0))
	_check("relief.hill-sees-over-1story", GridManager.sight_line_clear(space, hill, target, 12.0, 8.0))
	w1.free()
	await _settle()

	# --- the same wall as a 3-story building wall: the hill viewer loses the line
	var w3: Structure = ml._spawn_geo_structure(_vwall_row(520.0, 200.0, 500.0, {"occlude_h": 3.0}), null, 64)
	await _settle()
	_check("relief.3story-top", is_equal_approx(_top(w3), 11.0), "top=%.2f" % _top(w3))
	_check("relief.3story-shadows-2-up-cone", (_mask(w3) & _bbit(10.0)) != 0 and (_mask(w3) & _bbit(12.0)) == 0,
		"mask=%d" % _mask(w3))
	_check("relief.hill-blocked-by-3story", not GridManager.sight_line_clear(space, hill, target, 12.0, 8.0))
	w3.free()
	await _settle()

	# --- a hedge: no cone shadow, ground eyes see over it, the tile is blocked
	var hg: Structure = ml._spawn_geo_structure(_hedge_row(520.0, 352.0), null, 64)
	await _settle()
	_check("relief.hedge-no-cone-shadow", _mask(hg) == 0, "mask=%d" % _mask(hg))
	_check("relief.hedge-street-sees-over", GridManager.sight_line_clear(space, street, target, 8.4, 8.0))
	_check("relief.hedge-blocks-walking", not GridManager.would_walk(GridManager.world_to_map(Vector2(520.0, 352.0))))
	hg.free()
	await _settle()

	# --- curtains: a walker 1.6 up beside the wall (x 600) sees over contract 1's
	# 1.6, not over contract 2's drawn 2.17
	var walker := Vector2(600.0, 352.0)
	var cu1: Structure = ml._spawn_geo_structure(_vwall_row(520.0, 200.0, 500.0, {"occlude_h": 1.6}), null, 64)
	await _settle()
	_check("relief.walker-sees-over-c1-curtain", GridManager.sight_line_clear(space, walker, target, 9.6, 8.0))
	cu1.free()
	await _settle()
	var cu2: Structure = ml._spawn_geo_structure(_vwall_row(520.0, 200.0, 500.0, {"occlude_h": 2.17}), null, 64)
	await _settle()
	_check("relief.c2-curtain-mask", _mask(cu2) == (high | GridManager.band_mask_below(10.17)), "mask=%d" % _mask(cu2))
	_check("relief.walker-blocked-by-c2-curtain", not GridManager.sight_line_clear(space, walker, target, 9.6, 8.0))
	# a tower deck 1.44 up on the hill clears the 10.17 top (eye line ~10.7 there)
	_check("relief.hill-tower-sees-over-c2-curtain", GridManager.sight_line_clear(space, hill, target, 13.44, 8.0))
	cu2.free()
	await _settle()

	# --- a terrain-following pad-edge wall re-bases its OWN occlude_h on the ground
	for x in range(3, 7):
		for y in range(12, 16):
			GridManager.elevations[Vector2i(x, y)] = 9.0
	var pw: Structure = ml._spawn_geo_structure(_vwall_row(190.0, 768.0, 1024.0, {"occlude_h": 2.0}), null, 64)
	_check("relief.follow-wall-keeps-occlude-h", pw.has_meta("occlude_rel_h")
		and is_equal_approx(float(pw.get_meta("occlude_rel_h")), 2.0))
	pw.free()
	ml.queue_free()
	await _settle()
