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
	
	var data = json.data
	# Clear existing definitions
	item_definitions.clear()
	
	# Load each item definition
	for item_data in data:
		if not item_data.has("id"):
			print("Warning: Item definition missing 'id' field, skipping")
			continue
		
		var item_def = ItemDefinition.new()
		item_def.id = item_data.id
		item_def.name = item_data.get("name", "Unknown Item")
		item_def.description = item_data.get("description", "")
		item_def.icon_path = item_data.get("icon_path", "")
		item_def.stackable = item_data.get("stackable", false)
		item_def.max_stack = item_data.get("max_stack", 1)
		item_def.rarity = item_data.get("rarity", "common")
		
		item_definitions[item_def.id] = item_def
	
	print("Loaded ", item_definitions.size(), " item definitions")
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
