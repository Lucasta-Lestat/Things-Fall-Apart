#AbilityDatabase.gd
extends Node
var _abilities: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/Abilities.json"
	if not FileAccess.file_exists(file_path):
		push_error("Ability Database not found at: " + file_path)
		return
		
	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)
	print("====== Ability list =======")
	if error == OK:
		var data = json.get_data()
		# Index abilities by ID for fast lookup
		#print("ability data: ")
		for entry in data.get("abilities", []):
			_abilities[entry["id"]] = entry
		#	print(_abilities[entry["id"]])
	else:
		push_error("Failed to parse Ability JSON: ", json.get_error_message())
	print(" 
	
	===== end Ability list")
func get_ability_data(ability_id: String) -> Dictionary:
	if _abilities.has(ability_id):
		return _abilities[ability_id]
	push_error("Ability ID not found: " + ability_id)
	return {}

func get_all_ability_ids() -> Array:
	return _abilities.keys()

# Full ability dicts. DowntimeEffectApplier._pick_random_unknown_spell has called
# this behind a has_method guard since it was written; the method never existed,
# so the guard always failed and the Research activity's "new_spell" outcome
# (learn_spell: "random_spell") silently did nothing. Returns copies so a caller
# filtering or sorting the pool can't mutate the database — get_ability_data
# hands out the live dict and that is already a sharp edge.
func get_all_abilities() -> Array:
	var out: Array = []
	for id in _abilities:
		out.append((_abilities[id] as Dictionary).duplicate(true))
	return out
