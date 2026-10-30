# res://tests/boot_items_check.gd
# Regression harness: booting straight into a map keeps its authored items.
# Game.current_map_id starts as the launch map (_start_map_id: Perrow's
# tg_hillside_lower, or TFA_START_MAP), so the first load_map's
# _unload_current_map ran while NO map was loaded. _capture_item_state then
# recorded [] for the launch map and _restore_item_state freed every item the
# load had just spawned: a new game opened on a bare Perrow, and the empty
# record stuck on every revisit. Unlike the other game.tscn harnesses this one
# does NOT clear current_map_id: _ready boots the real launch path.
# Run:  godot --headless --path . res://tests/boot_items_check.tscn
# Judge by PASS/FAIL lines and the DONE line (startup noise is normal).
extends Node2D

var failures := 0
var game = null

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame

## Sorted ids of the live world items: compared across the warp, so a lost,
## duplicated or swapped item shows up even when the count happens to match.
func _item_ids() -> Array:
	var out: Array = []
	for it in game.items_in_scene:
		if is_instance_valid(it) and not it.is_queued_for_deletion():
			out.append(str(it.id))
	out.sort()
	return out

## First warp target of the loaded map that MapDatabase can load.
func _warp_target() -> String:
	for w in game.current_map_data.get("warp_points", []):
		if not (w is Dictionary):
			continue
		var target: String = str((w as Dictionary).get("target_map", ""))
		if not target.is_empty() and target != game.current_map_id \
				and not MapDatabase.get_map_data(target).is_empty():
			return target
	return ""

func _ready() -> void:
	TimeManager.pause_time()
	# Let the initial scene-ready cascade finish first (law_persist_test): a node
	# added to root DURING it never receives NOTIFICATION_READY.
	await get_tree().process_frame
	var game_scene: PackedScene = load("res://game.tscn")
	game = game_scene.instantiate()
	var start: String = str(game.current_map_id)
	_check("boot.start-map-set", not start.is_empty() and not MapDatabase.get_map_data(start).is_empty(),
		"current_map_id=%s" % start)
	# The launch path: _ready's own load_map(current_map_id) loads the map, so
	# the game must already BE current_scene when it enters the tree (AIs
	# spawned by that load cache current_scene as their Game). A scene change
	# sets current_scene before add_child; this harness steps aside first and
	# stays alive as a plain root child.
	get_tree().current_scene = null
	get_tree().change_scene_to_node(game)
	await _await_frames(6)

	_check("boot.map-loaded", str(game.current_map_id) == start and not game.current_map_data.is_empty(),
		"current_map_id=%s" % str(game.current_map_id))
	var authored: int = (game.current_map_data.get("item_spawns", []) as Array).size()
	var boot_ids: Array = _item_ids()
	print("INFO %s: %d authored item rows, %d live items after boot" % [start, authored, boot_ids.size()])
	_check("boot.items-spawned", authored > 0 and not boot_ids.is_empty(),
		"%d authored rows, %d live items" % [authored, boot_ids.size()])
	# Nothing may be captured while no map is loaded: the launch map has no
	# visited state yet, and its region bucket holds no NPC snapshot.
	_check("boot.no-item-capture-before-load", not game.item_state_per_map.has(start),
		"item_state_per_map[%s] = %s" % [start, str(game.item_state_per_map.get(start))])
	var bucket_key: String = game._npc_bucket_key()
	_check("boot.no-npc-capture-before-load", not game.npc_state_per_region.has(bucket_key),
		"npc_state_per_region[%s] = %s" % [bucket_key, str(game.npc_state_per_region.get(bucket_key))])

	# Warp out and back: the real unload captures the launch map's items, and
	# the revisit restores the same set.
	var out: String = _warp_target()
	_check("warp.target-found", not out.is_empty(), "no loadable warp target on %s" % start)
	if out.is_empty():
		_finish()
		return
	game.load_map(out, start)
	await _await_frames(6)
	_check("warp.left-start", str(game.current_map_id) == out, "current_map_id=%s" % str(game.current_map_id))
	var captured: Array = game.item_state_per_map.get(start, [])
	_check("warp.start-items-captured", captured.size() == boot_ids.size(),
		"captured %d of %d" % [captured.size(), boot_ids.size()])
	game.load_map(start, out)
	await _await_frames(6)
	_check("warp.back-on-start", str(game.current_map_id) == start, "current_map_id=%s" % str(game.current_map_id))
	var back_ids: Array = _item_ids()
	_check("warp.items-survive", not back_ids.is_empty() and back_ids == boot_ids,
		"%d live items after the round trip, %d after boot" % [back_ids.size(), boot_ids.size()])
	_finish()

func _finish() -> void:
	print("BOOT ITEMS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)
