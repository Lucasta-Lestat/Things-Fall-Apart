# MapDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "MapDatabase"
extends Node

var _maps: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/maps.json"
	if not FileAccess.file_exists(file_path):
		push_error("Map Database not found at: " + file_path)
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)
	print("====== Map Database =======")
	if error == OK:
		var data = json.get_data()
		for entry in data.get("maps", []):
			_maps[entry["id"]] = entry
		print("Loaded %d maps" % _maps.size())
	else:
		push_error("Failed to parse Map JSON: " + json.get_error_message())
	print("====== End Map Database ======")

func get_map_data(map_id: String) -> Dictionary:
	if _maps.has(map_id):
		return _maps[map_id]
	push_error("Map ID not found: " + map_id)
	return {}

func get_all_map_ids() -> Array:
	return _maps.keys()

func get_warp_targets(map_id: String) -> Array:
	## Returns all maps reachable from this map via warp points.
	var data = get_map_data(map_id)
	var targets: Array = []
	for warp in data.get("warp_points", []):
		var target = warp.get("target_map", "")
		if not target.is_empty() and target not in targets:
			targets.append(target)
	return targets
