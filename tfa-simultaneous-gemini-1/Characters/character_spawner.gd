# character_spawner.gd
# Attach to your main scene or a manager node
extends Node

const ProceduralCharacterScript = preload("res://Characters/ProceduralCharacter.gd")

@export var characters_json_path: String = "res://data/TopDownCharacters.json"
@export var spawn_container: Node2D  # Where to spawn characters

var characters_database: Array = []
var spawned_characters: Array = []

func _ready() -> void:
	load_characters_database()
	var character_1 = spawn_character_by_name("Default Human", Vector2(40.0,40.0))
	character_1.give_weapon({
		"name": "Steel Longsword",
		"type": "longsword",
		"damage_type": "slashing",
		"base_damage": 14,
		"blade_color": "#c0c0c0",
		"handle_color": "#2d2d2d",
		"accent_color": "#ffd700"
	})
	
	character_1.give_weapon({
		"name": "Battle Axe",
		"type": "axe",
		"damage_type": "slashing",
		"base_damage": 16,
		"blade_color": "#b0b0b0",
		"handle_color": "#4a3728",
		"accent_color": "#cd7f32"
	})
	
	character_1.give_weapon({
		"name": "War Spear",
		"type": "spear",
		"damage_type": "piercing",
		"base_damage": 15,
		"blade_color": "#c0c0c0",
		"handle_color": "#2d2d2d",
		"accent_color": "#b22222"
	})
	
	character_1.give_weapon({
		"name": "Iron Mace",
		"type": "mace",
		"damage_type": "bludgeoning",
		"base_damage": 13,
		"blade_color": "#696969",
		"handle_color": "#4a3728",
		"accent_color": "#808080"
	})
	
	# Give the character some equipment
	character_1.equip_equipment({
		"name": "Steel Helmet",
		"type": "helmet",
		"primary_color": "#808080",
		"secondary_color": "#606060",
		"detail_color": "#c0c0c0"
	})
	
	character_1.equip_equipment({
		"name": "Leather Backpack",
		"type": "backpack",
		"primary_color": "#8b4513",
		"secondary_color": "#5d4037",
		"detail_color": "#a1887f"
	})
	
	character_1.equip_equipment({
		"name": "Steel Pauldrons",
		"type": "shoulder_pads",
		"primary_color": "#9e9e9e",
		"secondary_color": "#757575",
		"detail_color": "#bdbdbd"
	})
	
	character_1.equip_equipment({
		"name": "Leather Pants",
		"type": "pants",
		"primary_color": "#5d4037",
		"secondary_color": "#3e2723",
		"detail_color": "#8d6e63"
	})
	
	character_1.equip_equipment({
		"name": "Leather Boots",
		"type": "boots",
		"primary_color": "#5d4037",
		"secondary_color": "#3e2723",
		"detail_color": "#8d6e63"
	})
func load_characters_database() -> void:
	if not FileAccess.file_exists(characters_json_path):
		push_warning("Characters JSON not found at: " + characters_json_path)
		return
	
	var file = FileAccess.open(characters_json_path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_text)
	
	if error != OK:
		push_error("Failed to parse characters JSON: " + json.get_error_message())
		return
	
	var data = json.get_data()
	if data is Dictionary and data.has("characters"):
		characters_database = data["characters"]
	elif data is Array:
		characters_database = data
	
	print("Loaded ", characters_database.size(), " character definitions")

func spawn_character_by_name(char_name: String, spawn_position: Vector2) -> ProceduralCharacter:
	for char_data in characters_database:
		if char_data.get("name", "") == char_name:
			return spawn_character(char_data, spawn_position)
	
	push_warning("Character not found: " + char_name)
	return null

func spawn_character_by_index(index: int, spawn_position: Vector2) -> ProceduralCharacter:
	if index < 0 or index >= characters_database.size():
		push_warning("Character index out of bounds: " + str(index))
		return null
	
	return spawn_character(characters_database[index], spawn_position)

func spawn_character(data: Dictionary, spawn_position: Vector2) -> ProceduralCharacter:
	var container = spawn_container if spawn_container else self
	
	# Create character node
	var character_node = Node2D.new()
	character_node.set_script(ProceduralCharacterScript)
	character_node.global_position = spawn_position
	
	container.add_child(character_node)
	
	# Load character data
	character_node.load_from_data(data)
	
	spawned_characters.append(character_node)
	
	print("Spawned character: ", data.get("name", "Unknown"))
	return character_node

func spawn_all_characters(spacing: float = 100.0) -> void:
	var start_x = -((characters_database.size() - 1) * spacing) / 2.0
	
	for i in range(characters_database.size()):
		var pos = Vector2(start_x + i * spacing, 0)
		spawn_character_by_index(i, pos)

func get_character_by_name(char_name: String) -> ProceduralCharacter:
	for character in spawned_characters:
		if character.character_data.get("name", "") == char_name:
			return character
	return null

func despawn_character(character: ProceduralCharacter) -> void:
	if character in spawned_characters:
		spawned_characters.erase(character)
		character.queue_free()

func despawn_all() -> void:
	for character in spawned_characters:
		character.queue_free()
	spawned_characters.clear()
