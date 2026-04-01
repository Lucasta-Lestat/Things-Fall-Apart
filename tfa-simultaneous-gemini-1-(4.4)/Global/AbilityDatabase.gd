# AbilityDatabase.gd
# Autoload singleton — loads all abilities from JSON and provides fast lookup.
extends Node

var _abilities: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/Abilities.json"
	if not FileAccess.file_exists(file_path):
		push_error("AbilityDatabase: file not found at " + file_path)
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)

	if error == OK:
		var data = json.get_data()
		for entry in data.get("abilities", []):
			_abilities[entry["id"]] = entry
	else:
		push_error("AbilityDatabase: failed to parse JSON: " + json.get_error_message())

func get_ability_data(ability_id: String) -> Dictionary:
	if _abilities.has(ability_id):
		return _abilities[ability_id]
	push_error("AbilityDatabase: ability ID not found: " + ability_id)
	return {}
