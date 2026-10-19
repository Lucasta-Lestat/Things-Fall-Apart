extends Node2D
# Real-game smoke for the Grass Lab hillside town (tg_hillside_*): boots
# game.tscn, loads each map through Game.load_map and checks the high-ground
# contracts on REAL terraced data (the elevation harness only uses synthetic
# terrain):
#  (1) relief_los turns on (terrain spans many stories),
#  (2) per-tile terrain comes from cells.json tile_elev, not nearest-cell,
#  (3) the party stands ON the ground (height above ground ~0, not "high
#      layer") and roof view stays off although the ground is 0.5..17 stories,
#  (4) NPCs on the ground are not on the high layer (so ground view shows them),
#  (5) every warp's target map + target_spawn exist, and the warp is reachable
#      on foot from the arrival point (A* with the 0.55-story step gate),
#  (6) sight cones use elevation bands: cliff occluders were built, every
#      cone culls on GROUND + its viewer's single band bit (pink: the band
#      above), no occluder carries bit 1, and the summit's band is not
#      clamped (its own brow never shadows it).
# Headless-safe. Run:
#   godot --headless --path . res://tests/hillside_town_check.tscn
# Prints PASS/FAIL lines, then "HILLSIDE DONE failures=N"; exit code = failures.
const MAPS := ["tg_hillside_upper", "tg_hillside_middle", "tg_hillside_lower", "tg_hillside_harbor"]

var game: Node = null
# The start map's NPCs spawn inside add_child(game), before current_scene points
# at the game, so their ai.gd caches THIS node as `game` (ai.gd:414) and reads
# characters_in_scene from it until the first load_map frees them.
var characters_in_scene: Array = []
var _fails := 0
var _checks := 0


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s%s" % ["PASS" if ok else "FAIL", check_name, (": " + detail) if detail != "" else ""])


func _await_frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame


func _ready() -> void:
	await get_tree().process_frame
	var game_scene: PackedScene = load("res://game.tscn")
	game = game_scene.instantiate()
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(5)
	for map_id in MAPS:
		await _check_map(String(map_id))
	print("HILLSIDE DONE failures=%d (%d checks)" % [_fails, _checks])
	get_tree().quit(_fails)


