# HexIconDatabase.gd - Autoload singleton
# Sibling to HexTileDatabase. Loads res://data/hex_icons.json, which describes
# placeable building/feature icons (castle, fort, farm, factory, university,
# church, ...). Icons are STAMPS that the world-map editor lets you drop on
# top of a HexTile.
@tool  # also load in the editor so the world-map plugin can preview placed icons
extends Node

signal hex_icon_definitions_loaded

# Dictionary keyed by icon id (e.g. "castle", "farm", ...)
var hex_icon_definitions: Dictionary = {}

# Path to the JSON file containing hex icon definitions.
var hex_icon_data_path: String = "res://data/hex_icons.json"

func _ready() -> void:
	load_hex_icon_definitions()

func ensure_loaded() -> void:
	if hex_icon_definitions.is_empty():
		load_hex_icon_definitions()

func load_hex_icon_definitions() -> void:
	var file = FileAccess.open(hex_icon_data_path, FileAccess.READ)
	if file == null:
		printerr("HexIconDatabase: could not open file at: ", hex_icon_data_path)
		return

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_result = json.parse(json_text)
	if parse_result != OK:
		printerr("HexIconDatabase: JSON parse error: ", json.get_error_message())
		return

	hex_icon_definitions.clear()
	hex_icon_definitions = json.data
	print("HexIconDatabase: loaded %d icon definitions" % hex_icon_definitions.size())
	emit_signal("hex_icon_definitions_loaded")

func get_all_icon_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in hex_icon_definitions.keys():
		ids.append(id)
	return ids

func get_icon_ids_by_category(category: String) -> Array[String]:
	var ids: Array[String] = []
	for id in hex_icon_definitions.keys():
		var def = hex_icon_definitions[id]
		if typeof(def) == TYPE_DICTIONARY and def.get("category", "") == category:
			ids.append(id)
	return ids

func get_definition(icon_id: String) -> Variant:
	return hex_icon_definitions.get(icon_id)
