extends Node

signal map_definitions_loaded

# Dictionary to store all map definitions
var map_definitions: Dictionary = {}

# Path to the JSON file containing map definitions
var map_data_path: String = "res://data/Maps.json"

func _ready():
	load_map_definitions()

func load_map_definitions():
	var file = FileAccess.open(map_data_path, FileAccess.READ)
	if file == null:
		printerr("Error: Could not open map definitions file at: ", map_data_path)
		return
	
	var json_text = file.get_as_text()
	file.close()
	#print("json_text: ", json_text)
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	print("parsed_result: ", parse_result)
	if parse_result != OK:
		print("Error parsing JSON: ", json.get_error_message())
		return
	map_definitions.clear()

	map_definitions = json.data
	
func get_all_map_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in map_definitions.keys():
		ids.append(id)
	return ids