func _tile_elev_table(cell_graph_path: String) -> Dictionary:
	var f := FileAccess.open(cell_graph_path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var te: Variant = (parsed as Dictionary).get("tile_elev", null)
	return te if te is Dictionary else {}


func _check_map(map_id: String) -> void:
	game.load_map(map_id)
	await _await_frames(20)
	var data: Dictionary = MapDatabase.get_map_data(map_id)
	_check("%s.loaded" % map_id, String(game.current_map_id) == map_id, "current=%s" % game.current_map_id)
	# (1) relief LOS model is on for terraced terrain
	_check("%s.relief-los-on" % map_id, GridManager.relief_los,
		"terrain %.2f..%.2f" % [GridManager.terrain_min, GridManager.terrain_max])
	# (2) terrain per tile == cells.json tile_elev (sampled on a stride)
	var te := _tile_elev_table(String(data.get("cell_graph", "")))
	var cols: int = int(te.get("cols", 0))
	var rows: int = int(te.get("rows", 0))
	var vals: Array = te.get("data", [])
	var bad := 0
	var n := 0
	if cols > 0 and rows > 0 and vals.size() == cols * rows:
		for i in range(0, cols * rows, 37):
			var t := Vector2i(i % cols, floori(float(i) / float(cols)))
			n += 1
			if absf(GridManager.terrain_elev(t) - float(vals[i])) > 0.002:
				bad += 1
	_check("%s.tile-elev-consumed" % map_id, n > 0 and bad == 0, "%d sampled, %d mismatched" % [n, bad])
	# (3) party on the ground, roof view off
	var party_ok := true
	var party_detail := ""
	var leader_elev := 0.0
	for pc in game.party_chars:
		if not is_instance_valid(pc):
			continue
		var hag: float = pc.height_above_ground()
		leader_elev = maxf(leader_elev, float(pc.get_elevation()))
		if GridManager.is_high_layer(pc) or absf(hag) > 0.3:
			party_ok = false
			party_detail += " %s hag=%.2f" % [pc.name, hag]
	_check("%s.party-on-ground" % map_id, party_ok and not game.party_chars.is_empty(),
		"elev %.2f stories%s" % [leader_elev, party_detail])
	_check("%s.roof-view-off" % map_id, not bool(game.roof_view))
	# (4) ground NPCs are on the ground layer
	var npc_high := 0
	var npc_n := 0
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or c in game.party_chars:
			continue
		npc_n += 1
		if GridManager.is_high_layer(c):
			npc_high += 1
	_check("%s.npcs-ground-layer" % map_id, npc_high == 0, "%d npcs, %d high-layer" % [npc_n, npc_high])
	# (5) warps: data pairing + reachable on foot from the default arrival
	var spawns: Dictionary = data.get("player_spawns", {})
	var dflt: Dictionary = spawns.get("default", {})
	var dpos: Array = dflt.get("position", [0, 0])
	var start := GridManager.world_to_map(Vector2(float(dpos[0]), float(dpos[1])))
	for w in data.get("warp_points", []):
		var wd: Dictionary = w
		var target: String = String(wd.get("target_map", ""))
		var tspawn: String = String(wd.get("target_spawn", ""))
		var tdata: Dictionary = MapDatabase.get_map_data(target)
		var tsp: Dictionary = tdata.get("player_spawns", {})
		_check("%s.warp-pair.%s" % [map_id, String(wd.get("id", "?"))],
			not tdata.is_empty() and tsp.has(tspawn), "-> %s / %s" % [target, tspawn])
		var wp: Array = wd.get("position", [0, 0])
		var goal := GridManager.world_to_map(Vector2(float(wp[0]), float(wp[1])))
		var reached := goal == start or not GridManager.find_path(start, goal).is_empty()
		if not reached:
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if not GridManager.find_path(start, goal + d).is_empty():
					reached = true
					break
		_check("%s.warp-reachable.%s" % [map_id, String(wd.get("id", "?"))], reached,
			"from %s to %s" % [start, goal])
	# (6) elevation-band sight cones on real terraced data
	var cliffs: Node2D = game.map_loader.cliff_occluders
	_check("%s.cliff-occluders-built" % map_id, is_instance_valid(cliffs) and cliffs.get_child_count() > 0,
		"%d runs" % (cliffs.get_child_count() if is_instance_valid(cliffs) else -1))
	var top_band: int = GridManager.cone_band(GridManager.terrain_max)
	_check("%s.summit-band-unclamped" % map_id, top_band < CollisionLayers.SIGHT_BAND_COUNT - 1
		and (GridManager.band_mask_below(GridManager.terrain_max) & GridManager.cone_band_bit(top_band)) == 0,
		"base %d, summit %.2f -> band %d" % [GridManager.cone_band_base, GridManager.terrain_max, top_band])
	var g1 := 0
	for s in game.map_loader.get_children():
		for c in s.get_children():
			if c is LightOccluder2D and ((c as LightOccluder2D).occluder_light_mask & CollisionLayers.SIGHT_MASK_GROUND) != 0:
				g1 += 1
	_check("%s.no-occluder-on-bit-1" % map_id, g1 == 0, "%d occluders carry bit 1" % g1)
	game.set_stealth_mode(true)
	await _await_frames(2)
	var cones := 0
	var cone_bad := ""
	for c in game.characters_in_scene:
		if not is_instance_valid(c):
			continue
		for cone_name in ["LineOfSight", "NPCLineOfSight", "NPCLineOfSightHigh"]:
			var l := c.get_node_or_null(cone_name) as PointLight2D
			if l == null:
				continue
			cones += 1
			var want: int = c.elevated_cone_mask() if cone_name == "NPCLineOfSightHigh" else c.sight_cone_mask()
			var m: int = l.shadow_item_cull_mask
			# GROUND (so light_mask-1 art receives the shadows) + one band bit
			var b: int = m & ~CollisionLayers.SIGHT_MASK_GROUND
			if m != want or (m & CollisionLayers.SIGHT_MASK_GROUND) == 0 or b < (1 << CollisionLayers.SIGHT_BAND_SHIFT) or (b & (b - 1)) != 0:
				cone_bad += " %s/%s=%d(want %d)" % [c.name, cone_name, m, want]
	game.set_stealth_mode(false)
	_check("%s.cones-on-band-bits" % map_id, cones > 0 and cone_bad == "", "%d cones%s" % [cones, cone_bad])
