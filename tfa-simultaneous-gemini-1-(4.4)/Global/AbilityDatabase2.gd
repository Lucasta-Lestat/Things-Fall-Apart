extends Node
var _abilities: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/Abilities2.json"
	if not FileAccess.file_exists(file_path):
		push_error("Ability Database not found at: " + file_path)
		return
		
	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)
	
	if error == OK:
		var data = json.get_data()
		# Index abilities by ID for fast lookup
		for entry in data.get("abilities", []):
			_abilities[entry["id"]] = entry
	else:
		push_error("Failed to parse Ability JSON: ", json.get_error_message())

func get_ability_data(ability_id: String) -> Dictionary:
	if _abilities.has(ability_id):
		return _abilities[ability_id]
	push_error("Ability ID not found: " + ability_id)
	return {}
