# res://Structures/Structure.gd
# Attach this to a StaticBody2D scene for any destructible object.
extends StaticBody2D
class_name Structure

signal destroyed(structure, grid_position)

@export var structure_id: StringName

var current_health: int
var max_health: int
var size: Vector2
var resources: Dictionary = {} # e.g., {"wood": 20}
var damage_resistances: Dictionary = {}
var damage: Dictionary = {"Bludgeoning": 1} 

@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

func _ready():
	_apply_structure_data()
	# Snap to the grid
	
	var grid_pos = GridManager.world_to_map(global_position)
	global_position = GridManager.map_to_world(grid_pos)

func _apply_structure_data():
	var data = StructureDatabase.get_structure_data(structure_id)
	if not data:
		printerr("Failed to get data for structure_id: ", structure_id)
		return
		
	max_health = data.max_health
	current_health = max_health
	resources = data.resources.duplicate()
	sprite.texture = load(data.texture)
	size = data.size
	var initial_texture_size = sprite.texture.get_size()
	print("sprite size: ", sprite.texture.get_size())
	var size_ratio = .5 * size.x/initial_texture_size.x
	sprite.scale = Vector2(size_ratio,size_ratio)
func take_damage(amount: int):
	current_health = max(0, current_health - amount)
	print_rich(structure_id, " takes ", amount, " damage. Health: ", current_health, "/", max_health)
	
	# Optional: Add visual feedback (flash red, shake)
	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color.RED, 0.1)
	tween.tween_property(sprite, "modulate", Color.WHITE, 0.1)
	
	if current_health <= 0:
		_destroy_structure()

func _destroy_structure():
	# Notify the game world that this tile is now clear
	emit_signal("destroyed", self, GridManager.world_to_map(global_position))
	
	# TODO: Implement spawning the actual resource items
	print_rich(structure_id, " destroyed! Dropped: ", resources)
	
	queue_free()
