# res://tests/run_hillside_check.gd
# RUN furniture through the REAL game on the tg_hillside_* maps: game.tscn
# loads each map, then its item_spawns are replaced by a re-export's spawns
# (RUN_SPAWNS_ROOT = a Terrain Generation sandbox holding data/Maps.json with
# the new run spawns; the ground/structures/cells of a run export are byte-
# identical to the committed maps, only item_spawns differ) and pushed through
# Game._spawn_items. Checks: every "length" spawn becomes ONE fixed run with a
# RunRenderer, no pick-up options, the guildhall table keeps its 14.1 m frame,
# LOS visibility runs, and a warp away and back restores every run (length,
# rotation) from _capture/_restore_item_state.
# Run:  RUN_SPAWNS_ROOT=<sandbox> godot --headless --path . res://tests/run_hillside_check.tscn
# Without RUN_SPAWNS_ROOT the map's own spawns are used (runs only after the
# re-export has been promoted). Judge by the DONE line.
extends Node2D

var failures := 0
var checks := 0
var game = null


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s %s" % [check_name, detail])
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _spawns_for(mid: String) -> Array:
	var root := OS.get_environment("RUN_SPAWNS_ROOT").replace("\\", "/").trim_suffix("/")
	var path := (root + "/data/Maps.json") if root != "" else "res://data/Maps.json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (d is Dictionary):
		return []
	for e in (d as Dictionary).get("maps", []):
		if String(e.get("id", "")) == mid:
			return e.get("item_spawns", [])
	return []


func _runs() -> Array:
	var out: Array = []
	for it in game.items_in_scene:
		if is_instance_valid(it) and it is Item and not (it as Item).run.is_empty():
			out.append(it)
	return out


func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	var want := {"tg_hillside_upper": 0, "tg_hillside_middle": 0, "tg_hillside_lower": 0, "tg_hillside_harbor": 0}
	for mid in want:
		await _case_map(mid)
	await _case_revisit()
	print("RUN HILLSIDE DONE: %d checks, failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


func _replace_spawns(mid: String) -> int:
	var spawns: Array = _spawns_for(mid)
	for it in game.items_in_scene:
		if is_instance_valid(it):
			GridManager.unregister_object(GridManager.world_to_map(it.global_position), it)
			it.queue_free()
	game.items_in_scene.clear()
	game._spawn_items(spawns)
	var n := 0
	for s in spawns:
		if (s as Dictionary).has("length"):
			n += 1
	return n


func _case_map(mid: String) -> void:
	game.load_map(mid)
	await _frames(4)
	_check("%s.loaded" % mid, game.current_map_id == mid)
	var want_runs: int = _replace_spawns(mid)
	await _frames(3)
	var runs: Array = _runs()
	_check("%s.runs-spawned" % mid, runs.size() == want_runs and want_runs > 0, "%d of %d" % [runs.size(), want_runs])
	var bad := 0
	for r in runs:
		var it: Item = r
		if not (it.fixed and it.collision_layer == 0 and it.get_node_or_null("RunRenderer") != null
				and not it.sprite.visible and game._world_item_options(it).is_empty()):
			bad += 1
	_check("%s.runs-fixed-drawn" % mid, bad == 0, "%d bad" % bad)
	game._update_item_los_visibility()
	_check("%s.los-update" % mid, true)
	if mid == "tg_hillside_middle":
		var guild = null
		for r in runs:
			if absf(float((r as Item).run.get("length", 0.0)) - 601.6) < 0.05:
				guild = r
		_check("middle.guildhall-run", guild != null and absf((guild as Item).rotation - 1.466) < 0.002
			and absf(float((guild as Item).run.get("width", 0.0)) - 83.2) < 0.05,
			"" if guild == null else "rot %.3f at %s" % [(guild as Item).rotation, str((guild as Item).global_position)])


func _case_revisit() -> void:
	# middle again with the new spawns, then away and back: the captured state
	# (not the committed Maps.json spawns) comes back, runs and all
	game.load_map("tg_hillside_middle")
	await _frames(4)
	var want_runs: int = _replace_spawns("tg_hillside_middle")
	await _frames(3)
	var before: Array = []
	for r in _runs():
		before.append([snappedf(float((r as Item).run["length"]), 0.01), snappedf((r as Item).rotation, 0.001)])
	before.sort()
	game.load_map("tg_hillside_lower")
	await _frames(4)
	game.load_map("tg_hillside_middle")
	await _frames(5)
	var after: Array = []
	for r in _runs():
		after.append([snappedf(float((r as Item).run["length"]), 0.01), snappedf((r as Item).rotation, 0.001)])
	after.sort()
	_check("revisit.runs-restored", after.size() == want_runs and str(after) == str(before), "%s -> %s" % [str(before), str(after)])
