# HexTileDatabase.gd - Autoload singleton
# Mirrors FloorDatabase. Loads res://data/hex_tiles.json on _ready().
# Each entry has an 'id' string key and a payload describing biome game properties
# (walkability, flammable, vision_modifier, movement_cost, resources, ...) plus
# texture paths for the carved hex PNGs. See tools/build_hex_tiles_json.py to
# regenerate the JSON from the contents of res://Assets/HexTiles/<scene>/.
@tool  # also load in the editor so the world-map plugin can preview placed tiles
extends Node

signal hex_tile_definitions_loaded

# Dictionary keyed by tile id (e.g. "plains", "forest_summer", ...)
var hex_tile_definitions: Dictionary = {}

# Path to the JSON file containing hex tile definitions
var hex_tile_data_path: String = "res://data/hex_tiles.json"

func _ready() -> void:
	load_hex_tile_definitions()

func load_hex_tile_definitions() -> void:
	var file = FileAccess.open(hex_tile_data_path, FileAccess.READ)
	if file == null:
		printerr("HexTileDatabase: could not open file at: ", hex_tile_data_path)
		return

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_result = json.parse(json_text)
	if parse_result != OK:
		printerr("HexTileDatabase: JSON parse error: ", json.get_error_message())
		return

	hex_tile_definitions.clear()
	hex_tile_definitions = json.data
	emit_signal("hex_tile_definitions_loaded")

func get_all_tile_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in hex_tile_definitions.keys():
		ids.append(id)
	return ids

# Convenience: return only tile ids whose biome matches `biome`.
func get_tile_ids_by_biome(biome: String) -> Array[String]:
	var ids: Array[String] = []
	for id in hex_tile_definitions.keys():
		var def = hex_tile_definitions[id]
		if typeof(def) == TYPE_DICTIONARY and def.get("biome", "") == biome:
			ids.append(id)
	return ids

# Convenience: return all distinct biome names known to the database.
func get_all_biomes() -> Array[String]:
	var seen: Dictionary = {}
	for def in hex_tile_definitions.values():
		if typeof(def) == TYPE_DICTIONARY and def.has("biome"):
			seen[def["biome"]] = true
	var out: Array[String] = []
	for b in seen.keys():
		out.append(b)
	out.sort()
	return out

# Look up a tile definition by id; returns null if unknown.
func get_definition(tile_id: String) -> Variant:
	return hex_tile_definitions.get(tile_id)
