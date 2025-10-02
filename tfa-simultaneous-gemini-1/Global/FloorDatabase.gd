# FloorDatabase.gd - Autoload singleton
# Add this to your project as an autoload named "FloorDatabase"
extends Node

signal floor_definitions_loaded

# Dictionary to store all floor definitions
var floor_definitions: Dictionary = {}

# Path to the JSON file containing floor definitions
var floor_data_path: String = "res://data/floors.json"

func _ready():
	load_floor_definitions()

func load_floor_definitions():
	var file = FileAccess.open(floor_data_path, FileAccess.READ)
	if file == null:
		printerr("Error: Could not open floor definitions file at: ", floor_data_path)
		return
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	
	if parse_result != OK:
		print("Error parsing JSON: ", json.get_error_message())
		return
	floor_definitions.clear()

	floor_definitions = json.data
	# Clear existing definitions
	
func get_all_item_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in floor_definitions.keys():
		ids.append(id)
	return ids
