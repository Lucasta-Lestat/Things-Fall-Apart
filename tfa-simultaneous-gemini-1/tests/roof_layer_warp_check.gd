# res://tests/roof_layer_warp_check.gd
# Real-game check that Game.roof_layer follows the LOADED map's roof cover
# across warps and a save-load. Every map change is Game._unload_current_map
# (MapLoader's children only queue_free) then the new map's load in the same
# frame, so the previous map's "RoofLayer" still holds that name while the new
# one spawns: the new sprite is auto-renamed and a name lookup returned the
# dying node. Game.roof_layer then pointed at it (and at a freed object once
# the frame ended), so roof_view stopped showing or hiding the new map's roofs.
# Boots game.tscn into tg_hillside_lower (all four town bands ship painted
# roofs), then lower -> harbor -> middle -> lower and a save-load
# (build_save_dict / load_save: a same-map reload, the worst case). After each:
#   same-frame   right after load_map returns, Game.roof_layer is the one live
#                roof cover under MapLoader: in the tree, not queued for
#                deletion, drawing this map's images.roofs, hidden in the
#                ground view
#   settled      the same a few frames later (valid, not freed with the old map)
#   view-drive   Ctrl+scroll up (step_view_layer) shows that layer through
#                Game._process, back down hides it again
#   loader-refs  MapLoader's other per-map references (ground, canopy, cliff
#                occluders, map lights) are null or live, never the old map's
# Headless-safe. Run:
#   godot --headless --audio-driver Dummy --path . res://tests/roof_layer_warp_check.tscn
# Prints PASS/FAIL lines, then "ROOF LAYER WARP CHECK DONE: N checks, M FAIL";
# exit code 1 on any failure.
extends Node2D

const START := "tg_hillside_lower"
# [target map, from map] in visiting order; "" from = a save-load of the current map
const STEPS := [["tg_hillside_harbor", "tg_hillside_lower"], ["tg_hillside_middle", "tg_hillside_harbor"],
	["tg_hillside_lower", "tg_hillside_middle"], ["tg_hillside_lower", ""]]

var game: Node = null
# The start map's NPCs spawn inside add_child(game), before current_scene points
# at the game, so their ai.gd caches THIS node as `game` and reads
# characters_in_scene from it until the first load_map frees them.
var characters_in_scene: Array = []
var _checks := 0
var _fails := 0


