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
	var flammable: bool = false
	# Player-facing name (hover readout). display_name can't serve: it builds
	# the texture path ("Wall Stone" -> Wall Stone.png).
	var label: String = ""

	func _init(p_id, p_name, p_health, p_resources, p_size = size, p_flammable: bool = false):
		var texture_path = "res://Structures/" + p_name + ".png"
		print("texture_path: ", texture_path, " #structures")
		id = p_id
		display_name = p_name
		texture = texture_path

		max_health = p_health
		current_health = max_health
		resources = p_resources
		size = p_size
		flammable = p_flammable

var structure_data: Dictionary = {}

func _ready():
	_setup_structure_data()

	
func _setup_structure_data():
	# Define your structures here
	var wood_wall = StructureData.new(&"wood_wall", "Wall Wood", 50, {&"wood": 20}, Vector2(64,128), true)
	structure_data[&"wood_wall"] = wood_wall

	var stone_wall = StructureData.new(&"stone_wall", "Wall Stone", 80, {&"stone": 20}, Vector2(64,128), false)
	structure_data[&"stone_wall"] = stone_wall

	var tree = StructureData.new(&"tree", "Tree", 80, {&"wood": 40}, Vector2(75,75), true)
	structure_data[&"tree"] = tree

	# Trimmed garden/skylight hedge shrub (TG export contract 2: "tree" rows with
	# id "hedge" and occlude_h 0.45). Blocks movement like a tree; its occlude_h
	# is below EYE_HEIGHT_STORIES, so MapLoader gives it no cone shadow and eyes
	# see over it. Rows carry their own hp (TG: half a tree).
	var hedge = StructureData.new(&"hedge", "Hedge", 40, {&"wood": 10}, Vector2(48,48), true)
	structure_data[&"hedge"] = hedge

	var wood_door = StructureData.new(&"door_wood", "Door Wood", 50, {&"wood": 10}, Vector2(64,128), true)
	structure_data[&"door_wood"] = wood_door
	
	wood_wall.label = "Wooden wall"
	stone_wall.label = "Stone wall"
	tree.label = "Tree"
	hedge.label = "Hedge"
	wood_door.label = "Wooden door"
	

## A set-piece item spawned as a Structure (MapLoader.spawn_prop_structure:
## Items.json entries with a "structure" block). Its art comes from the item's
## sprite, so the texture path StructureData builds is never loaded.
func register_prop(prop_id: StringName, label: String, hp: int, flammable: bool) -> void:
	if structure_data.has(prop_id):
		return
	var d := StructureData.new(prop_id, String(prop_id), hp, {}, Vector2(64, 64), flammable)
	d.label = label
	structure_data[prop_id] = d

func get_structure_data(structure_id: StringName) -> StructureData:
	if structure_data.has(structure_id):
		return structure_data[structure_id]
	else:
		print("Warning: Structure ID '", structure_id, "' not found in database #structures")
		return null

## Player-facing structure name. Quiet on a miss (unlike get_structure_data),
## so the hover readout can ask every frame: unknown ids read from the id.
func get_structure_label(structure_id: StringName) -> String:
	var d = structure_data.get(structure_id)
	if d != null and d.label != "":
		return d.label
	return String(structure_id).replace("_", " ").capitalize()
