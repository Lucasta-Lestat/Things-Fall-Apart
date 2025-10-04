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
var damage_resistances = {"slashing": 0, "bludgeoning": 0, "piercing": 0, "fire": 0, "cold": 0, "electric": 0, "sonic":0, "poison":0, "acid":0, "radiant":0, "necrotic":0 }
var damage: Dictionary = {"Bludgeoning": 1} 

@onready var floating_text_label: RichTextLabel = $FloatingTextLabel
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

func _ready():
	_apply_structure_data()
	# Snap to the grid
	floating_text_label.visible = false

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
	#structure_id = structure
	#print(data.texture, " applying structure data with texture ", sprite.texture, " ", data.texture)
	size = data.size
	#print(size, data.size, "texture size")
	#print
	var initial_texture_size = sprite.texture.get_size()
	#print("sprite size: ", sprite.texture.get_size())
	var size_ratio =  size.x/initial_texture_size.x
	sprite.scale = Vector2(size_ratio,size_ratio)
	
func take_damage(amount: Dictionary, success_level:int = 0):
	var damage_multiplier = pow(1.5,success_level)

	for damage_type in amount.keys():
		current_health = max(0, current_health - (amount[damage_type]*damage_multiplier - self.damage_resistances[damage_type]))
		print_rich(name, " takes ", amount[damage_type], damage_type,  " damage.", "crit tier:", success_level, " Health: ", current_health, "/", max_health)
		if damage_type == "fire": 
			show_floating_text(str(amount[damage_type]), Color.CRIMSON, success_level)
		elif damage_type == "electric":
			show_floating_text(str(amount[damage_type]), Color.YELLOW, success_level)
		elif damage_type == "cold":
			show_floating_text(str(amount[damage_type]), Color.ALICE_BLUE, success_level)
		elif damage_type == "acid":
			show_floating_text(str(amount[damage_type]), Color.DARK_GREEN, success_level)
		elif damage_type == "radiant":
			show_floating_text(str(amount[damage_type]), Color.LIGHT_GOLDENROD, success_level)
		elif damage_type == "necrotic":
			show_floating_text(str(amount[damage_type]), Color.BLACK, success_level)
		elif damage_type == "poison":
			show_floating_text(str(amount[damage_type]), Color.BLUE_VIOLET, success_level)
		else:
			show_floating_text(str(amount[damage_type]), Color.WHITE_SMOKE, success_level)
			
	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color.RED, 0.1)
	tween.tween_property(sprite, "modulate", Color.WHITE, 0.1)
	
	emit_signal("health_changed", current_health, max_health, self)
	
	if current_health <= 0:
		emit_signal("died", self); sprite.visible = false; $CollisionShape2D.disabled = true

func show_floating_text(text: String, color: Color = Color.WHITE, success_level = 0):
	var formatted_text = "[b]" + text + "[/b]" if success_level else text
	floating_text_label.text = formatted_text; floating_text_label.modulate = color
	# Make critical hit text bigger too
	var scale_multiplier = 1.3 * success_level if success_level else 1.0
	floating_text_label.scale = Vector2(scale_multiplier, scale_multiplier)
	
	floating_text_label.visible = true
	
	var tween = create_tween().set_parallel()
	tween.tween_property(floating_text_label, "position", Vector2(0, -70), 0.9).from(Vector2(0, -40))
	tween.tween_property(floating_text_label, "modulate:a", 0.0, 0.9)
	tween.chain().tween_callback(func(): floating_text_label.visible = false)
	
func _destroy_structure():
	# Notify the game world that this tile is now clear
	emit_signal("destroyed", self, GridManager.world_to_map(global_position))
	
	# TODO: Implement spawning the actual resource items
	print_rich(structure_id, " destroyed! Dropped: ", resources)
	
	queue_free()

func change_texture(texture_path):
	#print("attempting to update structure texture with: ", texture_path)
	$Sprite.texture = load(texture_path)
	
func scale_sprite(new_size):
	var initial_texture_size = sprite.texture.get_size()
	var size_ratio = size.x/initial_texture_size.x
	sprite.scale = Vector2(size_ratio,size_ratio)
