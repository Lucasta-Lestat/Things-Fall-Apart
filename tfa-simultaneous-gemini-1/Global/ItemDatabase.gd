# ItemDatabase.gd - Autoload singleton
# Add this to your project as an autoload named "ItemDatabase"
extends Node

signal item_definitions_loaded

# Dictionary to store all item definitions
var item_definitions: Dictionary = {}

# Path to the JSON file containing item definitions
var item_data_path: String = "res://data/items.json"

func _ready():
	load_item_definitions()

func load_item_definitions():
	var file = FileAccess.open(item_data_path, FileAccess.READ)
	if file == null:
		printerr("Error: Could not open item definitions file at: ", item_data_path)
		return
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	
	if parse_result != OK:
		print("Error parsing JSON: ", json.get_error_message())
		return
	#print("parse_result: ", parse_result)
	# Clear existing definitions
	item_definitions.clear()
	item_definitions = json.data
	#print("item_definitions: ", item_definitions)
	item_definitions_loaded.emit()

func get_item_definition(item_id: String) -> ItemDefinition:
	return item_definitions.get(item_id, null)

func has_item_definition(item_id: String) -> bool:
	return item_definitions.has(item_id)

func get_all_item_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in item_definitions.keys():
		ids.append(id)
	return ids

# ItemDefinition class to hold item data
class ItemDefinition:
	var id: String
	var name: String
	var description: String
	var icon_path: String
	var stackable: bool = false
	var max_stack: int = 1
	var rarity: String = "common"
