# res://Data/Structures/StructureDatabase.gd
#AUTOLOAD
# A database to define all types of structures in the game.
extends Node

# A simple data class for structure properties
class StructureData:
	var id: StringName
	var display_name: String
	var texture: String
	var size = Vector2(64,64)
	var max_health: int = 100
	var current_health: int = max_health
	var damage_resistances: Dictionary = {}
	var damage: Dictionary = {"Bludgeoning": 1} 
	var resources: Dictionary = {} # What resources it drops on destruction
	
	func _init(p_id, p_name, p_health, p_resources,p_size = size):
		var texture_path = "res://Structures/" + p_name + ".png"
		print("texture_path: ", texture_path, " #structures")
		id = p_id
		display_name = p_name
		texture = texture_path
		
		max_health = p_health
		current_health = max_health
		resources = p_resources
		size = p_size

var structure_data: Dictionary = {}

func _ready():
	_setup_structure_data()

	
func _setup_structure_data():
	# Define your structures here
	var wood_wall = StructureData.new(&"wood_wall", "Wooden Wall", 50, {&"wood": 20},Vector2(64,64))
	structure_data[&"wood_wall"] = wood_wall
	
	var pine_tree = StructureData.new(&"pine_tree", "Pine Tree", 80, {&"wood": 40}, Vector2(64,64))
	structure_data[&"oak_tree"] = pine_tree

func get_structure_data(structure_id: StringName) -> StructureData:
	if structure_data.has(structure_id):
		return structure_data[structure_id]
	else:
		print("Warning: Structure ID '", structure_id, "' not found in database #structures")
		return null