func _check(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s%s" % ["PASS" if ok else "FAIL", check_name, (": " + detail) if detail != "" else ""])


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame


func _ready() -> void:
	# A SCRIPT ERROR aborts the coroutine; don't hang waiting for quit().
	get_tree().create_timer(900.0, true).timeout.connect(func():
		print("FAIL watchdog timeout (coroutine aborted?) after %d checks, %d FAIL" % [_checks, _fails])
		get_tree().quit(99))
	await get_tree().process_frame
	var game_scene: PackedScene = load("res://game.tscn")
	game = game_scene.instantiate()
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(5)
	if String(game.current_map_id) != START:
		game.load_map(START)
		await _frames(10)
	_check("boot.on-start-map", String(game.current_map_id) == START, "current=%s" % game.current_map_id)
	var prev: Node = _live_roof_cover(START)
	_check_layer("boot", START, prev)
	await _check_view_drive("boot")
	for step in STEPS:
		var target: String = String(step[0])
		var from: String = String(step[1])
		var tag: String = ("%s->%s" % [from, target]) if from != "" else ("save-load:%s" % target)
		# Variant: with the bug this is the previous map's freed node, and a
		# typed assignment of a freed instance aborts the coroutine
		var old: Variant = game.roof_layer
		if from != "":
			game.load_map(target, from)
		else:
			var d: Dictionary = game.build_save_dict()
			game.load_save(d)
		# same frame: the old map's nodes are still in the tree, queued
		_check("%s.loaded" % tag, String(game.current_map_id) == target, "current=%s" % game.current_map_id)
		var live: Node = _live_roof_cover(target)
		_check_layer(tag + ".same-frame", target, live)
		_check("%s.fresh-layer" % tag, live != null and live != old, "old %s, new %s" % [str(old), str(live)])
		# (same frame: a freed object reads as null, so only now can a reference
		# to the old map's node be told from no node at all)
		_check_loader_refs(tag + ".same-frame")
		await _frames(10)
		_check_layer(tag + ".settled", target, _live_roof_cover(target))
		_check("%s.old-layer-freed" % tag, not is_instance_valid(old))
		_check_loader_refs(tag + ".settled")
		await _check_view_drive(tag)
	print("ROOF LAYER WARP CHECK DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 or _checks == 0 else 0)


func _alive(n: Variant) -> bool:
	return n != null and is_instance_valid(n) and (n as Node).is_inside_tree() and not (n as Node).is_queued_for_deletion()


# The loaded map's roof cover, found WITHOUT Game.roof_layer or a name: every
# MapLoader child not queued for deletion that is a procedural RoofLayer or a
# sprite drawing this map's painted images.roofs. Exactly one is expected
# (null and a FAIL otherwise).
func _live_roof_cover(map_id: String) -> Node:
	var roofs_path: String = String(MapDatabase.get_map_data(map_id).get("images", {}).get("roofs", ""))
	var found: Array = []
	for c in game.map_loader.get_children():
		if c.is_queued_for_deletion():
			continue
		if c is RoofLayer:
			found.append(c)
		elif c is Sprite2D and roofs_path != "" and (c as Sprite2D).texture != null \
				and (c as Sprite2D).texture.resource_path == roofs_path:
			found.append(c)
	_check("%s.one-live-roof-cover" % map_id, found.size() == 1, "%d found (%s)" % [found.size(), roofs_path])
	return found[0] if found.size() == 1 else null


func _check_layer(tag: String, map_id: String, live: Node) -> void:
	var rl: Variant = game.roof_layer
	var ok: bool = _alive(rl) and live != null and rl == live and (rl as Node).get_parent() == game.map_loader
	var detail := "roof_layer %s (valid %s), live cover %s" % [str(rl) if is_instance_valid(rl) else "<freed>",
		str(is_instance_valid(rl)), str(live)]
	if is_instance_valid(rl):
		var n := rl as Node
		detail += ", in tree %s, queued %s, name %s" % [str(n.is_inside_tree()), str(n.is_queued_for_deletion()), n.name]
	_check("%s.roof-layer-is-live-cover" % tag, ok, detail)
	var painted: String = String(MapDatabase.get_map_data(map_id).get("images", {}).get("roofs", ""))
	var tex_ok: bool = _alive(rl) and rl is Sprite2D and (rl as Sprite2D).texture != null \
		and (rl as Sprite2D).texture.resource_path == painted
	_check("%s.draws-this-maps-roofs" % tag, tex_ok, painted)
	_check("%s.visible-matches-view" % tag, _alive(rl) and (rl as CanvasItem).visible == bool(game.roof_view),
		"roof_view %s" % str(game.roof_view))


# Ctrl+scroll up pins the roof slice; Game._process applies it to roof_layer.
func _check_view_drive(tag: String) -> void:
	var live: Node = game.roof_layer if _alive(game.roof_layer) else null
	game.step_view_layer(true)
	await _frames(3)
	_check("%s.view-up-shows-roofs" % tag, bool(game.roof_view) and live != null and (live as CanvasItem).visible,
		"roof_view %s, layer %s" % [str(game.roof_view), str(live)])
	game.step_view_layer(false)
	await _frames(3)
	_check("%s.view-down-hides-roofs" % tag, not bool(game.roof_view) and live != null and not (live as CanvasItem).visible,
		"roof_view %s" % str(game.roof_view))
	game.roof_view_override = -1


func _check_loader_refs(tag: String) -> void:
	var ml: Node = game.map_loader
	var bad: Array = []
	for prop in ["structured_ground", "canopy_layer", "cliff_occluders", "map_lights", "roof_layer"]:
		var v: Variant = ml.get(prop)
		if v == null:
			continue
		if not _alive(v) or (v as Node).get_parent() != ml:
			bad.append(prop)
	_check("%s.loader-refs-live" % tag, bad.is_empty() and _alive(ml.get("structured_ground")), "stale: %s" % [bad])
